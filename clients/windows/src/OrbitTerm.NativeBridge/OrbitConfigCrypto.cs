namespace OrbitTerm.NativeBridge;

/// <summary>Windows bridge for the shared Rust V2 config-root derivation.</summary>
public static class OrbitConfigCrypto
{
    public static byte[] DeriveConfigRootKeyV2(string masterPassword, string accountScope)
    {
        if (string.IsNullOrWhiteSpace(masterPassword) || string.IsNullOrWhiteSpace(accountScope))
        {
            throw new ArgumentException("主密码和账户作用域不能为空。");
        }

        using var result = NativeMethods.orbit_derive_config_root_key_v2(masterPassword, accountScope);
        var value = result.ToOwnedString();
        if (!value.StartsWith("OK:", StringComparison.Ordinal))
        {
            throw new OrbitNativeException("共享加密核心未返回有效的 V2 配置根密钥。");
        }

        var key = Convert.FromBase64String(value[3..]);
        if (key.Length != 32)
        {
            throw new OrbitNativeException("共享加密核心未返回有效的 V2 配置根密钥。");
        }

        return key;
    }

    public static byte[] DecryptConfigV2(byte[] rootKey, byte[] encrypted)
    {
        ArgumentNullException.ThrowIfNull(rootKey);
        ArgumentNullException.ThrowIfNull(encrypted);
        if (rootKey.Length != 32 || encrypted.Length == 0)
        {
            throw new ArgumentException("V2 配置解密输入无效。");
        }

        using var result = NativeMethods.orbit_decrypt_config_v2(
            rootKey,
            (nuint)rootKey.Length,
            Convert.ToBase64String(encrypted));
        return ReadDecryptedPayload(result, "无法用当前主密码解锁加密配置。");
    }

    public static byte[] DecryptConfigLegacy(string masterPassword, byte[] encrypted)
    {
        if (string.IsNullOrWhiteSpace(masterPassword) || encrypted.Length == 0)
        {
            throw new ArgumentException("旧版配置解密输入无效。");
        }

        using var result = NativeMethods.orbit_decrypt_config(masterPassword, Convert.ToBase64String(encrypted));
        return ReadDecryptedPayload(result, "无法用当前主密码解锁历史加密配置。");
    }

    public static byte[] EncryptConfigLegacy(string masterPassword, byte[] plaintext)
    {
        if (string.IsNullOrWhiteSpace(masterPassword) || plaintext.Length == 0)
        {
            throw new ArgumentException("旧版配置加密输入无效。");
        }

        using var result = NativeMethods.orbit_encrypt_config(
            masterPassword,
            plaintext,
            (nuint)plaintext.Length);
        return ReadDecryptedPayload(result, "无法加密历史配置。");
    }

    public static byte[] EncryptConfigV2(byte[] rootKey, byte[] plaintext)
    {
        ArgumentNullException.ThrowIfNull(rootKey);
        ArgumentNullException.ThrowIfNull(plaintext);
        if (rootKey.Length != 32 || plaintext.Length == 0)
        {
            throw new ArgumentException("V2 配置加密输入无效。");
        }

        using var result = NativeMethods.orbit_encrypt_config_v2(
            rootKey,
            (nuint)rootKey.Length,
            plaintext,
            (nuint)plaintext.Length);
        return ReadDecryptedPayload(result, "无法加密 V2 配置。");
    }

    private static byte[] ReadDecryptedPayload(OrbitCString result, string errorMessage)
    {
        var value = result.ToOwnedString();
        if (!value.StartsWith("OK:", StringComparison.Ordinal))
        {
            throw new OrbitNativeException(errorMessage);
        }

        return Convert.FromBase64String(value[3..]);
    }
}
