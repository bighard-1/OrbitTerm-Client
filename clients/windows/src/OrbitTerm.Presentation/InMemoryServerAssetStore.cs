using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

internal sealed class InMemoryServerAssetStore : IServerAssetStore
{
    private IReadOnlyList<ServerAssetRecord> assets = [];

    public ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(assets);
    }

    public ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        this.assets = assets.ToArray();
        return ValueTask.CompletedTask;
    }
}
