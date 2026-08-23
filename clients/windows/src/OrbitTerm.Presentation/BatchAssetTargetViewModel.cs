namespace OrbitTerm.Presentation;

public sealed class BatchAssetTargetViewModel : ObservableObject
{
    private bool isSelected;
    private string stateText;

    public BatchAssetTargetViewModel(
        Guid assetId,
        string name,
        string endpoint,
        string group,
        bool isSelected,
        bool isConnected,
        string stateText)
    {
        AssetId = assetId;
        Name = name;
        Endpoint = endpoint;
        Group = group;
        this.isSelected = isSelected;
        IsConnected = isConnected;
        this.stateText = stateText;
    }

    public Guid AssetId { get; }

    public string Name { get; }

    public string Endpoint { get; }

    public string Group { get; }

    public bool IsSelected
    {
        get => isSelected;
        set => SetProperty(ref isSelected, value);
    }

    public bool IsConnected { get; private set; }

    public string StateText
    {
        get => stateText;
        private set => SetProperty(ref stateText, value);
    }

    public void UpdateConnection(bool connected)
    {
        IsConnected = connected;
        OnPropertyChanged(nameof(IsConnected));
        if (StateText is "已连接" or "未连接" or "可自动连接")
        {
            StateText = connected ? "已连接" : "可自动连接";
        }
    }

    public void SetState(string value) => StateText = value;
}
