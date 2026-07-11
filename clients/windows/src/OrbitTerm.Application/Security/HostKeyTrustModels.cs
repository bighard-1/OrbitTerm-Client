namespace OrbitTerm.Application.Security;

public sealed record HostKeyChallengeViewModel(
    string ChallengeId,
    string RequestId,
    string Host,
    string NormalizedHost,
    int Port,
    string KeyAlgorithm,
    string FingerprintSha256,
    string ReasonCode,
    bool CanTrust,
    DateTimeOffset ExpiresAt);

public abstract record HostKeyTrustResult
{
    private HostKeyTrustResult()
    {
    }

    public sealed record Persisted(
        string ChallengeId,
        string Host,
        string NormalizedHost,
        int Port,
        string KeyAlgorithm,
        string FingerprintSha256,
        string Status) : HostKeyTrustResult;

    public sealed record Failed(string Code, string MessageKey) : HostKeyTrustResult;
}

public sealed record HostKeyBlockedViewModel(
    string Host,
    string NormalizedHost,
    int Port,
    string KeyAlgorithm,
    string PresentedFingerprintSha256,
    string? PreviousFingerprintSha256,
    string ReasonCode,
    string MessageKey);
