using System.Text;
using OrbitTerm.Application.Security;
using OrbitTerm.Platform.Windows.Security;
using Xunit;

namespace OrbitTerm.Platform.Windows.Tests;

public sealed class WindowsSshKeyVaultTests
{
    [Fact]
    public async Task DpapiVaultRoundTripsWithoutPlaintextMetadataOrSecret()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OrbitTerm", "Tests", Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "ssh-key-library.dpapi");
        try
        {
            var vault = new WindowsSshKeyVault(path);
            var now = DateTimeOffset.UtcNow;
            var privateKey = """
                -----BEGIN OPENSSH PRIVATE KEY-----
                dpapi-integration-secret
                -----END OPENSSH PRIVATE KEY-----
                """;
            var record = new SshKeyRecord(
                Guid.NewGuid(), "DPAPI 集成密钥", "OpenSSH",
                SshKeyMaterialPolicy.MaterialFingerprint(privateKey), now, now,
                SshKeyOrigin.Imported, [Guid.NewGuid()]);

            await vault.SaveAsync(
                new SshKeyVaultEntry(record, new SshKeySecret(privateKey, "secret-passphrase")),
                CancellationToken.None);

            var restored = await vault.ReadAsync(record.Id, CancellationToken.None);
            Assert.NotNull(restored);
            Assert.Equal(record.Name, restored.Record.Name);
            Assert.Equal(SshKeyMaterialPolicy.NormalizePrivateKey(privateKey), restored.Secret.PrivateKey);
            Assert.Equal("secret-passphrase", restored.Secret.Passphrase);

            var encryptedBytes = await File.ReadAllBytesAsync(path);
            var accidentalText = Encoding.UTF8.GetString(encryptedBytes);
            Assert.DoesNotContain("DPAPI 集成密钥", accidentalText, StringComparison.Ordinal);
            Assert.DoesNotContain("dpapi-integration-secret", accidentalText, StringComparison.Ordinal);
            Assert.DoesNotContain("secret-passphrase", accidentalText, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
