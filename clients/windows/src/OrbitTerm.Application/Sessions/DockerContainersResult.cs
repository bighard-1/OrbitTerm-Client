using System;
using System.Collections.Generic;
using System.Linq;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record DockerContainersResult
{
    public sealed record Listed(
        VerifiedSessionLease Lease,
        IReadOnlyList<DockerContainer> Containers) : DockerContainersResult;

    public sealed record Failed(string Code, string MessageKey) : DockerContainersResult;

    public static DockerContainersResult FromEnvelope(VerifiedSessionLease lease, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "docker_list_failed",
                envelope.Error?.MessageKey ?? "error.docker.list_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.DockerContainers, StringComparison.Ordinal))
        {
            return new Failed("invalid_docker_list_kind", "error.docker.list.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<DockerContainersPayload>(
            envelope,
            CheckedFfiKind.DockerContainers);
        payload.Validate();
        if (payload.ParsedBaseSessionId != lease.BaseSessionId)
        {
            return new Failed("docker_list_mismatch", "error.docker.list.mismatch");
        }

        return new Listed(
            lease,
            payload.Containers
                .Select(container => new DockerContainer(
                    container.Id,
                    container.Name,
                    container.Image,
                    container.State,
                    container.Status,
                    container.RunningFor))
                .ToArray());
    }
}

public sealed record DockerContainer(
    string Id,
    string Name,
    string Image,
    string State,
    string Status,
    string RunningFor);
