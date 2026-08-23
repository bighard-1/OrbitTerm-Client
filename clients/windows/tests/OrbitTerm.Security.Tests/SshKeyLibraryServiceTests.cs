using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SshKeyLibraryServiceTests
{
    private const string FirstKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        first-test-key-material
        -----END OPENSSH PRIVATE KEY-----
        """;
    private const string SecondKey = """
        -----BEGIN PRIVATE KEY-----
        second-test-key-material
        -----END PRIVATE KEY-----
        """;

    [Fact]
    public async Task ImportNormalizesMetadataAndRejectsDuplicateMaterial()
    {
        var keys = new MemoryKeyVault();
        var service = new SshKeyLibraryService(keys, new MemoryCredentialVault());

        var record = await service.ImportAsync("  工作密钥  ", FirstKey, "口令", CancellationToken.None);

        Assert.Equal("工作密钥", record.Name);
        Assert.Equal("OpenSSH", record.Format);
        Assert.StartsWith("SHA256:", record.MaterialFingerprint, StringComparison.Ordinal);
        Assert.Empty(record.AssignedAssetIds);
        Assert.Equal("[REDACTED SSH KEY SECRET]", (await keys.ReadAsync(record.Id, CancellationToken.None))!.Secret.ToString());
        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await service.ImportAsync("重复", FirstKey, string.Empty, CancellationToken.None));
    }

    [Fact]
    public async Task GeneratedOriginIsPersistedWithoutChangingImportValidation()
    {
        var keys = new MemoryKeyVault();
        var service = new SshKeyLibraryService(keys, new MemoryCredentialVault());

        var record = await service.ImportAsync(
            "本机生成",
            FirstKey,
            "",
            CancellationToken.None,
            SshKeyOrigin.Generated);

        Assert.Equal(SshKeyOrigin.Generated, record.Origin);
        Assert.Equal(SshKeyOrigin.Generated, (await keys.ReadAsync(record.Id, CancellationToken.None))!.Record.Origin);
    }

    [Fact]
    public async Task SynchronizedKeysAreIsolatedByOrbitAccountScope()
    {
        var keys = new MemoryKeyVault();
        var service = new SshKeyLibraryService(keys, new MemoryCredentialVault());
        var local = await service.ImportAsync("本机", FirstKey, "", CancellationToken.None);
        var synced = await service.ImportAsync(
            "账户 A", SecondKey, "", CancellationToken.None,
            SshKeyOrigin.Imported, SshKeySyncScope.EndToEndEncrypted, "account-a");

        var accountA = await service.ListAccessibleAsync("account-a", true, CancellationToken.None);
        var accountB = await service.ListAccessibleAsync("account-b", true, CancellationToken.None);
        var locked = await service.ListAccessibleAsync("account-a", false, CancellationToken.None);

        Assert.Contains(local, accountA);
        Assert.Contains(synced, accountA);
        Assert.Single(accountB);
        Assert.Equal(local.Id, accountB[0].Id);
        Assert.Single(locked);
        Assert.Equal(local.Id, locked[0].Id);
        Assert.Single(await service.ReadSynchronizedEntriesAsync("account-a", CancellationToken.None));
        Assert.Empty(await service.ReadSynchronizedEntriesAsync("account-b", CancellationToken.None));
    }

    [Fact]
    public async Task AssignMovesAssetBetweenKeysAndPreservesPassword()
    {
        var keys = new MemoryKeyVault();
        var credentials = new MemoryCredentialVault();
        var service = new SshKeyLibraryService(keys, credentials);
        var first = await service.ImportAsync("第一把", FirstKey, "first-passphrase", CancellationToken.None);
        var second = await service.ImportAsync("第二把", SecondKey, "second-passphrase", CancellationToken.None);
        var asset = Asset();
        await credentials.SaveAsync(asset.CredentialId, new CredentialMaterial("password", string.Empty, string.Empty), CancellationToken.None);

        await service.AssignToAssetAsync(first.Id, asset, CancellationToken.None);
        await service.AssignToAssetAsync(second.Id, asset, CancellationToken.None);

        var material = await credentials.ReadAsync(asset.CredentialId, CancellationToken.None);
        Assert.Equal("password", material.Password);
        Assert.Equal(SshKeyMaterialPolicy.NormalizePrivateKey(SecondKey), material.PrivateKey);
        Assert.Equal("second-passphrase", material.PrivateKeyPassphrase);
        Assert.DoesNotContain(asset.Id, (await keys.ReadAsync(first.Id, CancellationToken.None))!.Record.AssignedAssetIds);
        Assert.Contains(asset.Id, (await keys.ReadAsync(second.Id, CancellationToken.None))!.Record.AssignedAssetIds);
    }

    [Fact]
    public async Task RemovingAndDeletingKeyNeverRemovesTheAssetPassword()
    {
        var keys = new MemoryKeyVault();
        var credentials = new MemoryCredentialVault();
        var service = new SshKeyLibraryService(keys, credentials);
        var key = await service.ImportAsync("临时密钥", FirstKey, string.Empty, CancellationToken.None);
        var asset = Asset();
        await credentials.SaveAsync(asset.CredentialId, new CredentialMaterial("fallback", string.Empty, string.Empty), CancellationToken.None);
        await service.AssignToAssetAsync(key.Id, asset, CancellationToken.None);

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await service.DeleteAsync(key.Id, CancellationToken.None));
        await service.RemoveFromAssetAsync(key.Id, asset, CancellationToken.None);
        await service.DeleteAsync(key.Id, CancellationToken.None);

        var material = await credentials.ReadAsync(asset.CredentialId, CancellationToken.None);
        Assert.Equal("fallback", material.Password);
        Assert.Empty(material.PrivateKey);
        Assert.Null(await keys.ReadAsync(key.Id, CancellationToken.None));
    }

    [Fact]
    public async Task SynchronizedAssignmentRehydratesAssetCredentialOnANewDevice()
    {
        var keys = new MemoryKeyVault();
        var credentials = new MemoryCredentialVault();
        var service = new SshKeyLibraryService(keys, credentials);
        var asset = Asset() with
        {
            StorageScope = AssetStorageScope.AccountSynced,
            OwnerAccountScope = "account-a",
        };
        await credentials.SaveAsync(
            asset.CredentialId,
            new CredentialMaterial("fallback-password", string.Empty, string.Empty),
            CancellationToken.None);
        var fingerprint = SshKeyMaterialPolicy.MaterialFingerprint(FirstKey);
        var record = new SshKeyRecord(
            Guid.NewGuid(), "同步密钥", "OpenSSH", fingerprint,
            DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow,
            SshKeyOrigin.Synchronized, [asset.Id],
            SshKeySyncScope.EndToEndEncrypted, "account-a");
        await service.SaveSynchronizedEntryAsync(
            new SshKeyVaultEntry(record, new SshKeySecret(FirstKey, "key-passphrase")),
            "account-a",
            CancellationToken.None);

        var result = await service.ReconcileSynchronizedAssignmentsAsync(
            [asset], "account-a", CancellationToken.None);

        Assert.Equal(1, result.Restored);
        Assert.Equal(0, result.Conflicted);
        var restored = await credentials.ReadAsync(asset.CredentialId, CancellationToken.None);
        Assert.Equal("fallback-password", restored.Password);
        Assert.Equal(SshKeyMaterialPolicy.NormalizePrivateKey(FirstKey), restored.PrivateKey);
        Assert.Equal("key-passphrase", restored.PrivateKeyPassphrase);
    }

    [Fact]
    public async Task SynchronizedAssignmentNeverOverwritesDifferentExistingKey()
    {
        var keys = new MemoryKeyVault();
        var credentials = new MemoryCredentialVault();
        var service = new SshKeyLibraryService(keys, credentials);
        var asset = Asset() with
        {
            StorageScope = AssetStorageScope.AccountSynced,
            OwnerAccountScope = "account-a",
        };
        var existing = SshKeyMaterialPolicy.NormalizePrivateKey(SecondKey);
        await credentials.SaveAsync(
            asset.CredentialId,
            new CredentialMaterial(string.Empty, existing, string.Empty),
            CancellationToken.None);
        var record = new SshKeyRecord(
            Guid.NewGuid(), "远程密钥", "OpenSSH",
            SshKeyMaterialPolicy.MaterialFingerprint(FirstKey),
            DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow,
            SshKeyOrigin.Synchronized, [asset.Id],
            SshKeySyncScope.EndToEndEncrypted, "account-a");
        await service.SaveSynchronizedEntryAsync(
            new SshKeyVaultEntry(record, new SshKeySecret(FirstKey, string.Empty)),
            "account-a",
            CancellationToken.None);

        var result = await service.ReconcileSynchronizedAssignmentsAsync(
            [asset], "account-a", CancellationToken.None);

        Assert.Equal(0, result.Restored);
        Assert.Equal(1, result.Conflicted);
        Assert.Equal(existing, (await credentials.ReadAsync(asset.CredentialId, CancellationToken.None)).PrivateKey);
    }

    private static ServerAssetRecord Asset() => new(
        Guid.NewGuid(), Guid.NewGuid(), "测试资产", "192.0.2.10", 22, "root",
        ServerTransport.Ssh, true, "测试", []);

    private sealed class MemoryKeyVault : ISshKeyVault
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

    private sealed class MemoryCredentialVault : ICredentialVault
    {
        private readonly Dictionary<Guid, CredentialMaterial> entries = [];

        public ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken) =>
            ValueTask.FromResult(entries.GetValueOrDefault(credentialId) ?? new CredentialMaterial(string.Empty, string.Empty, string.Empty));

        public ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken)
        {
            if (credential.IsEmpty) entries.Remove(credentialId); else entries[credentialId] = credential;
            return ValueTask.CompletedTask;
        }

        public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            entries.Remove(credentialId);
            return ValueTask.CompletedTask;
        }
    }
}
