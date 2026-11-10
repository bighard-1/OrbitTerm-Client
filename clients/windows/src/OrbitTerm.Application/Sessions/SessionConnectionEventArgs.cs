namespace OrbitTerm.Application.Sessions;

public enum SessionConnectionEventKind
{
    ConnectionLost,
    TerminalClosed,
}

public sealed class SessionConnectionEventArgs(
    Guid workspaceId,
    Guid serverId,
    ulong sessionOrChannelId,
    SessionConnectionEventKind kind) : EventArgs
{
    public Guid WorkspaceId { get; } = workspaceId;

    public Guid ServerId { get; } = serverId;

    public ulong SessionOrChannelId { get; } = sessionOrChannelId;

    public SessionConnectionEventKind Kind { get; } = kind;
}
