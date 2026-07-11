using System.Collections.ObjectModel;

namespace OrbitTerm.Presentation;

public sealed class SnippetGroupViewModel(string category, IEnumerable<SnippetViewModel> items)
{
    public string Category { get; } = category;

    public ObservableCollection<SnippetViewModel> Items { get; } = new(items);
}
