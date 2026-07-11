using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalOpenResultTests
{
    [Fact]
    public void OpenedTerminalMapsToLeaseOnlyForMatchingBaseSessionAndSize()
    {
        var baseLease = CreateLease(42);
        var outcome = new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
            "42",
            "77",
            CheckedSecurityGeneration.HostKeyVerified,
            120,
            32));

        var result = TerminalOpenResult.FromNative(baseLease, new TerminalSize(120, 32), outcome);

        var opened = Assert.IsType<TerminalOpenResult.Opened>(result);
        Assert.Equal(77UL, opened.Lease.TerminalChannelId);
        Assert.Equal(42UL, opened.Lease.BaseSessionId);
        Assert.Equal(new TerminalSize(120, 32), opened.Lease.Size);
    }

    [Fact]
    public void TerminalOpenRejectsDifferentBaseSession()
    {
        var baseLease = CreateLease(42);
        var outcome = new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
            "43",
            "77",
            CheckedSecurityGeneration.HostKeyVerified,
            120,
            32));

        Assert.Throws<InvalidOperationException>(() =>
            TerminalOpenResult.FromNative(baseLease, new TerminalSize(120, 32), outcome));
    }

    [Fact]
    public void TerminalOpenRejectsSizeDrift()
    {
        var baseLease = CreateLease(42);
        var outcome = new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
            "42",
            "77",
            CheckedSecurityGeneration.HostKeyVerified,
            100,
            32));

        Assert.Throws<InvalidOperationException>(() =>
            TerminalOpenResult.FromNative(baseLease, new TerminalSize(120, 32), outcome));
    }

    [Fact]
    public void TerminalOpenErrorMapsToFailedResult()
    {
        var result = TerminalOpenResult.FromNative(
            CreateLease(42),
            TerminalSize.Default,
            new CheckedTerminalOpenOutcome.Failed(new CheckedErrorPayload(
                "checked_terminal_not_verified",
                "error.terminal.not_verified",
                "request-1")));

        var failed = Assert.IsType<TerminalOpenResult.Failed>(result);
        Assert.Equal("checked_terminal_not_verified", failed.Code);
    }

    private static VerifiedSessionLease CreateLease(ulong baseSessionId)
    {
        return new VerifiedSessionLease(
            Guid.NewGuid(),
            Guid.NewGuid(),
            baseSessionId,
            "example.com",
            22,
            "alice",
            "ssh-ed25519",
            "SHA256:abc");
    }
}
