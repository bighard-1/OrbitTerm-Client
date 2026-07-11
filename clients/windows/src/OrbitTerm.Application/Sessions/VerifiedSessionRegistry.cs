using System.Collections.Concurrent;

namespace OrbitTerm.Application.Sessions;

public sealed class VerifiedSessionRegistry
{
    private readonly ConcurrentDictionary<SessionKey, VerifiedSessionLease> leases = new();

    public int Count => leases.Count;

    public VerifiedSessionLease Register(VerifiedSessionLease lease)
    {
        Validate(lease);
        leases[new SessionKey(lease.WorkspaceId, lease.ServerId)] = lease;
        return lease;
    }

    public bool TryGet(Guid workspaceId, Guid serverId, out VerifiedSessionLease lease)
    {
        return leases.TryGetValue(new SessionKey(workspaceId, serverId), out lease!);
    }

    public bool Remove(VerifiedSessionLease lease)
    {
        Validate(lease);
        return leases.TryRemove(
            new KeyValuePair<SessionKey, VerifiedSessionLease>(
                new SessionKey(lease.WorkspaceId, lease.ServerId),
                lease));
    }

    private static void Validate(VerifiedSessionLease lease)
    {
        if (lease.WorkspaceId == Guid.Empty ||
            lease.ServerId == Guid.Empty ||
            lease.BaseSessionId == 0 ||
            string.IsNullOrWhiteSpace(lease.Host) ||
            lease.Port is < 1 or > 65535 ||
            string.IsNullOrWhiteSpace(lease.HostKeyAlgorithm) ||
            string.IsNullOrWhiteSpace(lease.HostKeyFingerprintSha256))
        {
            throw new ArgumentException("Verified session lease is incomplete.", nameof(lease));
        }
    }

    private readonly record struct SessionKey(Guid WorkspaceId, Guid ServerId);
}
