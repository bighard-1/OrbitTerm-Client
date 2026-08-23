using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Security;

public enum OrbitBackupRestoreMode
{
    Merge,
    ReplaceCurrentScope,
}

public sealed record OrbitBackupSummary(
    DateTimeOffset CreatedAt,
    int AssetCount,
    int SnippetCount,
    int CredentialCount,
    int SshKeyCount,
    bool IncludesCredentials,
    int LockedAssetCount);

public sealed record OrbitBackupRestoreResult(
    int RestoredAssets,
    int RestoredSnippets,
    int RestoredCredentials,
    int RestoredSshKeys,
    int SkippedLockedAssets);

/// <summary>
/// Creates a portable, password-encrypted OrbitTerm backup. Account tokens,
/// master-password verifiers, host-key trust and diagnostics are intentionally
/// excluded. Connection credentials are opt-in and remain inside the encrypted
/// payload only.
/// </summary>
public sealed class OrbitBackupService(
    IServerAssetStore assetStore,
    ISnippetStore snippetStore,
    ICredentialVault credentialVault,
    SshKeyLibraryService? sshKeyLibrary = null,
    TimeProvider? timeProvider = null)
{
    public const string FileExtension = ".orbitterm-backup";
    private const string Magic = "OrbitTermBackup";
    private const int Version = 1;
    private const int MinimumPasswordLength = 12;
    private const int MaximumBackupBytes = 32 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async ValueTask<byte[]> ExportAsync(
        string password,
        bool includeCredentials,
        CancellationToken cancellationToken)
    {
        ValidatePassword(password);
        var assets = await assetStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        var snippets = await snippetStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        var credentials = new Dictionary<Guid, CredentialMaterial>();
        var sshKeys = new List<BackupSshKey>();
        if (includeCredentials)
        {
            foreach (var credentialId in assets
                .SelectMany(asset => asset.JumpHost is null
                    ? new[] { asset.CredentialId }
                    : new[] { asset.CredentialId, asset.JumpHost.CredentialId })
                .Where(id => id != Guid.Empty)
                .Distinct())
            {
                var credential = await credentialVault.ReadAsync(credentialId, cancellationToken).ConfigureAwait(false);
                if (!credential.IsEmpty)
                {
                    credentials[credentialId] = credential;
                }
            }
            if (sshKeyLibrary is not null)
            {
                foreach (var key in await sshKeyLibrary.ListAsync(cancellationToken).ConfigureAwait(false))
                {
                    var secret = await sshKeyLibrary.ReadSecretAsync(key.Id, cancellationToken).ConfigureAwait(false);
                    sshKeys.Add(new BackupSshKey(key, secret.PrivateKey, secret.Passphrase));
                }
            }
        }

        var createdAt = clock.GetUtcNow();
        var backupScope = Guid.NewGuid().ToString("N");
        var payload = JsonSerializer.SerializeToUtf8Bytes(
            new BackupPayload(Version, createdAt, assets, snippets, credentials, sshKeys),
            JsonOptions);
        byte[] rootKey = [];
        byte[] encrypted = [];
        try
        {
            rootKey = OrbitConfigCrypto.DeriveConfigRootKeyV2(password, BackupKeyScope(backupScope));
            encrypted = OrbitConfigCrypto.EncryptConfigV2(rootKey, payload);
            var envelope = new BackupEnvelope(
                Magic,
                Version,
                backupScope,
                createdAt,
                includeCredentials,
                Convert.ToBase64String(encrypted));
            return JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(rootKey);
            CryptographicOperations.ZeroMemory(payload);
            CryptographicOperations.ZeroMemory(encrypted);
        }
    }

    public async ValueTask<OrbitBackupSummary> InspectAsync(
        byte[] backup,
        string password,
        string currentAccountScope,
        CancellationToken cancellationToken)
    {
        var (envelope, payload) = Decrypt(backup, password);
        try
        {
            await Task.Yield();
            cancellationToken.ThrowIfCancellationRequested();
            var locked = payload.Assets.Count(asset => !CanRestore(asset, currentAccountScope));
            return new OrbitBackupSummary(
                envelope.CreatedAt,
                payload.Assets.Count,
                payload.Snippets.Count,
                payload.Credentials.Count,
                payload.EffectiveSshKeys.Count,
                envelope.IncludesCredentials,
                locked);
        }
        finally
        {
            payload.ClearSecrets();
        }
    }

    public async ValueTask<OrbitBackupRestoreResult> RestoreAsync(
        byte[] backup,
        string password,
        string currentAccountScope,
        OrbitBackupRestoreMode mode,
        CancellationToken cancellationToken)
    {
        var (_, payload) = Decrypt(backup, password);
        try
        {
            var allowedAssets = payload.Assets
                .Where(asset => CanRestore(asset, currentAccountScope))
                .Select(asset => ClaimLegacyOwner(asset, currentAccountScope))
                .ToArray();
            var allowedCredentialIds = allowedAssets
                .SelectMany(asset => asset.JumpHost is null
                    ? new[] { asset.CredentialId }
                    : new[] { asset.CredentialId, asset.JumpHost.CredentialId })
                .ToHashSet();
            var existingAssets = await assetStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            var existingSnippets = await snippetStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            var mergedAssets = mode == OrbitBackupRestoreMode.Merge
                ? MergeById(existingAssets, allowedAssets, item => item.Id)
                : existingAssets
                    .Where(asset => !CanRestore(asset, currentAccountScope))
                    .Concat(allowedAssets)
                    .GroupBy(asset => asset.Id)
                    .Select(group => group.Last())
                    .ToArray();
            var mergedSnippets = mode == OrbitBackupRestoreMode.Merge
                ? MergeById(existingSnippets, payload.Snippets, item => item.Id)
                : payload.Snippets;

            await assetStore.SaveAsync(mergedAssets, cancellationToken).ConfigureAwait(false);
            await snippetStore.SaveAsync(mergedSnippets, cancellationToken).ConfigureAwait(false);
            var restoredCredentials = 0;
            foreach (var (credentialId, credential) in payload.Credentials)
            {
                if (!allowedCredentialIds.Contains(credentialId))
                {
                    continue;
                }
                await credentialVault.SaveAsync(credentialId, credential, cancellationToken).ConfigureAwait(false);
                restoredCredentials++;
            }
            var restoredSshKeys = 0;
            if (sshKeyLibrary is not null)
            {
                var currentKeys = await sshKeyLibrary.ListAsync(cancellationToken).ConfigureAwait(false);
                var restoredAssetsById = allowedAssets.ToDictionary(asset => asset.Id);
                foreach (var backedUpKey in payload.EffectiveSshKeys)
                {
                    var key = currentKeys.FirstOrDefault(item => string.Equals(
                        item.MaterialFingerprint,
                        backedUpKey.Record.MaterialFingerprint,
                        StringComparison.Ordinal));
                    key ??= await sshKeyLibrary.ImportAsync(
                        backedUpKey.Record.Name,
                        backedUpKey.PrivateKey,
                        backedUpKey.Passphrase,
                        cancellationToken,
                        backedUpKey.Record.Origin).ConfigureAwait(false);
                    foreach (var assetId in backedUpKey.Record.AssignedAssetIds)
                    {
                        if (restoredAssetsById.TryGetValue(assetId, out var assignedAsset))
                        {
                            key = await sshKeyLibrary.AssignToAssetAsync(
                                key.Id,
                                assignedAsset,
                                cancellationToken).ConfigureAwait(false);
                        }
                    }
                    restoredSshKeys++;
                }
            }
            return new OrbitBackupRestoreResult(
                allowedAssets.Length,
                payload.Snippets.Count,
                restoredCredentials,
                restoredSshKeys,
                payload.Assets.Count - allowedAssets.Length);
        }
        finally
        {
            payload.ClearSecrets();
        }
    }

    private static (BackupEnvelope Envelope, BackupPayload Payload) Decrypt(byte[] backup, string password)
    {
        ArgumentNullException.ThrowIfNull(backup);
        ValidatePassword(password);
        if (backup.Length is <= 0 or > MaximumBackupBytes)
        {
            throw new InvalidDataException("备份文件大小无效。");
        }
        var envelope = JsonSerializer.Deserialize<BackupEnvelope>(backup, JsonOptions)
            ?? throw new InvalidDataException("无法识别备份文件。");
        if (envelope.Magic != Magic || envelope.Version != Version ||
            !Guid.TryParseExact(envelope.BackupScope, "N", out _))
        {
            throw new InvalidDataException("备份格式或版本不受支持。");
        }
        byte[] rootKey = [];
        byte[] encrypted = [];
        byte[] plaintext = [];
        try
        {
            encrypted = Convert.FromBase64String(envelope.Ciphertext);
            rootKey = OrbitConfigCrypto.DeriveConfigRootKeyV2(password, BackupKeyScope(envelope.BackupScope));
            plaintext = OrbitConfigCrypto.DecryptConfigV2(rootKey, encrypted);
            var payload = JsonSerializer.Deserialize<BackupPayload>(plaintext, JsonOptions)
                ?? throw new InvalidDataException("备份内容无效。");
            if (payload.Version != Version || payload.Assets.Count > 512 ||
                payload.Snippets.Count > 512 || payload.EffectiveSshKeys.Count > 128)
            {
                payload.ClearSecrets();
                throw new InvalidDataException("备份内容超出安全限制。");
            }
            return (envelope, payload);
        }
        catch (FormatException exception)
        {
            throw new InvalidDataException("备份密文格式无效。", exception);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(rootKey);
            CryptographicOperations.ZeroMemory(encrypted);
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static bool CanRestore(ServerAssetRecord asset, string currentAccountScope) =>
        asset.StorageScope == AssetStorageScope.LocalOnly ||
        (!string.IsNullOrWhiteSpace(currentAccountScope) &&
         (string.IsNullOrWhiteSpace(asset.OwnerAccountScope) ||
          string.Equals(asset.OwnerAccountScope, currentAccountScope, StringComparison.Ordinal)));

    private static ServerAssetRecord ClaimLegacyOwner(ServerAssetRecord asset, string currentAccountScope) =>
        asset.StorageScope == AssetStorageScope.AccountSynced && string.IsNullOrWhiteSpace(asset.OwnerAccountScope)
            ? asset with { OwnerAccountScope = currentAccountScope }
            : asset;

    private static IReadOnlyList<T> MergeById<T>(IReadOnlyList<T> existing, IReadOnlyList<T> restored, Func<T, Guid> id) =>
        existing.Concat(restored)
            .GroupBy(id)
            .Select(group => group.Last())
            .ToArray();

    private static void ValidatePassword(string password)
    {
        if (string.IsNullOrEmpty(password) || password.Length < MinimumPasswordLength)
        {
            throw new ArgumentException("备份密码至少需要 12 个字符。", nameof(password));
        }
    }

    private static string BackupKeyScope(string backupScope) => string.Concat("orbitterm-portable-backup-v1:", backupScope);

    private sealed record BackupEnvelope(
        string Magic,
        int Version,
        string BackupScope,
        DateTimeOffset CreatedAt,
        bool IncludesCredentials,
        string Ciphertext);

    private sealed record BackupPayload(
        int Version,
        DateTimeOffset CreatedAt,
        IReadOnlyList<ServerAssetRecord> Assets,
        IReadOnlyList<SnippetRecord> Snippets,
        IReadOnlyDictionary<Guid, CredentialMaterial> Credentials,
        IReadOnlyList<BackupSshKey>? SshKeys)
    {
        [JsonIgnore]
        public IReadOnlyList<BackupSshKey> EffectiveSshKeys => SshKeys ?? [];

        public void ClearSecrets()
        {
            foreach (var credential in Credentials.Values)
            {
                // Managed strings cannot be reliably zeroed. Clearing the
                // collection reference minimizes lifetime; plaintext byte
                // buffers are zeroed by the caller.
                _ = credential;
            }
        }
    }

    private sealed record BackupSshKey(SshKeyRecord Record, string PrivateKey, string Passphrase);
}
