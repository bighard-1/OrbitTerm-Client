namespace OrbitTerm.Application.Sessions;

public abstract record TerminalControlOutcome
{
    private TerminalControlOutcome()
    {
    }

    public sealed record Succeeded : TerminalControlOutcome;

    public sealed record Failed(string Code, string MessageKey) : TerminalControlOutcome;
}
