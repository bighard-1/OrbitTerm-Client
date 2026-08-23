using System.Diagnostics;
using System.Net.Sockets;

namespace OrbitTerm.Application.Sessions;

public sealed record TcpLatencyProbeResult(bool Connected, double? Milliseconds);

/// <summary>
/// Measures client-to-server TCP connect latency without sending credentials or
/// protocol data. The caller owns cadence and overlap prevention.
/// </summary>
public static class TcpLatencyProbe
{
    public static async Task<TcpLatencyProbeResult> MeasureAsync(
        string host,
        int port,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(host) || port is < 1 or > 65535)
        {
            return new(false, null);
        }

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout <= TimeSpan.Zero ? TimeSpan.FromSeconds(2) : timeout);
        using var client = new TcpClient { NoDelay = true };
        var stopwatch = Stopwatch.StartNew();
        try
        {
            await client.ConnectAsync(host.Trim(), port, timeoutCts.Token).ConfigureAwait(false);
            stopwatch.Stop();
            return new(true, Math.Max(0, stopwatch.Elapsed.TotalMilliseconds));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new(false, null);
        }
        catch (SocketException)
        {
            return new(false, null);
        }
    }
}
