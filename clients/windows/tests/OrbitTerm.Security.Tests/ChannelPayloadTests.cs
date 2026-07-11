using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class ChannelPayloadTests
{
    [Fact]
    public void TerminalChannelRejectsLegacyGeneration()
    {
        var payload = new TerminalChannelOpenedPayload(
            "1",
            "2",
            CheckedSecurityGeneration.LegacyUnverified,
            120,
            32);

        Assert.Throws<OrbitNativeException>(payload.Validate);
    }

    [Fact]
    public void TerminalChannelRejectsInvalidSize()
    {
        var payload = new TerminalChannelOpenedPayload(
            "1",
            "2",
            CheckedSecurityGeneration.HostKeyVerified,
            0,
            32);

        Assert.Throws<OrbitNativeException>(payload.Validate);
    }

    [Fact]
    public void SftpChannelRequiresVerifiedGeneration()
    {
        var payload = new SftpChannelOpenedPayload(
            "1",
            "5",
            CheckedSecurityGeneration.LegacyUnverified);

        Assert.Throws<OrbitNativeException>(payload.Validate);
    }
}
