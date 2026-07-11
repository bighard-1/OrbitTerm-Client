using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record SftpUploadResult
{
    public sealed record Uploaded(SftpSessionLease Lease, string Path, ulong ByteLength) : SftpUploadResult;

    public sealed record Failed(string Code, string MessageKey) : SftpUploadResult;

    public static SftpUploadResult FromEnvelope(SftpSessionLease lease, string path, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "sftp_upload_failed",
                envelope.Error?.MessageKey ?? "error.sftp.upload_failed");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpUploadPayload>(
            envelope,
            CheckedFfiKind.SftpUploadCompleted);
        payload.Validate();
        if (payload.ParsedSftpSessionId != lease.SftpSessionId ||
            !string.Equals(payload.Path, path, StringComparison.Ordinal))
        {
            return new Failed("sftp_upload_mismatch", "error.sftp.upload.mismatch");
        }

        return new Uploaded(lease, payload.Path, payload.ByteLength);
    }
}
