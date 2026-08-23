using System.Diagnostics;

namespace OrbitTerm.Application.Sessions;

internal sealed class SftpTransferProgressThrottle
{
    private const ulong MinimumByteDelta = 512UL * 1024UL;
    private static readonly TimeSpan MinimumInterval = TimeSpan.FromMilliseconds(125);
    private readonly object gate = new();
    private bool hasReported;
    private ulong lastReportedBytes;
    private long lastReportedTimestamp;

    public bool ShouldReport(ulong transferredBytes, ulong? totalBytes)
    {
        lock (gate)
        {
            var isComplete = totalBytes is { } total && transferredBytes >= total;
            var now = Stopwatch.GetTimestamp();
            if (hasReported &&
                !isComplete &&
                transferredBytes - Math.Min(transferredBytes, lastReportedBytes) < MinimumByteDelta &&
                Stopwatch.GetElapsedTime(lastReportedTimestamp, now) < MinimumInterval)
            {
                return false;
            }

            hasReported = true;
            lastReportedBytes = transferredBytes;
            lastReportedTimestamp = now;
            return true;
        }
    }
}
