using System.Text;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class OrbitBackupServiceTests
{
    private const string Password = "correct-horse-backup";
    private static readonly string AccountScope = new('a', 64);

    [Fact]
    public async Task ExportAndRestore_RoundTripsAssetsSnippetsAndOptInCredentials()
    {
        var asset = CreateAsset(AssetStorageScope.LocalOnly, null);
        var snippet = new SnippetRecord(Guid.NewGuid(), "uptime", "uptime", "system", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var sourceAssets = new MemoryAssetStore([asset]);
        var sourceSnippets = new MemorySnippetStore([snippet]);
        var sourceVault = new MemoryCredentialVault();
        await sourceVault.SaveAsync(asset.CredentialId, new CredentialMaterial("secret-password", string.Empty, string.Empty), default);
        var sourceKeyVault = new MemorySshKeyVault();
        var sourceKeys = new SshKeyLibraryService(sourceKeyVault, sourceVault);
        var privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nbackup-test-key\n-----END OPENSSH PRIVATE KEY-----";
        var importedKey = await sourceKeys.ImportAsync("backup key", privateKey, "key-passphrase", default);
        await sourceKeys.AssignToAssetAsync(importedKey.Id, asset, default);
        var source = new OrbitBackupService(sourceAssets, sourceSnippets, sourceVault, sourceKeys);

        var backup = await source.ExportAsync(Password, includeCredentials: true, default);

        Assert.DoesNotContain("secret-password", Encoding.UTF8.GetString(backup), StringComparison.Ordinal);
        var targetAssets = new MemoryAssetStore([]);
        var targetSnippets = new MemorySnippetStore([]);
        var targetVault = new MemoryCredentialVault();
        var targetKeyVault = new MemorySshKeyVault();
        var targetKeys = new SshKeyLibraryService(targetKeyVault, targetVault);
        var target = new OrbitBackupService(targetAssets, targetSnippets, targetVault, targetKeys);
        var result = await target.RestoreAsync(backup, Password, string.Empty, OrbitBackupRestoreMode.Merge, default);

        Assert.Equal(1, result.RestoredAssets);
        Assert.Equal(1, result.RestoredSnippets);
        Assert.Equal(1, result.RestoredCredentials);
        Assert.Equal(1, result.RestoredSshKeys);
        Assert.Equal(asset.Id, Assert.Single(targetAssets.Items).Id);
        Assert.Equal(snippet.Id, Assert.Single(targetSnippets.Items).Id);
        Assert.Equal("secret-password", (await targetVault.ReadAsync(asset.CredentialId, default)).Password);
        var restoredKey = Assert.Single(await targetKeys.ListAsync(default));
        Assert.Equal("backup key", restoredKey.Name);
        Assert.Equal(SshKeyMaterialPolicy.NormalizePrivateKey(privateKey), (await targetKeys.ReadSecretAsync(restoredKey.Id, default)).PrivateKey);
    }

    [Fact]
    public async Task Restore_SkipsAssetsOwnedByAnotherAccount()
    {
        var accountAsset = CreateAsset(AssetStorageScope.AccountSynced, AccountScope);
        var source = new OrbitBackupService(
            new MemoryAssetStore([accountAsset]),
            new MemorySnippetStore([]),
            new MemoryCredentialVault());
        var backup = await source.ExportAsync(Password, includeCredentials: false, default);
        var targetAssets = new MemoryAssetStore([]);
        var target = new OrbitBackupService(targetAssets, new MemorySnippetStore([]), new MemoryCredentialVault());

        var result = await target.RestoreAsync(
            backup,
            Password,
            new string('b', 64),
            OrbitBackupRestoreMode.Merge,
            default);

        Assert.Empty(targetAssets.Items);
        Assert.Equal(1, result.SkippedLockedAssets);
    }

    [Fact]
    public async Task Inspect_RejectsWrongPassword()
    {
        var service = new OrbitBackupService(
            new MemoryAssetStore([CreateAsset(AssetStorageScope.LocalOnly, null)]),
            new MemorySnippetStore([]),
            new MemoryCredentialVault());
        var backup = await service.ExportAsync(Password, includeCredentials: false, default);

        await Assert.ThrowsAnyAsync<Exception>(async () =>
            await service.InspectAsync(backup, "wrong-password-value", string.Empty, default));
    }

    private static ServerAssetRecord CreateAsset(AssetStorageScope scope, string? owner) => new(
        Guid.NewGuid(),
        Guid.NewGuid(),
        "server",
        "192.0.2.1",
        22,
        "root",
        ServerTransport.Ssh,
        true,
        "test",
        ["linux"],
        null,
        scope,
        owner);

    private sealed class MemoryAssetStore(IReadOnlyList<ServerAssetRecord> initial) : IServerAssetStore
    {
        public IReadOnlyList<ServerAssetRecord> Items { get; private set; } = initial;
        public ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken cancellationToken) => ValueTask.FromResult(Items);
        public ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken cancellationToken)
        {
            Items = assets.ToArray();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemorySnippetStore(IReadOnlyList<SnippetRecord> initial) : ISnippetStore
    {
        public IReadOnlyList<SnippetRecord> Items { get; private set; } = initial;
        public ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken cancellationToken) => ValueTask.FromResult(Items);
        public ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken cancellationToken)
        {
            Items = snippets.ToArray();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemoryCredentialVault : ICredentialVault
    {
        private readonly Dictionary<Guid, CredentialMaterial> values = [];
        public ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken) =>
            ValueTask.FromResult(values.GetValueOrDefault(credentialId) ?? new CredentialMaterial(string.Empty, string.Empty, string.Empty));
        public ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken)
        {
            values[credentialId] = credential;
            return ValueTask.CompletedTask;
        }
        public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            values.Remove(credentialId);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemorySshKeyVault : ISshKeyVault
    {
        private readonly Dictionary<Guid, SshKeyVaultEntry> entries = [];
        public ValueTask<IReadOnlyList<SshKeyRecord>> ListAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult<IReadOnlyList<SshKeyRecord>>(entries.Values.Select(entry => entry.Record).ToArray());
        public ValueTask<SshKeyVaultEntry?> ReadAsync(Guid keyId, CancellationToken cancellationToken) =>
            ValueTask.FromResult(entries.GetValueOrDefault(keyId));
        public ValueTask SaveAsync(SshKeyVaultEntry entry, CancellationToken cancellationToken)
        {
            entries[entry.Record.Id] = entry;
            return ValueTask.CompletedTask;
        }
        public ValueTask DeleteAsync(Guid keyId, CancellationToken cancellationToken)
        {
            entries.Remove(keyId);
            return ValueTask.CompletedTask;
        }
    }
}
