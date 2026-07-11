using System;
using System.Collections.Generic;
using System.Linq;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Sessions;

public abstract record SftpDirectoryListResult
{
    public sealed record Listed(
        SftpSessionLease Lease,
        string Path,
        IReadOnlyList<SftpDirectoryEntry> Entries) : SftpDirectoryListResult;

    public sealed record Failed(string Code, string MessageKey) : SftpDirectoryListResult;

    public static SftpDirectoryListResult FromEnvelope(SftpSessionLease lease, string path, CheckedEnvelope envelope)
    {
        if (envelope.Error is not null)
        {
            return new Failed(envelope.Error.Code, envelope.Error.MessageKey);
        }

        if (!string.Equals(envelope.Kind, CheckedFfiKind.SftpDirectoryList, StringComparison.Ordinal))
        {
            return new Failed("invalid_sftp_list_kind", "error.sftp.list.invalid_kind");
        }

        var payload = CheckedEnvelopeDecoder.DecodePayload<SftpDirectoryListPayload>(
            envelope,
            CheckedFfiKind.SftpDirectoryList);
        payload.Validate();
        if (payload.ParsedSftpSessionId != lease.SftpSessionId ||
            !string.Equals(payload.Path, path, StringComparison.Ordinal))
        {
            return new Failed("sftp_list_mismatch", "error.sftp.list.mismatch");
        }

        return new Listed(
            lease,
            payload.Path,
            payload.Entries
                .Select(entry => new SftpDirectoryEntry(
                    entry.Name,
                    entry.Size,
                    entry.Permissions,
                    entry.PermissionsOctal,
                    entry.ModifiedAtUnix))
                .ToArray());
    }
}

public sealed record SftpDirectoryEntry(
    string Name,
    ulong Size,
    string Permissions,
    uint PermissionsOctal,
    ulong ModifiedAtUnix);
