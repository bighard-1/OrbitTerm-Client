namespace OrbitTerm.Application.Sessions;

public enum RemoteDesktopSessionPhase
{
    Starting,
    Authenticating,
    AwaitingUserDecision,
    Connected,
    Reconnecting,
    Disconnected,
    Failed,
    Closed,
}

public enum RemoteDesktopFailureKind
{
    None,
    EngineUnavailable,
    InvalidTarget,
    CertificateRejected,
    AuthenticationFailed,
    NetworkUnavailable,
    TimedOut,
    ProtocolError,
    Cancelled,
    Unknown,
}

public sealed record RemoteDesktopSessionUpdate(
    RemoteDesktopSessionPhase Phase,
    string Message,
    RemoteDesktopFailureKind FailureKind = RemoteDesktopFailureKind.None,
    string ErrorCode = "",
    bool CanRetry = false,
    DateTimeOffset? OccurredAt = null)
{
    public DateTimeOffset Timestamp { get; } = OccurredAt ?? DateTimeOffset.UtcNow;
}

/// <summary>
/// Owns the platform-independent RDP lifecycle contract. Native controls may
/// publish state, but cannot skip trust/authentication phases or revive a
/// session after it has been closed.
/// </summary>
public sealed class RemoteDesktopSessionStateMachine
{
    private static readonly IReadOnlyDictionary<RemoteDesktopSessionPhase, HashSet<RemoteDesktopSessionPhase>> Allowed =
        new Dictionary<RemoteDesktopSessionPhase, HashSet<RemoteDesktopSessionPhase>>
        {
            [RemoteDesktopSessionPhase.Starting] =
                [RemoteDesktopSessionPhase.Authenticating, RemoteDesktopSessionPhase.AwaitingUserDecision,
                    RemoteDesktopSessionPhase.Failed, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Authenticating] =
                [RemoteDesktopSessionPhase.AwaitingUserDecision, RemoteDesktopSessionPhase.Connected,
                    RemoteDesktopSessionPhase.Reconnecting,
                    RemoteDesktopSessionPhase.Failed, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.AwaitingUserDecision] =
                [RemoteDesktopSessionPhase.Authenticating, RemoteDesktopSessionPhase.Connected,
                    RemoteDesktopSessionPhase.Reconnecting,
                    RemoteDesktopSessionPhase.Failed, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Connected] =
                [RemoteDesktopSessionPhase.Reconnecting, RemoteDesktopSessionPhase.Disconnected,
                    RemoteDesktopSessionPhase.Failed, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Reconnecting] =
                [RemoteDesktopSessionPhase.Authenticating, RemoteDesktopSessionPhase.AwaitingUserDecision,
                    RemoteDesktopSessionPhase.Connected, RemoteDesktopSessionPhase.Disconnected,
                    RemoteDesktopSessionPhase.Failed, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Disconnected] =
                [RemoteDesktopSessionPhase.Reconnecting, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Failed] =
                [RemoteDesktopSessionPhase.Reconnecting, RemoteDesktopSessionPhase.Closed],
            [RemoteDesktopSessionPhase.Closed] = [],
        };

    public RemoteDesktopSessionUpdate Current { get; private set; } =
        new(RemoteDesktopSessionPhase.Starting, "正在准备远程桌面组件…");

    public bool TryTransition(RemoteDesktopSessionUpdate update)
    {
        ArgumentNullException.ThrowIfNull(update);
        if (update.Phase == Current.Phase)
        {
            Current = update;
            return true;
        }
        if (!Allowed[Current.Phase].Contains(update.Phase))
            return false;
        Current = update;
        return true;
    }
}

public static class RemoteDesktopFailurePresentation
{
    public static string UserMessage(RemoteDesktopSessionUpdate update) => update.FailureKind switch
    {
        RemoteDesktopFailureKind.EngineUnavailable =>
            "Windows 远程桌面组件不可用，请修复系统组件或重新安装完整客户端。",
        RemoteDesktopFailureKind.InvalidTarget =>
            "远程桌面地址或端口无效，请检查资产配置。",
        RemoteDesktopFailureKind.ProtocolError =>
            "远程桌面窗口初始化失败，请关闭窗口后重试。",
        RemoteDesktopFailureKind.CertificateRejected =>
            "服务器证书未被接受。请确认目标身份后选择继续，或取消本次连接。",
        RemoteDesktopFailureKind.AuthenticationFailed =>
            "远程桌面身份验证失败，请检查用户名、密码和 NLA 设置。",
        RemoteDesktopFailureKind.NetworkUnavailable =>
            "无法连接远程桌面端口，请检查网络、防火墙和远端 RDP 服务。",
        RemoteDesktopFailureKind.TimedOut =>
            "远程桌面连接等待超时。证书确认可能已取消，也可能是网络或认证服务未响应。",
        RemoteDesktopFailureKind.Cancelled =>
            "远程桌面连接已取消。",
        _ => "远程桌面未能完成连接，请稍后重试。",
    };
}
