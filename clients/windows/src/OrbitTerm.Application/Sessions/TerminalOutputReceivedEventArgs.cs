namespace OrbitTerm.Application.Sessions;

public sealed class TerminalOutputReceivedEventArgs : EventArgs
{
    public TerminalOutputReceivedEventArgs(TerminalSessionLease lease, string text, string snapshot)
    {
        Lease = lease;
        Text = string.IsNullOrEmpty(text) ? throw new ArgumentException("Terminal output text must not be empty.", nameof(text)) : text;
        Snapshot = snapshot;
    }

    public TerminalSessionLease Lease { get; }

    public string Text { get; }

    public string Snapshot { get; }
}
