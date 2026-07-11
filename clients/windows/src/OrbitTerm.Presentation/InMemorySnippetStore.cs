using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed class InMemorySnippetStore : ISnippetStore
{
    private IReadOnlyList<SnippetRecord> snippets = [];

    public ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(snippets);
    }

    public ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        this.snippets = snippets.ToArray();
        return ValueTask.CompletedTask;
    }
}
