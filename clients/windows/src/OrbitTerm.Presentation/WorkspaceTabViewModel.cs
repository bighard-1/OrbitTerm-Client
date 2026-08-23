using System.Collections.ObjectModel;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed class WorkspaceTabViewModel : ObservableObject
{
    private string title;
    private string endpoint;
    private string? remoteHostName;
    private bool isConnected;
    private bool hasHostKeyChallenge;
    private bool isBatchTargetSelected;

    public WorkspaceTabViewModel(
        Guid id,
        Guid assetId,
        Guid credentialId,
        string title,
        string host,
        string portText,
        string username,
        ServerTransport transport = ServerTransport.Ssh)
    {
        Id = id == Guid.Empty ? Guid.NewGuid() : id;
        AssetId = assetId == Guid.Empty ? Guid.NewGuid() : assetId;
        CredentialId = credentialId == Guid.Empty ? Guid.NewGuid() : credentialId;
        this.title = string.IsNullOrWhiteSpace(title) ? "新服务器" : title.Trim();
        Host = host;
        PortText = portText;
        Username = username;
        Transport = transport;
        endpoint = BuildEndpoint(username, host, portText);
    }

    public Guid Id { get; }

    public Guid WorkspaceId { get; } = Guid.NewGuid();

    public Guid AssetId { get; private set; }

    public Guid CredentialId { get; private set; }

    public string Host { get; private set; }

    public string PortText { get; private set; }

    public string Username { get; private set; }

    public ServerTransport Transport { get; private set; }

    public List<TerminalLineViewModel> TerminalLines { get; } = [];

    public ObservableCollection<TerminalSplitPaneViewModel> TerminalSplitPanes { get; } = [];

    public List<SftpDirectoryEntryViewModel> SftpEntries { get; } = [];

    public List<DockerContainerViewModel> DockerContainers { get; } = [];

    public List<DockerStatsViewModel> DockerStats { get; } = [];

    public List<RemoteProcessViewModel> RemoteProcesses { get; } = [];

    public DockerContainerViewModel? SelectedDockerContainer { get; set; }

    public List<string> CommandHistory { get; } = [];

    public string CommandText { get; set; } = string.Empty;

    public string Status { get; set; } = "待命";

    public string SecurityStatus { get; set; } = "尚未建立已验证会话";

    public string PasteSafetyStatus { get; set; } = "粘贴安全检查已就绪";

    public string SessionActionSummary { get; set; } = "会话待命";

    public string MonitorStatus { get; set; } = "监控待命";

    public string MonitorSummary { get; set; } = "尚无监控快照";

    public string SystemOverviewSummary { get; set; } = "尚无硬件概览";

    public List<MonitorSnapshot> MonitorHistory { get; } = [];

    public DateTimeOffset? LastSuccessfulMonitorRefreshAt { get; set; }

    public string DockerStatus { get; set; } = "Docker 待命";

    public string DockerSummary { get; set; } = "尚无 Docker 容器数据";

    public string DockerStatsSummary { get; set; } = "尚无 Docker 资源数据";

    public string RemoteProcessStatus { get; set; } = "等待进程采样";

    public string DockerLogStatus { get; set; } = "尚无 Docker 日志预览";

    public string DockerLogText { get; set; } = string.Empty;

    public string SftpStatus { get; set; } = "SFTP 未打开";

    public string SftpPathText { get; set; } = "/";

    public string SftpBrowserStatus { get; set; } = "打开 SFTP 后即可浏览远程目录";

    public string SftpOperationStatus { get; set; } = "需先打开经验证的 SFTP 通道才能传输文件";

    public string SftpPreviewStatus { get; set; } = "尚无 SFTP 文本预览";

    public string SftpPreviewText { get; set; } = string.Empty;

    public int CommandHistoryCursor { get; set; } = -1;

    public int HiddenTerminalLineCount { get; set; }

    public double TerminalScrollOffset { get; set; }

    public bool IsAutoScrollEnabled { get; set; } = true;

    public HostKeyChallengeViewModel? PendingChallenge { get; set; }

    public TerminalSessionLease? TerminalLease { get; set; }

    public SftpSessionLease? SftpLease { get; set; }

    public bool IsConnected
    {
        get => isConnected;
        set
        {
            if (SetProperty(ref isConnected, value))
            {
                NotifyConnectionStateChanged();
            }
        }
    }

    public bool HasHostKeyChallenge
    {
        get => hasHostKeyChallenge;
        set
        {
            if (SetProperty(ref hasHostKeyChallenge, value))
            {
                NotifyConnectionStateChanged();
            }
        }
    }

    /// <summary>
    /// A batch target is always an already verified workspace session. The UI only
    /// exposes this switch for connected tabs and clears it when the session ends.
    /// </summary>
    public bool IsBatchTargetSelected
    {
        get => isBatchTargetSelected;
        set => SetProperty(ref isBatchTargetSelected, value);
    }

    public string ConnectionStateLabel => IsConnected
        ? "已连接"
        : HasHostKeyChallenge ? "待确认" : "未连接";

    public string ConnectionStateGlyph => IsConnected
        ? "●"
        : HasHostKeyChallenge ? "◐" : "○";

    public string Title
    {
        get => title;
        private set => SetProperty(ref title, value);
    }

    /// <summary>
    /// Session chrome uses the actual remote host identity, never the
    /// user-authored asset label. The asset label remains available through
    /// <see cref="Title"/> for asset management and editing.
    /// </summary>
    public string DisplayTitle => remoteHostName ?? DisplayHost(Host);

    public string Endpoint
    {
        get => endpoint;
        private set => SetProperty(ref endpoint, value);
    }

    public void ApplyDraft(
        Guid assetId,
        Guid credentialId,
        string title,
        string host,
        string portText,
        string username,
        ServerTransport transport = ServerTransport.Ssh)
    {
        var nextAssetId = assetId == Guid.Empty ? AssetId : assetId;
        var identityChanged = nextAssetId != AssetId ||
            !string.Equals(Host, host, StringComparison.OrdinalIgnoreCase);
        AssetId = nextAssetId;
        CredentialId = credentialId == Guid.Empty ? CredentialId : credentialId;
        Host = host;
        PortText = portText;
        Username = username;
        Transport = transport;
        Title = string.IsNullOrWhiteSpace(title) ? "新服务器" : title.Trim();
        Endpoint = BuildEndpoint(username, host, portText);
        if (identityChanged)
        {
            remoteHostName = null;
        }
        OnPropertyChanged(nameof(DisplayTitle));
    }

    public void ApplyRemoteTerminalTitle(string? terminalTitle)
    {
        var candidate = ExtractRemoteHostName(terminalTitle);
        if (candidate is null || string.Equals(remoteHostName, candidate, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        remoteHostName = candidate;
        OnPropertyChanged(nameof(DisplayTitle));
    }

    private void NotifyConnectionStateChanged()
    {
        OnPropertyChanged(nameof(ConnectionStateLabel));
        OnPropertyChanged(nameof(ConnectionStateGlyph));
    }

    private static string BuildEndpoint(string username, string host, string portText)
    {
        var trimmedHost = host.Trim();
        if (trimmedHost.Length == 0)
        {
            return "尚未配置";
        }

        var trimmedUser = username.Trim();
        var endpoint = string.Concat(trimmedHost, ":", portText.Trim());
        return trimmedUser.Length == 0 ? endpoint : string.Concat(trimmedUser, "@", endpoint);
    }

    private static string DisplayHost(string host)
    {
        var value = host.Trim();
        return value.Length == 0 ? "新服务器" : value;
    }

    private static string? ExtractRemoteHostName(string? terminalTitle)
    {
        var title = terminalTitle?.Trim();
        if (string.IsNullOrEmpty(title))
        {
            return null;
        }

        var at = title.IndexOf('@');
        if (at < 0 || at == title.Length - 1)
        {
            return null;
        }

        var start = at + 1;
        string host;
        if (title[start] == '[')
        {
            var closingBracket = title.IndexOf(']', start + 1);
            if (closingBracket <= start + 1)
            {
                return null;
            }
            host = title[start..(closingBracket + 1)];
        }
        else
        {
            var end = title.IndexOf(':', start);
            if (end < 0)
            {
                end = title.IndexOf(' ', start);
            }
            if (end < 0)
            {
                end = title.Length;
            }
            host = title[start..end];
        }

        host = new string(host.Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (host.Length == 0 || host.Any(char.IsWhiteSpace))
        {
            return null;
        }
        return host.Length <= 128 ? host : host[..128];
    }
}
