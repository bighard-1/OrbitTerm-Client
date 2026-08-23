using System.Text;
using OrbitTerm.Application.Security;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SshPublicKeyDeploymentPolicyTests
{
    private const string PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhrAuQKqTzSY+oHGn4o9rGVKhX1jP/dxeObn7O66GjG OrbitTerm test";

    [Fact]
    public void NormalizePublicKeyRejectsAdditionalCommandsAndLineBreaks()
    {
        Assert.Throws<ArgumentException>(() =>
            SshPublicKeyDeploymentPolicy.NormalizePublicKey(PublicKey + "\nrm -rf /"));
        Assert.Throws<ArgumentException>(() =>
            SshPublicKeyDeploymentPolicy.NormalizePublicKey("not-a-public-key"));
    }

    [Fact]
    public void PosixCommandIsIdempotentAndQuotesComment()
    {
        var command = SshPublicKeyDeploymentPolicy.BuildPosixCommand(PublicKey + "'s");

        Assert.Contains("grep -Fqx", command, StringComparison.Ordinal);
        Assert.Contains("authorized_keys", command, StringComparison.Ordinal);
        Assert.Contains(SshPublicKeyDeploymentPolicy.SuccessMarker + "existing", command, StringComparison.Ordinal);
        Assert.Contains("'\"'\"'", command, StringComparison.Ordinal);
    }

    [Fact]
    public void WindowsCommandUsesEncodedPowerShellAndContainsNoPublicKeyText()
    {
        var command = SshPublicKeyDeploymentPolicy.BuildWindowsCommand(PublicKey);
        var encoded = command.Split(' ', StringSplitOptions.RemoveEmptyEntries)[^1];
        var script = Encoding.Unicode.GetString(Convert.FromBase64String(encoded));

        Assert.StartsWith("powershell.exe -NoLogo -NoProfile -NonInteractive", command, StringComparison.Ordinal);
        Assert.DoesNotContain(PublicKey, command, StringComparison.Ordinal);
        Assert.Contains("administrators_authorized_keys", script, StringComparison.Ordinal);
        Assert.Contains(SshPublicKeyDeploymentPolicy.SuccessMarker, script, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ORBITTERM_KEY_DEPLOY_OK:added", false)]
    [InlineData("ORBITTERM_KEY_DEPLOY_OK:existing", true)]
    public void SuccessMarkerIsParsed(string output, bool expectedExisting)
    {
        Assert.True(SshPublicKeyDeploymentPolicy.TryReadSuccess(output, string.Empty, out var existing));
        Assert.Equal(expectedExisting, existing);
    }
}
