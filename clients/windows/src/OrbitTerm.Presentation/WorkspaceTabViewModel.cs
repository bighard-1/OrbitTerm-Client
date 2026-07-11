using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed class WorkspaceTabViewModel : ObservableObject
{
    private string title;
    private string endpoint;

    public WorkspaceTabViewModel(
        Guid id,
        Guid assetId,
        Guid credentialId,
        string title,
        string host,
        string portText,
        string username)
    {
        Id = id == Guid.Empty ? Guid.NewGuid() : id;
        AssetId = assetId == Guid.Empty ? Guid.NewGuid() : assetId;
        CredentialId = credentialId == Guid.Empty ? Guid.NewGuid() : credentialId;
        this.title = string.IsNullOrWhiteSpace(title) ? "New Server" : title.Trim();
        Host = host;
        PortText = portText;
        Username = username;
        endpoint = BuildEndpoint(username, host, portText);
    }

    public Guid Id { get; }

    public Guid WorkspaceId { get; } = Guid.NewGuid();

    public Guid AssetId { get; private set; }

    public Guid CredentialId { get; private set; }

    public string Host { get; private set; }

    public string PortText { get; private set; }

    public string Username { get; private set; }

    public List<TerminalLineViewModel> TerminalLines { get; } = [];

    public List<SftpDirectoryEntryViewModel> SftpEntries { get; } = [];

    public List<DockerContainerViewModel> DockerContainers { get; } = [];

    public List<DockerStatsViewModel> DockerStats { get; } = [];

    public DockerContainerViewModel? SelectedDockerContainer { get; set; }

    public List<string> CommandHistory { get; } = [];

    public string CommandText { get; set; } = string.Empty;

    public string Status { get; set; } = "Idle";

    public string SecurityStatus { get; set; } = "No verified session";

    public string PasteSafetyStatus { get; set; } = "Paste safety ready";

    public string SessionActionSummary { get; set; } = "Session idle";

    public string MonitorStatus { get; set; } = "Monitor idle";

    public string MonitorSummary { get; set; } = "No monitor snapshot";

    public string DockerStatus { get; set; } = "Docker idle";

    public string DockerSummary { get; set; } = "No Docker containers";

    public string DockerStatsSummary { get; set; } = "No Docker stats";

    public string DockerLogStatus { get; set; } = "No Docker log preview";

    public string DockerLogText { get; set; } = string.Empty;

    public string BatchCommandText { get; set; } = string.Empty;

    public string BatchStatus { get; set; } = "Batch ready";

    public string BatchOutputText { get; set; } = string.Empty;

    public string SftpStatus { get; set; } = "SFTP not open";

    public string SftpPathText { get; set; } = "/";

    public string SftpBrowserStatus { get; set; } = "Open SFTP to prepare browsing";

    public string SftpOperationStatus { get; set; } = "Open a checked SFTP channel to transfer files";

    public string SftpPreviewStatus { get; set; } = "No SFTP text preview";

    public string SftpPreviewText { get; set; } = string.Empty;

    public int CommandHistoryCursor { get; set; } = -1;

    public int HiddenTerminalLineCount { get; set; }

    public bool IsAutoScrollEnabled { get; set; } = true;

    public HostKeyChallengeViewModel? PendingChallenge { get; set; }

    public TerminalSessionLease? TerminalLease { get; set; }

    public SftpSessionLease? SftpLease { get; set; }

    public bool IsConnected { get; set; }

    public bool HasHostKeyChallenge { get; set; }

    public string Title
    {
        get => title;
        private set => SetProperty(ref title, value);
    }

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
        string username)
    {
        AssetId = assetId == Guid.Empty ? AssetId : assetId;
        CredentialId = credentialId == Guid.Empty ? CredentialId : credentialId;
        Host = host;
        PortText = portText;
        Username = username;
        Title = string.IsNullOrWhiteSpace(title) ? "New Server" : title.Trim();
        Endpoint = BuildEndpoint(username, host, portText);
    }

    private static string BuildEndpoint(string username, string host, string portText)
    {
        var trimmedHost = host.Trim();
        if (trimmedHost.Length == 0)
        {
            return "Not configured";
        }

        var trimmedUser = username.Trim();
        var endpoint = string.Concat(trimmedHost, ":", portText.Trim());
        return trimmedUser.Length == 0 ? endpoint : string.Concat(trimmedUser, "@", endpoint);
    }
}
