using System.Text;
using System.Text.Json;
using OrbitTerm.Application.Accounts;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class PortForwardProfileSyncContractTests
{
    [Fact]
    public void RoundTripContainsProfilesButNeverLiveTunnelState()
    {
        var envelope = new PortForwardProfileSyncEnvelope(
            PortForwardProfileSyncContract.Marker,
            PortForwardProfileSyncContract.Version,
            1_770_000_000,
            [new PortForwardProfileWire(
                Guid.Parse("abcdef00-1234-5678-9abc-def012345678"),
                Guid.Parse("11111111-2222-3333-4444-555555555555"),
                " 数据库 ", "local", "127.0.0.1", 15432, "127.0.0.1", 5432,
                1_760_000_000, 1_770_000_000)],
            []);

        var json = Encoding.UTF8.GetString(PortForwardProfileSyncContract.Serialize(envelope));
        Assert.DoesNotContain("tunnelId", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("isRunning", json, StringComparison.OrdinalIgnoreCase);
        using var document = JsonDocument.Parse(json);
        var parsed = Assert.IsType<PortForwardProfileSyncEnvelope>(PortForwardProfileSyncContract.Parse(document.RootElement));
        Assert.Equal("数据库", Assert.Single(parsed.Profiles).Name);
    }

    [Fact]
    public void LiveStateOrAutoStartIsRejected()
    {
        using var document = JsonDocument.Parse("""
        {"kind":"orbit_port_forwards","version":1,"updatedAtUnix":1770000000,"profiles":[{"id":"abcdef00-1234-5678-9abc-def012345678","assetId":"11111111-2222-3333-4444-555555555555","name":"db","mode":"local","bindHost":"127.0.0.1","bindPort":15432,"destinationHost":"127.0.0.1","destinationPort":5432,"createdAtUnix":1760000000,"updatedAtUnix":1770000000,"tunnelId":42}],"tombstones":[]}
        """);
        Assert.Null(PortForwardProfileSyncContract.Parse(document.RootElement));
    }
}
