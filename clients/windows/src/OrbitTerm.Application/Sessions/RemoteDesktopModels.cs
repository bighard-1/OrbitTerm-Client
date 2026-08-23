namespace OrbitTerm.Application.Sessions;

public enum RemoteDesktopGatewayMode
{
    Direct,
    ThroughVerifiedSshTunnel,
}

public sealed record RemoteDesktopLaunchRequest(
    Guid AssetId,
    string Host,
    int Port = 3389,
    RemoteDesktopGatewayMode GatewayMode = RemoteDesktopGatewayMode.Direct,
    bool ClipboardEnabled = true,
    bool DriveRedirectionEnabled = false,
    bool PrinterRedirectionEnabled = false,
    bool UseNetworkLevelAuthentication = true);

public static class RemoteDesktopPolicy
{
    public static RemoteDesktopLaunchRequest Validate(RemoteDesktopLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var host = request.Host.Trim();
        if (request.AssetId == Guid.Empty || host.Length is 0 or > 253 ||
            host.Any(character => char.IsControl(character) || char.IsWhiteSpace(character)))
            throw new ArgumentException("远程桌面资产或地址无效。", nameof(request));
        if (request.Port is < 1 or > 65535)
            throw new ArgumentOutOfRangeException(nameof(request), "远程桌面端口必须是 1 到 65535。");
        if (!request.UseNetworkLevelAuthentication)
            throw new InvalidOperationException("OrbitTerm 内置远程桌面要求启用网络级别身份验证（NLA）。");
        return request with { Host = host };
    }

    public static bool RequiresRedirectionConfirmation(RemoteDesktopLaunchRequest request) =>
        request.ClipboardEnabled || request.DriveRedirectionEnabled || request.PrinterRedirectionEnabled;
}
