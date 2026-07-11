namespace OrbitTerm.NativeBridge;

public abstract record TerminalControlResult
{
    private const string Separator = ":";
    private static readonly string OkPrefix = string.Concat("OK", Separator);
    private static readonly string ErrorPrefix = string.Concat("ERR", Separator);

    private TerminalControlResult()
    {
    }

    public sealed record Succeeded(string Detail) : TerminalControlResult;

    public sealed record Failed(string Message) : TerminalControlResult;

    public static TerminalControlResult Decode(string value)
    {
        if (value.StartsWith(OkPrefix, StringComparison.Ordinal))
        {
            return new Succeeded(value[OkPrefix.Length..]);
        }

        if (value.StartsWith(ErrorPrefix, StringComparison.Ordinal))
        {
            return new Failed(value[ErrorPrefix.Length..]);
        }

        throw new OrbitNativeException("Terminal control returned an unsupported response.");
    }
}
