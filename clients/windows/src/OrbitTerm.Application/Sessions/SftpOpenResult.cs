using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record SftpOpenResult
{
    public sealed record Opened(SftpSessionLease Lease) : SftpOpenResult;

    public sealed record Failed(string Code, string MessageKey) : SftpOpenResult;

    public static SftpOpenResult FromEnvelope(VerifiedSessionLease baseLease, CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "sftp_open_failed",
                envelope.Error?.MessageKey ?? "error.sftp.open_failed");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpChannelOpenedPayload>(
            envelope,
            CheckedFfiKind.SftpChannelOpened);
        payload.Validate();

        if (payload.ParsedBaseSessionId != baseLease.BaseSessionId)
        {
            throw new InvalidOperationException("SFTP channel base session does not match the verified session.");
        }

        return new Opened(new SftpSessionLease(
            baseLease.WorkspaceId,
            baseLease.ServerId,
            baseLease.BaseSessionId,
            payload.ParsedSftpSessionId,
            baseLease.Host,
            baseLease.Port,
            baseLease.HostKeyAlgorithm,
            baseLease.HostKeyFingerprintSha256));
    }
}
