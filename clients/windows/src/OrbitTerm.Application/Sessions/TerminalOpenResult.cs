using OrbitTerm.NativeBridge;
using OrbitTerm.Terminal;

namespace OrbitTerm.Application.Sessions;

public abstract record TerminalOpenResult
{
    private TerminalOpenResult()
    {
    }

    public sealed record Opened(TerminalSessionLease Lease) : TerminalOpenResult;

    public sealed record Failed(string Code, string MessageKey) : TerminalOpenResult;

    public static TerminalOpenResult FromNative(
        VerifiedSessionLease baseLease,
        TerminalSize requestedSize,
        CheckedTerminalOpenOutcome outcome)
    {
        requestedSize.Validate();

        return outcome switch
        {
            CheckedTerminalOpenOutcome.Opened opened => FromOpened(baseLease, requestedSize, opened.Payload),
            CheckedTerminalOpenOutcome.Failed failed => new Failed(failed.Error.Code, failed.Error.MessageKey),
            _ => throw new InvalidOperationException("Unknown checked terminal outcome."),
        };
    }

    private static Opened FromOpened(
        VerifiedSessionLease baseLease,
        TerminalSize requestedSize,
        TerminalChannelOpenedPayload payload)
    {
        payload.Validate();

        if (payload.ParsedBaseSessionId != baseLease.BaseSessionId)
        {
            throw new InvalidOperationException("Terminal channel was opened for a different base session.");
        }

        if (payload.Columns != requestedSize.Columns || payload.Rows != requestedSize.Rows)
        {
            throw new InvalidOperationException("Terminal channel size differs from the requested size.");
        }

        return new Opened(new TerminalSessionLease(
            baseLease.WorkspaceId,
            baseLease.ServerId,
            baseLease.BaseSessionId,
            payload.ParsedTerminalChannelId,
            requestedSize,
            baseLease.Host,
            baseLease.Port,
            baseLease.HostKeyAlgorithm,
            baseLease.HostKeyFingerprintSha256));
    }
}
