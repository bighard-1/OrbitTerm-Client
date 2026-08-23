using System.Text;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class EncryptedSnippetPublisherTests
{
    [Fact]
    public async Task PublishUsesAppleSnippetEnvelopeAndPersistsTheRemoteCursor()
    {
        OrbitNativeLibraryLoader.Register();
        var protocol = new Protocol();
        var state = new StateStore();
        var publisher = new EncryptedSnippetPublisher(protocol, state);
        var snippets = new[]
        {
            new SnippetRecord(Guid.NewGuid(), "日志", "journalctl -u sshd", "系统", DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow),
        };

        var result = await publisher.PublishAsync(Session, "scope", snippets, "correct horse", new byte[32], CancellationToken.None);

        Assert.Equal(1, result.PublishedCount);
        Assert.NotNull(protocol.Upload);
        Assert.Null(protocol.Upload!.AssetId);
        var plaintext = OrbitConfigCrypto.DecryptConfigLegacy("correct horse", Convert.FromBase64String(protocol.Upload.EncryptedBlobBase64));
        var json = Encoding.UTF8.GetString(plaintext);
        Assert.Contains("\"kind\":\"orbit_snippets\"", json, StringComparison.Ordinal);
        Assert.Contains("\"version\":1", json, StringComparison.Ordinal);
        Assert.Contains("\"createdAt\":", json, StringComparison.Ordinal);
        Assert.DoesNotContain("2026-", json, StringComparison.Ordinal);
        Assert.Equal((ulong)71, state.State!.SnippetMetadata!.RemoteId);
        Assert.Contains("snippet_client", state.State.SnippetMetadata.VectorClock, StringComparison.Ordinal);
    }

    private static readonly AccountSessionRecord Session = new(1, "user", "access", "refresh", DateTimeOffset.UtcNow, null, null);

    private sealed class Protocol : IOrbitEncryptedSyncProtocol
    {
        public EncryptedConfigUpload? Upload { get; private set; }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord session, EncryptedConfigUpload upload, CancellationToken cancellationToken)
        {
            Upload = upload;
            return ValueTask.FromResult(new AuthorizedProtocolResult<EncryptedConfigRecord>(
                new(71, null, null, upload.EncryptedBlobBase64, upload.VectorClock, "active", 1, DateTimeOffset.UtcNow), session));
        }
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord session, ulong cursor, int limit, CancellationToken cancellationToken) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord session, SyncAcknowledgement acknowledgement, CancellationToken cancellationToken) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(AccountSessionRecord session, Guid assetId, AssetDeletionRequest deletion, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class StateStore : IEncryptedSyncStateStore
    {
        public EncryptedSyncState? State { get; private set; }
        public ValueTask<EncryptedSyncState?> ReadAsync(string accountScope, CancellationToken cancellationToken) => ValueTask.FromResult(State);
        public ValueTask SaveAsync(string accountScope, EncryptedSyncState state, CancellationToken cancellationToken) { State = state; return ValueTask.CompletedTask; }
    }
}
