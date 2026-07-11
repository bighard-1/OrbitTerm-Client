using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record DockerActionResult
{
    public sealed record Completed(
        VerifiedSessionLease Lease,
        string ContainerId,
        string Action) : DockerActionResult;

    public sealed record Failed(string Code, string MessageKey) : DockerActionResult;

    public static DockerActionResult FromEnvelope(
        VerifiedSessionLease lease,
        string requestedContainerId,
        string requestedAction,
        CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "docker_action_failed",
                envelope.Error?.MessageKey ?? "error.docker.action_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.DockerActionResult, StringComparison.Ordinal))
        {
            return new Failed("invalid_docker_action_kind", "error.docker.action.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<DockerActionResultPayload>(
            envelope,
            CheckedFfiKind.DockerActionResult);
        payload.Validate();
        if (payload.ParsedBaseSessionId != lease.BaseSessionId ||
            !string.Equals(payload.ContainerId, requestedContainerId, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(payload.Action, requestedAction, StringComparison.Ordinal))
        {
            return new Failed("docker_action_mismatch", "error.docker.action.mismatch");
        }

        return new Completed(lease, payload.ContainerId, payload.Action);
    }
}
