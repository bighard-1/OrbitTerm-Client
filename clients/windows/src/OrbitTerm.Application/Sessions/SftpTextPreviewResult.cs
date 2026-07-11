using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record SftpTextPreviewResult
{
    public sealed record Previewed(
        SftpSessionLease Lease,
        string Path,
        ulong ByteLength,
        string Content) : SftpTextPreviewResult;

    public sealed record Failed(string Code, string MessageKey) : SftpTextPreviewResult;

    public static SftpTextPreviewResult FromEnvelope(SftpSessionLease lease, string path, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "sftp_read_failed",
                envelope.Error?.MessageKey ?? "error.sftp.read_failed");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpTextFilePayload>(
            envelope,
            CheckedFfiKind.SftpTextFile);
        payload.Validate();

        if (payload.ParsedSftpSessionId != lease.SftpSessionId ||
            !string.Equals(payload.Path, path, StringComparison.Ordinal))
        {
            return new Failed("sftp_read_mismatch", "error.sftp.read.mismatch");
        }

        return new Previewed(lease, payload.Path, payload.ByteLength, payload.Content);
    }
}
