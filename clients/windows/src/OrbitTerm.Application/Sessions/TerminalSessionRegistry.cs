using System.Collections.Concurrent;
using OrbitTerm.Terminal;

namespace OrbitTerm.Application.Sessions;

public sealed class TerminalSessionRegistry
{
    private readonly ConcurrentDictionary<TerminalKey, TerminalSessionLease> leases = new();

    public int Count => leases.Count;

    public TerminalSessionLease Register(TerminalSessionLease lease)
    {
        Validate(lease);
        leases[new TerminalKey(lease.WorkspaceId, lease.ServerId, lease.TerminalChannelId)] = lease;
        return lease;
    }

    public bool TryGet(Guid workspaceId, Guid serverId, ulong terminalChannelId, out TerminalSessionLease lease)
    {
        return leases.TryGetValue(new TerminalKey(workspaceId, serverId, terminalChannelId), out lease!);
    }

    public bool TryGetByChannelId(ulong terminalChannelId, out TerminalSessionLease lease)
    {
        foreach (var candidate in leases.Values)
        {
            if (candidate.TerminalChannelId == terminalChannelId)
            {
                lease = candidate;
                return true;
            }
        }

        lease = null!;
        return false;
    }

    public TerminalSessionLease UpdateSize(TerminalSessionLease lease, TerminalSize size)
    {
        Validate(lease);
        size.Validate();

        var updated = lease with { Size = size };
        leases[new TerminalKey(lease.WorkspaceId, lease.ServerId, lease.TerminalChannelId)] = updated;
        return updated;
    }

    public bool Remove(TerminalSessionLease lease)
    {
        Validate(lease);
        return leases.TryRemove(
            new KeyValuePair<TerminalKey, TerminalSessionLease>(
                new TerminalKey(lease.WorkspaceId, lease.ServerId, lease.TerminalChannelId),
                lease));
    }

    public IReadOnlyList<TerminalSessionLease> RemoveAll(Guid workspaceId, Guid serverId)
    {
        var removed = new List<TerminalSessionLease>();
        foreach (var pair in leases.ToArray())
        {
            if (pair.Key.WorkspaceId != workspaceId || pair.Key.ServerId != serverId)
            {
                continue;
            }
            if (leases.TryRemove(pair))
            {
                removed.Add(pair.Value);
            }
        }
        return removed;
    }

    private static void Validate(TerminalSessionLease lease)
    {
        lease.Size.Validate();

        if (lease.WorkspaceId == Guid.Empty ||
            lease.ServerId == Guid.Empty ||
            lease.BaseSessionId == 0 ||
            lease.TerminalChannelId == 0 ||
            string.IsNullOrWhiteSpace(lease.Host) ||
            lease.Port is < 1 or > 65535 ||
            string.IsNullOrWhiteSpace(lease.HostKeyAlgorithm) ||
            string.IsNullOrWhiteSpace(lease.HostKeyFingerprintSha256))
        {
            throw new ArgumentException("Terminal session lease is incomplete.", nameof(lease));
        }
    }

    private readonly record struct TerminalKey(Guid WorkspaceId, Guid ServerId, ulong TerminalChannelId);
}
