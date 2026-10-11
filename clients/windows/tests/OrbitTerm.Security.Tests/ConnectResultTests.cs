using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class ConnectResultTests
{
    [Fact]
    public void NativeConnectedOutcomeMapsToVerifiedLease()
    {
        var outcome = new CheckedConnectOutcome.Connected(new ConnectedPayload(
            9UL,
            "Example.COM",
            "example.com",
            22,
            "example.com:22",
            "ssh-ed25519",
            "SHA256:abc",
            CheckedSecurityGeneration.HostKeyVerified));

        var result = ConnectResult.FromNative(Guid.NewGuid(), Guid.NewGuid(), outcome);

        var connected = Assert.IsType<ConnectResult.Connected>(result);
        Assert.Equal(9UL, connected.Lease.BaseSessionId);
        Assert.Equal("example.com", connected.Lease.Host);
    }

    [Fact]
    public void NativeChallengeMapsToTrustPromptOnlyWhenTrustableAndNotReplaceable()
    {
        var outcome = new CheckedConnectOutcome.Challenge(new HostKeyChallengePayload(
            "challenge-1",
            "request-1",
            "new.example",
            "new.example",
            22,
            "new.example:22",
            "ssh-ed25519",
            "SHA256:new",
            "unknown_host",
            "unknown",
            true,
            false,
            1893456000,
            false,
            1));

        var result = ConnectResult.FromNative(Guid.NewGuid(), Guid.NewGuid(), outcome);

        var prompt = Assert.IsType<ConnectResult.RequiresHostKeyTrust>(result);
        Assert.Equal("challenge-1", prompt.Challenge.ChallengeId);
        Assert.Equal("request-1", prompt.Challenge.RequestId);
        Assert.Equal("SHA256:new", prompt.Challenge.FingerprintSha256);
    }

    [Fact]
    public void ReplaceableChallengeIsRejectedByApplicationLayer()
    {
        var outcome = new CheckedConnectOutcome.Challenge(new HostKeyChallengePayload(
            "challenge-1",
            "request-1",
            "example.com",
            "example.com",
            22,
            "example.com:22",
            "ssh-ed25519",
            "SHA256:new",
            "changed",
            "changed",
            true,
            true,
            1893456000,
            false,
            1));

        Assert.Throws<InvalidOperationException>(() =>
            ConnectResult.FromNative(Guid.NewGuid(), Guid.NewGuid(), outcome));
    }

    [Fact]
    public void BlockedOutcomeCannotBecomeTrustPrompt()
    {
        var outcome = new CheckedConnectOutcome.Blocked(new HostKeyBlockedPayload(
            "example.com",
            "example.com",
            22,
            "example.com:22",
            "ssh-ed25519",
            "SHA256:new",
            "SHA256:old",
            "changed",
            "changed",
            false,
            false,
            "error.host_key.changed"));

        var result = ConnectResult.FromNative(Guid.NewGuid(), Guid.NewGuid(), outcome);

        var blocked = Assert.IsType<ConnectResult.Blocked>(result);
        Assert.Equal("changed", blocked.Block.ReasonCode);
    }

    [Theory]
    [InlineData("verification_code_required", false)]
    [InlineData("jump_verification_code_required", true)]
    public void SecondFactorErrorIdentifiesTheCorrectHop(string detailCode, bool forJump)
    {
        var outcome = new CheckedConnectOutcome.Failed(new CheckedErrorPayload(
            "ssh_second_factor_required",
            "error.ssh.second_factor_required",
            "request-1",
            detailCode));

        var result = ConnectResult.FromNative(Guid.NewGuid(), Guid.NewGuid(), outcome);

        Assert.Equal(forJump, Assert.IsType<ConnectResult.RequiresSecondFactor>(result).ForJump);
    }

    [Fact]
    public void ConnectionRequestDiagnosticStringDoesNotExposeCredentialsOrCode()
    {
        var request = new CheckedConnectionRequest(
            "host.example", 22, "user", "password-secret", "", "", true,
            "known-hosts", OneTimeCode: "one-time-secret");

        Assert.DoesNotContain("password-secret", request.ToString());
        Assert.DoesNotContain("one-time-secret", request.ToString());
    }
}
