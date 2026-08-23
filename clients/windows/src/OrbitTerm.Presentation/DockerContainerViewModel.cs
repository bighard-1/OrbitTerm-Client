namespace OrbitTerm.Presentation;

public sealed class DockerContainerViewModel : ObservableObject
{
    private string name;
    private string image;
    private string state;
    private string status;
    private string runningFor;
    private string cpuPercent;
    private string memoryPercent;
    private string memoryUsage;
    private string networkIo;
    private string blockIo;
    private string pids;

    public DockerContainerViewModel(
        string shortId,
        string name,
        string image,
        string state,
        string status,
        string runningFor,
        string id,
        string cpuPercent = "—",
        string memoryPercent = "—",
        string memoryUsage = "尚无数据",
        string networkIo = "尚无数据",
        string blockIo = "尚无数据",
        string pids = "—")
    {
        ShortId = shortId;
        this.name = name;
        this.image = image;
        this.state = state;
        this.status = status;
        this.runningFor = runningFor;
        Id = id;
        this.cpuPercent = cpuPercent;
        this.memoryPercent = memoryPercent;
        this.memoryUsage = memoryUsage;
        this.networkIo = networkIo;
        this.blockIo = blockIo;
        this.pids = pids;
    }

    public string ShortId { get; }

    public string Id { get; }

    public string Name => name;

    public string Image => image;

    public string State => state;

    public string Status => status;

    public string RunningFor => runningFor;

    public string CpuPercent => cpuPercent;

    public string MemoryPercent => memoryPercent;

    public string MemoryUsage => memoryUsage;

    public string NetworkIo => networkIo;

    public string BlockIo => blockIo;

    public string Pids => pids;

    public bool IsRunning =>
        string.Equals(State, "running", System.StringComparison.OrdinalIgnoreCase) ||
        Status.Contains("up", System.StringComparison.OrdinalIgnoreCase);

    public bool IsPaused =>
        string.Equals(State, "paused", System.StringComparison.OrdinalIgnoreCase);

    public bool CanStart => !IsRunning && !IsPaused;

    public bool CanStop => IsRunning || IsPaused;

    public bool CanRestart => IsRunning && !IsPaused;

    public bool CanPause => IsRunning && !IsPaused;

    public bool CanUnpause => IsPaused;

    public bool CanKill => IsRunning || IsPaused;

    public bool CanRemove => true;

    public bool HasResourceStats => CpuPercent != "—";

    public string ResourceUsageSummary => HasResourceStats
        ? string.Concat("CPU ", CpuPercent, "  ·  内存 ", MemoryPercent, "（", MemoryUsage, "）")
        : "资源数据待刷新";

    public string ResourceIoSummary => HasResourceStats
        ? string.Concat("网络 ", NetworkIo, "  ·  块 I/O ", BlockIo, "  ·  ", Pids, " 个进程")
        : string.Empty;

    public string AccessibilityDescription => string.Concat(
        "容器 ", Name, "，状态 ", State, "，镜像 ", Image, "，", Status);

    public void UpdateContainer(DockerContainerViewModel source)
    {
        var wasRunning = IsRunning;
        var wasPaused = IsPaused;
        var accessibilityChanged = false;
        if (!string.Equals(name, source.Name, System.StringComparison.Ordinal))
        {
            name = source.Name;
            OnPropertyChanged(nameof(Name));
            accessibilityChanged = true;
        }
        if (!string.Equals(image, source.Image, System.StringComparison.Ordinal))
        {
            image = source.Image;
            OnPropertyChanged(nameof(Image));
            accessibilityChanged = true;
        }
        if (!string.Equals(state, source.State, System.StringComparison.Ordinal))
        {
            state = source.State;
            OnPropertyChanged(nameof(State));
            accessibilityChanged = true;
        }
        if (!string.Equals(status, source.Status, System.StringComparison.Ordinal))
        {
            status = source.Status;
            OnPropertyChanged(nameof(Status));
            accessibilityChanged = true;
        }
        if (!string.Equals(runningFor, source.RunningFor, System.StringComparison.Ordinal))
        {
            runningFor = source.RunningFor;
            OnPropertyChanged(nameof(RunningFor));
        }
        if (wasRunning != IsRunning || wasPaused != IsPaused)
        {
            NotifyDerivedContainerState();
        }
        else if (accessibilityChanged)
        {
            OnPropertyChanged(nameof(AccessibilityDescription));
        }
    }

    public DockerContainerViewModel WithStats(DockerStatsViewModel stats)
    {
        var changed = false;
        changed |= UpdateField(ref cpuPercent, stats.CpuPercent, nameof(CpuPercent));
        changed |= UpdateField(ref memoryPercent, stats.MemoryPercent, nameof(MemoryPercent));
        changed |= UpdateField(ref memoryUsage, stats.MemoryUsage, nameof(MemoryUsage));
        changed |= UpdateField(ref networkIo, stats.NetworkIo, nameof(NetworkIo));
        changed |= UpdateField(ref blockIo, stats.BlockIo, nameof(BlockIo));
        changed |= UpdateField(ref pids, stats.Pids, nameof(Pids));
        if (changed)
        {
            OnPropertyChanged(nameof(HasResourceStats));
            OnPropertyChanged(nameof(ResourceUsageSummary));
            OnPropertyChanged(nameof(ResourceIoSummary));
        }
        return this;
    }

    private bool UpdateField(ref string field, string value, string propertyName)
    {
        if (string.Equals(field, value, System.StringComparison.Ordinal))
        {
            return false;
        }
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void NotifyDerivedContainerState()
    {
        OnPropertyChanged(nameof(IsRunning));
        OnPropertyChanged(nameof(IsPaused));
        OnPropertyChanged(nameof(CanStart));
        OnPropertyChanged(nameof(CanStop));
        OnPropertyChanged(nameof(CanRestart));
        OnPropertyChanged(nameof(CanPause));
        OnPropertyChanged(nameof(CanUnpause));
        OnPropertyChanged(nameof(CanKill));
        OnPropertyChanged(nameof(CanRemove));
        OnPropertyChanged(nameof(AccessibilityDescription));
    }
}
