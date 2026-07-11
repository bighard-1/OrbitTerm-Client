using System.Linq;
using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record SftpEntrySnapshot(
    ulong Size,
    uint PermissionsOctal,
    ulong ModifiedAtUnix,
    bool IsDirectory)
{
    public void Validate()
    {
        var permissionType = PermissionsOctal & 0xF000U;
        if (PermissionsOctal > 0xFFFFU || IsDirectory != (permissionType == 0x4000U))
        {
            throw new ArgumentException("SFTP entry snapshot contains inconsistent metadata.");
        }
    }
}

public sealed record SftpMutationPayload(
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("operation")] string Operation,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("destination_path")] string? DestinationPath,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration)
{
    public ulong ParsedSftpSessionId => ulong.TryParse(SftpSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("SFTP mutation contains an invalid sftp_session_id.");

    public void Validate()
    {
        SftpMutationPolicy.EnsureCanonicalPath(Path, nameof(Path));
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified)
        {
            throw new OrbitNativeException("SFTP mutation is not bound to a HostKeyVerified session.");
        }

        if (string.Equals(Operation, "rename", StringComparison.Ordinal))
        {
            SftpMutationPolicy.EnsureCanonicalPath(DestinationPath, nameof(DestinationPath));
            if (string.Equals(Path, DestinationPath, StringComparison.Ordinal))
            {
                throw new OrbitNativeException("SFTP rename paths must be distinct.");
            }
        }
        else if ((!string.Equals(Operation, "mkdir", StringComparison.Ordinal) &&
                  !string.Equals(Operation, "create_file", StringComparison.Ordinal) &&
                  !string.Equals(Operation, "remove", StringComparison.Ordinal) &&
                  !string.Equals(Operation, "chmod", StringComparison.Ordinal) &&
                  !string.Equals(Operation, "write_text", StringComparison.Ordinal)) ||
                 DestinationPath is not null)
        {
            throw new OrbitNativeException("SFTP mutation operation payload is invalid.");
        }
    }
}

internal static class SftpMutationPolicy
{
    public static void EnsureCanonicalPath(string? remotePath, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(remotePath) ||
            remotePath.Length > 512 ||
            remotePath == "/" ||
            !remotePath.StartsWith("/", StringComparison.Ordinal) ||
            remotePath.EndsWith("/", StringComparison.Ordinal) ||
            remotePath.Contains('\\', StringComparison.Ordinal) ||
            remotePath.Any(char.IsControl) ||
            remotePath.Split('/').Skip(1).Any(segment => segment is "" or "." or ".."))
        {
            throw new ArgumentException("SFTP mutation requires a canonical non-root absolute path.", parameterName);
        }
    }
}
