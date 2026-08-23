using OrbitTerm.Application.Sessions;
using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class RemoteAccessPolicyTests
{
    [Fact]
    public void LocalTunnelDefaultsCanRemainLoopbackOnly()
    {
        var rule = PortForwardingPolicy.Validate(new PortForwardingRule(
            Guid.NewGuid(), Guid.NewGuid(), "数据库", PortForwardingMode.Local,
            "127.0.0.1", 0, "db.internal", 5432));

        Assert.False(PortForwardingPolicy.RequiresExplicitExposureConfirmation(rule));
        Assert.Equal(0, rule.BindPort);
    }

    [Fact]
    public void PublicBindRequiresExplicitExposureConfirmation()
    {
        var rule = PortForwardingPolicy.Validate(new PortForwardingRule(
            Guid.NewGuid(), Guid.NewGuid(), "共享代理", PortForwardingMode.DynamicSocks5,
            "0.0.0.0", 1080, string.Empty, 0));

        Assert.True(PortForwardingPolicy.RequiresExplicitExposureConfirmation(rule));
        Assert.Empty(rule.DestinationHost);
    }

    [Fact]
    public void RdpFailsClosedWhenNlaIsDisabledAndFlagsRedirection()
    {
        var request = RemoteDesktopPolicy.Validate(new RemoteDesktopLaunchRequest(
            Guid.NewGuid(), "rdp.example.test", ClipboardEnabled: true));
        Assert.True(RemoteDesktopPolicy.RequiresRedirectionConfirmation(request));

        Assert.Throws<InvalidOperationException>(() => RemoteDesktopPolicy.Validate(
            request with { UseNetworkLevelAuthentication = false }));
    }

    [Fact]
    public void RemoteDesktopAssetKeepsItsProtocolAndNativeLabel()
    {
        var record = new ServerAssetRecord(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "财务 Windows",
            "10.0.1.25",
            3389,
            "Administrator",
            ServerTransport.RemoteDesktop,
            false,
            "Windows",
            ["RDP"]);

        var asset = AssetViewModel.FromRecord(record);

        Assert.Equal(ServerTransport.RemoteDesktop, asset.Transport);
        Assert.Equal("RDP", asset.TransportLabel);
        Assert.Equal(record, asset.ToRecord());
    }
}
