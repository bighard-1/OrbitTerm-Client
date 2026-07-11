using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record HostKeyTrustPersistedPayload(
    [property: JsonPropertyName("challenge_id")] string ChallengeId,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("normalized_host")] string NormalizedHost,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("lookup_token")] string LookupToken,
    [property: JsonPropertyName("key_algorithm")] string KeyAlgorithm,
    [property: JsonPropertyName("fingerprint_sha256")] string FingerprintSha256,
    [property: JsonPropertyName("status")] string Status)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ChallengeId) ||
            string.IsNullOrWhiteSpace(Host) ||
            string.IsNullOrWhiteSpace(NormalizedHost) ||
            Port == 0 ||
            string.IsNullOrWhiteSpace(LookupToken) ||
            string.IsNullOrWhiteSpace(KeyAlgorithm) ||
            string.IsNullOrWhiteSpace(FingerprintSha256) ||
            Status is not ("trusted_added" or "already_trusted"))
        {
            throw new OrbitNativeException("Host Key trust payload is incomplete.");
        }
    }
}
