using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record DockerLogsResult
{
    public sealed record Captured(
        VerifiedSessionLease Lease,
        string ContainerId,
        string Logs) : DockerLogsResult;

    public sealed record Failed(string Code, string MessageKey) : DockerLogsResult;

    public static DockerLogsResult FromEnvelope(
        VerifiedSessionLease lease,
        string requestedContainerId,
        CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "docker_logs_failed",
                envelope.Error?.MessageKey ?? "error.docker.logs_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.DockerLogs, StringComparison.Ordinal))
        {
            return new Failed("invalid_docker_logs_kind", "error.docker.logs.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<DockerLogsPayload>(
            envelope,
            CheckedFfiKind.DockerLogs);
        payload.Validate();
        if (payload.ParsedBaseSessionId != lease.BaseSessionId ||
            !string.Equals(payload.ContainerId, requestedContainerId, StringComparison.OrdinalIgnoreCase))
        {
            return new Failed("docker_logs_mismatch", "error.docker.logs.mismatch");
        }

        return new Captured(lease, payload.ContainerId, payload.Logs);
    }
}
