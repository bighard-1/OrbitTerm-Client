using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class VerifiedSessionRegistryTests
{
    [Fact]
    public void RegisterStoresLatestVerifiedLeasePerWorkspaceAndServer()
    {
        var registry = new VerifiedSessionRegistry();
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();

        registry.Register(CreateLease(workspaceId, serverId, 1));
        registry.Register(CreateLease(workspaceId, serverId, 2));

        Assert.True(registry.TryGet(workspaceId, serverId, out var lease));
        Assert.Equal(2UL, lease.BaseSessionId);
        Assert.Equal(1, registry.Count);
    }

    [Fact]
    public void RemoveRequiresTheCurrentLease()
    {
        var registry = new VerifiedSessionRegistry();
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var oldLease = CreateLease(workspaceId, serverId, 1);
        var currentLease = CreateLease(workspaceId, serverId, 2);

        registry.Register(oldLease);
        registry.Register(currentLease);

        Assert.False(registry.Remove(oldLease));
        Assert.True(registry.Remove(currentLease));
        Assert.False(registry.TryGet(workspaceId, serverId, out _));
    }

    [Fact]
    public void InvalidLeaseIsRejected()
    {
        var registry = new VerifiedSessionRegistry();
        var lease = CreateLease(Guid.NewGuid(), Guid.NewGuid(), 0);

        Assert.Throws<ArgumentException>(() => registry.Register(lease));
    }

    private static VerifiedSessionLease CreateLease(Guid workspaceId, Guid serverId, ulong baseSessionId)
    {
        return new VerifiedSessionLease(
            workspaceId,
            serverId,
            baseSessionId,
            "example.com",
            22,
            "alice",
            "ssh-ed25519",
            "SHA256:abc");
    }
}
