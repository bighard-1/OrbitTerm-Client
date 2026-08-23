using System.Net;
using System.Net.Sockets;
using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TcpLatencyProbeTests
{
    [Fact]
    public async Task MeasuresReachableTcpEndpointWithoutProtocolTraffic()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            var accept = listener.AcceptTcpClientAsync();
            var result = await TcpLatencyProbe.MeasureAsync(
                IPAddress.Loopback.ToString(),
                endpoint.Port,
                TimeSpan.FromSeconds(2),
                CancellationToken.None);
            using var accepted = await accept;

            Assert.True(result.Connected);
            Assert.NotNull(result.Milliseconds);
            Assert.True(result.Milliseconds >= 0);
        }
        finally
        {
            listener.Stop();
        }
    }

    [Theory]
    [InlineData("", 22)]
    [InlineData("127.0.0.1", 0)]
    [InlineData("127.0.0.1", 65536)]
    public async Task RejectsInvalidTargets(string host, int port)
    {
        var result = await TcpLatencyProbe.MeasureAsync(
            host,
            port,
            TimeSpan.FromMilliseconds(10),
            CancellationToken.None);

        Assert.False(result.Connected);
        Assert.Null(result.Milliseconds);
    }
}
