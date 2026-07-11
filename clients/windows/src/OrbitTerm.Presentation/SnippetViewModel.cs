using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed record SnippetViewModel(
    Guid Id,
    string Title,
    string Command,
    string Category,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public SnippetRecord ToRecord() => new(Id, Title, Command, Category, CreatedAt, UpdatedAt);

    public static SnippetViewModel FromRecord(SnippetRecord record) =>
        new(record.Id, record.Title, record.Command, record.Category, record.CreatedAt, record.UpdatedAt);
}
