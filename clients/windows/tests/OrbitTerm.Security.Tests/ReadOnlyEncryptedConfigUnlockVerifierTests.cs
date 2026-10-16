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
    public async Task EmptyPurgedTombstoneCannotBeUsedAsMasterPasswordEvidence()
    {
        var sync = new Sync([Record(string.Empty, "purged")]);
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);

        Assert.Null(await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None));
        Assert.Equal(1, sync.PullCount);
    }

    [Fact]
    public async Task PurgedFirstPageDoesNotHideEncryptedRecordOnNextPage()
    {
        OrbitTerm.NativeBridge.OrbitNativeLibraryLoader.Register();
        var encrypted = OrbitTerm.NativeBridge.OrbitConfigCrypto.EncryptConfigLegacy("correct horse", "proof"u8.ToArray());
        var sync = new PagedSync(
            new EncryptedConfigChanges([Record(string.Empty, "purged")], 9, true, false),
            new EncryptedConfigChanges([Record(Convert.ToBase64String(encrypted))], 10, false, false));
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);

        Assert.True(await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None));
        Assert.Equal(new ulong[] { 0, 9 }, sync.Cursors);
    }

    [Fact]
    public async Task NonAdvancingVerificationCursorFailsClosed()
    {
        var sync = new PagedSync(new EncryptedConfigChanges([Record(string.Empty, "purged")], 0, true, false));
        var verifier = new ReadOnlyEncryptedConfigUnlockVerifier(sync);

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await verifier.VerifyAsync(Session, "correct horse", new byte[32], CancellationToken.None));
        Assert.Equal(new ulong[] { 0 }, sync.Cursors);
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
    private static EncryptedConfigRecord Record(string blob, string? state = null) => new(1, null, null, blob, "v", state, null, DateTimeOffset.UtcNow);
    private sealed class Sync(IReadOnlyList<EncryptedConfigRecord> items) : IOrbitEncryptedSyncProtocol
    {
        public int PullCount { get; private set; }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord s, EncryptedConfigUpload u, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord s, ulong cursor, int limit, CancellationToken c) { PullCount++; return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigChanges>(new(items, 0, false, false), s)); }
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord s, SyncAcknowledgement a, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord s, Guid id, AssetDeletionRequest d, CancellationToken c) => throw new NotSupportedException();
    }

    private sealed class PagedSync(params EncryptedConfigChanges[] pages) : IOrbitEncryptedSyncProtocol
    {
        public List<ulong> Cursors { get; } = [];
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord s, EncryptedConfigUpload u, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord s, ulong cursor, int limit, CancellationToken c)
        {
            Cursors.Add(cursor);
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigChanges>(pages[Cursors.Count - 1], s));
        }
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord s, SyncAcknowledgement a, CancellationToken c) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord s, Guid id, AssetDeletionRequest d, CancellationToken c) => throw new NotSupportedException();
    }
}
