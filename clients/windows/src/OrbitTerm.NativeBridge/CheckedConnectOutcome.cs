namespace OrbitTerm.NativeBridge;

public abstract record CheckedConnectOutcome
{
    private CheckedConnectOutcome()
    {
    }

    public sealed record Connected(ConnectedPayload Payload) : CheckedConnectOutcome;

    public sealed record Challenge(HostKeyChallengePayload Payload) : CheckedConnectOutcome;

    public sealed record Blocked(HostKeyBlockedPayload Payload) : CheckedConnectOutcome;

    public sealed record Failed(CheckedErrorPayload Error) : CheckedConnectOutcome;

    public static CheckedConnectOutcome FromEnvelope(CheckedEnvelope envelope)
    {
        if (envelope.Error is { } error)
        {
            return new Failed(error);
        }

        return envelope.Kind switch
        {
            CheckedFfiKind.Connected => new Connected(
                CheckedEnvelopeDecoder.DecodePayload<ConnectedPayload>(
                    envelope,
                    CheckedFfiKind.Connected)),
            CheckedFfiKind.HostKeyChallenge => new Challenge(
                CheckedEnvelopeDecoder.DecodePayload<HostKeyChallengePayload>(
                    envelope,
                    CheckedFfiKind.HostKeyChallenge)),
            CheckedFfiKind.HostKeyBlocked => new Blocked(
                CheckedEnvelopeDecoder.DecodePayload<HostKeyBlockedPayload>(
                    envelope,
                    CheckedFfiKind.HostKeyBlocked)),
            _ => throw new OrbitNativeException($"Unsupported checked connect outcome: {envelope.Kind}."),
        };
    }
}
