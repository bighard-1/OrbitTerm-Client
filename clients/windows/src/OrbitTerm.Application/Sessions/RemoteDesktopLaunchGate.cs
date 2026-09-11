namespace OrbitTerm.Application.Sessions;

/// <summary>
/// Coalesces duplicate activation events for the same saved RDP asset while
/// still allowing different assets to launch independently.
/// </summary>
public sealed class RemoteDesktopLaunchGate
{
    private readonly object sync = new();
    private readonly HashSet<Guid> activeAssetIds = [];

    public IDisposable? TryAcquire(Guid assetId)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(assetId, Guid.Empty);
        lock (sync)
        {
            if (!activeAssetIds.Add(assetId)) return null;
        }
        return new Lease(this, assetId);
    }

    private void Release(Guid assetId)
    {
        lock (sync) activeAssetIds.Remove(assetId);
    }

    private sealed class Lease(RemoteDesktopLaunchGate owner, Guid assetId) : IDisposable
    {
        private RemoteDesktopLaunchGate? owner = owner;

        public void Dispose() => Interlocked.Exchange(ref owner, null)?.Release(assetId);
    }
}
