namespace OrbitTerm.Application.Security;

public static class Redaction
{
    public const string Marker = "[REDACTED]";

    public static string Secret(string? value) => string.IsNullOrEmpty(value) ? string.Empty : Marker;

    public static string Command(string? value) => string.IsNullOrWhiteSpace(value) ? string.Empty : Marker;

    public static string Path(string? value) => string.IsNullOrWhiteSpace(value) ? string.Empty : Marker;
}
