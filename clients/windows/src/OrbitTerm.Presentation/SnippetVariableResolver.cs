using System.Text.RegularExpressions;

namespace OrbitTerm.Presentation;

public static partial class SnippetVariableResolver
{
    public static IReadOnlyList<string> Extract(string command)
    {
        ArgumentNullException.ThrowIfNull(command);
        return VariablePattern().Matches(command)
            .Select(match => match.Groups[1].Value)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
    }

    public static string Resolve(string command, IReadOnlyDictionary<string, string> values)
    {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentNullException.ThrowIfNull(values);
        var required = Extract(command);
        if (required.Any(key => !values.TryGetValue(key, out var value) ||
                                value.Length > 1024 || value.Any(char.IsControl)))
        {
            throw new ArgumentException("Every Snippet variable requires a bounded printable value.", nameof(values));
        }

        var resolved = VariablePattern().Replace(command, match => values[match.Groups[1].Value]);
        if (resolved.Length is < 1 or > 8192 || resolved.Any(char.IsControl))
        {
            throw new ArgumentException("Resolved Snippet command is invalid.", nameof(values));
        }

        return resolved;
    }

    [GeneratedRegex(@"\{\{([a-zA-Z0-9_]+)\}\}", RegexOptions.CultureInvariant)]
    private static partial Regex VariablePattern();
}
