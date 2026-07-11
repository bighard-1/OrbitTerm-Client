namespace OrbitTerm.Application.Sessions;

public sealed record VerifiedSessionLease(
    Guid WorkspaceId,
    Guid ServerId,
    ulong BaseSessionId,
    string Host,
    int Port,
    string Username,
    string HostKeyAlgorithm,
    string HostKeyFingerprintSha256);
