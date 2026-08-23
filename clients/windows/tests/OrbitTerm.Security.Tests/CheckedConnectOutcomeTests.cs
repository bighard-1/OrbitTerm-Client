using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class CheckedConnectOutcomeTests
{
    [Fact]
    public void ConnectedOutcomeDecodesVerifiedSession()
    {
        var envelope = Decode("""
        {
          "schema_version": 1,
          "kind": "connected",
          "request_id": "request-1",
          "data": {
            "session_id": 42,
            "host": "Example.COM",
            "normalized_host": "example.com",
            "port": 22,
            "lookup_token": "example.com:22",
            "key_algorithm": "ssh-ed25519",
            "fingerprint_sha256": "SHA256:abc",
            "security_generation": "host_key_verified"
          }
        }
        """);

        var outcome = CheckedConnectOutcome.FromEnvelope(envelope);

        var connected = Assert.IsType<CheckedConnectOutcome.Connected>(outcome);
        Assert.Equal(42UL, connected.Payload.BaseSessionId);
        Assert.Equal(CheckedSecurityGeneration.HostKeyVerified, connected.Payload.SecurityGeneration);
    }

    [Fact]
    public void UnknownHostChallengeDecodesWithoutGrantingConnection()
    {
        var envelope = Decode("""
        {
          "schema_version": 1,
          "kind": "host_key_challenge",
          "request_id": "request-1",
          "data": {
            "challenge_id": "challenge-1",
            "request_id": "request-1",
            "host": "new.example",
            "normalized_host": "new.example",
            "port": 22,
            "lookup_token": "new.example:22",
            "key_algorithm": "ssh-ed25519",
            "fingerprint_sha256": "SHA256:new",
            "reason_code": "unknown_host",
            "known_state": "unknown",
            "can_trust": true,
            "can_replace": false,
            "expires_at_unix": 1893456000,
            "reused_existing_challenge": false,
            "related_request_count": 1
          }
        }
        """);

        var outcome = CheckedConnectOutcome.FromEnvelope(envelope);

        var challenge = Assert.IsType<CheckedConnectOutcome.Challenge>(outcome);
        Assert.Equal("challenge-1", challenge.Payload.ChallengeId);
        Assert.True(challenge.Payload.CanTrust);
        Assert.False(challenge.Payload.CanReplace);
    }

    [Fact]
    public void ChangedHostKeyDecodesAsBlocked()
    {
        var envelope = Decode("""
        {
          "schema_version": 1,
          "kind": "host_key_blocked",
          "request_id": "request-1",
          "data": {
            "host": "example.com",
            "normalized_host": "example.com",
            "port": 22,
            "lookup_token": "example.com:22",
            "key_algorithm": "ssh-ed25519",
            "presented_fingerprint_sha256": "SHA256:new",
            "previous_fingerprint_sha256": "SHA256:old",
            "reason_code": "changed",
            "known_state": "changed",
            "can_trust": false,
            "can_replace": false,
            "message_key": "error.host_key.changed"
          }
        }
        """);

        var outcome = CheckedConnectOutcome.FromEnvelope(envelope);

        var blocked = Assert.IsType<CheckedConnectOutcome.Blocked>(outcome);
        Assert.Equal("changed", blocked.Payload.ReasonCode);
        Assert.False(blocked.Payload.CanTrust);
        Assert.False(blocked.Payload.CanReplace);
    }

    [Fact]
    public void ErrorEnvelopeBecomesFailedOutcome()
    {
        var envelope = Decode("""
        {
          "schema_version": 1,
          "kind": "error",
          "error": {
            "code": "known_hosts_read_failed",
            "message_key": "error.known_hosts.read_failed",
            "request_id": "request-1"
          }
        }
        """);

        var outcome = CheckedConnectOutcome.FromEnvelope(envelope);

        var failed = Assert.IsType<CheckedConnectOutcome.Failed>(outcome);
        Assert.Equal("known_hosts_read_failed", failed.Error.Code);
    }

    private static CheckedEnvelope Decode(string json)
    {
        return CheckedEnvelopeDecoder.Decode(json, new HostKeyRequestId("request-1"));
    }
}
