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
}
