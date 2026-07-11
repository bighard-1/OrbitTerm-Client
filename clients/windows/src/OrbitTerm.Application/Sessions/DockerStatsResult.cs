using System;
using System.Collections.Generic;
using System.Linq;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record DockerStatsResult
{
    public sealed record Captured(
        VerifiedSessionLease Lease,
        IReadOnlyList<DockerStatsItem> Stats) : DockerStatsResult;

    public sealed record Failed(string Code, string MessageKey) : DockerStatsResult;

    public static DockerStatsResult FromEnvelope(VerifiedSessionLease lease, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "docker_stats_failed",
                envelope.Error?.MessageKey ?? "error.docker.stats_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.DockerStats, StringComparison.Ordinal))
        {
            return new Failed("invalid_docker_stats_kind", "error.docker.stats.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<DockerStatsPayload>(
            envelope,
            CheckedFfiKind.DockerStats);
        payload.Validate();
        if (payload.ParsedBaseSessionId != lease.BaseSessionId)
        {
            return new Failed("docker_stats_mismatch", "error.docker.stats.mismatch");
        }

        return new Captured(
            lease,
            payload.Stats
                .Select(item => new DockerStatsItem(
                    item.Id,
                    item.Name,
                    item.CpuPercent,
                    item.MemoryPercent,
                    item.MemoryUsage,
                    item.NetworkIo,
                    item.BlockIo,
                    item.Pids))
                .ToArray());
    }
}

public sealed record DockerStatsItem(
    string Id,
    string Name,
    double CpuPercent,
    double MemoryPercent,
    string MemoryUsage,
    string NetworkIo,
    string BlockIo,
    uint Pids);
