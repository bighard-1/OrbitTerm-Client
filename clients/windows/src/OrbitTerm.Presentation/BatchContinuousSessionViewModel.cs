using OrbitTerm.Terminal;

namespace OrbitTerm.Presentation;

/// <summary>
/// Presentation state for one isolated PTY used by a continuous batch command.
/// The terminal lease remains private to MainWindowViewModel so UI code cannot
/// accidentally write to or close another asset's channel.
/// </summary>
public sealed class BatchContinuousSessionViewModel : ObservableObject
{
    private const int MaximumVisibleRows = 1_000;
    private const int MaximumOutputCharacters = 256 * 1024;
    private string status;
    private string outputText = string.Empty;
    private bool isRunning;
    private DateTimeOffset? stoppedAt;
    private readonly bool renderCurrentViewportOnly;

    public BatchContinuousSessionViewModel(
        Guid id,
        Guid assetId,
        string name,
        string endpoint,
        DateTimeOffset startedAt,
        DateTimeOffset deadline,
        bool renderCurrentViewportOnly = false)
    {
        Id = id == Guid.Empty ? Guid.NewGuid() : id;
        AssetId = assetId;
        Name = name;
        Endpoint = endpoint;
        StartedAt = startedAt;
        Deadline = deadline;
        this.renderCurrentViewportOnly = renderCurrentViewportOnly;
        status = "正在准备会话";
    }

    public Guid Id { get; }

    public Guid AssetId { get; }

    public string Name { get; }

    public string Endpoint { get; }

    public DateTimeOffset StartedAt { get; }

    public DateTimeOffset Deadline { get; }

    public string DeadlineText => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"最迟 {Deadline:HH:mm:ss} 自动停止");

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public string OutputText
    {
        get => outputText;
        private set
        {
            if (SetProperty(ref outputText, value))
            {
                OnPropertyChanged(nameof(OutputSummary));
                OnPropertyChanged(nameof(HasOutput));
            }
        }
    }

    public bool IsRunning
    {
        get => isRunning;
        private set
        {
            if (SetProperty(ref isRunning, value))
            {
                OnPropertyChanged(nameof(CanStop));
                OnPropertyChanged(nameof(StateSummary));
            }
        }
    }

    public bool CanStop => IsRunning;

    public bool HasOutput => OutputText.Length > 0;

    public string OutputSummary => HasOutput
        ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已接收 {OutputText.Length:N0} 个字符")
        : "等待首批输出";

    public string StateSummary => IsRunning
        ? string.Concat(Status, " · ", DeadlineText)
        : stoppedAt is { } ended
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Status} · {ended:HH:mm:ss}")
            : Status;

    public void MarkConnecting()
    {
        Status = "正在安全连接";
        IsRunning = false;
        OnPropertyChanged(nameof(StateSummary));
    }

    public void MarkRunning()
    {
        Status = "持续输出中";
        IsRunning = true;
        OnPropertyChanged(nameof(StateSummary));
    }

    public void MarkStopping(string reason)
    {
        Status = reason;
        IsRunning = false;
        OnPropertyChanged(nameof(StateSummary));
    }

    public void MarkStopped(string reason, DateTimeOffset endedAt)
    {
        stoppedAt = endedAt;
        Status = reason;
        IsRunning = false;
        OnPropertyChanged(nameof(StateSummary));
    }

    public void MarkFailed(string reason, DateTimeOffset endedAt)
    {
        stoppedAt = endedAt;
        Status = reason;
        IsRunning = false;
        OnPropertyChanged(nameof(StateSummary));
    }

    public void ApplyScreen(TerminalScreenSnapshot screen)
    {
        var firstRow = renderCurrentViewportOnly
            ? Math.Clamp(screen.HistoryRowCount, 0, screen.Rows.Count)
            : Math.Max(0, screen.Rows.Count - MaximumVisibleRows);
        var output = string.Join(
            Environment.NewLine,
            screen.Rows.Skip(firstRow).Select(static row => row.Text.TrimEnd()))
            .TrimEnd('\r', '\n');
        if (output.Length > MaximumOutputCharacters)
        {
            output = string.Concat(
                "[较早输出已截断]\n",
                output.AsSpan(output.Length - MaximumOutputCharacters));
        }
        OutputText = output;
    }
}
