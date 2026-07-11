namespace OrbitTerm.Terminal;

public readonly record struct TerminalSize(uint Columns, uint Rows)
{
    public static TerminalSize Default => new(120, 32);

    public void Validate()
    {
        if (Columns is < 1 or > 1000 || Rows is < 1 or > 1000)
        {
            throw new ArgumentOutOfRangeException(nameof(TerminalSize), "Terminal size must be between 1 and 1000 cells.");
        }
    }
}
