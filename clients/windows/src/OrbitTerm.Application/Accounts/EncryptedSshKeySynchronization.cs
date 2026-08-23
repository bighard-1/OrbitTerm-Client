using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Security;

namespace OrbitTerm.Application.Accounts;

public sealed record EncryptedSshKeySyncMetadata(
    ulong? RemoteId,
    string VectorClock,
    long EnvelopeTime,
    string PayloadFingerprint,
    IReadOnlyDictionary<Guid, string>? KnownKeys = null,
    IReadOnlyDictionary<Guid, long>? Tombstones = null);

internal sealed record SshKeySyncEnvelope(
    string Kind,
    int Version,
    long UpdatedAtUnix,
    SshKeySyncWire[] Keys,
    SshKeyTombstoneWire[] Tombstones,
    ulong RemoteId = 0,
    string VectorClock = "{}");

internal sealed record SshKeySyncWire(
    Guid Id,
    string Name,
    string Format,
    string MaterialFingerprint,
    long CreatedAtUnix,
    long UpdatedAtUnix,
    Guid[] AssignedAssetIds,
    string PrivateKey,
    string Passphrase);

internal sealed record SshKeyTombstoneWire(Guid Id, long DeletedAtUnix);

internal sealed record SshKeyMergeResult(
    int Applied,
    int Deleted,
    int Conflicted,
    EncryptedSshKeySyncMetadata Metadata);

/// <summary>
/// Merges the authenticated SSH-key envelope into the current-user DPAPI vault.
/// Private material exists in plaintext only inside the already-unlocked sync
/// operation and is never written to the sync-state document or diagnostics.
/// </summary>
internal sealed class EncryptedSshKeySynchronization(SshKeyLibraryService library)
{
    internal const string Marker = "orbit_ssh_keys";
    internal const int Version = 1;
    internal const int MaximumKeys = 128;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static SshKeySyncEnvelope? Parse(JsonElement root, ulong remoteId, string vectorClock)
    {
        var envelope = root.Deserialize<SshKeySyncEnvelope>(JsonOptions);
        if (envelope is null ||
            !string.Equals(envelope.Kind, Marker, StringComparison.Ordinal) ||
            envelope.Version != Version ||
            envelope.UpdatedAtUnix <= 0 ||
            envelope.Keys is null || envelope.Tombstones is null ||
            envelope.Keys.Length > MaximumKeys || envelope.Tombstones.Length > MaximumKeys * 4 ||
            envelope.Keys.Select(item => item.Id).Distinct().Count() != envelope.Keys.Length ||
            envelope.Keys.Select(item => item.MaterialFingerprint).Distinct(StringComparer.Ordinal).Count() != envelope.Keys.Length ||
            envelope.Tombstones.Select(item => item.Id).Distinct().Count() != envelope.Tombstones.Length)
        {
            return null;
        }

        foreach (var key in envelope.Keys)
        {
            if (key.Id == Guid.Empty || string.IsNullOrWhiteSpace(key.Name) ||
                key.CreatedAtUnix <= 0 || key.UpdatedAtUnix < key.CreatedAtUnix ||
                key.AssignedAssetIds is null || key.AssignedAssetIds.Length > 512)
            {
                return null;
            }

            try
            {
                var normalized = SshKeyMaterialPolicy.NormalizePrivateKey(key.PrivateKey);
                if (!string.Equals(
                        SshKeyMaterialPolicy.MaterialFingerprint(normalized),
                        key.MaterialFingerprint,
                        StringComparison.Ordinal))
                {
                    return null;
                }
            }
            catch (ArgumentException)
            {
                return null;
            }
        }

        if (envelope.Tombstones.Any(item => item.Id == Guid.Empty || item.DeletedAtUnix <= 0))
        {
            return null;
        }

        return envelope with { RemoteId = remoteId, VectorClock = vectorClock };
    }

    public async ValueTask<SshKeyMergeResult> ApplyAsync(
        SshKeySyncEnvelope remote,
        EncryptedSshKeySyncMetadata? previous,
        string accountScope,
        CancellationToken cancellationToken)
    {
        var allLocal = (await library.ListAsync(cancellationToken).ConfigureAwait(false))
            .ToDictionary(item => item.Id);
        var synchronized = (await library.ReadSynchronizedEntriesAsync(accountScope, cancellationToken).ConfigureAwait(false))
            .ToDictionary(item => item.Record.Id);
        var tombstones = previous?.Tombstones?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // A key that was part of the previously confirmed synchronized set but
        // is now absent from this DPAPI vault represents an explicit local
        // delete/scope change. Fresh devices have no KnownKeys and never infer
        // deletions merely because their vault starts empty.
        foreach (var knownKeyId in previous?.KnownKeys?.Keys ?? [])
        {
            if (!synchronized.ContainsKey(knownKeyId))
            {
                tombstones[knownKeyId] = Math.Max(tombstones.GetValueOrDefault(knownKeyId), now);
            }
        }

        foreach (var tombstone in remote.Tombstones)
        {
            tombstones[tombstone.Id] = Math.Max(tombstones.GetValueOrDefault(tombstone.Id), tombstone.DeletedAtUnix);
        }

        var applied = 0;
        var deleted = 0;
        var conflicted = 0;
        foreach (var wire in remote.Keys.OrderBy(item => item.UpdatedAtUnix).ThenBy(item => item.Id))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remoteUpdated = DateTimeOffset.FromUnixTimeSeconds(wire.UpdatedAtUnix);
            if (tombstones.GetValueOrDefault(wire.Id) >= wire.UpdatedAtUnix)
            {
                if (synchronized.Remove(wire.Id))
                {
                    await library.DeleteSynchronizedEntryAsync(wire.Id, cancellationToken).ConfigureAwait(false);
                    allLocal.Remove(wire.Id);
                    deleted++;
                }
                continue;
            }

            if (allLocal.TryGetValue(wire.Id, out var localRecord))
            {
                if (localRecord.SyncScope == SshKeySyncScope.LocalOnly)
                {
                    conflicted++;
                    continue;
                }
                if (localRecord.UpdatedAt > remoteUpdated)
                {
                    continue;
                }
            }
            else
            {
                // Never create two library records for the same private key.
                var materialCollision = allLocal.Values.FirstOrDefault(item =>
                    string.Equals(item.MaterialFingerprint, wire.MaterialFingerprint, StringComparison.Ordinal));
                if (materialCollision is not null)
                {
                    conflicted++;
                    continue;
                }
            }

            var record = new SshKeyRecord(
                wire.Id,
                wire.Name,
                wire.Format,
                wire.MaterialFingerprint,
                DateTimeOffset.FromUnixTimeSeconds(wire.CreatedAtUnix),
                remoteUpdated,
                SshKeyOrigin.Synchronized,
                wire.AssignedAssetIds.Distinct().Order().ToArray(),
                SshKeySyncScope.EndToEndEncrypted,
                accountScope);
            var entry = new SshKeyVaultEntry(record, new SshKeySecret(wire.PrivateKey, wire.Passphrase));
            await library.SaveSynchronizedEntryAsync(entry, accountScope, cancellationToken).ConfigureAwait(false);
            synchronized[wire.Id] = entry;
            allLocal[wire.Id] = record;
            applied++;
        }

        foreach (var tombstone in tombstones.ToArray())
        {
            if (!synchronized.TryGetValue(tombstone.Key, out var entry) ||
                entry.Record.UpdatedAt.ToUnixTimeSeconds() > tombstone.Value)
            {
                continue;
            }

            await library.DeleteSynchronizedEntryAsync(tombstone.Key, cancellationToken).ConfigureAwait(false);
            synchronized.Remove(tombstone.Key);
            allLocal.Remove(tombstone.Key);
            deleted++;
        }

        var current = await library.ReadSynchronizedEntriesAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var known = current.ToDictionary(item => item.Record.Id, EntryFingerprint);
        var remoteFingerprint = PayloadFingerprint(remote.Keys, remote.Tombstones);
        return new SshKeyMergeResult(
            applied,
            deleted,
            conflicted,
            new EncryptedSshKeySyncMetadata(
                remote.RemoteId,
                remote.VectorClock,
                remote.UpdatedAtUnix,
                remoteFingerprint,
                known,
                tombstones));
    }

    public async ValueTask<(SshKeySyncEnvelope Envelope, string Fingerprint)> BuildLocalEnvelopeAsync(
        EncryptedSshKeySyncMetadata? metadata,
        string accountScope,
        CancellationToken cancellationToken)
    {
        var entries = await library.ReadSynchronizedEntriesAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var currentIds = entries.Select(item => item.Record.Id).ToHashSet();
        var tombstones = metadata?.Tombstones?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        foreach (var knownKeyId in metadata?.KnownKeys?.Keys ?? [])
        {
            if (!currentIds.Contains(knownKeyId))
            {
                tombstones[knownKeyId] = Math.Max(tombstones.GetValueOrDefault(knownKeyId), now);
            }
        }

        // A later re-created key wins and removes its earlier tombstone.
        foreach (var entry in entries)
        {
            if (tombstones.GetValueOrDefault(entry.Record.Id) < entry.Record.UpdatedAt.ToUnixTimeSeconds())
            {
                tombstones.Remove(entry.Record.Id);
            }
        }

        var keys = entries
            .OrderBy(item => item.Record.Id)
            .Select(ToWire)
            .ToArray();
        var deleted = tombstones
            .OrderBy(item => item.Key)
            .Select(item => new SshKeyTombstoneWire(item.Key, item.Value))
            .ToArray();
        var envelopeTime = Math.Max(
            now,
            Math.Max(
                keys.Length == 0 ? 0 : keys.Max(item => item.UpdatedAtUnix),
                deleted.Length == 0 ? 0 : deleted.Max(item => item.DeletedAtUnix)));
        var envelope = new SshKeySyncEnvelope(Marker, Version, envelopeTime, keys, deleted);
        return (envelope, PayloadFingerprint(keys, deleted));
    }

    public static byte[] Serialize(SshKeySyncEnvelope envelope) =>
        JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);

    public static IReadOnlyDictionary<Guid, string> KnownKeys(SshKeySyncEnvelope envelope) =>
        envelope.Keys.ToDictionary(item => item.Id, item => WireFingerprint(item));

    private static SshKeySyncWire ToWire(SshKeyVaultEntry entry) => new(
        entry.Record.Id,
        entry.Record.Name,
        entry.Record.Format,
        entry.Record.MaterialFingerprint,
        entry.Record.CreatedAt.ToUnixTimeSeconds(),
        entry.Record.UpdatedAt.ToUnixTimeSeconds(),
        entry.Record.AssignedAssetIds.Distinct().Order().ToArray(),
        entry.Secret.PrivateKey,
        entry.Secret.Passphrase);

    private static string EntryFingerprint(SshKeyVaultEntry entry) => WireFingerprint(ToWire(entry));

    private static string WireFingerprint(SshKeySyncWire wire)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(wire, JsonOptions);
        try { return Convert.ToHexString(SHA256.HashData(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static string PayloadFingerprint(
        IReadOnlyList<SshKeySyncWire> keys,
        IReadOnlyList<SshKeyTombstoneWire> tombstones)
    {
        var canonical = new
        {
            keys = keys.OrderBy(item => item.Id).ToArray(),
            tombstones = tombstones.OrderBy(item => item.Id).ToArray(),
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(canonical, JsonOptions);
        try { return Convert.ToHexString(SHA256.HashData(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
