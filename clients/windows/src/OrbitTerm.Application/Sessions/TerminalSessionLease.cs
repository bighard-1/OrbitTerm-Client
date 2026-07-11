using OrbitTerm.Terminal;

namespace OrbitTerm.Application.Sessions;

public sealed record TerminalSessionLease(
    Guid WorkspaceId,
    Guid ServerId,
    ulong BaseSessionId,
    ulong TerminalChannelId,
    TerminalSize Size,
    string Host,
    int Port,
    string HostKeyAlgorithm,
    string HostKeyFingerprintSha256);
