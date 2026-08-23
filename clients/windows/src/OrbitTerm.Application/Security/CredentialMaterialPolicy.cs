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

    /// <summary>
    /// Canonicalizes SSH key text at every platform boundary.  In particular,
    /// Windows text files may contain a UTF BOM or CRLF line endings which are
    /// harmless to an editor but are not accepted consistently by SSH key
    /// parsers on every device.
    /// </summary>
    public static CredentialMaterial NormalizeSshCredential(CredentialMaterial credential)
    {
        ArgumentNullException.ThrowIfNull(credential);
        EnsureStorable(credential);
        if (string.IsNullOrWhiteSpace(credential.PrivateKey))
        {
            return credential with
            {
                PrivateKey = string.Empty,
                PrivateKeyPassphrase = string.Empty,
            };
        }

        var normalized = credential with
        {
            PrivateKey = SshKeyMaterialPolicy.NormalizePrivateKey(credential.PrivateKey),
            PrivateKeyPassphrase = SshKeyMaterialPolicy.NormalizePassphrase(credential.PrivateKeyPassphrase),
        };
        EnsureStorable(normalized);
        return normalized;
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
