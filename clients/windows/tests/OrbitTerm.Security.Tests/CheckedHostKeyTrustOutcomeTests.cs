using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class CheckedHostKeyTrustOutcomeTests
{
    [Fact]
    public void PersistedEnvelopeDecodesAndValidatesPayload()
    {
        const string json = """
            {
              "schema_version": 1,
              "kind": "host_key_trust_persisted",
              "request_id": "request-1",
              "data": {
                "challenge_id": "challenge-1",
                "host": "Example.COM",
                "normalized_host": "example.com",
                "port": 22,
                "lookup_token": "example.com:22",
                "key_algorithm": "ssh-ed25519",
                "fingerprint_sha256": "SHA256:abc",
                "status": "trusted_added"
              }
            }
            """;

        var envelope = CheckedEnvelopeDecoder.Decode(json, new HostKeyRequestId("request-1"));
        var outcome = CheckedHostKeyTrustOutcome.FromEnvelope(envelope);

        var persisted = Assert.IsType<CheckedHostKeyTrustOutcome.Persisted>(outcome);
        Assert.Equal("challenge-1", persisted.Payload.ChallengeId);
        Assert.Equal("trusted_added", persisted.Payload.Status);
    }

    [Fact]
    public void InvalidPersistedStatusIsRejected()
    {
        const string json = """
            {
              "schema_version": 1,
              "kind": "host_key_trust_persisted",
              "request_id": "request-1",
              "data": {
                "challenge_id": "challenge-1",
                "host": "example.com",
                "normalized_host": "example.com",
                "port": 22,
                "lookup_token": "example.com:22",
                "key_algorithm": "ssh-ed25519",
                "fingerprint_sha256": "SHA256:abc",
                "status": "accepted_not_persisted"
              }
            }
            """;

        var envelope = CheckedEnvelopeDecoder.Decode(json, new HostKeyRequestId("request-1"));

        Assert.Throws<OrbitNativeException>(() => CheckedHostKeyTrustOutcome.FromEnvelope(envelope));
    }
}
