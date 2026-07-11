using System.Text.Json;
using OrbitTerm.Application.Security;

namespace OrbitTerm.Platform.Windows.Security;

internal static class CredentialVaultSerializer
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static byte[] Serialize(CredentialMaterial credential)
    {
        CredentialMaterialPolicy.EnsureStorable(credential);
        return JsonSerializer.SerializeToUtf8Bytes(
            new CredentialVaultRecord(
                credential.Password,
                credential.PrivateKey,
                credential.PrivateKeyPassphrase),
            JsonOptions);
    }

    public static CredentialMaterial Deserialize(byte[] payload)
    {
        if (payload.Length == 0 || payload.Length > 3 * CredentialMaterialPolicy.MaxFieldBytes)
        {
            throw new InvalidDataException("Credential payload size is invalid.");
        }

        var record = JsonSerializer.Deserialize<CredentialVaultRecord>(payload, JsonOptions)
            ?? throw new InvalidDataException("Credential payload is empty.");

        var credential = new CredentialMaterial(
            record.Password ?? string.Empty,
            record.PrivateKey ?? string.Empty,
            record.PrivateKeyPassphrase ?? string.Empty);
        CredentialMaterialPolicy.EnsureStorable(credential);
        return credential;
    }

    private sealed record CredentialVaultRecord(
        string? Password,
        string? PrivateKey,
        string? PrivateKeyPassphrase);
}
