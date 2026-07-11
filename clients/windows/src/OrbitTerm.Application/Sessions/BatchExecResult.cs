using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record BatchExecResult
{
    public sealed record Completed(VerifiedSessionLease Lease, string Stdout, string Stderr) : BatchExecResult;

    public sealed record Failed(string Code, string MessageKey) : BatchExecResult;

    public static BatchExecResult FromEnvelope(VerifiedSessionLease lease, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "batch_exec_failed",
                envelope.Error?.MessageKey ?? "error.batch.exec_failed");
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.ExecResult, StringComparison.Ordinal))
        {
            return new Failed("invalid_exec_result_kind", "error.batch.exec.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<ExecResultPayload>(envelope, CheckedFfiKind.ExecResult);
        payload.Validate();
        return payload.ParsedBaseSessionId == lease.BaseSessionId
            ? new Completed(lease, payload.Stdout, payload.Stderr)
            : new Failed("exec_result_mismatch", "error.batch.exec.mismatch");
    }
}
