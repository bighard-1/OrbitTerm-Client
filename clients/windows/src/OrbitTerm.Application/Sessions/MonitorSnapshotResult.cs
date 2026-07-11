using System;
using System.Collections.Generic;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record MonitorSnapshotResult
{
    public sealed record Captured(
        VerifiedSessionLease Lease,
        MonitorSnapshot Snapshot) : MonitorSnapshotResult;

    public sealed record Failed(string Code, string MessageKey) : MonitorSnapshotResult;

    public static MonitorSnapshotResult FromEnvelope(VerifiedSessionLease lease, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "monitor_snapshot_failed",
                envelope.Error?.MessageKey ?? "error.monitor.snapshot_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.MonitorSnapshot, StringComparison.Ordinal))
        {
            return new Failed("invalid_monitor_snapshot_kind", "error.monitor.snapshot.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<MonitorSnapshotPayload>(
            envelope,
            CheckedFfiKind.MonitorSnapshot);
        payload.Validate();
        if (payload.ParsedBaseSessionId != lease.BaseSessionId)
        {
            return new Failed("monitor_snapshot_mismatch", "error.monitor.snapshot.mismatch");
        }

        return new Captured(
            lease,
            new MonitorSnapshot(
                payload.Stats.SampledAtUnix,
                payload.Stats.CpuUsagePercent,
                payload.Stats.MemoryAvailableMegabytes,
                payload.Stats.MemoryUsedPercent,
                payload.Stats.DiskUsedPercent,
                payload.Stats.PingLatencyMilliseconds,
                payload.Stats.ReceiveRateKilobitsPerSecond,
                payload.Stats.TransmitRateKilobitsPerSecond,
                payload.Diagnostics));
    }
}

public sealed record MonitorSnapshot(
    ulong SampledAtUnix,
    double CpuUsagePercent,
    ulong MemoryAvailableMegabytes,
    double MemoryUsedPercent,
    double DiskUsedPercent,
    double? PingLatencyMilliseconds,
    double ReceiveRateKilobitsPerSecond,
    double TransmitRateKilobitsPerSecond,
    IReadOnlyList<string> Diagnostics);
