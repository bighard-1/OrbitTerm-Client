using System.Security.Cryptography;
using System.Text;

namespace OrbitTerm.Application.Security;

public static class SshKeyMaterialPolicy
{
    public const int MaximumPrivateKeyBytes = 1024 * 1024;
    public const int MaximumPassphraseBytes = 16 * 1024;
    public const int MaximumNameLength = 80;

    public static string NormalizeName(string? name)
    {
        var cleaned = new string((name ?? string.Empty)
            .Trim()
            .Where(character => !char.IsControl(character))
            .ToArray());
        if (cleaned.Length == 0)
        {
            throw new ArgumentException("密钥名称不能为空。", nameof(name));
        }

        return cleaned.Length <= MaximumNameLength ? cleaned : cleaned[..MaximumNameLength];
    }

    public static string NormalizePrivateKey(string? privateKey)
    {
        var normalized = (privateKey ?? string.Empty)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .TrimStart('\uFEFF')
            .Trim();
        if (normalized.Length == 0 || normalized.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("私钥内容为空或无效。", nameof(privateKey));
        }

        if (Encoding.UTF8.GetByteCount(normalized) > MaximumPrivateKeyBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(privateKey), "私钥文件不能超过 1 MB。");
        }

        if (!normalized.StartsWith("PuTTY-User-Key-File-2:", StringComparison.Ordinal) &&
            !normalized.StartsWith("PuTTY-User-Key-File-3:", StringComparison.Ordinal) &&
            !normalized.Contains("-----BEGIN OPENSSH PRIVATE KEY-----", StringComparison.Ordinal) &&
            !normalized.Contains("-----BEGIN RSA PRIVATE KEY-----", StringComparison.Ordinal) &&
            !normalized.Contains("-----BEGIN EC PRIVATE KEY-----", StringComparison.Ordinal) &&
            !normalized.Contains("-----BEGIN PRIVATE KEY-----", StringComparison.Ordinal) &&
            !normalized.Contains("-----BEGIN ENCRYPTED PRIVATE KEY-----", StringComparison.Ordinal))
        {
            throw new ArgumentException("仅支持 Ed25519、RSA 或 ECDSA 的 OpenSSH、PEM/PKCS#8、PuTTY PPK v2/v3 私钥，不能导入 .pub 公钥或 DSA 私钥。", nameof(privateKey));
        }

        return string.Concat(normalized, "\n");
    }

    public static string NormalizePassphrase(string? passphrase)
    {
        var value = passphrase ?? string.Empty;
        if (Encoding.UTF8.GetByteCount(value) > MaximumPassphraseBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(passphrase), "私钥口令过长。");
        }

        return value;
    }

    public static string DetectContainer(string privateKey) => privateKey switch
    {
        var value when value.StartsWith("PuTTY-User-Key-File-3:", StringComparison.Ordinal) => "PuTTY PPK v3",
        var value when value.StartsWith("PuTTY-User-Key-File-2:", StringComparison.Ordinal) => "PuTTY PPK v2",
        var value when value.Contains("BEGIN OPENSSH PRIVATE KEY", StringComparison.Ordinal) => "OpenSSH",
        var value when value.Contains("BEGIN RSA PRIVATE KEY", StringComparison.Ordinal) => "RSA/PEM",
        var value when value.Contains("BEGIN EC PRIVATE KEY", StringComparison.Ordinal) => "ECDSA/PEM",
        var value when value.Contains("BEGIN ENCRYPTED PRIVATE KEY", StringComparison.Ordinal) => "PKCS#8 加密",
        _ => "PKCS#8",
    };

    /// <summary>
    /// Stable local duplicate detector. This is deliberately named a material
    /// fingerprint: it is not presented as an SSH public-key fingerprint.
    /// </summary>
    public static string MaterialFingerprint(string privateKey)
    {
        var normalized = NormalizePrivateKey(privateKey);
        var bytes = Encoding.UTF8.GetBytes(normalized);
        try
        {
            return string.Concat("SHA256:", Convert.ToBase64String(SHA256.HashData(bytes)).TrimEnd('='));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}
