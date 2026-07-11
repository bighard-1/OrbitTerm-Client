namespace OrbitTerm.Application.Sessions;

public sealed record SnippetRecord(
    Guid Id,
    string Title,
    string Command,
    string Category,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);
