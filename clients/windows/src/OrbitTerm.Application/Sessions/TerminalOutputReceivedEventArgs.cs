using OrbitTerm.Terminal;

namespace OrbitTerm.Application.Sessions;

public sealed class TerminalOutputReceivedEventArgs : EventArgs
{
    public TerminalOutputReceivedEventArgs(TerminalSessionLease lease, string text, string snapshot, TerminalScreenSnapshot screen)
    {
        Lease = lease;
        Text = string.IsNullOrEmpty(text) ? throw new ArgumentException("Terminal output text must not be empty.", nameof(text)) : text;
        Snapshot = snapshot;
        Screen = screen ?? throw new ArgumentNullException(nameof(screen));
    }

    public TerminalSessionLease Lease { get; }

    public string Text { get; }

    public string Snapshot { get; }

    /// <summary>ANSI-aware screen and scrollback state after <see cref="Text"/> was applied.</summary>
    public TerminalScreenSnapshot Screen { get; }
}
