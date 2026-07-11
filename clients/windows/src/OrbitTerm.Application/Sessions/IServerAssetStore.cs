namespace OrbitTerm.Application.Sessions;

public interface IServerAssetStore
{
    ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken cancellationToken);

    ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken cancellationToken);
}
