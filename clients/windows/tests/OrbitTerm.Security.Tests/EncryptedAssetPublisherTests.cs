using System.Text;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class EncryptedAssetPublisherTests
{
    [Fact]
    public async Task PublishUsesAppleCompatibleCiphertextAndPortableFieldNames()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var state = new States();
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, state);
        var asset = Asset();
        var result = await publisher.PublishAsync(Session, "scope", asset, new CredentialMaterial("secret", "", ""), null, "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.Published, result.Status);
        Assert.NotNull(protocol.Upload);
        var blob = Convert.FromBase64String(protocol.Upload!.EncryptedBlobBase64);
        var plaintext = OrbitConfigCrypto.DecryptConfigLegacy("correct horse", blob);
        var json = Encoding.UTF8.GetString(plaintext);
        Assert.Contains("\"credentialID\"", json, StringComparison.Ordinal);
        Assert.Contains(asset.Id.ToString("D"), json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("\"password\":\"secret\"", json, StringComparison.Ordinal);
        Assert.Equal(asset.Id.ToString("D"), protocol.Upload.AssetId);
        Assert.True(state.State!.Assets!.ContainsKey(asset.Id));
    }

    [Fact]
    public async Task UploadedWindowsPrivateKeyIsFullyIncludedInPortableAssetEnvelope()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, new States());
        var uploaded = new CredentialMaterial(
            string.Empty,
            "\uFEFF-----BEGIN OPENSSH PRIVATE KEY-----\r\nuploaded-key\r\n-----END OPENSSH PRIVATE KEY-----\r\n",
            "key-passphrase");

        var result = await publisher.PublishAsync(
            Session, "scope", Asset(), uploaded, null,
            "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.Published, result.Status);
        var plaintext = OrbitConfigCrypto.DecryptConfigLegacy(
            "correct horse", Convert.FromBase64String(protocol.Upload!.EncryptedBlobBase64));
        using var document = System.Text.Json.JsonDocument.Parse(plaintext);
        Assert.Equal("key", document.RootElement.GetProperty("authMethod").GetString());
        Assert.Equal(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nuploaded-key\n-----END OPENSSH PRIVATE KEY-----\n",
            document.RootElement.GetProperty("privateKeyContent").GetString());
        Assert.Equal("key-passphrase", document.RootElement.GetProperty("privateKeyPassphrase").GetString());
    }

    [Fact]
    public async Task ProductionPublisherRejectsAContainerOnlyKeyBeforeEncryptedUpload()
    {
        OrbitNativeLibraryLoader.Register();
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(
            protocol,
            new States(),
            enforceCorePrivateKeyValidation: true);
        var malformed = new CredentialMaterial(
            string.Empty,
            "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----",
            string.Empty);

        await Assert.ThrowsAsync<ArgumentException>(async () =>
            await publisher.PublishAsync(
                Session,
                "scope",
                Asset(),
                malformed,
                null,
                "correct horse",
                new byte[32],
                CancellationToken.None));

        Assert.Null(protocol.Upload);
    }

    [Fact]
    public async Task RemoteDesktopAssetPublishesItsProtocolPortAndEncryptedCredential()
    {
        OrbitNativeLibraryLoader.Register();
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, new States());
        var asset = Asset() with
        {
            Host = "windows.example.test",
            Port = 3389,
            Username = "Administrator",
            Transport = ServerTransport.RemoteDesktop,
        };

        var result = await publisher.PublishAsync(
            Session, "scope", asset, new CredentialMaterial("rdp-secret", "", ""), null,
            "correct horse", root, CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.Published, result.Status);
        var plaintext = OrbitConfigCrypto.DecryptConfigLegacy(
            "correct horse", Convert.FromBase64String(protocol.Upload!.EncryptedBlobBase64));
        using var document = System.Text.Json.JsonDocument.Parse(plaintext);
        Assert.Equal("rdp", document.RootElement.GetProperty("transport").GetString());
        Assert.Equal(3389, document.RootElement.GetProperty("port").GetInt32());
        Assert.Equal("Administrator", document.RootElement.GetProperty("username").GetString());
        Assert.Equal("rdp-secret", document.RootElement.GetProperty("password").GetString());
    }

    [Fact]
    public async Task TombstoneUsesTheKnownRemoteVectorAndRemovesLocalMetadata()
    {
        var asset = Asset();
        var state = new States
        {
            State = new EncryptedSyncState(Guid.NewGuid(), 8, new Dictionary<Guid, EncryptedAssetSyncMetadata>
            {
                [asset.Id] = new(42, "{\"other\":4}", "active", 4, true),
            }),
        };
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, state);
        var result = await publisher.TombstoneAsync(Session, "scope", asset.Id, new byte[32], CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.Deleted, result.Status);
        Assert.Equal(asset.Id, protocol.DeletedAssetId);
        Assert.NotNull(protocol.Deletion);
        Assert.Contains("other", protocol.Deletion!.VectorClock, StringComparison.Ordinal);
        Assert.False(state.State!.Assets!.ContainsKey(asset.Id));
    }

    [Fact]
    public async Task MissingCredentialNeverOverwritesAnExistingRemoteCredential()
    {
        var asset = Asset();
        var state = new States
        {
            State = new EncryptedSyncState(Guid.NewGuid(), 0, new Dictionary<Guid, EncryptedAssetSyncMetadata>
            {
                [asset.Id] = new(42, "{}", "active", 1, true),
            }),
        };
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, state);
        var result = await publisher.PublishAsync(Session, "scope", asset, new CredentialMaterial("", "", ""), null, "correct horse", new byte[32], CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.CredentialUnavailable, result.Status);
        Assert.Null(protocol.Upload);
    }

    [Fact]
    public async Task LocalOnlyAssetIsNeverUploaded()
    {
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, new States());
        var asset = Asset() with { StorageScope = AssetStorageScope.LocalOnly };

        var result = await publisher.PublishAsync(
            Session,
            "scope",
            asset,
            new CredentialMaterial("secret", "", ""),
            null,
            "correct horse",
            new byte[32],
            CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.LocalOnlySkipped, result.Status);
        Assert.Null(protocol.Upload);
    }

    [Fact]
    public async Task QueuedIntentSurvivesUntilTheMatchingUploadCompletes()
    {
        OrbitNativeLibraryLoader.Register();
        var asset = Asset();
        var state = new States();
        var publisher = new EncryptedAssetPublisher(new Protocol(), state);
        await publisher.QueueUpsertAsync("scope", asset.Id, CancellationToken.None);

        Assert.Equal(PendingAssetSyncOperationKind.Upsert, state.State!.PendingOperations![asset.Id].Kind);
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");
        await publisher.PublishAsync(Session, "scope", asset, new CredentialMaterial("secret", "", ""), null, "correct horse", root, CancellationToken.None);

        Assert.False(state.State!.PendingOperations!.ContainsKey(asset.Id));
        Assert.True(state.State.Snapshots!.ContainsKey(asset.Id));
    }

    [Fact]
    public async Task PublishWritesAppleCompatibleJumpHostAndSecondCredential()
    {
        OrbitNativeLibraryLoader.Register();
        var jumpCredentialId = Guid.NewGuid();
        var asset = Asset() with
        {
            JumpHost = new JumpHostRecord(jumpCredentialId, "bastion.example.com", 2222, "jump", true),
        };
        var protocol = new Protocol();
        var state = new States();
        var publisher = new EncryptedAssetPublisher(protocol, state);
        var root = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "scope");

        var result = await publisher.PublishAsync(
            Session,
            "scope",
            asset,
            new CredentialMaterial("destination-secret", "", ""),
            new CredentialMaterial(
                "",
                "-----BEGIN OPENSSH PRIVATE KEY-----\r\njump-test-key\r\n-----END OPENSSH PRIVATE KEY-----",
                "jump-passphrase"),
            "correct horse",
            root,
            CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.Published, result.Status);
        var plaintext = OrbitConfigCrypto.DecryptConfigLegacy(
            "correct horse",
            Convert.FromBase64String(protocol.Upload!.EncryptedBlobBase64));
        using var document = System.Text.Json.JsonDocument.Parse(plaintext);
        var jump = document.RootElement.GetProperty("jumpHost");
        Assert.Equal(jumpCredentialId.ToString("D"), jump.GetProperty("credentialID").GetString(), ignoreCase: true);
        Assert.Equal("bastion.example.com", jump.GetProperty("host").GetString());
        Assert.Equal(2222, jump.GetProperty("port").GetInt32());
        Assert.Equal("jump", jump.GetProperty("username").GetString());
        Assert.Equal("key", jump.GetProperty("authMethod").GetString());
        Assert.Equal(
            "-----BEGIN OPENSSH PRIVATE KEY-----\njump-test-key\n-----END OPENSSH PRIVATE KEY-----\n",
            jump.GetProperty("privateKeyContent").GetString());
        Assert.True(state.State!.Assets![asset.Id].HasJumpHostCredentialMaterial);
        Assert.NotNull(state.State.Snapshots![asset.Id].JumpHostCredentialFingerprint);
    }

    [Fact]
    public async Task MissingJumpHostCredentialNeverPublishesPartialEnvelope()
    {
        var asset = Asset() with
        {
            JumpHost = new JumpHostRecord(Guid.NewGuid(), "bastion.example.com", 22, "jump", true),
        };
        var protocol = new Protocol();
        var publisher = new EncryptedAssetPublisher(protocol, new States());

        var result = await publisher.PublishAsync(
            Session,
            "scope",
            asset,
            new CredentialMaterial("destination-secret", "", ""),
            new CredentialMaterial("", "", ""),
            "correct horse",
            new byte[32],
            CancellationToken.None);

        Assert.Equal(EncryptedAssetPublishStatus.CredentialUnavailable, result.Status);
        Assert.Null(protocol.Upload);
    }

    private static readonly AccountSessionRecord Session = new(1, "user", "access", "refresh", DateTimeOffset.UtcNow, null, null);
    private static ServerAssetRecord Asset() => new(Guid.NewGuid(), Guid.NewGuid(), "生产", "10.0.0.8", 22, "root", ServerTransport.Ssh, false, "生产", ["linux"]);

    private sealed class Protocol : IOrbitEncryptedSyncProtocol
    {
        public EncryptedConfigUpload? Upload { get; private set; }
        public Guid DeletedAssetId { get; private set; }
        public AssetDeletionRequest? Deletion { get; private set; }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord s, EncryptedConfigUpload upload, CancellationToken c)
        {
            Upload = upload;
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigRecord>(new(99, upload.AssetId, upload.IdentityFingerprint, upload.EncryptedBlobBase64, upload.VectorClock, "active", 3, DateTimeOffset.UtcNow), s));
        }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord s, ulong c, int l, CancellationToken t) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord s, SyncAcknowledgement a, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord s, Guid id, AssetDeletionRequest deletion, CancellationToken c)
        {
            DeletedAssetId = id;
            Deletion = deletion;
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigRecord>(new(99, id.ToString("D"), null, "", deletion.VectorClock, "deleted", 4, DateTimeOffset.UtcNow), s));
        }
    }
    private sealed class States : IEncryptedSyncStateStore
    {
        public EncryptedSyncState? State;
        public ValueTask<EncryptedSyncState?> ReadAsync(string s, CancellationToken c) => ValueTask.FromResult(State);
        public ValueTask SaveAsync(string s, EncryptedSyncState state, CancellationToken c) { State = state; return ValueTask.CompletedTask; }
    }
}
