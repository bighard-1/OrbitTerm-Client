using OrbitTerm.Application.Sessions;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalSessionRegistryTests
{
    [Fact]
    public void RegisterStoresTerminalLeaseByWorkspaceServerAndChannel()
    {
        var registry = new TerminalSessionRegistry();
        var lease = CreateLease(5);

        registry.Register(lease);

        Assert.True(registry.TryGet(lease.WorkspaceId, lease.ServerId, 5, out var current));
        Assert.Equal(lease, current);
        Assert.Equal(1, registry.Count);
    }

    [Fact]
    public void UpdateSizeReplacesTheCurrentLease()
    {
        var registry = new TerminalSessionRegistry();
        var lease = CreateLease(5);

        registry.Register(lease);
        var updated = registry.UpdateSize(lease, new TerminalSize(100, 30));

        Assert.True(registry.TryGet(lease.WorkspaceId, lease.ServerId, 5, out var current));
        Assert.Equal(updated, current);
        Assert.Equal(new TerminalSize(100, 30), current.Size);
    }

    [Fact]
    public void RemoveRequiresTheCurrentLease()
    {
        var registry = new TerminalSessionRegistry();
        var lease = CreateLease(5);
        var updated = lease with { Size = new TerminalSize(100, 30) };

        registry.Register(lease);
        registry.UpdateSize(lease, updated.Size);

        Assert.False(registry.Remove(lease));
        Assert.True(registry.Remove(updated));
        Assert.False(registry.TryGet(lease.WorkspaceId, lease.ServerId, 5, out _));
    }

    [Fact]
    public void InvalidTerminalLeaseIsRejected()
    {
        var registry = new TerminalSessionRegistry();
        var lease = CreateLease(0);

        Assert.Throws<ArgumentException>(() => registry.Register(lease));
    }

    [Fact]
    public void RemoveAllDropsOnlyTheDisconnectedAssetPanes()
    {
        var registry = new TerminalSessionRegistry();
        var primary = CreateLease(5);
        var split = primary with { TerminalChannelId = 6 };
        var other = CreateLease(7);
        registry.Register(primary);
        registry.Register(split);
        registry.Register(other);

        var removed = registry.RemoveAll(primary.WorkspaceId, primary.ServerId);

        Assert.Equal(2, removed.Count);
        Assert.False(registry.TryGet(primary.WorkspaceId, primary.ServerId, 5, out _));
        Assert.False(registry.TryGet(primary.WorkspaceId, primary.ServerId, 6, out _));
        Assert.True(registry.TryGet(other.WorkspaceId, other.ServerId, 7, out _));
    }

    private static TerminalSessionLease CreateLease(ulong terminalChannelId)
    {
        return new TerminalSessionLease(
            Guid.NewGuid(),
            Guid.NewGuid(),
            9,
            terminalChannelId,
            TerminalSize.Default,
            "example.com",
            22,
            "ssh-ed25519",
            "SHA256:abc");
    }
}
