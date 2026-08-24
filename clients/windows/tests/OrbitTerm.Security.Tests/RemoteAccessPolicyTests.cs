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

    [Fact]
    public void RemoteDesktopStateMachineRejectsStaleRevivalAfterClose()
    {
        var machine = new RemoteDesktopSessionStateMachine();

        Assert.True(machine.TryTransition(new(
            RemoteDesktopSessionPhase.Authenticating,
            "正在验证")));
        Assert.True(machine.TryTransition(new(
            RemoteDesktopSessionPhase.AwaitingUserDecision,
            "等待证书确认")));
        Assert.True(machine.TryTransition(new(
            RemoteDesktopSessionPhase.Connected,
            "已连接")));
        Assert.True(machine.TryTransition(new(
            RemoteDesktopSessionPhase.Disconnected,
            "已断开",
            RemoteDesktopFailureKind.NetworkUnavailable,
            CanRetry: true)));
        Assert.True(machine.TryTransition(new(
            RemoteDesktopSessionPhase.Closed,
            "已关闭")));
        Assert.False(machine.TryTransition(new(
            RemoteDesktopSessionPhase.Connected,
            "迟到的已连接事件")));
        Assert.Equal(RemoteDesktopSessionPhase.Closed, machine.Current.Phase);
    }

    [Fact]
    public void RemoteDesktopFailureFeedbackDoesNotExposeNativeExceptionText()
    {
        var update = new RemoteDesktopSessionUpdate(
            RemoteDesktopSessionPhase.Failed,
            "native detail with host and username",
            RemoteDesktopFailureKind.AuthenticationFailed,
            "0x80004005",
            CanRetry: true);

        var message = RemoteDesktopFailurePresentation.UserMessage(update);

        Assert.Contains("身份验证失败", message);
        Assert.DoesNotContain("native detail", message);
        Assert.DoesNotContain("username", message);
    }
}
