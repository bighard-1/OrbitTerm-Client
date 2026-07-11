namespace OrbitTerm.NativeBridge;

public sealed class TerminalDataReceivedEventArgs : EventArgs
{
    public TerminalDataReceivedEventArgs(ulong terminalChannelId, byte[] data)
    {
        if (terminalChannelId == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(terminalChannelId));
        }

        TerminalChannelId = terminalChannelId;
        Data = data.Length == 0 ? throw new ArgumentException("Terminal output must not be empty.", nameof(data)) : data;
    }

    public ulong TerminalChannelId { get; }

    public byte[] Data { get; }
}
