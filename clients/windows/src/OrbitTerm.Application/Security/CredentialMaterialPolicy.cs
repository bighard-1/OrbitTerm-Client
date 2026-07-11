using System.Text;

namespace OrbitTerm.Application.Security;

public static class CredentialMaterialPolicy
{
    public const int MaxFieldBytes = 1024 * 1024;

    public static void EnsureStorable(CredentialMaterial credential)
    {
        ArgumentNullException.ThrowIfNull(credential);
        EnsureField("password", credential.Password);
        EnsureField("private_key", credential.PrivateKey);
        EnsureField("private_key_passphrase", credential.PrivateKeyPassphrase);
    }

    private static void EnsureField(string name, string value)
    {
        if (value is null)
        {
            throw new ArgumentException($"Credential field is missing: {name}.");
        }

        if (Encoding.UTF8.GetByteCount(value) > MaxFieldBytes)
        {
            throw new ArgumentOutOfRangeException(name, "Credential field is too large.");
        }
    }
}
