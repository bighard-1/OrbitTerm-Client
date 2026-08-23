using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record LocalTunnelStartedPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("tunnel_id")] string TunnelId,
    [property: JsonPropertyName("bind_host")] string BindHost,
    [property: JsonPropertyName("bind_port")] int BindPort)
{
    public ulong ParsedBaseSessionId => ulong.Parse(BaseSessionId, System.Globalization.CultureInfo.InvariantCulture);
    public ulong ParsedTunnelId => ulong.Parse(TunnelId, System.Globalization.CultureInfo.InvariantCulture);
}

public sealed record LocalTunnelStoppedPayload(
    [property: JsonPropertyName("tunnel_id")] string TunnelId)
{
    public ulong ParsedTunnelId => ulong.Parse(TunnelId, System.Globalization.CultureInfo.InvariantCulture);
}
