using OrbitTerm.Application.Sessions;
using OrbitTerm.Platform.Windows.Sessions;
using Xunit;

namespace OrbitTerm.Platform.Windows.Tests;

public sealed class WindowsServerAssetStoreTests
{
    [Fact]
    public async Task RoundTripPreservesStorageScopeAndAccountOwner()
    {
        var directory = Path.Combine(Path.GetTempPath(), "OrbitTerm-AssetStore", Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "assets.json");
        var owner = new string('a', 64);
        var local = Asset("local") with { StorageScope = AssetStorageScope.LocalOnly };
        var synced = Asset("synced") with
        {
            StorageScope = AssetStorageScope.AccountSynced,
            OwnerAccountScope = owner,
        };
        try
        {
            var store = new WindowsServerAssetStore(path);
            await store.SaveAsync([local, synced], default);

            var restored = await store.LoadAsync(default);

            Assert.Equal(2, restored.Count);
            Assert.Equal(AssetStorageScope.LocalOnly, restored.Single(item => item.Id == local.Id).StorageScope);
            Assert.Null(restored.Single(item => item.Id == local.Id).OwnerAccountScope);
            Assert.Equal(owner, restored.Single(item => item.Id == synced.Id).OwnerAccountScope);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static ServerAssetRecord Asset(string name) => new(
        Guid.NewGuid(),
        Guid.NewGuid(),
        name,
        "192.0.2.10",
        22,
        "root",
        ServerTransport.Ssh,
        true);
}
