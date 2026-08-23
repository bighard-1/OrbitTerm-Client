using System.Text;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class EncryptedConfigSynchronizationServiceTests
{
    [Fact]
    public async Task AppliesV2AndLegacyAssetsBeforeAcknowledgingThePage()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var v2 = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, JsonAsset(Guid.NewGuid(), Guid.NewGuid(), "v2")));
        var legacy = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigLegacy("correct horse", JsonAsset(Guid.NewGuid(), Guid.NewGuid(), "legacy")));
        var assets = new Assets();
        var credentials = new Credentials();
        var protocol = new Sync([Record(v2), Record(legacy)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(protocol, assets, new Snippets(), credentials, new States());

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        Assert.Equal(2, result.AddedAssets);
        Assert.Equal(1, result.AcknowledgedPages);
        Assert.Equal(2, assets.Values.Count);
        Assert.Equal(2, credentials.Values.Count);
        Assert.Equal(1, protocol.Acknowledgements);
        Assert.True(protocol.AssetsWereAppliedBeforeAcknowledgement);
    }

    [Fact]
    public async Task UnsupportedPayloadIsNeverAcknowledgedOrApplied()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, "{\"kind\":\"future_format\"}"u8.ToArray()));
        var assets = new Assets();
        var credentials = new Credentials();
        var protocol = new Sync([Record(encrypted)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(protocol, assets, new Snippets(), credentials, new States());

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.UnsupportedConfiguration, result.Status);
        Assert.Equal(0, protocol.Acknowledgements);
        Assert.Empty(assets.Values);
        Assert.Empty(credentials.Values);
    }

    [Fact]
    public async Task SnippetEnvelopeIsAppliedAndAcknowledged()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var snippetId = Guid.NewGuid();
        var plaintext = Encoding.UTF8.GetBytes($$"""{"kind":"orbit_snippets","version":1,"updatedAtUnix":2000000000,"snippets":[{"id":"{{snippetId}}","title":"检查","command":"whoami","category":"默认","createdAt":789004800,"updatedAt":789004800}]}""");
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, plaintext));
        var snippets = new Snippets();
        var assets = new Assets();
        var credentials = new Credentials();
        var protocol = new Sync([Record(encrypted)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(protocol, assets, snippets, credentials, new States());

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        Assert.Equal(1, result.AppliedSnippets);
        Assert.Single(snippets.Values);
        Assert.Equal(1, protocol.Acknowledgements);
    }

    [Fact]
    public async Task SshKeyEnvelopeIsAppliedToVaultAndProtectedFromDuplicatePublication()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        const string privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nsynchronized-test-key\n-----END OPENSSH PRIVATE KEY-----\n";
        var keyId = Guid.NewGuid();
        var fingerprint = SshKeyMaterialPolicy.MaterialFingerprint(privateKey);
        var plaintext = Encoding.UTF8.GetBytes($$"""{"kind":"orbit_ssh_keys","version":1,"updatedAtUnix":2000000000,"keys":[{"id":"{{keyId}}","name":"同步密钥","format":"OpenSSH","materialFingerprint":"{{fingerprint}}","createdAtUnix":1999999990,"updatedAtUnix":2000000000,"assignedAssetIds":[],"privateKey":"{{privateKey.Replace("\n", "\\n", StringComparison.Ordinal)}}","passphrase":"口令"}],"tombstones":[]}""");
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, plaintext));
        var assets = new Assets();
        var credentials = new Credentials();
        var keyVault = new Keys();
        var keyLibrary = new SshKeyLibraryService(keyVault, credentials);
        var protocol = new Sync([Record(encrypted)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(
            protocol, assets, new Snippets(), credentials, new States(), keyLibrary);

        var result = await service.SynchronizeAsync(
            Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        Assert.Equal(1, result.AppliedSshKeys);
        Assert.Equal(0, protocol.Uploads);
        var restored = Assert.Single(await keyLibrary.ReadSynchronizedEntriesAsync("scope", CancellationToken.None));
        Assert.Equal(keyId, restored.Record.Id);
        Assert.Equal(SshKeySyncScope.EndToEndEncrypted, restored.Record.SyncScope);
        Assert.Equal(privateKey, restored.Secret.PrivateKey);
        Assert.Equal("口令", restored.Secret.Passphrase);
    }

    [Fact]
    public async Task SynchronizedKeyAssignmentMakesRestoredAssetImmediatelyConnectable()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var assetId = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var keyId = Guid.NewGuid();
        const string privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nsynchronized-asset-key\n-----END OPENSSH PRIVATE KEY-----\n";
        var fingerprint = SshKeyMaterialPolicy.MaterialFingerprint(privateKey);
        var assetBlob = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(
            root,
            JsonAsset(assetId, credentialId, "密钥资产")));
        var keyJson = Encoding.UTF8.GetBytes($$"""{"kind":"orbit_ssh_keys","version":1,"updatedAtUnix":2000000000,"keys":[{"id":"{{keyId}}","name":"资产密钥","format":"OpenSSH","materialFingerprint":"{{fingerprint}}","createdAtUnix":1999999990,"updatedAtUnix":2000000000,"assignedAssetIds":["{{assetId}}"],"privateKey":"{{privateKey.Replace("\n", "\\n", StringComparison.Ordinal)}}","passphrase":"sync-passphrase"}],"tombstones":[]}""");
        var keyBlob = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, keyJson));
        var assets = new Assets();
        var credentials = new Credentials();
        var keyLibrary = new SshKeyLibraryService(new Keys(), credentials);
        var protocol = new Sync([Record(assetBlob), Record(keyBlob)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(
            protocol, assets, new Snippets(), credentials, new States(), keyLibrary);

        var result = await service.SynchronizeAsync(
            Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        var restored = credentials.Values[credentialId];
        Assert.Equal("secret", restored.Password);
        Assert.Equal(privateKey, restored.PrivateKey);
        Assert.Equal("sync-passphrase", restored.PrivateKeyPassphrase);
    }

    [Fact]
    public async Task OptedInLocalSshKeyPublishesAsIndependentEncryptedEnvelope()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        const string privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nlocal-test-key\n-----END OPENSSH PRIVATE KEY-----";
        var assets = new Assets();
        var credentials = new Credentials();
        var keyLibrary = new SshKeyLibraryService(new Keys(), credentials);
        await keyLibrary.ImportAsync(
            "工作密钥", privateKey, "", CancellationToken.None,
            SshKeyOrigin.Generated, SshKeySyncScope.EndToEndEncrypted, "scope");
        var protocol = new Sync([], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(
            protocol, assets, new Snippets(), credentials, new States(), keyLibrary);

        await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(1, protocol.Uploads);
        Assert.NotNull(protocol.LastUpload);
        Assert.Null(protocol.LastUpload!.AssetId);
        var decoded = OrbitConfigCrypto.DecryptConfigLegacy(
            "correct horse",
            Convert.FromBase64String(protocol.LastUpload.EncryptedBlobBase64));
        using var document = System.Text.Json.JsonDocument.Parse(decoded);
        Assert.Equal("orbit_ssh_keys", document.RootElement.GetProperty("kind").GetString());
        Assert.Single(document.RootElement.GetProperty("keys").EnumerateArray());
    }

    [Fact]
    public async Task DeletedSynchronizedKeyPublishesDurableTombstoneWithoutSecretMaterial()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        const string privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ndelete-test-key\n-----END OPENSSH PRIVATE KEY-----";
        var assets = new Assets();
        var credentials = new Credentials();
        var states = new States();
        var keyLibrary = new SshKeyLibraryService(new Keys(), credentials);
        var key = await keyLibrary.ImportAsync(
            "待删除", privateKey, "", CancellationToken.None,
            SshKeyOrigin.Generated, SshKeySyncScope.EndToEndEncrypted, "scope");
        var firstProtocol = new Sync([], assets, credentials);
        var firstService = new EncryptedConfigSynchronizationService(
            firstProtocol, assets, new Snippets(), credentials, states, keyLibrary);
        await firstService.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);
        await keyLibrary.DeleteSynchronizedEntryAsync(key.Id, CancellationToken.None);

        var secondProtocol = new Sync([], assets, credentials);
        var secondService = new EncryptedConfigSynchronizationService(
            secondProtocol, assets, new Snippets(), credentials, states, keyLibrary);
        await secondService.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(1, secondProtocol.Uploads);
        var decoded = OrbitConfigCrypto.DecryptConfigLegacy(
            "correct horse",
            Convert.FromBase64String(secondProtocol.LastUpload!.EncryptedBlobBase64));
        using var document = System.Text.Json.JsonDocument.Parse(decoded);
        Assert.Empty(document.RootElement.GetProperty("keys").EnumerateArray());
        var tombstone = Assert.Single(document.RootElement.GetProperty("tombstones").EnumerateArray());
        Assert.Equal(key.Id, tombstone.GetProperty("id").GetGuid());
        Assert.DoesNotContain("delete-test-key", Encoding.UTF8.GetString(decoded), StringComparison.Ordinal);
    }

    [Fact]
    public async Task RemoteDesktopEnvelopeRestoresProtocolEndpointAndCredential()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var plaintext = Encoding.UTF8.GetBytes($$"""{"id":"{{id}}","credentialID":"{{credentialId}}","name":"Windows","group":"桌面","tags":["RDP"],"host":"10.0.1.25","port":3389,"username":"Administrator","transport":"rdp","allowPasswordFallback":false,"password":"rdp-secret","privateKeyContent":"","privateKeyPassphrase":""}""");
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, plaintext));
        var assets = new Assets();
        var credentials = new Credentials();
        var service = new EncryptedConfigSynchronizationService(
            new Sync([Record(encrypted)], assets, credentials),
            assets, new Snippets(), credentials, new States());

        var result = await service.SynchronizeAsync(
            Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        var asset = Assert.Single(assets.Values);
        Assert.Equal(ServerTransport.RemoteDesktop, asset.Transport);
        Assert.Equal(3389, asset.Port);
        Assert.Equal("Administrator", asset.Username);
        Assert.Equal("rdp-secret", credentials.Values[credentialId].Password);
    }

    [Fact]
    public async Task UploadedPrivateKeyAssetRestoresCompleteCanonicalCredential()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var assetId = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var plaintext = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["id"] = assetId.ToString("D"),
            ["credentialID"] = credentialId.ToString("D"),
            ["name"] = "Windows 上传密钥资产",
            ["group"] = "生产",
            ["tags"] = new[] { "key" },
            ["host"] = "key.example.test",
            ["port"] = 22,
            ["username"] = "root",
            ["transport"] = "ssh",
            ["allowPasswordFallback"] = true,
            ["password"] = "fallback",
            ["privateKeyContent"] = "\uFEFF-----BEGIN OPENSSH PRIVATE KEY-----\r\nupload-sync\r\n-----END OPENSSH PRIVATE KEY-----\r\n",
            ["privateKeyPassphrase"] = "key-passphrase",
        });
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, plaintext));
        var assets = new Assets();
        var credentials = new Credentials();
        var service = new EncryptedConfigSynchronizationService(
            new Sync([Record(encrypted)], assets, credentials),
            assets, new Snippets(), credentials, new States());

        var result = await service.SynchronizeAsync(
            Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        var restoredAsset = Assert.Single(assets.Values);
        Assert.Equal(assetId, restoredAsset.Id);
        var restoredCredential = credentials.Values[credentialId];
        Assert.Equal("fallback", restoredCredential.Password);
        Assert.Equal(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nupload-sync\n-----END OPENSSH PRIVATE KEY-----\n",
            restoredCredential.PrivateKey);
        Assert.Equal("key-passphrase", restoredCredential.PrivateKeyPassphrase);
    }

    [Fact]
    public async Task PendingLocalEditAutoMergesNonOverlappingRemoteFieldsAndKeepsUploadQueued()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var baseline = Asset(id, credentialId, "旧名称", "生产");
        var local = baseline with { Name = "Windows 改名" };
        var remoteBlob = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, JsonAsset(id, credentialId, "旧名称", "远端分组")));
        var assets = new Assets { Values = [local] };
        var credentials = new Credentials();
        await credentials.SaveAsync(credentialId, new CredentialMaterial("secret", "", ""), CancellationToken.None);
        var snapshot = new AssetSyncSnapshot(
            baseline,
            EncryptedConfigSynchronizationService.CredentialFingerprint(new CredentialMaterial("secret", "", "")));
        var metadata = new Dictionary<Guid, EncryptedAssetSyncMetadata>();
        metadata.Add(id, new EncryptedAssetSyncMetadata(1, "{\"apple\":1}", "active", 1, true));
        var pending = new Dictionary<Guid, PendingAssetSyncOperation>();
        pending.Add(id, new PendingAssetSyncOperation(PendingAssetSyncOperationKind.Upsert, "{\"apple\":1}", 1));
        var snapshots = new Dictionary<Guid, AssetSyncSnapshot>();
        snapshots.Add(id, snapshot);
        var state = new States
        {
            State = new EncryptedSyncState(Guid.NewGuid(), 0, metadata, pending, snapshots)
        };
        var service = new EncryptedConfigSynchronizationService(new Sync([Record(remoteBlob)], assets, credentials), assets, new Snippets(), credentials, state);

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(0, result.ConflictedAssets);
        Assert.Equal("Windows 改名", Assert.Single(assets.Values).Name);
        Assert.Equal("远端分组", Assert.Single(assets.Values).Group);
        Assert.Equal(PendingAssetSyncOperationKind.Upsert, state.State!.PendingOperations![id].Kind);
    }

    [Fact]
    public async Task OverlappingPendingEditIsRetainedAsConflictWithoutOverwritingLocalAsset()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var baseline = Asset(id, credentialId, "旧名称", "生产");
        var local = baseline with { Name = "Windows 改名" };
        var remoteBlob = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, JsonAsset(id, credentialId, "iOS 改名", "生产")));
        var assets = new Assets { Values = [local] };
        var credentials = new Credentials();
        await credentials.SaveAsync(credentialId, new CredentialMaterial("secret", "", ""), CancellationToken.None);
        var snapshot = new AssetSyncSnapshot(
            baseline,
            EncryptedConfigSynchronizationService.CredentialFingerprint(new CredentialMaterial("secret", "", "")));
        var metadata = new Dictionary<Guid, EncryptedAssetSyncMetadata>();
        metadata.Add(id, new EncryptedAssetSyncMetadata(1, "{\"apple\":1}", "active", 1, true));
        var pending = new Dictionary<Guid, PendingAssetSyncOperation>();
        pending.Add(id, new PendingAssetSyncOperation(PendingAssetSyncOperationKind.Upsert, "{\"apple\":1}", 1));
        var snapshots = new Dictionary<Guid, AssetSyncSnapshot>();
        snapshots.Add(id, snapshot);
        var state = new States
        {
            State = new EncryptedSyncState(Guid.NewGuid(), 0, metadata, pending, snapshots)
        };
        var service = new EncryptedConfigSynchronizationService(new Sync([Record(remoteBlob)], assets, credentials), assets, new Snippets(), credentials, state);

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(1, result.ConflictedAssets);
        Assert.Equal("Windows 改名", Assert.Single(assets.Values).Name);
        var conflict = state.State!.PendingOperations![id];
        Assert.Equal(PendingAssetSyncOperationKind.Conflict, conflict.Kind);
        Assert.Contains("名称", conflict.ConflictingFields!);
    }

    [Fact]
    public async Task RemoteTombstoneNeverSilentlyErasesAQueuedLocalEdit()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var local = Asset(id, credentialId, "Windows 改名", "生产");
        var assets = new Assets { Values = [local] };
        var credentials = new Credentials();
        await credentials.SaveAsync(credentialId, new CredentialMaterial("secret", "", ""), CancellationToken.None);
        var state = new States
        {
            State = new EncryptedSyncState(
                Guid.NewGuid(),
                0,
                new Dictionary<Guid, EncryptedAssetSyncMetadata> { [id] = new(1, "{}", "active", 1, true) },
                new Dictionary<Guid, PendingAssetSyncOperation> { [id] = new(PendingAssetSyncOperationKind.Upsert, "{}", 1) })
        };
        var deleted = new EncryptedConfigRecord(2, id.ToString("D"), null, string.Empty, "{}", "deleted", 2, DateTimeOffset.UtcNow);
        var service = new EncryptedConfigSynchronizationService(new Sync([deleted], assets, credentials), assets, new Snippets(), credentials, state);

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(1, result.ConflictedAssets);
        Assert.Single(assets.Values);
        Assert.Equal(PendingAssetSyncOperationKind.Conflict, state.State!.PendingOperations![id].Kind);
        Assert.Contains("删除与本机编辑", state.State.PendingOperations[id].ConflictingFields!);
    }

    [Fact]
    public async Task TombstoneWinsWhenCompleteInventoryAlsoContainsOlderActiveRecord()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var activeBlob = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(
            root,
            JsonAsset(id, credentialId, "已删除资产")));
        var active = new EncryptedConfigRecord(
            10, id.ToString("D").ToLowerInvariant(), null, activeBlob, "{}", "active", 10, DateTimeOffset.UtcNow.AddMinutes(-1));
        var tombstone = new EncryptedConfigRecord(
            11, id.ToString("D").ToUpperInvariant(), null, string.Empty, "{}", "deleted", 11, DateTimeOffset.UtcNow);
        var assets = new Assets { Values = [Asset(id, credentialId, "旧本机副本", "生产")] };
        var credentials = new Credentials();
        await credentials.SaveAsync(credentialId, new CredentialMaterial("secret", "", ""), CancellationToken.None);
        var service = new EncryptedConfigSynchronizationService(
            new Sync([active, tombstone], assets, credentials),
            assets,
            new Snippets(),
            credentials,
            new States());

        var result = await service.SynchronizeAsync(
            Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(1, result.DeletedAssets);
        Assert.Empty(assets.Values);
        Assert.Empty(credentials.Values);
    }

    [Fact]
    public async Task ExplicitReconciliationReplaysHistoryFromZeroCursor()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var assets = new Assets();
        var credentials = new Credentials();
        var state = new States { State = new EncryptedSyncState(Guid.NewGuid(), 77) };
        var protocol = new Sync([], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(
            protocol, assets, new Snippets(), credentials, state);

        await service.SynchronizeAsync(
            Session,
            "scope",
            "correct horse",
            root,
            CancellationToken.None,
            forceCompleteReconciliation: true);

        Assert.Equal(0UL, protocol.LastPullCursor);
    }

    [Fact]
    public async Task AppleJumpHostEnvelopeRestoresBothCredentialsAndHopMetadata()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var id = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var jumpCredentialId = Guid.NewGuid();
        var plaintext = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["id"] = id,
            ["credentialID"] = credentialId,
            ["name"] = "跨端跳板资产",
            ["group"] = "生产",
            ["tags"] = new[] { "jump" },
            ["host"] = "10.0.0.8",
            ["port"] = 22,
            ["username"] = "root",
            ["authMethod"] = "password",
            ["transport"] = "ssh",
            ["networkDeviceProfile"] = "auto",
            ["allowPasswordFallback"] = false,
            ["password"] = "destination-secret",
            ["privateKeyContent"] = "",
            ["privateKeyPassphrase"] = "",
            ["keyReference"] = "",
            ["savedAtUnix"] = 2_000_000_000,
            ["jumpHost"] = new Dictionary<string, object?>
            {
                ["credentialID"] = jumpCredentialId,
                ["host"] = "bastion.example.com",
                ["port"] = 2222,
                ["username"] = "jump",
                ["authMethod"] = "key",
                ["allowPasswordFallback"] = true,
                ["password"] = "",
                ["privateKeyContent"] = "-----BEGIN OPENSSH PRIVATE KEY-----\njump-test-key\n-----END OPENSSH PRIVATE KEY-----\n",
                ["privateKeyPassphrase"] = "jump-passphrase",
            },
        });
        var encrypted = Convert.ToBase64String(OrbitConfigCrypto.EncryptConfigV2(root, plaintext));
        var assets = new Assets();
        var credentials = new Credentials();
        var protocol = new Sync([new EncryptedConfigRecord(7, id.ToString("D"), null, encrypted, "{}", "active", 1, DateTimeOffset.UtcNow)], assets, credentials);
        var service = new EncryptedConfigSynchronizationService(protocol, assets, new Snippets(), credentials, new States());

        var result = await service.SynchronizeAsync(Session, "scope", "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedConfigSynchronizationStatus.Completed, result.Status);
        var restored = Assert.Single(assets.Values);
        Assert.NotNull(restored.JumpHost);
        Assert.Equal(jumpCredentialId, restored.JumpHost!.CredentialId);
        Assert.Equal("bastion.example.com", restored.JumpHost.Host);
        Assert.Equal("destination-secret", credentials.Values[credentialId].Password);
        Assert.Equal(
            "-----BEGIN OPENSSH PRIVATE KEY-----\njump-test-key\n-----END OPENSSH PRIVATE KEY-----\n",
            credentials.Values[jumpCredentialId].PrivateKey);
        Assert.Equal("jump-passphrase", credentials.Values[jumpCredentialId].PrivateKeyPassphrase);
        Assert.Equal(2, credentials.Values.Count);
        Assert.True(protocol.AssetsWereAppliedBeforeAcknowledgement);
    }

    private static readonly AccountSessionRecord Session = new(1, "user", "access", "refresh", DateTimeOffset.UtcNow, null, null);
    private static EncryptedConfigRecord Record(string blob) => new(1, null, null, blob, "{}", "active", null, DateTimeOffset.UtcNow);
    private static ServerAssetRecord Asset(Guid id, Guid credentialId, string name, string group) =>
        new(id, credentialId, name, "10.0.0.1", 22, "root", ServerTransport.Ssh, false, group, ["linux"]);
    private static byte[] JsonAsset(Guid id, Guid credentialId, string name, string group = "生产") => Encoding.UTF8.GetBytes($$"""{"id":"{{id}}","credentialID":"{{credentialId}}","name":"{{name}}","group":"{{group}}","tags":["linux"],"host":"10.0.0.1","port":22,"username":"root","transport":"ssh","allowPasswordFallback":false,"password":"secret","privateKeyContent":"","privateKeyPassphrase":""}""");

    private sealed class Sync(IReadOnlyList<EncryptedConfigRecord> items, Assets assets, Credentials credentials) : IOrbitEncryptedSyncProtocol
    {
        public int Acknowledgements { get; private set; }
        public int Uploads { get; private set; }
        public EncryptedConfigUpload? LastUpload { get; private set; }
        public bool AssetsWereAppliedBeforeAcknowledgement { get; private set; }
        public ulong LastPullCursor { get; private set; } = ulong.MaxValue;
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord s, EncryptedConfigUpload u, CancellationToken c)
        {
            Uploads++;
            LastUpload = u;
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigRecord>(
                new EncryptedConfigRecord(99, u.AssetId, u.IdentityFingerprint, u.EncryptedBlobBase64, u.VectorClock, "active", 1, DateTimeOffset.UtcNow), s));
        }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord s, ulong cursor, int limit, CancellationToken c)
        {
            LastPullCursor = cursor;
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigChanges>(new(items, 7, false, false), s));
        }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord s, Guid id, AssetDeletionRequest d, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord s, SyncAcknowledgement a, CancellationToken c)
        {
            AssetsWereAppliedBeforeAcknowledgement = assets.Values.Count > 0 && credentials.Values.Count > 0;
            Acknowledgements++;
            return ValueTask.FromResult(new AuthorizedProtocolResult<bool>(true, s));
        }
    }

    private sealed class Assets : IServerAssetStore
    {
        public IReadOnlyList<ServerAssetRecord> Values { get; set; } = [];
        public ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken c) => ValueTask.FromResult(Values);
        public ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken c) { Values = assets.ToArray(); return ValueTask.CompletedTask; }
    }
    private sealed class Snippets : ISnippetStore
    {
        public IReadOnlyList<SnippetRecord> Values { get; private set; } = [];
        public ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken c) => ValueTask.FromResult(Values);
        public ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken c) { Values = snippets.ToArray(); return ValueTask.CompletedTask; }
    }
    private sealed class Credentials : ICredentialVault
    {
        public Dictionary<Guid, CredentialMaterial> Values { get; } = [];
        public ValueTask<CredentialMaterial> ReadAsync(Guid id, CancellationToken c) => ValueTask.FromResult(Values.TryGetValue(id, out var value) ? value : new CredentialMaterial("", "", ""));
        public ValueTask SaveAsync(Guid id, CredentialMaterial value, CancellationToken c) { Values[id] = value; return ValueTask.CompletedTask; }
        public ValueTask DeleteAsync(Guid id, CancellationToken c) { Values.Remove(id); return ValueTask.CompletedTask; }
    }
    private sealed class States : IEncryptedSyncStateStore
    {
        public EncryptedSyncState? State;
        public ValueTask<EncryptedSyncState?> ReadAsync(string s, CancellationToken c) => ValueTask.FromResult(State);
        public ValueTask SaveAsync(string s, EncryptedSyncState state, CancellationToken c) { State = state; return ValueTask.CompletedTask; }
    }

    private sealed class Keys : ISshKeyVault
    {
        private readonly Dictionary<Guid, SshKeyVaultEntry> values = [];
        public ValueTask<IReadOnlyList<SshKeyRecord>> ListAsync(CancellationToken c) =>
            ValueTask.FromResult<IReadOnlyList<SshKeyRecord>>(values.Values.Select(item => item.Record).ToArray());
        public ValueTask<SshKeyVaultEntry?> ReadAsync(Guid id, CancellationToken c) =>
            ValueTask.FromResult(values.GetValueOrDefault(id));
        public ValueTask SaveAsync(SshKeyVaultEntry entry, CancellationToken c)
        {
            values[entry.Record.Id] = entry;
            return ValueTask.CompletedTask;
        }
        public ValueTask DeleteAsync(Guid id, CancellationToken c)
        {
            values.Remove(id);
            return ValueTask.CompletedTask;
        }
    }
}
