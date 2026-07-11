namespace OrbitTerm.NativeBridge;

public abstract record CheckedHostKeyTrustOutcome
{
    private CheckedHostKeyTrustOutcome()
    {
    }

    public sealed record Persisted(HostKeyTrustPersistedPayload Payload) : CheckedHostKeyTrustOutcome;

    public sealed record Failed(CheckedErrorPayload Error) : CheckedHostKeyTrustOutcome;

    public static CheckedHostKeyTrustOutcome FromEnvelope(CheckedEnvelope envelope)
    {
        if (envelope.Error is { } error)
        {
            return new Failed(error);
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<HostKeyTrustPersistedPayload>(
            envelope,
            CheckedFfiKind.HostKeyTrustPersisted);
        payload.Validate();

        return new Persisted(payload);
    }
}
