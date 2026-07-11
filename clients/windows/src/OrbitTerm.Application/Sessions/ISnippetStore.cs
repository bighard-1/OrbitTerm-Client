namespace OrbitTerm.Application.Sessions;

public interface ISnippetStore
{
    ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken cancellationToken);

    ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken cancellationToken);
}
