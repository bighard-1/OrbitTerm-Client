namespace OrbitTerm.Application.Sessions;

public enum PortForwardingMode
{
    Local,
    Remote,
    DynamicSocks5,
}

public sealed record PortForwardingRule(
    Guid Id,
    Guid AssetId,
    string Name,
    PortForwardingMode Mode,
    string BindHost,
    int BindPort,
    string DestinationHost,
    int DestinationPort,
    bool StartAfterVerifiedConnection = false);

public static class PortForwardingPolicy
{
    public const int MaximumRulesPerAsset = 32;

    public static PortForwardingRule Validate(PortForwardingRule rule)
    {
        ArgumentNullException.ThrowIfNull(rule);
        if (rule.Id == Guid.Empty || rule.AssetId == Guid.Empty)
            throw new ArgumentException("端口映射规则与资产标识不能为空。", nameof(rule));
        var name = NormalizeText(rule.Name, 80, "规则名称");
        var bindHost = NormalizeHost(rule.BindHost, "监听地址");
        if (rule.BindPort is < 0 or > 65535)
            throw new ArgumentOutOfRangeException(nameof(rule), "监听端口必须是 0 到 65535；0 表示自动分配。 ");

        var requiresDestination = rule.Mode != PortForwardingMode.DynamicSocks5;
        var destinationHost = requiresDestination
            ? NormalizeHost(rule.DestinationHost, "目标地址")
            : string.Empty;
        var destinationPort = requiresDestination ? rule.DestinationPort : 0;
        if (requiresDestination && destinationPort is < 1 or > 65535)
            throw new ArgumentOutOfRangeException(nameof(rule), "目标端口必须是 1 到 65535。");

        return rule with
        {
            Name = name,
            BindHost = bindHost,
            DestinationHost = destinationHost,
            DestinationPort = destinationPort,
        };
    }

    public static bool RequiresExplicitExposureConfirmation(PortForwardingRule rule) =>
        !IsLoopback(rule.BindHost);

    public static bool IsLoopback(string host) =>
        string.Equals(host.Trim(), "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(host.Trim(), "localhost", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(host.Trim(), "::1", StringComparison.OrdinalIgnoreCase);

    private static string NormalizeHost(string? value, string label)
    {
        var host = NormalizeText(value, 253, label);
        if (host.Any(character => char.IsControl(character) || char.IsWhiteSpace(character)))
            throw new ArgumentException($"{label}不能包含空格或控制字符。", nameof(value));
        return host;
    }

    private static string NormalizeText(string? value, int maximumLength, string label)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > maximumLength || normalized.Any(char.IsControl))
            throw new ArgumentException($"{label}为空、过长或包含控制字符。", nameof(value));
        return normalized;
    }
}
