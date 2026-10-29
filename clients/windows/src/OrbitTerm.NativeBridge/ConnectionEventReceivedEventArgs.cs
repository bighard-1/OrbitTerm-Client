namespace OrbitTerm.NativeBridge;

public enum OrbitConnectionEventKind
{
    ConnectionLost,
    TerminalClosed,
}

public sealed class ConnectionEventReceivedEventArgs(
    ulong sessionOrChannelId,
    OrbitConnectionEventKind kind) : EventArgs
{
    public ulong SessionOrChannelId { get; } = sessionOrChannelId;

    public OrbitConnectionEventKind Kind { get; } = kind;
}
