using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record ConnectedPayload(
    [property: JsonPropertyName("session_id")] ulong SessionId,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("normalized_host")] string NormalizedHost,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("lookup_token")] string LookupToken,
    [property: JsonPropertyName("key_algorithm")] string KeyAlgorithm,
    [property: JsonPropertyName("fingerprint_sha256")] string FingerprintSha256,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration)
{
    public ulong BaseSessionId => SessionId != 0
        ? SessionId
        : throw new OrbitNativeException("Connected payload contains an invalid session id.");
}

public sealed record HostKeyChallengePayload(
    [property: JsonPropertyName("challenge_id")] string ChallengeId,
    [property: JsonPropertyName("request_id")] string? RequestId,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("normalized_host")] string NormalizedHost,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("lookup_token")] string LookupToken,
    [property: JsonPropertyName("key_algorithm")] string KeyAlgorithm,
    [property: JsonPropertyName("fingerprint_sha256")] string FingerprintSha256,
    [property: JsonPropertyName("reason_code")] string ReasonCode,
    [property: JsonPropertyName("known_state")] string KnownState,
    [property: JsonPropertyName("can_trust")] bool CanTrust,
    [property: JsonPropertyName("can_replace")] bool CanReplace,
    [property: JsonPropertyName("expires_at_unix")] ulong ExpiresAtUnix,
    [property: JsonPropertyName("reused_existing_challenge")] bool ReusedExistingChallenge,
    [property: JsonPropertyName("related_request_count")] uint RelatedRequestCount);

public sealed record HostKeyBlockedPayload(
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("normalized_host")] string NormalizedHost,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("lookup_token")] string LookupToken,
    [property: JsonPropertyName("key_algorithm")] string KeyAlgorithm,
    [property: JsonPropertyName("presented_fingerprint_sha256")] string PresentedFingerprintSha256,
    [property: JsonPropertyName("previous_fingerprint_sha256")] string? PreviousFingerprintSha256,
    [property: JsonPropertyName("reason_code")] string ReasonCode,
    [property: JsonPropertyName("known_state")] string KnownState,
    [property: JsonPropertyName("can_trust")] bool CanTrust,
    [property: JsonPropertyName("can_replace")] bool CanReplace,
    [property: JsonPropertyName("message_key")] string MessageKey);

public sealed record TrustPersistedPayload(
    [property: JsonPropertyName("challenge_id")] string ChallengeId,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("normalized_host")] string NormalizedHost,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("lookup_token")] string LookupToken,
    [property: JsonPropertyName("key_algorithm")] string KeyAlgorithm,
    [property: JsonPropertyName("fingerprint_sha256")] string FingerprintSha256,
    [property: JsonPropertyName("status")] string Status);
