using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record SftpDownloadResult
{
    public sealed record Downloaded(SftpSessionLease Lease, string Path, ulong ByteLength) : SftpDownloadResult;

    public sealed record Failed(string Code, string MessageKey) : SftpDownloadResult;

    public static SftpDownloadResult FromEnvelope(SftpSessionLease lease, string path, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "sftp_download_failed",
                envelope.Error?.MessageKey ?? "error.sftp.download_failed");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpDownloadPayload>(
            envelope,
            CheckedFfiKind.SftpDownloadCompleted);
        payload.Validate();
        if (payload.ParsedSftpSessionId != lease.SftpSessionId ||
            !string.Equals(payload.Path, path, StringComparison.Ordinal))
        {
            return new Failed("sftp_download_mismatch", "error.sftp.download.mismatch");
        }

        return new Downloaded(lease, payload.Path, payload.ByteLength);
    }
}
