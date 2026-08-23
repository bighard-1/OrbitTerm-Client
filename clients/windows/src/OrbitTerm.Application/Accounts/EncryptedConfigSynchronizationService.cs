using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

public sealed record EncryptedAssetSyncMetadata(
    ulong? RemoteId,
    string VectorClock,
    string State,
    ulong ServerRevision,
    bool HasCredentialMaterial = false,
    bool HasJumpHostCredentialMaterial = false);

/// <summary>Non-secret cursor for the single encrypted Snippets envelope.</summary>
public sealed record EncryptedSnippetSyncMetadata(ulong? RemoteId, string VectorClock, long EnvelopeTime);

public enum PendingAssetSyncOperationKind
{
    Upsert,
    Tombstone,
    Conflict,
}

/// <summary>
/// A durable, DPAPI-protected intent.  It contains no credential material: the
/// credential vault remains the sole persistence location for passwords and keys.
/// </summary>
public sealed record PendingAssetSyncOperation(
    PendingAssetSyncOperationKind Kind,
    string? BaseVectorClock,
    long QueuedAtUnix,
    IReadOnlyList<string>? ConflictingFields = null);

/// <summary>Last confirmed asset shape plus a one-way credential fingerprint.</summary>
public sealed record AssetSyncSnapshot(
    ServerAssetRecord Record,
    string CredentialFingerprint,
    string? JumpHostCredentialFingerprint = null);

/// <summary>Per-account cursor, stable device identity and non-secret remote metadata.</summary>
public sealed record EncryptedSyncState(
    Guid DeviceId,
    ulong Cursor,
    IReadOnlyDictionary<Guid, EncryptedAssetSyncMetadata>? Assets = null,
    IReadOnlyDictionary<Guid, PendingAssetSyncOperation>? PendingOperations = null,
    IReadOnlyDictionary<Guid, AssetSyncSnapshot>? Snapshots = null,
    EncryptedSnippetSyncMetadata? SnippetMetadata = null,
    EncryptedSshKeySyncMetadata? SshKeyMetadata = null,
    EncryptedPortForwardProfileSyncMetadata? PortForwardProfileMetadata = null);

public interface IEncryptedSyncStateStore
{
    ValueTask<EncryptedSyncState?> ReadAsync(string accountScope, CancellationToken cancellationToken);
    ValueTask SaveAsync(string accountScope, EncryptedSyncState state, CancellationToken cancellationToken);
}

public sealed class NullEncryptedSyncStateStore : IEncryptedSyncStateStore
{
    private readonly Dictionary<string, EncryptedSyncState> states = new(StringComparer.Ordinal);
    public ValueTask<EncryptedSyncState?> ReadAsync(string accountScope, CancellationToken cancellationToken) =>
        ValueTask.FromResult(states.TryGetValue(accountScope, out var state) ? state : null);
    public ValueTask SaveAsync(string accountScope, EncryptedSyncState state, CancellationToken cancellationToken)
    {
        states[accountScope] = state;
        return ValueTask.CompletedTask;
    }
}

public enum EncryptedConfigSynchronizationStatus
{
    Completed,
    UnsupportedConfiguration,
}

/// <summary>Only a completed result has been applied, acknowledged, and cursor-persisted.</summary>
public sealed record EncryptedConfigSynchronizationResult(
    EncryptedConfigSynchronizationStatus Status,
    AccountSessionRecord Session,
    int AddedAssets,
    int UpdatedAssets,
    int DeletedAssets,
    int ConflictedAssets,
    int AppliedSnippets,
    int AcknowledgedPages,
    int ConflictedSnippets = 0,
    int AppliedSshKeys = 0,
    int DeletedSshKeys = 0,
    int ConflictedSshKeys = 0,
    int AppliedPortForwardProfiles = 0,
    int DeletedPortForwardProfiles = 0,
    int ConflictedPortForwardProfiles = 0);

public interface IEncryptedConfigSynchronizer
{
    ValueTask<EncryptedConfigSynchronizationResult> SynchronizeAsync(
        AccountSessionRecord session,
        string accountScope,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken,
        bool forceCompleteReconciliation = false);
}

/// <summary>
/// Applies only configurations understood by this client. Each page is decrypted and
/// validated before local writes; acknowledgement and cursor persistence happen only
/// after those writes succeed.
/// </summary>
public sealed class EncryptedConfigSynchronizationService(
    IOrbitEncryptedSyncProtocol protocol,
    IServerAssetStore assetStore,
    ISnippetStore snippetStore,
    ICredentialVault credentialVault,
    IEncryptedSyncStateStore stateStore,
    SshKeyLibraryService? sshKeyLibrary = null,
    bool enforceCorePrivateKeyValidation = false,
    PortForwardProfileLibrary? portForwardProfileLibrary = null) : IEncryptedConfigSynchronizer
{
    private const int PageSize = 100;
    private const string SnippetMarker = "orbit_snippets";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async ValueTask<EncryptedConfigSynchronizationResult> SynchronizeAsync(
        AccountSessionRecord session,
        string accountScope,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken,
        bool forceCompleteReconciliation = false)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentException.ThrowIfNullOrWhiteSpace(accountScope);
        ArgumentException.ThrowIfNullOrWhiteSpace(masterPassword);
        ArgumentNullException.ThrowIfNull(rootKey);
        if (rootKey.Length != 32) throw new ArgumentException("同步根密钥长度无效。", nameof(rootKey));

        var state = await stateStore.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false)
            ?? new EncryptedSyncState(Guid.NewGuid(), 0);
        if (state.DeviceId == Guid.Empty) state = state with { DeviceId = Guid.NewGuid() };
        var assetMetadata = state.Assets?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var pendingOperations = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var snapshots = state.Snapshots?.ToDictionary(item => item.Key, item => item.Value) ?? [];

        var assets = (await assetStore.LoadAsync(cancellationToken).ConfigureAwait(false))
            .ToDictionary(asset => asset.Id);
        var snippets = (await snippetStore.LoadAsync(cancellationToken).ConfigureAwait(false)).ToArray();
        var currentSession = session;
        // An explicit user reconciliation must replay the complete change
        // history.  A cursor written by an older client can legally sit beyond
        // a historical tombstone; continuing from that cursor would leave a
        // stale local asset visible forever. Automatic background refreshes
        // keep using the durable cursor and remain inexpensive.
        var cursor = forceCompleteReconciliation ? 0UL : state.Cursor;
        var resetAttempted = false;
        var added = 0;
        var updated = 0;
        var deleted = 0;
        var conflicted = 0;
        var appliedSnippets = 0;
        var conflictedSnippets = 0;
        var appliedSshKeys = 0;
        var deletedSshKeys = 0;
        var conflictedSshKeys = 0;
        var appliedPortForwardProfiles = 0;
        var deletedPortForwardProfiles = 0;
        var conflictedPortForwardProfiles = 0;
        var acknowledgedPages = 0;
        var sshKeySync = sshKeyLibrary is null ? null : new EncryptedSshKeySynchronization(sshKeyLibrary);
        var portForwardSync = portForwardProfileLibrary is null
            ? null
            : new EncryptedPortForwardProfileSynchronization(portForwardProfileLibrary);

        while (true)
        {
            var pull = await protocol.PullChangesAsync(currentSession, cursor, PageSize, cancellationToken).ConfigureAwait(false);
            currentSession = pull.Session;
            var page = pull.Value;
            if (page.ResetRequired)
            {
                if (resetAttempted)
                {
                    throw new InvalidDataException("同步游标连续失效，未确认任何新变更。");
                }

                cursor = 0;
                resetAttempted = true;
                continue;
            }

            var pagePlan = PreparePage(
                page.Items,
                masterPassword,
                rootKey,
                accountScope,
                enforceCorePrivateKeyValidation);
            if (pagePlan.Unsupported)
            {
                return new EncryptedConfigSynchronizationResult(
                    EncryptedConfigSynchronizationStatus.UnsupportedConfiguration,
                    currentSession,
                    added,
                    updated,
                    deleted,
                    conflicted,
                    appliedSnippets,
                    acknowledgedPages);
            }

            foreach (var deletion in pagePlan.DeletedAssetIds)
            {
                if (pendingOperations.TryGetValue(deletion, out var pending) &&
                    pending.Kind == PendingAssetSyncOperationKind.Upsert)
                {
                    // Delete versus edit is inherently overlapping.  Keep the local
                    // edit and surface it as a decision, rather than resurrecting
                    // remotely or discarding it without notice.
                    pendingOperations[deletion] = pending with
                    {
                        Kind = PendingAssetSyncOperationKind.Conflict,
                        ConflictingFields = ["删除与本机编辑"],
                    };
                    conflicted++;
                    continue;
                }

                assetMetadata.Remove(deletion);
                snapshots.Remove(deletion);
                pendingOperations.Remove(deletion);
                if (assets.Remove(deletion, out var removed))
                {
                    await credentialVault.DeleteAsync(removed.CredentialId, cancellationToken).ConfigureAwait(false);
                    if (removed.JumpHost is { } removedJump)
                    {
                        await credentialVault.DeleteAsync(removedJump.CredentialId, cancellationToken).ConfigureAwait(false);
                    }
                    deleted++;
                }
            }

            foreach (var asset in pagePlan.ActiveAssets)
            {
                if (pendingOperations.TryGetValue(asset.Record.Id, out var pending))
                {
                    if (pending.Kind == PendingAssetSyncOperationKind.Tombstone)
                    {
                        // A local deletion wins over a concurrently observed active
                        // version.  Keep the tombstone intent and refresh the vector
                        // metadata so the subsequent delete is based on this version.
                        assetMetadata[asset.Record.Id] = asset.Metadata;
                        snapshots[asset.Record.Id] = Snapshot(asset.Record, asset.Credential, asset.JumpHostCredential);
                        continue;
                    }

                    if (pending.Kind == PendingAssetSyncOperationKind.Conflict)
                    {
                        // A conflict is deliberately sticky until the user edits the
                        // asset again or a dedicated conflict UI resolves it.
                        continue;
                    }

                    if (assets.TryGetValue(asset.Record.Id, out var localRecord))
                    {
                        var localCredential = await credentialVault.ReadAsync(localRecord.CredentialId, cancellationToken).ConfigureAwait(false);
                        var localJumpCredential = localRecord.JumpHost is { } localJump
                            ? await credentialVault.ReadAsync(localJump.CredentialId, cancellationToken).ConfigureAwait(false)
                            : null;
                        if (!TryMergePendingAsset(
                                snapshots.GetValueOrDefault(asset.Record.Id),
                                localRecord,
                                localCredential,
                                localJumpCredential,
                                asset,
                                out var mergedRecord,
                                out var mergedCredential,
                                out var mergedJumpCredential,
                                out var conflictingFields))
                        {
                            pendingOperations[asset.Record.Id] = pending with
                            {
                                Kind = PendingAssetSyncOperationKind.Conflict,
                                ConflictingFields = conflictingFields,
                            };
                            assetMetadata[asset.Record.Id] = asset.Metadata;
                            snapshots[asset.Record.Id] = Snapshot(asset.Record, asset.Credential, asset.JumpHostCredential);
                            conflicted++;
                            continue;
                        }

                        if (mergedRecord != localRecord) updated++;
                        if (mergedCredential.IsEmpty)
                        {
                            await credentialVault.DeleteAsync(mergedRecord.CredentialId, cancellationToken).ConfigureAwait(false);
                        }
                        else
                        {
                            await credentialVault.SaveAsync(mergedRecord.CredentialId, mergedCredential, cancellationToken).ConfigureAwait(false);
                        }
                        if (mergedRecord.JumpHost is { } mergedJump && mergedJumpCredential is { IsEmpty: false })
                        {
                            await credentialVault.SaveAsync(mergedJump.CredentialId, mergedJumpCredential, cancellationToken).ConfigureAwait(false);
                        }
                        if (localRecord.JumpHost is { } priorJump &&
                            mergedRecord.JumpHost?.CredentialId != priorJump.CredentialId)
                        {
                            await credentialVault.DeleteAsync(priorJump.CredentialId, cancellationToken).ConfigureAwait(false);
                        }

                        assets[mergedRecord.Id] = mergedRecord;
                        assetMetadata[mergedRecord.Id] = asset.Metadata;
                        // Preserve the confirmed remote snapshot as the base for the
                        // queued merged upload; do not silently mark it as published.
                        snapshots[mergedRecord.Id] = Snapshot(asset.Record, asset.Credential, asset.JumpHostCredential);
                        continue;
                    }
                }

                if (assets.TryGetValue(asset.Record.Id, out var previous))
                {
                    if (previous != asset.Record)
                    {
                        updated++;
                    }

                    if (previous.CredentialId != asset.Record.CredentialId)
                    {
                        await credentialVault.DeleteAsync(previous.CredentialId, cancellationToken).ConfigureAwait(false);
                    }
                    if (previous.JumpHost is { } previousJump &&
                        asset.Record.JumpHost?.CredentialId != previousJump.CredentialId)
                    {
                        await credentialVault.DeleteAsync(previousJump.CredentialId, cancellationToken).ConfigureAwait(false);
                    }
                }
                else
                {
                    added++;
                }

                if (asset.Credential.IsEmpty)
                {
                    await credentialVault.DeleteAsync(asset.Record.CredentialId, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await credentialVault.SaveAsync(asset.Record.CredentialId, asset.Credential, cancellationToken).ConfigureAwait(false);
                }
                if (asset.Record.JumpHost is { } jumpHost && asset.JumpHostCredential is { IsEmpty: false } jumpCredential)
                {
                    await credentialVault.SaveAsync(jumpHost.CredentialId, jumpCredential, cancellationToken).ConfigureAwait(false);
                }

                assets[asset.Record.Id] = asset.Record;
                assetMetadata[asset.Record.Id] = asset.Metadata;
                snapshots[asset.Record.Id] = Snapshot(asset.Record, asset.Credential, asset.JumpHostCredential);
            }

            if (pagePlan.ActiveAssets.Count > 0 || pagePlan.DeletedAssetIds.Count > 0)
            {
                await assetStore.SaveAsync(assets.Values.OrderBy(asset => asset.Id).ToArray(), cancellationToken).ConfigureAwait(false);
            }

            if (pagePlan.SnippetEnvelope is { } envelope && ShouldApplySnippetEnvelope(envelope, snippets))
            {
                snippets = envelope.Snippets;
                await snippetStore.SaveAsync(snippets, cancellationToken).ConfigureAwait(false);
                appliedSnippets += snippets.Length;
            }
            else if (pagePlan.SnippetEnvelope is not null)
            {
                // Keep newer local work intact and make the pending decision visible.
                conflictedSnippets++;
            }

            if (pagePlan.SshKeyEnvelope is { } keyEnvelope && sshKeySync is not null)
            {
                var merge = await sshKeySync.ApplyAsync(
                    keyEnvelope,
                    state.SshKeyMetadata,
                    accountScope,
                    cancellationToken).ConfigureAwait(false);
                appliedSshKeys += merge.Applied;
                deletedSshKeys += merge.Deleted;
                conflictedSshKeys += merge.Conflicted;
                state = state with { SshKeyMetadata = merge.Metadata };
            }

            if (pagePlan.PortForwardProfileEnvelope is { } profileEnvelope && portForwardSync is not null)
            {
                var merge = await portForwardSync.ApplyAsync(profileEnvelope, accountScope, cancellationToken).ConfigureAwait(false);
                appliedPortForwardProfiles += merge.Applied;
                deletedPortForwardProfiles += merge.Deleted;
                conflictedPortForwardProfiles += merge.Conflicted;
                state = state with { PortForwardProfileMetadata = merge.Metadata };
            }

            if (sshKeyLibrary is not null)
            {
                var assignments = await sshKeyLibrary.ReconcileSynchronizedAssignmentsAsync(
                    assets.Values.ToArray(),
                    accountScope,
                    cancellationToken).ConfigureAwait(false);
                conflictedSshKeys += assignments.Conflicted;
            }

            var acknowledgement = await protocol.AcknowledgeAsync(
                currentSession,
                new SyncAcknowledgement(state.DeviceId, page.NextCursor, "windows", ClientVersion()),
                cancellationToken).ConfigureAwait(false);
            currentSession = acknowledgement.Session;
            cursor = page.NextCursor;
            state = state with
            {
                Cursor = cursor,
                Assets = assetMetadata,
                PendingOperations = pendingOperations,
                Snapshots = snapshots,
                SnippetMetadata = pagePlan.SnippetEnvelope is { } snippetEnvelope
                    ? new EncryptedSnippetSyncMetadata(
                        snippetEnvelope.RemoteId,
                        snippetEnvelope.VectorClock,
                        snippetEnvelope.UpdatedAtUnix)
                    : state.SnippetMetadata,
            };
            await stateStore.SaveAsync(accountScope, state, cancellationToken).ConfigureAwait(false);
            acknowledgedPages++;

            if (!page.HasMore) break;
        }


        if (sshKeySync is not null)
        {
            var local = await sshKeySync.BuildLocalEnvelopeAsync(state.SshKeyMetadata, accountScope, cancellationToken).ConfigureAwait(false);
            var shouldPublish = local.Envelope.Keys.Length > 0 ||
                local.Envelope.Tombstones.Length > 0 ||
                state.SshKeyMetadata?.RemoteId is not null;
            // A same-ID local-only record or duplicate material is a real user
            // decision. Never overwrite the remote envelope while such a
            // conflict is unresolved; report it and retry after the user has
            // made the local scope/library unambiguous.
            if (shouldPublish && conflictedSshKeys == 0 && !string.Equals(
                    local.Fingerprint,
                    state.SshKeyMetadata?.PayloadFingerprint,
                    StringComparison.Ordinal))
            {
                var plaintext = EncryptedSshKeySynchronization.Serialize(local.Envelope);
                byte[] encrypted = [];
                try
                {
                    // Keep the deployed cross-platform V1 writer until the
                    // capability handshake allows every client to emit OTC2.
                    encrypted = OrbitConfigCrypto.EncryptConfigLegacy(masterPassword, plaintext);
                    var uploaded = await protocol.UploadAsync(
                        currentSession,
                        new EncryptedConfigUpload(
                            state.SshKeyMetadata?.RemoteId,
                            null,
                            null,
                            Convert.ToBase64String(encrypted),
                            BumpSshKeyVectorClock(state.SshKeyMetadata?.VectorClock)),
                        cancellationToken).ConfigureAwait(false);
                    currentSession = uploaded.Session;
                    state = state with
                    {
                        SshKeyMetadata = new EncryptedSshKeySyncMetadata(
                            uploaded.Value.Id,
                            uploaded.Value.VectorClock,
                            local.Envelope.UpdatedAtUnix,
                            local.Fingerprint,
                            EncryptedSshKeySynchronization.KnownKeys(local.Envelope),
                            local.Envelope.Tombstones.ToDictionary(item => item.Id, item => item.DeletedAtUnix)),
                    };
                    await stateStore.SaveAsync(accountScope, state, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(plaintext);
                    CryptographicOperations.ZeroMemory(encrypted);
                }
            }
        }

        if (portForwardSync is not null)
        {
            var local = await portForwardSync.BuildLocalEnvelopeAsync(
                accountScope, state.PortForwardProfileMetadata, cancellationToken).ConfigureAwait(false);
            var shouldPublish = local.Envelope.Profiles.Length > 0 || local.Envelope.Tombstones.Length > 0 ||
                state.PortForwardProfileMetadata?.RemoteId is not null;
            if (shouldPublish && conflictedPortForwardProfiles == 0 && !string.Equals(
                    local.Fingerprint, state.PortForwardProfileMetadata?.PayloadFingerprint, StringComparison.Ordinal))
            {
                var plaintext = PortForwardProfileSyncContract.Serialize(local.Envelope);
                byte[] encrypted = [];
                try
                {
                    encrypted = OrbitConfigCrypto.EncryptConfigLegacy(masterPassword, plaintext);
                    var uploaded = await protocol.UploadAsync(
                        currentSession,
                        new EncryptedConfigUpload(
                            state.PortForwardProfileMetadata?.RemoteId,
                            null,
                            null,
                            Convert.ToBase64String(encrypted),
                            BumpVectorClock(state.PortForwardProfileMetadata?.VectorClock, "port_forward_client")),
                        cancellationToken).ConfigureAwait(false);
                    currentSession = uploaded.Session;
                    state = state with
                    {
                        PortForwardProfileMetadata = new(
                            uploaded.Value.Id,
                            uploaded.Value.VectorClock,
                            local.Envelope.UpdatedAtUnix,
                            local.Fingerprint),
                    };
                    await stateStore.SaveAsync(accountScope, state, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(plaintext);
                    CryptographicOperations.ZeroMemory(encrypted);
                }
            }
        }

        return new EncryptedConfigSynchronizationResult(
            EncryptedConfigSynchronizationStatus.Completed,
            currentSession,
            added,
            updated,
            deleted,
            conflicted,
            appliedSnippets,
            acknowledgedPages,
            conflictedSnippets,
            appliedSshKeys,
            deletedSshKeys,
            conflictedSshKeys,
            appliedPortForwardProfiles,
            deletedPortForwardProfiles,
            conflictedPortForwardProfiles);
    }

    private static SyncPagePlan PreparePage(
        IReadOnlyList<EncryptedConfigRecord> items,
        string masterPassword,
        byte[] rootKey,
        string accountScope,
        bool validatePrivateKeys)
    {
        var assets = new List<PortableAsset>();
        var deletions = new HashSet<Guid>();
        SnippetEnvelope? latestSnippetEnvelope = null;
        SshKeySyncEnvelope? latestSshKeyEnvelope = null;
        PortForwardProfileSyncEnvelope? latestPortForwardProfileEnvelope = null;

        foreach (var item in items)
        {
            if (!string.Equals(item.State, "active", StringComparison.OrdinalIgnoreCase) && item.State is not null)
            {
                if (Guid.TryParse(item.AssetId, out var deletedAssetId))
                {
                    deletions.Add(deletedAssetId);
                    continue;
                }

                return SyncPagePlan.UnsupportedPlan;
            }

            byte[]? plaintext = null;
            try
            {
                plaintext = Decrypt(item.EncryptedBlobBase64, masterPassword, rootKey);
                using var document = JsonDocument.Parse(plaintext);
                if (document.RootElement.TryGetProperty("kind", out var kind) &&
                    string.Equals(kind.GetString(), SnippetMarker, StringComparison.Ordinal))
                {
                    var envelope = TryParseSnippetEnvelope(document.RootElement);
                    if (!IsValid(envelope)) return SyncPagePlan.UnsupportedPlan;
                    envelope = envelope! with { RemoteId = item.Id, VectorClock = item.VectorClock };
                    if (latestSnippetEnvelope is null || envelope!.UpdatedAtUnix > latestSnippetEnvelope.UpdatedAtUnix)
                    {
                        latestSnippetEnvelope = envelope;
                    }

                    continue;
                }

                if (document.RootElement.TryGetProperty("kind", out kind) &&
                    string.Equals(kind.GetString(), EncryptedSshKeySynchronization.Marker, StringComparison.Ordinal))
                {
                    var envelope = EncryptedSshKeySynchronization.Parse(document.RootElement, item.Id, item.VectorClock);
                    if (envelope is null) return SyncPagePlan.UnsupportedPlan;
                    if (latestSshKeyEnvelope is null || envelope.UpdatedAtUnix > latestSshKeyEnvelope.UpdatedAtUnix)
                    {
                        latestSshKeyEnvelope = envelope;
                    }
                    continue;
                }

                if (document.RootElement.TryGetProperty("kind", out kind) &&
                    string.Equals(kind.GetString(), PortForwardProfileSyncContract.Marker, StringComparison.Ordinal))
                {
                    var envelope = PortForwardProfileSyncContract.Parse(document.RootElement);
                    if (envelope is null) return SyncPagePlan.UnsupportedPlan;
                    envelope = envelope with { RemoteId = item.Id, VectorClock = item.VectorClock };
                    if (latestPortForwardProfileEnvelope is null || envelope.UpdatedAtUnix > latestPortForwardProfileEnvelope.UpdatedAtUnix)
                        latestPortForwardProfileEnvelope = envelope;
                    continue;
                }

                var portable = JsonSerializer.Deserialize<PortableServerConfig>(plaintext, JsonOptions);
                if (!TryCreateAsset(portable, item, accountScope, validatePrivateKeys, out var asset)) return SyncPagePlan.UnsupportedPlan;
                assets.Add(asset!);
            }
            catch (JsonException)
            {
                return SyncPagePlan.UnsupportedPlan;
            }
            catch (FormatException)
            {
                return SyncPagePlan.UnsupportedPlan;
            }
            catch (OrbitNativeException)
            {
                return SyncPagePlan.UnsupportedPlan;
            }
            finally
            {
                if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
            }
        }

        // A full pull can contain the last active record and a later trash
        // record for the same logical asset. Deletion is authoritative within
        // that snapshot regardless of record order; never re-add the active
        // copy after applying its tombstone.
        assets.RemoveAll(asset => deletions.Contains(asset.Record.Id));
        return new SyncPagePlan(assets, deletions, latestSnippetEnvelope, latestSshKeyEnvelope, latestPortForwardProfileEnvelope, false);
    }

    private static byte[] Decrypt(string encryptedBlobBase64, string masterPassword, byte[] rootKey)
    {
        var encrypted = Convert.FromBase64String(encryptedBlobBase64);
        try
        {
            return IsV2(encrypted)
                ? OrbitConfigCrypto.DecryptConfigV2(rootKey, encrypted)
                : OrbitConfigCrypto.DecryptConfigLegacy(masterPassword, encrypted);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
        }
    }

    private static bool TryCreateAsset(
        PortableServerConfig? portable,
        EncryptedConfigRecord remote,
        string accountScope,
        bool validatePrivateKeys,
        out PortableAsset? asset)
    {
        asset = null;
        if (portable is null ||
            !Guid.TryParse(portable.Id, out var id) ||
            !Guid.TryParse(portable.CredentialId, out var credentialId) ||
            (remote.AssetId is not null && (!Guid.TryParse(remote.AssetId, out var remoteId) || remoteId != id)) ||
            string.IsNullOrWhiteSpace(portable.Name) ||
            string.IsNullOrWhiteSpace(portable.Host) ||
            string.IsNullOrWhiteSpace(portable.Username) ||
            portable.Port is <= 0 or > 65535 ||
            !TryParseTransport(portable.Transport, out var transport))
        {
            return false;
        }

        JumpHostRecord? jumpHost = null;
        CredentialMaterial? jumpHostCredential = null;
        if (portable.JumpHost is { } portableJump)
        {
            if (transport != ServerTransport.Ssh ||
                !Guid.TryParse(portableJump.CredentialId, out var jumpCredentialId) ||
                jumpCredentialId == credentialId ||
                string.IsNullOrWhiteSpace(portableJump.Host) ||
                string.IsNullOrWhiteSpace(portableJump.Username) ||
                portableJump.Port is <= 0 or > 65535 ||
                !TryParseAuthMethod(portableJump.AuthMethod) ||
                (string.IsNullOrWhiteSpace(portableJump.Password) &&
                 string.IsNullOrWhiteSpace(portableJump.PrivateKeyContent)))
            {
                return false;
            }

            jumpHost = new JumpHostRecord(
                jumpCredentialId,
                portableJump.Host,
                portableJump.Port,
                portableJump.Username,
                portableJump.AllowPasswordFallback);
            jumpHostCredential = new CredentialMaterial(
                portableJump.Password ?? string.Empty,
                portableJump.PrivateKeyContent ?? string.Empty,
                portableJump.PrivateKeyPassphrase ?? string.Empty);
        }

        var record = new ServerAssetRecord(
            id,
            credentialId,
            portable.Name,
            portable.Host,
            portable.Port,
            portable.Username,
            transport,
            portable.AllowPasswordFallback,
            string.IsNullOrWhiteSpace(portable.Group) ? "未分组" : portable.Group,
            portable.Tags ?? [],
            jumpHost,
            AssetStorageScope.AccountSynced,
            accountScope);
        CredentialMaterial credential;
        try
        {
            credential = CredentialMaterialPolicy.NormalizeSshCredential(new CredentialMaterial(
                portable.Password ?? string.Empty,
                portable.PrivateKeyContent ?? string.Empty,
                portable.PrivateKeyPassphrase ?? string.Empty));
            if (jumpHostCredential is not null)
            {
                jumpHostCredential = CredentialMaterialPolicy.NormalizeSshCredential(jumpHostCredential);
            }
            if (validatePrivateKeys && !string.IsNullOrWhiteSpace(credential.PrivateKey))
            {
                _ = SshPrivateKeyInspector.Inspect(credential.PrivateKey, credential.PrivateKeyPassphrase);
            }
            if (validatePrivateKeys && jumpHostCredential is { PrivateKey.Length: > 0 })
            {
                _ = SshPrivateKeyInspector.Inspect(
                    jumpHostCredential.PrivateKey,
                    jumpHostCredential.PrivateKeyPassphrase);
            }
        }
        catch (ArgumentException)
        {
            return false;
        }

        asset = new PortableAsset(
            record,
            credential,
            new EncryptedAssetSyncMetadata(
                remote.Id,
                remote.VectorClock,
                remote.State ?? "active",
                remote.ServerRevision ?? 0,
                !string.IsNullOrEmpty(portable.Password) || !string.IsNullOrEmpty(portable.PrivateKeyContent),
                jumpHostCredential is { IsEmpty: false }),
            jumpHostCredential);
        return true;
    }

    private static bool TryParseAuthMethod(string? value) =>
        string.Equals(value, "password", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "key", StringComparison.OrdinalIgnoreCase);

    private static bool TryParseTransport(string? value, out ServerTransport transport)
    {
        transport = value?.Trim().ToLowerInvariant() switch
        {
            "ssh" => ServerTransport.Ssh,
            "telnet" => ServerTransport.Telnet,
            "rdp" => ServerTransport.RemoteDesktop,
            _ => ServerTransport.Ssh,
        };
        return string.Equals(value, "ssh", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(value, "telnet", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(value, "rdp", StringComparison.OrdinalIgnoreCase);
    }

    private static AssetSyncSnapshot Snapshot(
        ServerAssetRecord record,
        CredentialMaterial credential,
        CredentialMaterial? jumpHostCredential) =>
        new(
            record,
            CredentialFingerprint(credential),
            jumpHostCredential is null ? null : CredentialFingerprint(jumpHostCredential));

    private static bool TryMergePendingAsset(
        AssetSyncSnapshot? baseline,
        ServerAssetRecord local,
        CredentialMaterial localCredential,
        CredentialMaterial? localJumpCredential,
        PortableAsset remote,
        out ServerAssetRecord mergedRecord,
        out CredentialMaterial mergedCredential,
        out CredentialMaterial? mergedJumpCredential,
        out IReadOnlyList<string> conflictingFields)
    {
        var conflicts = new List<string>();
        if (baseline is null)
        {
            mergedRecord = local;
            mergedCredential = localCredential;
            mergedJumpCredential = localJumpCredential;
            conflictingFields = ["资产缺少可安全合并的基线"];
            return false;
        }

        var baseRecord = baseline.Record;
        var remoteRecord = remote.Record;
        var name = MergeValue("名称", baseRecord.Name, local.Name, remoteRecord.Name, conflicts);
        var host = MergeValue("主机", baseRecord.Host, local.Host, remoteRecord.Host, conflicts);
        var port = MergeValue("端口", baseRecord.Port, local.Port, remoteRecord.Port, conflicts);
        var username = MergeValue("用户名", baseRecord.Username, local.Username, remoteRecord.Username, conflicts);
        var transport = MergeValue("传输方式", baseRecord.Transport, local.Transport, remoteRecord.Transport, conflicts);
        var fallback = MergeValue("密码回退", baseRecord.AllowPasswordFallback, local.AllowPasswordFallback, remoteRecord.AllowPasswordFallback, conflicts);
        var group = MergeValue("分组", baseRecord.Group, local.Group, remoteRecord.Group, conflicts);
        var tags = MergeTags(baseRecord.Tags, local.Tags, remoteRecord.Tags, conflicts);
        var credentialId = MergeValue("凭据引用", baseRecord.CredentialId, local.CredentialId, remoteRecord.CredentialId, conflicts);
        var jumpHost = MergeValue("跳板机", baseRecord.JumpHost, local.JumpHost, remoteRecord.JumpHost, conflicts);

        var localCredentialFingerprint = CredentialFingerprint(localCredential);
        var remoteCredentialFingerprint = CredentialFingerprint(remote.Credential);
        var credentialFingerprint = MergeValue("凭据", baseline.CredentialFingerprint, localCredentialFingerprint, remoteCredentialFingerprint, conflicts);
        mergedCredential = credentialFingerprint == remoteCredentialFingerprint ? remote.Credential : localCredential;
        var localJumpFingerprint = localJumpCredential is null ? null : CredentialFingerprint(localJumpCredential);
        var remoteJumpFingerprint = remote.JumpHostCredential is null ? null : CredentialFingerprint(remote.JumpHostCredential);
        var jumpCredentialFingerprint = MergeValue(
            "跳板机凭据",
            baseline.JumpHostCredentialFingerprint,
            localJumpFingerprint,
            remoteJumpFingerprint,
            conflicts);
        mergedJumpCredential = jumpCredentialFingerprint == remoteJumpFingerprint
            ? remote.JumpHostCredential
            : localJumpCredential;
        mergedRecord = new ServerAssetRecord(
            local.Id,
            credentialId,
            name,
            host,
            port,
            username,
            transport,
            fallback,
            group,
            tags,
            jumpHost,
            AssetStorageScope.AccountSynced,
            remoteRecord.OwnerAccountScope);
        conflictingFields = conflicts;
        return conflicts.Count == 0;
    }

    private static T MergeValue<T>(string field, T baseline, T local, T remote, ICollection<string> conflicts)
    {
        var comparer = EqualityComparer<T>.Default;
        if (comparer.Equals(local, baseline)) return remote;
        if (comparer.Equals(remote, baseline) || comparer.Equals(local, remote)) return local;
        conflicts.Add(field);
        return local;
    }

    private static IReadOnlyList<string> MergeTags(
        IReadOnlyList<string>? baseline,
        IReadOnlyList<string>? local,
        IReadOnlyList<string>? remote,
        ICollection<string> conflicts)
    {
        var baseTags = baseline?.ToArray() ?? [];
        var localTags = local?.ToArray() ?? [];
        var remoteTags = remote?.ToArray() ?? [];
        if (localTags.SequenceEqual(baseTags, StringComparer.Ordinal)) return remoteTags;
        if (remoteTags.SequenceEqual(baseTags, StringComparer.Ordinal) || localTags.SequenceEqual(remoteTags, StringComparer.Ordinal)) return localTags;
        conflicts.Add("标签");
        return localTags;
    }

    public static string CredentialFingerprint(CredentialMaterial credential)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(string.Concat(
            credential.Password, "\0", credential.PrivateKey, "\0", credential.PrivateKeyPassphrase));
        try { return Convert.ToHexString(SHA256.HashData(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static bool ShouldApplySnippetEnvelope(SnippetEnvelope envelope, IReadOnlyList<SnippetRecord> current)
    {
        var localLatest = current.Count == 0
            ? 0
            : current.Max(snippet => snippet.UpdatedAt.ToUnixTimeSeconds());
        return envelope.UpdatedAtUnix >= localLatest;
    }

    private static bool IsValid(SnippetEnvelope? envelope) =>
        envelope is { Kind: SnippetMarker, Version: 1, UpdatedAtUnix: > 0, Snippets: not null } &&
        envelope.Snippets.All(snippet =>
            snippet.Id != Guid.Empty &&
            !string.IsNullOrWhiteSpace(snippet.Title) &&
            !string.IsNullOrWhiteSpace(snippet.Command));

    /// <summary>
    /// Apple JSONEncoder writes Date using its reference-date number by default,
    /// while older export paths may use ISO-8601 text. Accept both forms without
    /// relaxing any content validation.
    /// </summary>
    private static SnippetEnvelope? TryParseSnippetEnvelope(JsonElement root)
    {
        if (!root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var versionValue) ||
            !root.TryGetProperty("updatedAtUnix", out var updated) || !updated.TryGetInt64(out var updatedAtUnix) ||
            !root.TryGetProperty("snippets", out var snippets) || snippets.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var parsed = new List<SnippetRecord>();
        foreach (var item in snippets.EnumerateArray())
        {
            if (!item.TryGetProperty("id", out var idValue) || !Guid.TryParse(idValue.GetString(), out var id) ||
                !item.TryGetProperty("title", out var title) || string.IsNullOrWhiteSpace(title.GetString()) ||
                !item.TryGetProperty("command", out var command) || string.IsNullOrWhiteSpace(command.GetString()) ||
                !item.TryGetProperty("category", out var category) || category.ValueKind != JsonValueKind.String ||
                !item.TryGetProperty("createdAt", out var createdAt) ||
                !item.TryGetProperty("updatedAt", out var snippetUpdatedAt))
            {
                return null;
            }

            var created = ParseAppleDate(createdAt);
            var changed = ParseAppleDate(snippetUpdatedAt);
            if (created is null || changed is null) return null;
            var scope = ParseSnippetScope(item);
            if (scope is null) return null;
            parsed.Add(new SnippetRecord(
                id,
                title.GetString()!,
                command.GetString()!,
                category.GetString() ?? string.Empty,
                created.Value,
                changed.Value,
                scope));
        }

        return new SnippetEnvelope(SnippetMarker, versionValue, updatedAtUnix, parsed.ToArray(), 0, "{}");
    }

    private static SnippetAssetScope? ParseSnippetScope(JsonElement item)
    {
        if (!item.TryGetProperty("assetScope", out var scope)) return SnippetAssetScope.AllAssets;
        if (scope.ValueKind != JsonValueKind.Object || !scope.TryGetProperty("mode", out var mode)) return null;
        var modeValue = mode.GetString();
        if (string.Equals(modeValue, SnippetAssetScope.AllAssetsMode, StringComparison.Ordinal)) return SnippetAssetScope.AllAssets;
        if (!string.Equals(modeValue, SnippetAssetScope.SelectedAssetsMode, StringComparison.Ordinal) ||
            !scope.TryGetProperty("assetIDs", out var ids) || ids.ValueKind != JsonValueKind.Array) return null;
        var values = new List<Guid>();
        foreach (var value in ids.EnumerateArray())
        {
            if (!Guid.TryParse(value.GetString(), out var id)) return null;
            values.Add(id);
        }
        return SnippetAssetScope.Normalize(new SnippetAssetScope(SnippetAssetScope.SelectedAssetsMode, values));
    }

    private static DateTimeOffset? ParseAppleDate(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(value.GetString(), System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
                out var textual))
        {
            return textual;
        }

        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var seconds) ||
            double.IsNaN(seconds) || double.IsInfinity(seconds))
        {
            return null;
        }

        try
        {
            // Values above 2008's Unix timestamp range are from an ISO/Unix
            // export; normal Apple Date values are seconds since 2001-01-01.
            var epoch = Math.Abs(seconds) >= 1_200_000_000d
                ? DateTimeOffset.UnixEpoch
                : new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
            return epoch.AddSeconds(seconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static bool IsV2(ReadOnlySpan<byte> encrypted) =>
        encrypted.Length >= 4 && encrypted[..4].SequenceEqual("OTC2"u8);

    private static string ClientVersion() =>
        typeof(EncryptedConfigSynchronizationService).Assembly.GetName().Version?.ToString() ?? "0.0.0";

    private static string BumpSshKeyVectorClock(string? raw)
    {
        var values = string.IsNullOrWhiteSpace(raw)
            ? new Dictionary<string, int>(StringComparer.Ordinal)
            : JsonSerializer.Deserialize<Dictionary<string, int>>(raw) ?? new(StringComparer.Ordinal);
        values["ssh_key_client"] = values.GetValueOrDefault("ssh_key_client") + 1;
        return JsonSerializer.Serialize(values, JsonOptions);
    }

    private static string BumpVectorClock(string? raw, string actor)
    {
        var values = string.IsNullOrWhiteSpace(raw)
            ? new Dictionary<string, int>(StringComparer.Ordinal)
            : JsonSerializer.Deserialize<Dictionary<string, int>>(raw) ?? new(StringComparer.Ordinal);
        values[actor] = values.GetValueOrDefault(actor) + 1;
        return JsonSerializer.Serialize(values, JsonOptions);
    }

    private sealed record SyncPagePlan(
        IReadOnlyList<PortableAsset> ActiveAssets,
        IReadOnlySet<Guid> DeletedAssetIds,
        SnippetEnvelope? SnippetEnvelope,
        SshKeySyncEnvelope? SshKeyEnvelope,
        PortForwardProfileSyncEnvelope? PortForwardProfileEnvelope,
        bool Unsupported)
    {
        public static SyncPagePlan UnsupportedPlan { get; } = new([], new HashSet<Guid>(), null, null, null, true);
    }

    private sealed record PortableAsset(
        ServerAssetRecord Record,
        CredentialMaterial Credential,
        EncryptedAssetSyncMetadata Metadata,
        CredentialMaterial? JumpHostCredential);

    private sealed class PortableServerConfig
    {
        public string? Id { get; init; }
        public string? CredentialId { get; init; }
        public string? Name { get; init; }
        public string? Group { get; init; }
        public IReadOnlyList<string>? Tags { get; init; }
        public string? Host { get; init; }
        public int Port { get; init; }
        public string? Username { get; init; }
        public string? Transport { get; init; }
        public bool AllowPasswordFallback { get; init; }
        public string? Password { get; init; }
        public string? PrivateKeyContent { get; init; }
        public string? PrivateKeyPassphrase { get; init; }
        public PortableJumpHostConfiguration? JumpHost { get; init; }
    }

    private sealed class PortableJumpHostConfiguration
    {
        public string? CredentialId { get; init; }
        public string? Host { get; init; }
        public int Port { get; init; }
        public string? Username { get; init; }
        public string? AuthMethod { get; init; }
        public bool AllowPasswordFallback { get; init; }
        public string? Password { get; init; }
        public string? PrivateKeyContent { get; init; }
        public string? PrivateKeyPassphrase { get; init; }
    }

    private sealed record SnippetEnvelope(
        string? Kind,
        int Version,
        long UpdatedAtUnix,
        SnippetRecord[] Snippets,
        ulong RemoteId,
        string VectorClock);
}
