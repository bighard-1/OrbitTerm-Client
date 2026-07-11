namespace OrbitTerm.Application.Sessions;

public sealed record SftpSessionLease(
    Guid WorkspaceId,
    Guid ServerId,
    ulong BaseSessionId,
    ulong SftpSessionId,
    string Host,
    int Port,
    string HostKeyAlgorithm,
    string HostKeyFingerprintSha256);
