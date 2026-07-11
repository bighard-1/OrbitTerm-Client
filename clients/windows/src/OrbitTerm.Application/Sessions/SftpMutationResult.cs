using System;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public static class SftpMutationOperations
{
    public const string MakeDirectory = "mkdir";
    public const string CreateFile = "create_file";
    public const string Rename = "rename";
    public const string Remove = "remove";
    public const string ChangePermissions = "chmod";
    public const string WriteText = "write_text";
}

public sealed record SftpMutationSnapshot(
    ulong Size,
    uint PermissionsOctal,
    ulong ModifiedAtUnix,
    bool IsDirectory);

public abstract record SftpMutationResult
{
    public sealed record Completed(
        SftpSessionLease Lease,
        string Operation,
        string Path,
        string? DestinationPath) : SftpMutationResult;

    public sealed record Failed(string Code, string MessageKey) : SftpMutationResult;

    public static SftpMutationResult FromEnvelope(
        SftpSessionLease lease,
        string operation,
        string path,
        string? destinationPath,
        CheckedEnvelope envelope)
    {
        if (envelope.IsError)
        {
            return new Failed(
                envelope.Error?.Code ?? "sftp_mutation_failed",
                envelope.Error?.MessageKey ?? "error.sftp.mutation_failed");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpMutationPayload>(
            envelope,
            CheckedFfiKind.SftpMutationCompleted);
        payload.Validate();
        if (payload.ParsedSftpSessionId != lease.SftpSessionId ||
            !string.Equals(payload.Operation, operation, StringComparison.Ordinal) ||
            !string.Equals(payload.Path, path, StringComparison.Ordinal) ||
            !string.Equals(payload.DestinationPath, destinationPath, StringComparison.Ordinal))
        {
            return new Failed("sftp_mutation_mismatch", "error.sftp.mutation.mismatch");
        }

        return new Completed(
            lease,
            payload.Operation,
            payload.Path,
            payload.DestinationPath);
    }
}
