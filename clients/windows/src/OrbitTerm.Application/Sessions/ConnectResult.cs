using OrbitTerm.Application.Security;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record ConnectResult
{
    private ConnectResult()
    {
    }

    public sealed record Connected(VerifiedSessionLease Lease) : ConnectResult;

    public sealed record RequiresHostKeyTrust(HostKeyChallengeViewModel Challenge) : ConnectResult;

    public sealed record Blocked(HostKeyBlockedViewModel Block) : ConnectResult;

    public sealed record Failed(string Code, string MessageKey) : ConnectResult;

    public static ConnectResult FromNative(Guid workspaceId, Guid serverId, CheckedConnectOutcome outcome)
    {
        return outcome switch
        {
            CheckedConnectOutcome.Connected connected => FromConnected(workspaceId, serverId, connected.Payload),
            CheckedConnectOutcome.Challenge challenge => FromChallenge(challenge.Payload),
            CheckedConnectOutcome.Blocked blocked => FromBlocked(blocked.Payload),
            CheckedConnectOutcome.Failed failed => new Failed(failed.Error.Code, failed.Error.MessageKey),
            _ => throw new InvalidOperationException("Unknown checked connection outcome."),
        };
    }

    private static Connected FromConnected(Guid workspaceId, Guid serverId, ConnectedPayload payload)
    {
        if (payload.SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified)
        {
            throw new InvalidOperationException("Connected payload is not HostKeyVerified.");
        }

        return new Connected(new VerifiedSessionLease(
            workspaceId,
            serverId,
            payload.BaseSessionId,
            payload.NormalizedHost,
            payload.Port,
            string.Empty,
            payload.KeyAlgorithm,
            payload.FingerprintSha256));
    }

    private static RequiresHostKeyTrust FromChallenge(HostKeyChallengePayload payload)
    {
        if (!payload.CanTrust || payload.CanReplace)
        {
            throw new InvalidOperationException("Unexpected Host Key challenge trust capability.");
        }

        if (string.IsNullOrWhiteSpace(payload.RequestId))
        {
            throw new InvalidOperationException("Host Key challenge is missing a request identifier.");
        }

        return new RequiresHostKeyTrust(new HostKeyChallengeViewModel(
            payload.ChallengeId,
            payload.RequestId,
            payload.Host,
            payload.NormalizedHost,
            payload.Port,
            payload.KeyAlgorithm,
            payload.FingerprintSha256,
            payload.ReasonCode,
            payload.CanTrust,
            DateTimeOffset.FromUnixTimeSeconds((long)payload.ExpiresAtUnix)));
    }

    private static Blocked FromBlocked(HostKeyBlockedPayload payload)
    {
        if (payload.CanTrust || payload.CanReplace)
        {
            throw new InvalidOperationException("Blocked Host Key payload must not be trustable.");
        }

        return new Blocked(new HostKeyBlockedViewModel(
            payload.Host,
            payload.NormalizedHost,
            payload.Port,
            payload.KeyAlgorithm,
            payload.PresentedFingerprintSha256,
            payload.PreviousFingerprintSha256,
            payload.ReasonCode,
            payload.MessageKey));
    }
}
