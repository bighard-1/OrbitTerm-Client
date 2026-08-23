using System.Collections.ObjectModel;

namespace OrbitTerm.Presentation;

public sealed class AssetGroupViewModel(string name, IEnumerable<AssetViewModel> items)
{
    public string Name { get; } = name;

    public ObservableCollection<AssetViewModel> Items { get; } = new(items);

    public int Count => Items.Count;
}
