using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

internal sealed record SshPrivateKeyValidatedPayload(
    [property: JsonPropertyName("algorithm")] string Algorithm);

public sealed record SshPrivateKeyInspection(string Algorithm)
{
    public string DisplayName => Algorithm switch
    {
        "ssh-ed25519" => "Ed25519",
        "ssh-rsa" or "rsa-sha2-256" or "rsa-sha2-512" => "RSA",
        "ecdsa-sha2-nistp256" => "ECDSA P-256",
        "ecdsa-sha2-nistp384" => "ECDSA P-384",
        "ecdsa-sha2-nistp521" => "ECDSA P-521",
        _ => Algorithm,
    };
}

/// <summary>
/// Uses orbit-core's real SSH decoder. This is intentionally synchronous:
/// parsing is local, bounded to the 1 MB key policy and performs no network IO.
/// </summary>
public static class SshPrivateKeyInspector
{
    public static SshPrivateKeyInspection Inspect(string privateKey, string passphrase)
    {
        if (string.IsNullOrWhiteSpace(privateKey))
        {
            throw new ArgumentException("SSH 私钥不能为空。", nameof(privateKey));
        }

        var requestId = HostKeyRequestId.Create();
        using var result = NativeMethods.orbit_validate_ssh_private_key_checked_v2(
            privateKey,
            passphrase ?? string.Empty,
            requestId.Value);
        var envelope = CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
        if (!envelope.IsError)
        {
            var payload = CheckedEnvelopeDecoder.DecodePayload<SshPrivateKeyValidatedPayload>(
                envelope,
                CheckedFfiKind.SshPrivateKeyValidated);
            if (!string.IsNullOrWhiteSpace(payload.Algorithm))
            {
                return new SshPrivateKeyInspection(payload.Algorithm);
            }
        }

        throw new ArgumentException(envelope.Error?.Code switch
        {
            "ssh_key_algorithm_unsupported" =>
                "该私钥使用 DSA、FIDO/安全密钥或其他不可移植算法。请选择 Ed25519、RSA 或 ECDSA 私钥。",
            "ssh_key_parse_failed" =>
                "无法解析该私钥。请检查私钥格式和私钥口令；不要粘贴 .pub 公钥。",
            _ => "SSH 私钥无效，无法安全保存。",
        }, nameof(privateKey));
    }
}
