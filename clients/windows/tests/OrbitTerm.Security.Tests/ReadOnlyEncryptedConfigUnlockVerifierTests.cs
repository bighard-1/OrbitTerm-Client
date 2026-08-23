using OrbitTerm.Application.Accounts;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class ReadOnlyEncryptedConfigUnlockVerifierTests
{
    [Fact]
    public async Task EmptyRemoteStateRequiresExplicitFirstDeviceSetup()
    {
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(new Sync([]));
        var result = await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None);
        Assert.Null(result);
    }

    [Fact]
    public async Task InvalidCiphertextDoesNotUnlockAndNeverAcknowledges()
    {
        var sync = new Sync([Record("not-base64")]);
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);
        var result = await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None);
        Assert.False(result);
        Assert.Equal(1, sync.PullCount);
    }

    [Fact]
    public async Task V2CiphertextFromTheSharedCoreUnlocksReadOnlyWithoutAcknowledgement()
    {
        OrbitTerm.NativeBridge.OrbitNativeLibraryLoader.Register();
        var root = OrbitTerm.NativeBridge.OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "account-scope");
        var encrypted = OrbitTerm.NativeBridge.OrbitConfigCrypto.EncryptConfigV2(root, "payload"u8.ToArray());
        var sync = new Sync([Record(Convert.ToBase64String(encrypted))]);
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);

        var result = await verifier.VerifyAsync(Session, "correct horse", root, CancellationToken.None);

        Assert.True(result);
        Assert.Equal(1, sync.PullCount);
    }

    [Fact]
    public async Task LegacyCiphertextFromTheSharedCoreAlsoUnlocksReadOnly()
    {
        OrbitTerm.NativeBridge.OrbitNativeLibraryLoader.Register();
        var encrypted = OrbitTerm.NativeBridge.OrbitConfigCrypto.EncryptConfigLegacy("correct horse", "legacy"u8.ToArray());
        var sync = new Sync([Record(Convert.ToBase64String(encrypted))]);
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);

        var result = await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None);

        Assert.True(result);
        Assert.Equal(1, sync.PullCount);
    }

    private static readonly AccountSessionRecord Session = new(1, "user", "access", "refresh", DateTimeOffset.UtcNow, null, null);
    private static EncryptedConfigRecord Record(string blob) => new(1, null, null, blob, "v", null, null, DateTimeOffset.UtcNow);
    private sealed class Sync(IReadOnlyList<EncryptedConfigRecord> items) : IOrbitEncryptedSyncProtocol
    {
        public int PullCount { get; private set; }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord s, EncryptedConfigUpload u, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord s, ulong cursor, int limit, CancellationToken c) { PullCount++; return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigChanges>(new(items, 0, false, false), s)); }
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord s, SyncAcknowledgement a, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord s, Guid id, AssetDeletionRequest d, CancellationToken c) => throw new NotSupportedException();
    }
}
