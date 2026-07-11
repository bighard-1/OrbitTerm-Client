namespace OrbitTerm.NativeBridge;

public abstract record CheckedTerminalOpenOutcome
{
    private CheckedTerminalOpenOutcome()
    {
    }

    public sealed record Opened(TerminalChannelOpenedPayload Payload) : CheckedTerminalOpenOutcome;

    public sealed record Failed(CheckedErrorPayload Error) : CheckedTerminalOpenOutcome;

    public static CheckedTerminalOpenOutcome FromEnvelope(CheckedEnvelope envelope)
    {
        if (envelope.Error is { } error)
        {
            return new Failed(error);
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<TerminalChannelOpenedPayload>(
            envelope,
            CheckedFfiKind.TerminalChannelOpened);
        payload.Validate();

        return new Opened(payload);
    }
}
