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
