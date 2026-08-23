using OrbitTerm.Application.Security;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class CredentialMaterialPolicyTests
{
    [Fact]
    public void StorableCredentialAllowsPasswordAndKeyMaterial()
    {
        var credential = new CredentialMaterial(
            "password",
            "private-key",
            "passphrase");

        CredentialMaterialPolicy.EnsureStorable(credential);
    }

    [Fact]
    public void OversizedCredentialFieldIsRejected()
    {
        var oversized = new string('a', CredentialMaterialPolicy.MaxFieldBytes + 1);
        var credential = new CredentialMaterial(
            oversized,
            string.Empty,
            string.Empty);

        Assert.Throws<ArgumentOutOfRangeException>(() =>
            CredentialMaterialPolicy.EnsureStorable(credential));
    }

    [Fact]
    public void UploadedPrivateKeyIsCanonicalizedBeforeStorageOrSynchronization()
    {
        var credential = new CredentialMaterial(
            string.Empty,
            "\uFEFF-----BEGIN OPENSSH PRIVATE KEY-----\r\nwindows-upload\r\n-----END OPENSSH PRIVATE KEY-----\r\n",
            "passphrase");

        var normalized = CredentialMaterialPolicy.NormalizeSshCredential(credential);

        Assert.Equal(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nwindows-upload\n-----END OPENSSH PRIVATE KEY-----\n",
            normalized.PrivateKey);
        Assert.Equal("passphrase", normalized.PrivateKeyPassphrase);
    }

    [Fact]
    public void PuttyPpkV3IsAcceptedForWindowsFileImport()
    {
        var credential = new CredentialMaterial(
            string.Empty,
            "PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: none\r\nComment: test",
            string.Empty);

        var normalized = CredentialMaterialPolicy.NormalizeSshCredential(credential);

        Assert.StartsWith("PuTTY-User-Key-File-3:", normalized.PrivateKey, StringComparison.Ordinal);
        Assert.EndsWith("\n", normalized.PrivateKey, StringComparison.Ordinal);
    }
}
