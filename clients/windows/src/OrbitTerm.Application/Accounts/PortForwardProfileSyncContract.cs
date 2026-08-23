using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Application.Accounts;

internal sealed record PortForwardProfileSyncEnvelope(
    string Kind,
    int Version,
    long UpdatedAtUnix,
    PortForwardProfileWire[] Profiles,
    PortForwardProfileTombstoneWire[] Tombstones,
    [property: JsonIgnore] ulong RemoteId = 0,
    [property: JsonIgnore] string VectorClock = "{}");

internal sealed record PortForwardProfileWire(
    Guid Id,
    Guid AssetId,
    string Name,
    string Mode,
    string BindHost,
    int BindPort,
    string DestinationHost,
    int DestinationPort,
    long CreatedAtUnix,
    long UpdatedAtUnix);

internal sealed record PortForwardProfileTombstoneWire(Guid Id, long DeletedAtUnix);

/// <summary>
/// Versioned, non-secret profile contract shared by desktop and mobile clients.
/// It deliberately contains no tunnel handle, process identifier, running
/// state or auto-start flag. Receiving a profile can never start a tunnel.
/// </summary>
internal static class PortForwardProfileSyncContract
{
    internal const string Marker = "orbit_port_forwards";
    internal const int Version = 1;
    internal const int MaximumProfiles = 256;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    internal static PortForwardProfileSyncEnvelope? Parse(JsonElement root)
    {
        if (ContainsLiveState(root)) return null;
        PortForwardProfileSyncEnvelope? envelope;
        try { envelope = root.Deserialize<PortForwardProfileSyncEnvelope>(JsonOptions); }
        catch (JsonException) { return null; }
        if (envelope is null ||
            !string.Equals(envelope.Kind, Marker, StringComparison.Ordinal) ||
            envelope.Version != Version || envelope.UpdatedAtUnix <= 0 ||
            envelope.Profiles is null || envelope.Tombstones is null ||
            envelope.Profiles.Length > MaximumProfiles ||
            envelope.Tombstones.Length > MaximumProfiles * 4 ||
            envelope.Profiles.Select(item => item.Id).Distinct().Count() != envelope.Profiles.Length ||
            envelope.Tombstones.Select(item => item.Id).Distinct().Count() != envelope.Tombstones.Length)
        {
            return null;
        }

        var normalized = new List<PortForwardProfileWire>(envelope.Profiles.Length);
        foreach (var item in envelope.Profiles)
        {
            if (item.CreatedAtUnix <= 0 || item.UpdatedAtUnix < item.CreatedAtUnix ||
                !TryParseMode(item.Mode, out var mode)) return null;
            try
            {
                var rule = PortForwardingPolicy.Validate(new PortForwardingRule(
                    item.Id, item.AssetId, item.Name, mode, item.BindHost, item.BindPort,
                    item.DestinationHost, item.DestinationPort));
                normalized.Add(item with
                {
                    Name = rule.Name,
                    Mode = ToWireMode(rule.Mode),
                    BindHost = rule.BindHost,
                    BindPort = rule.BindPort,
                    DestinationHost = rule.DestinationHost,
                    DestinationPort = rule.DestinationPort,
                });
            }
            catch (ArgumentException) { return null; }
        }

        if (normalized.GroupBy(item => item.AssetId).Any(group => group.Count() > PortForwardingPolicy.MaximumRulesPerAsset) ||
            envelope.Tombstones.Any(item => item.Id == Guid.Empty || item.DeletedAtUnix <= 0)) return null;
        return envelope with { Profiles = normalized.ToArray() };
    }

    internal static byte[] Serialize(PortForwardProfileSyncEnvelope envelope)
    {
        var root = JsonSerializer.SerializeToElement(envelope, JsonOptions);
        var normalized = Parse(root) ?? throw new ArgumentException("端口映射配置同步信封无效。", nameof(envelope));
        return JsonSerializer.SerializeToUtf8Bytes(normalized, JsonOptions);
    }

    private static bool TryParseMode(string raw, out PortForwardingMode mode)
    {
        mode = raw switch
        {
            "local" => PortForwardingMode.Local,
            "remote" => PortForwardingMode.Remote,
            "dynamicSocks5" => PortForwardingMode.DynamicSocks5,
            _ => (PortForwardingMode)(-1),
        };
        return Enum.IsDefined(mode);
    }

    private static string ToWireMode(PortForwardingMode mode) => mode switch
    {
        PortForwardingMode.Local => "local",
        PortForwardingMode.Remote => "remote",
        PortForwardingMode.DynamicSocks5 => "dynamicSocks5",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    private static bool ContainsLiveState(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return true;
        foreach (var forbidden in new[] { "tunnelId", "processId", "isRunning", "running", "autoStart" })
        {
            if (root.TryGetProperty(forbidden, out _)) return true;
        }
        if (!root.TryGetProperty("profiles", out var profiles) || profiles.ValueKind != JsonValueKind.Array) return false;
        foreach (var profile in profiles.EnumerateArray())
        {
            foreach (var forbidden in new[] { "tunnelId", "processId", "isRunning", "running", "autoStart", "startAfterVerifiedConnection" })
            {
                if (profile.ValueKind == JsonValueKind.Object && profile.TryGetProperty(forbidden, out _)) return true;
            }
        }
        return false;
    }
}
