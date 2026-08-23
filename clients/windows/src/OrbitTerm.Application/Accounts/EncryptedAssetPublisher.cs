using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

public enum EncryptedAssetPublishStatus
{
    Published,
    Deleted,
    LocalOnlyDeleted,
    LocalOnlySkipped,
    CredentialUnavailable,
    Conflict,
}

public sealed record EncryptedAssetPublishResult(
    EncryptedAssetPublishStatus Status,
    AccountSessionRecord Session,
    EncryptedAssetSyncMetadata? Metadata = null);

public interface IEncryptedAssetPublisher
{
    ValueTask QueueUpsertAsync(string accountScope, Guid assetId, CancellationToken cancellationToken);

    ValueTask QueueTombstoneAsync(string accountScope, Guid assetId, CancellationToken cancellationToken);

    ValueTask<IReadOnlyDictionary<Guid, PendingAssetSyncOperation>> ReadPendingOperationsAsync(
        string accountScope,
        CancellationToken cancellationToken);

    ValueTask QueueUnsyncedAssetsAsync(
        string accountScope,
        IReadOnlyCollection<Guid> assetIds,
        CancellationToken cancellationToken);

    ValueTask<EncryptedAssetPublishResult> PublishAsync(
        AccountSessionRecord session,
        string accountScope,
        ServerAssetRecord asset,
        CredentialMaterial credential,
        CredentialMaterial? jumpHostCredential,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken);

    ValueTask<EncryptedAssetPublishResult> TombstoneAsync(
        AccountSessionRecord session,
        string accountScope,
        Guid assetId,
        byte[] rootKey,
        CancellationToken cancellationToken);
}

/// <summary>
/// Writes the compatibility cipher used by the currently released Apple sync
/// clients. OTC2 remains fully readable; writing it is deferred until a
/// cross-device capability handshake is available, rather than assuming every
/// deployed client can consume it.
/// </summary>
public sealed class EncryptedAssetPublisher(
    IOrbitEncryptedSyncProtocol protocol,
    IEncryptedSyncStateStore stateStore,
    bool enforceCorePrivateKeyValidation = false) : IEncryptedAssetPublisher
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public async ValueTask<EncryptedAssetPublishResult> PublishAsync(
        AccountSessionRecord session,
        string accountScope,
        ServerAssetRecord asset,
        CredentialMaterial credential,
        CredentialMaterial? jumpHostCredential,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(asset);
        ArgumentNullException.ThrowIfNull(credential);
        credential = CredentialMaterialPolicy.NormalizeSshCredential(credential);
        if (jumpHostCredential is not null)
        {
            jumpHostCredential = CredentialMaterialPolicy.NormalizeSshCredential(jumpHostCredential);
        }
        if (enforceCorePrivateKeyValidation && !string.IsNullOrWhiteSpace(credential.PrivateKey))
        {
            _ = SshPrivateKeyInspector.Inspect(credential.PrivateKey, credential.PrivateKeyPassphrase);
        }
        if (enforceCorePrivateKeyValidation && jumpHostCredential is { PrivateKey.Length: > 0 })
        {
            _ = SshPrivateKeyInspector.Inspect(
                jumpHostCredential.PrivateKey,
                jumpHostCredential.PrivateKeyPassphrase);
        }
        ValidateRootKey(rootKey);
        if (asset.IsLocalOnly)
        {
            // Local-only is a hard security boundary, not merely a UI filter.
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.LocalOnlySkipped, session);
        }
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var metadata = state.Assets?.TryGetValue(asset.Id, out var known) == true ? known : null;
        if (metadata is { HasCredentialMaterial: true } && credential.IsEmpty)
        {
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.CredentialUnavailable, session, metadata);
        }
        if (asset.JumpHost is not null &&
            (jumpHostCredential is null || jumpHostCredential.IsEmpty))
        {
            // Apple rejects portable jump hosts without authentication material.
            // Never publish a partial hop that would make another device discard
            // the complete encrypted asset.
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.CredentialUnavailable, session, metadata);
        }
        if (asset.JumpHost is { } jumpHost &&
            (asset.Transport != ServerTransport.Ssh || jumpHost.CredentialId == asset.CredentialId))
        {
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.CredentialUnavailable, session, metadata);
        }
        ArgumentException.ThrowIfNullOrWhiteSpace(masterPassword);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(CreatePortable(asset, credential, jumpHostCredential), JsonOptions);
        byte[] encrypted = [];
        try
        {
            encrypted = OrbitConfigCrypto.EncryptConfigLegacy(masterPassword, plaintext);
            var vectorClock = BumpVectorClock(metadata?.VectorClock, state.DeviceId);
            try
            {
                var uploaded = await protocol.UploadAsync(
                    session,
                    new EncryptedConfigUpload(
                        metadata?.RemoteId,
                        asset.Id.ToString("D"),
                        null,
                        Convert.ToBase64String(encrypted),
                        vectorClock),
                    cancellationToken).ConfigureAwait(false);
                var nextMetadata = new EncryptedAssetSyncMetadata(
                    uploaded.Value.Id,
                    uploaded.Value.VectorClock,
                    uploaded.Value.State ?? "active",
                    uploaded.Value.ServerRevision ?? 0,
                    !credential.IsEmpty,
                    asset.JumpHost is not null && jumpHostCredential is { IsEmpty: false });
                var assets = state.Assets?.ToDictionary(item => item.Key, item => item.Value) ?? [];
                assets[asset.Id] = nextMetadata;
                var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
                pending.Remove(asset.Id);
                var snapshots = state.Snapshots?.ToDictionary(item => item.Key, item => item.Value) ?? [];
                snapshots[asset.Id] = new AssetSyncSnapshot(
                    asset,
                    EncryptedConfigSynchronizationService.CredentialFingerprint(credential),
                    jumpHostCredential is null
                        ? null
                        : EncryptedConfigSynchronizationService.CredentialFingerprint(jumpHostCredential));
                await stateStore.SaveAsync(accountScope, state with
                {
                    Assets = assets,
                    PendingOperations = pending,
                    Snapshots = snapshots,
                }, cancellationToken).ConfigureAwait(false);
                return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.Published, uploaded.Session, nextMetadata);
            }
            catch (HttpRequestException exception) when (exception.StatusCode == HttpStatusCode.Conflict)
            {
                return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.Conflict, session, metadata);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(encrypted);
        }
    }

    public async ValueTask<EncryptedAssetPublishResult> TombstoneAsync(
        AccountSessionRecord session,
        string accountScope,
        Guid assetId,
        byte[] rootKey,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ValidateRootKey(rootKey);
        if (assetId == Guid.Empty) throw new ArgumentException("资产标识无效。", nameof(assetId));
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var knownAssets = state.Assets;
        if (knownAssets is null || !knownAssets.TryGetValue(assetId, out var metadata))
        {
            var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
            pending.Remove(assetId);
            var snapshots = state.Snapshots?.ToDictionary(item => item.Key, item => item.Value) ?? [];
            snapshots.Remove(assetId);
            await stateStore.SaveAsync(accountScope, state with
            {
                PendingOperations = pending,
                Snapshots = snapshots,
            }, cancellationToken).ConfigureAwait(false);
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.LocalOnlyDeleted, session);
        }

        try
        {
            var deletion = await protocol.DeleteAssetAsync(
                session,
                assetId,
                new AssetDeletionRequest(state.DeviceId, Guid.NewGuid(), BumpVectorClock(metadata.VectorClock, state.DeviceId)),
                cancellationToken).ConfigureAwait(false);
            var assets = knownAssets.ToDictionary(item => item.Key, item => item.Value);
            assets.Remove(assetId);
            var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
            pending.Remove(assetId);
            var snapshots = state.Snapshots?.ToDictionary(item => item.Key, item => item.Value) ?? [];
            snapshots.Remove(assetId);
            await stateStore.SaveAsync(accountScope, state with
            {
                Assets = assets,
                PendingOperations = pending,
                Snapshots = snapshots,
            }, cancellationToken).ConfigureAwait(false);
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.Deleted, deletion.Session);
        }
        catch (HttpRequestException exception) when (exception.StatusCode == HttpStatusCode.Conflict)
        {
            return new EncryptedAssetPublishResult(EncryptedAssetPublishStatus.Conflict, session, metadata);
        }
    }

    public async ValueTask QueueUpsertAsync(string accountScope, Guid assetId, CancellationToken cancellationToken)
    {
        if (assetId == Guid.Empty) throw new ArgumentException("资产标识无效。", nameof(assetId));
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var baseVector = state.Assets?.TryGetValue(assetId, out var known) == true ? known.VectorClock : null;
        pending[assetId] = new PendingAssetSyncOperation(
            PendingAssetSyncOperationKind.Upsert,
            baseVector,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        await stateStore.SaveAsync(accountScope, state with { PendingOperations = pending }, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask QueueTombstoneAsync(string accountScope, Guid assetId, CancellationToken cancellationToken)
    {
        if (assetId == Guid.Empty) throw new ArgumentException("资产标识无效。", nameof(assetId));
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        var baseVector = state.Assets?.TryGetValue(assetId, out var known) == true ? known.VectorClock : null;
        pending[assetId] = new PendingAssetSyncOperation(
            PendingAssetSyncOperationKind.Tombstone,
            baseVector,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        await stateStore.SaveAsync(accountScope, state with { PendingOperations = pending }, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask<IReadOnlyDictionary<Guid, PendingAssetSyncOperation>> ReadPendingOperationsAsync(
        string accountScope,
        CancellationToken cancellationToken)
    {
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        return state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ??
            new Dictionary<Guid, PendingAssetSyncOperation>();
    }

    public async ValueTask QueueUnsyncedAssetsAsync(
        string accountScope,
        IReadOnlyCollection<Guid> assetIds,
        CancellationToken cancellationToken)
    {
        var state = await ReadStateAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var pending = state.PendingOperations?.ToDictionary(item => item.Key, item => item.Value) ?? [];
        foreach (var assetId in assetIds.Where(id => id != Guid.Empty))
        {
            if (state.Assets?.ContainsKey(assetId) == true || pending.ContainsKey(assetId)) continue;
            pending[assetId] = new PendingAssetSyncOperation(
                PendingAssetSyncOperationKind.Upsert,
                null,
                DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        }

        if (pending.Count != (state.PendingOperations?.Count ?? 0))
        {
            await stateStore.SaveAsync(accountScope, state with { PendingOperations = pending }, cancellationToken).ConfigureAwait(false);
        }
    }

    private async ValueTask<EncryptedSyncState> ReadStateAsync(string accountScope, CancellationToken cancellationToken)
    {
        var state = await stateStore.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false)
            ?? new EncryptedSyncState(Guid.NewGuid(), 0);
        return state.DeviceId == Guid.Empty ? state with { DeviceId = Guid.NewGuid() } : state;
    }

    private static void ValidateRootKey(byte[] rootKey)
    {
        ArgumentNullException.ThrowIfNull(rootKey);
        if (rootKey.Length != 32) throw new ArgumentException("同步根密钥长度无效。", nameof(rootKey));
    }

    private static string BumpVectorClock(string? current, Guid deviceId)
    {
        Dictionary<string, long>? clock = null;
        try { clock = JsonSerializer.Deserialize<Dictionary<string, long>>(current ?? "{}"); } catch (JsonException) { }
        clock ??= [];
        var actor = deviceId.ToString("D").ToLowerInvariant();
        var wallClock = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        clock[actor] = Math.Max(clock.GetValueOrDefault(actor) + 1, wallClock);
        return JsonSerializer.Serialize(clock);
    }

    private static PortableServerConfig CreatePortable(
        ServerAssetRecord asset,
        CredentialMaterial credential,
        CredentialMaterial? jumpHostCredential) => new()
    {
        Id = asset.Id.ToString("D"),
        CredentialId = asset.CredentialId.ToString("D"),
        Name = asset.Name,
        Group = asset.Group,
        Tags = asset.Tags?.ToArray() ?? [],
        Host = asset.Host,
        Port = asset.Port,
        Username = asset.Username,
        AuthMethod = string.IsNullOrEmpty(credential.PrivateKey) ? "password" : "key",
        Transport = asset.Transport switch
        {
            ServerTransport.Telnet => "telnet",
            ServerTransport.RemoteDesktop => "rdp",
            _ => "ssh",
        },
        NetworkDeviceProfile = "auto",
        AllowPasswordFallback = asset.AllowPasswordFallback,
        Password = credential.Password,
        PrivateKeyContent = credential.PrivateKey,
        PrivateKeyPassphrase = credential.PrivateKeyPassphrase,
        KeyReference = string.Empty,
        SavedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        JumpHost = asset.JumpHost is { } jump
            ? new PortableJumpHostConfiguration
            {
                CredentialId = jump.CredentialId.ToString("D"),
                Host = jump.Host,
                Port = jump.Port,
                Username = jump.Username,
                AuthMethod = string.IsNullOrEmpty(jumpHostCredential?.PrivateKey) ? "password" : "key",
                AllowPasswordFallback = jump.AllowPasswordFallback,
                Password = jumpHostCredential?.Password ?? string.Empty,
                PrivateKeyContent = jumpHostCredential?.PrivateKey ?? string.Empty,
                PrivateKeyPassphrase = jumpHostCredential?.PrivateKeyPassphrase ?? string.Empty,
            }
            : null,
    };

    private sealed class PortableServerConfig
    {
        [JsonPropertyName("id")] public string Id { get; init; } = string.Empty;
        [JsonPropertyName("credentialID")] public string CredentialId { get; init; } = string.Empty;
        [JsonPropertyName("name")] public string Name { get; init; } = string.Empty;
        [JsonPropertyName("group")] public string Group { get; init; } = string.Empty;
        [JsonPropertyName("tags")] public string[] Tags { get; init; } = [];
        [JsonPropertyName("host")] public string Host { get; init; } = string.Empty;
        [JsonPropertyName("port")] public int Port { get; init; }
        [JsonPropertyName("username")] public string Username { get; init; } = string.Empty;
        [JsonPropertyName("authMethod")] public string AuthMethod { get; init; } = "password";
        [JsonPropertyName("transport")] public string Transport { get; init; } = "ssh";
        [JsonPropertyName("networkDeviceProfile")] public string NetworkDeviceProfile { get; init; } = "auto";
        [JsonPropertyName("allowPasswordFallback")] public bool AllowPasswordFallback { get; init; }
        [JsonPropertyName("password")] public string Password { get; init; } = string.Empty;
        [JsonPropertyName("privateKeyContent")] public string PrivateKeyContent { get; init; } = string.Empty;
        [JsonPropertyName("privateKeyPassphrase")] public string PrivateKeyPassphrase { get; init; } = string.Empty;
        [JsonPropertyName("keyReference")] public string KeyReference { get; init; } = string.Empty;
        [JsonPropertyName("savedAtUnix")] public long SavedAtUnix { get; init; }
        [JsonPropertyName("jumpHost")] public PortableJumpHostConfiguration? JumpHost { get; init; }
    }

    private sealed class PortableJumpHostConfiguration
    {
        [JsonPropertyName("credentialID")] public string CredentialId { get; init; } = string.Empty;
        [JsonPropertyName("host")] public string Host { get; init; } = string.Empty;
        [JsonPropertyName("port")] public int Port { get; init; }
        [JsonPropertyName("username")] public string Username { get; init; } = string.Empty;
        [JsonPropertyName("authMethod")] public string AuthMethod { get; init; } = "password";
        [JsonPropertyName("allowPasswordFallback")] public bool AllowPasswordFallback { get; init; }
        [JsonPropertyName("password")] public string Password { get; init; } = string.Empty;
        [JsonPropertyName("privateKeyContent")] public string PrivateKeyContent { get; init; } = string.Empty;
        [JsonPropertyName("privateKeyPassphrase")] public string PrivateKeyPassphrase { get; init; } = string.Empty;
    }
}
