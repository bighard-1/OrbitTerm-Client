using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class PortForwardProfileSynchronizationTests
{
    [Fact]
    public async Task RemoteTombstoneDeletesOnlySynchronizedProfileInSameAccount()
    {
        var vault = new MemoryVault();
        var library = new PortForwardProfileLibrary(vault);
        var now = DateTimeOffset.UtcNow;
        var id = Guid.NewGuid(); var asset = Guid.NewGuid();
        await library.SaveAsync("account-a", new(
            new(id, asset, "数据库", PortForwardingMode.Local, "127.0.0.1", 13306, "127.0.0.1", 3306),
            now, now, PortForwardProfileSyncScope.EndToEndEncrypted, "account-a"), CancellationToken.None);
        await library.SaveAsync("account-b", new(
            new(id, asset, "其他账户", PortForwardingMode.Local, "127.0.0.1", 13307, "127.0.0.1", 3306),
            now, now, PortForwardProfileSyncScope.EndToEndEncrypted, "account-b"), CancellationToken.None);

        var sync = new EncryptedPortForwardProfileSynchronization(library);
        await sync.ApplyAsync(new(
            PortForwardProfileSyncContract.Marker, 1, now.ToUnixTimeSeconds() + 2, [],
            [new(id, now.ToUnixTimeSeconds() + 1)]), "account-a", CancellationToken.None);

        Assert.Empty(await library.ListAsync("account-a", null, CancellationToken.None));
        Assert.Single(await library.ListAsync("account-b", null, CancellationToken.None));
    }

    [Fact]
    public async Task LocalOnlyProfileNeverLeavesEncryptedEnvelope()
    {
        var library = new PortForwardProfileLibrary(new MemoryVault());
        var now = DateTimeOffset.UtcNow;
        await library.SaveAsync("account-a", new(
            new(Guid.NewGuid(), Guid.NewGuid(), "仅本机", PortForwardingMode.Local, "127.0.0.1", 10022, "127.0.0.1", 22),
            now, now, PortForwardProfileSyncScope.LocalOnly, null), CancellationToken.None);
        var sync = new EncryptedPortForwardProfileSynchronization(library);
        var local = await sync.BuildLocalEnvelopeAsync("account-a", null, CancellationToken.None);
        Assert.Empty(local.Envelope.Profiles);
    }

    private sealed class MemoryVault : IPortForwardProfileVault
    {
        private readonly Dictionary<string, PortForwardProfileVaultDocument> documents = [];
        public ValueTask<PortForwardProfileVaultDocument> ReadAsync(string scope, CancellationToken token) =>
            ValueTask.FromResult(documents.GetValueOrDefault(scope) ?? new(1, [], new Dictionary<Guid, long>()));
        public ValueTask SaveAsync(string scope, PortForwardProfileVaultDocument document, CancellationToken token)
        { documents[scope] = document; return ValueTask.CompletedTask; }
        public ValueTask DeleteAccountAsync(string scope, CancellationToken token)
        { documents.Remove(scope); return ValueTask.CompletedTask; }
    }
}
