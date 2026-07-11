using System.Collections.ObjectModel;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using OrbitTerm.Application.Diagnostics;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Terminal;

namespace OrbitTerm.Presentation;

public sealed class MainWindowViewModel : ObservableObject
{
    private const int MaximumTerminalLines = 500;
    private const int MaximumSftpPathLength = 512;

    private readonly SessionOrchestrator orchestrator;
    private readonly ICredentialVault credentialVault;
    private readonly IServerAssetStore assetStore;
    private readonly ISnippetStore snippetStore;
    private readonly Action<Action> dispatch;
    private readonly List<string> commandHistory = [];
    private Guid draftAssetId = Guid.NewGuid();
    private Guid draftCredentialId = Guid.NewGuid();
    private AssetViewModel? selectedAsset;
    private WorkspaceTabViewModel? selectedWorkspaceTab;
    private HostKeyChallengeViewModel? pendingChallenge;
    private TerminalSessionLease? terminalLease;
    private SftpSessionLease? sftpLease;
    private string assetName = "New Server";
    private string assetEditorStatus = "Local assets ready";
    private string host = string.Empty;
    private string portText = "22";
    private string username = string.Empty;
    private string password = string.Empty;
    private string status = "Idle";
    private string securityStatus = "No verified session";
    private string commandText = string.Empty;
    private string pasteSafetyStatus = "Paste safety ready";
    private string sessionActionSummary = "Session idle";
    private string monitorStatus = "Monitor idle";
    private string monitorSummary = "No monitor snapshot";
    private string dockerStatus = "Docker idle";
    private string dockerSummary = "No Docker containers";
    private string dockerStatsSummary = "No Docker stats";
    private string dockerLogStatus = "No Docker log preview";
    private string dockerLogText = string.Empty;
    private string batchCommandText = string.Empty;
    private string batchStatus = "Batch ready";
    private string batchOutputText = string.Empty;
    private string sftpStatus = "SFTP not open";
    private string sftpPathText = "/";
    private string sftpBrowserStatus = "Open SFTP to prepare browsing";
    private string sftpOperationStatus = "Open a checked SFTP channel to transfer files";
    private string sftpPreviewStatus = "No SFTP text preview";
    private string sftpPreviewText = string.Empty;
    private string sftpPreviewOriginalText = string.Empty;
    private string? sftpPreviewPath;
    private SftpMutationSnapshot? sftpPreviewSnapshot;
    private string diagnosticsStatus = "Diagnostics ready";
    private SftpDirectoryEntryViewModel? selectedSftpEntry;
    private DockerContainerViewModel? selectedDockerContainer;
    private SnippetViewModel? selectedSnippet;
    private string snippetStatus = "Snippets ready";
    private string snippetQuery = string.Empty;
    private int commandHistoryCursor = -1;
    private int hiddenTerminalLineCount;
    private bool isConnected;
    private bool hasHostKeyChallenge;
    private bool isAutoScrollEnabled = true;
    private bool isRestoringWorkspaceTab;

    public MainWindowViewModel(
        SessionOrchestrator orchestrator,
        ICredentialVault credentialVault,
        IServerAssetStore? assetStore = null,
        ISnippetStore? snippetStore = null,
        Action<Action>? dispatch = null)
    {
        this.orchestrator = orchestrator;
        this.credentialVault = credentialVault;
        this.assetStore = assetStore ?? new InMemoryServerAssetStore();
        this.snippetStore = snippetStore ?? new InMemorySnippetStore();
        this.dispatch = dispatch ?? (action => action());
        this.orchestrator.TerminalOutputReceived += OnTerminalOutputReceived;

        LoadAssetsCommand = new AsyncRelayCommand(LoadAssetsAsync);
        LoadSnippetsCommand = new AsyncRelayCommand(LoadSnippetsAsync);
        NewAssetCommand = new AsyncRelayCommand(NewAssetAsync);
        SaveAssetCommand = new AsyncRelayCommand(SaveAssetAsync, CanSaveAsset);
        DeleteAssetCommand = new AsyncRelayCommand(DeleteAssetAsync, () => SelectedAsset is not null);
        OpenWorkspaceTabCommand = new AsyncRelayCommand(OpenWorkspaceTabAsync);
        CloseWorkspaceTabCommand = new AsyncRelayCommand(CloseWorkspaceTabAsync, CanCloseSelectedWorkspaceTab);
        DisconnectAndCloseWorkspaceTabCommand = new AsyncRelayCommand(
            DisconnectAndCloseWorkspaceTabAsync,
            CanDisconnectAndCloseSelectedWorkspaceTab);
        ConnectCommand = new AsyncRelayCommand(ConnectAsync, CanConnect);
        TrustHostKeyCommand = new AsyncRelayCommand(TrustHostKeyAsync, () => pendingChallenge is not null);
        EndSessionCommand = new AsyncRelayCommand(EndSessionAsync, () => isConnected || terminalLease is not null || sftpLease is not null || pendingChallenge is not null);
        OpenTerminalCommand = new AsyncRelayCommand(OpenTerminalAsync, () => isConnected && terminalLease is null);
        OpenSftpCommand = new AsyncRelayCommand(OpenSftpAsync, () => isConnected && sftpLease is null);
        RefreshMonitorSnapshotCommand = new AsyncRelayCommand(RefreshMonitorSnapshotAsync, () => isConnected);
        RefreshDockerContainersCommand = new AsyncRelayCommand(RefreshDockerContainersAsync, () => isConnected);
        RefreshDockerStatsCommand = new AsyncRelayCommand(RefreshDockerStatsAsync, () => isConnected);
        PreviewDockerLogsCommand = new AsyncRelayCommand(PreviewDockerLogsAsync, () => isConnected && SelectedDockerContainer is not null);
        StartDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("start", cancellationToken), () => isConnected && SelectedDockerContainer is not null);
        StopDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("stop", cancellationToken), () => isConnected && SelectedDockerContainer is not null);
        RestartDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("restart", cancellationToken), () => isConnected && SelectedDockerContainer is not null);
        RunBatchCommand = new AsyncRelayCommand(RunBatchCommandAsync, CanRunBatchCommand);
        DeleteSnippetCommand = new AsyncRelayCommand(DeleteSelectedSnippetAsync, () => SelectedSnippet is not null);
        InsertSnippetCommand = new AsyncRelayCommand(InsertSelectedSnippetAsync, () => SelectedSnippet is not null && IsTerminalOpen);
        ExecuteSnippetCommand = new AsyncRelayCommand(ExecuteSelectedSnippetAsync, () => SelectedSnippet is not null && IsTerminalOpen);
        FillBatchFromSnippetCommand = new AsyncRelayCommand(FillBatchFromSelectedSnippetAsync, () => SelectedSnippet is not null);
        PrepareSftpBrowseCommand = new AsyncRelayCommand(PrepareSftpBrowseAsync, CanNavigateSftp);
        RefreshSftpBrowseCommand = new AsyncRelayCommand(RefreshSftpBrowseAsync, CanNavigateSftp);
        GoParentSftpCommand = new AsyncRelayCommand(GoParentSftpAsync, CanNavigateSftp);
        OpenSelectedSftpEntryCommand = new AsyncRelayCommand(OpenSelectedSftpEntryAsync, () => CanNavigateSftp() && SelectedSftpEntry is not null);
        PreviewSftpTextCommand = new AsyncRelayCommand(PreviewSftpTextAsync, CanNavigateSftp);
        SendCommand = new AsyncRelayCommand(SendAsync, () => terminalLease is not null && !string.IsNullOrWhiteSpace(CommandText));
        CloseTerminalCommand = new AsyncRelayCommand(CloseTerminalAsync, () => terminalLease is not null);
        ClearTerminalCommand = new AsyncRelayCommand(ClearTerminalAsync, () => TerminalLines.Count > 0);
        PreviousCommandHistoryCommand = new AsyncRelayCommand(PreviousCommandHistoryAsync, () => commandHistory.Count > 0);
        NextCommandHistoryCommand = new AsyncRelayCommand(NextCommandHistoryAsync, () => commandHistory.Count > 0);

        var initialTab = CreateWorkspaceTabFromDraft();
        WorkspaceTabs.Add(initialTab);
        selectedWorkspaceTab = initialTab;
    }

    public ObservableCollection<AssetViewModel> Assets { get; } = [];

    public ObservableCollection<WorkspaceTabViewModel> WorkspaceTabs { get; } = [];

    public ObservableCollection<TerminalLineViewModel> TerminalLines { get; } = [];

    public ObservableCollection<SftpDirectoryEntryViewModel> SftpEntries { get; } = [];

    public ObservableCollection<DockerContainerViewModel> DockerContainers { get; } = [];

    public ObservableCollection<DockerStatsViewModel> DockerStats { get; } = [];

    public ObservableCollection<SnippetViewModel> Snippets { get; } = [];

    public ObservableCollection<SnippetGroupViewModel> SnippetGroups { get; } = [];

    public string SnippetQuery
    {
        get => snippetQuery;
        set
        {
            if (SetProperty(ref snippetQuery, value))
            {
                RefreshSnippetGroups();
            }
        }
    }

    public SnippetViewModel? SelectedSnippet
    {
        get => selectedSnippet;
        set
        {
            if (SetProperty(ref selectedSnippet, value))
            {
                OnPropertyChanged(nameof(HasSelectedSnippet));
                OnPropertyChanged(nameof(CanUseSelectedSnippetInTerminal));
                DeleteSnippetCommand.RaiseCanExecuteChanged();
                InsertSnippetCommand.RaiseCanExecuteChanged();
                ExecuteSnippetCommand.RaiseCanExecuteChanged();
                FillBatchFromSnippetCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool HasSelectedSnippet => SelectedSnippet is not null;

    public bool CanUseSelectedSnippetInTerminal => HasSelectedSnippet && IsTerminalOpen;

    public DockerContainerViewModel? SelectedDockerContainer
    {
        get => selectedDockerContainer;
        set
        {
            if (SetProperty(ref selectedDockerContainer, value))
            {
                PreviewDockerLogsCommand.RaiseCanExecuteChanged();
                StartDockerContainerCommand.RaiseCanExecuteChanged();
                StopDockerContainerCommand.RaiseCanExecuteChanged();
                RestartDockerContainerCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public SftpDirectoryEntryViewModel? SelectedSftpEntry
    {
        get => selectedSftpEntry;
        set
        {
            if (SetProperty(ref selectedSftpEntry, value))
            {
                OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(CanDownloadSelectedSftpEntry));
                OnPropertyChanged(nameof(CanMutateSelectedSftpEntry));
                OnPropertyChanged(nameof(CanChangeSelectedSftpPermissions));
            }
        }
    }

    public bool CanDownloadSelectedSftpEntry => sftpLease is not null && SelectedSftpEntry is { IsDirectory: false };

    public bool CanMutateSelectedSftpEntry =>
        sftpLease is not null && SelectedSftpEntry is not null && !IsSftpPreviewDirty;

    public bool CanChangeSelectedSftpPermissions =>
        sftpLease is not null &&
        !IsSftpPreviewDirty &&
        SelectedSftpEntry is { PermissionsOctal: var permissions } &&
        (permissions & 0xF000U) is 0x4000U or 0x8000U;

    public AssetViewModel? SelectedAsset
    {
        get => selectedAsset;
        set
        {
            var previousAssetId = selectedAsset?.Id;
            if (SetProperty(ref selectedAsset, value))
            {
                if (value is not null)
                {
                    draftAssetId = value.Id;
                    draftCredentialId = value.CredentialId;
                    AssetName = value.Name;
                    Host = value.Host;
                    PortText = value.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    Username = value.Username;
                    if (previousAssetId != value.Id)
                    {
                        Password = string.Empty;
                    }

                    AssetEditorStatus = "Asset selected";
                }

                DeleteAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public WorkspaceTabViewModel? SelectedWorkspaceTab
    {
        get => selectedWorkspaceTab;
        set
        {
            if (ReferenceEquals(selectedWorkspaceTab, value))
            {
                return;
            }

            SyncSelectedWorkspaceTabFromDraft();
            SaveRuntimeStateToSelectedWorkspaceTab();
            if (SetProperty(ref selectedWorkspaceTab, value) && value is not null)
            {
                RestoreWorkspaceTab(value);
                RestoreRuntimeStateFromWorkspaceTab(value);
                RefreshCommands();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string WorkspaceTabSummary => WorkspaceTabs.Count == 1
        ? "1 workspace tab"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{WorkspaceTabs.Count} workspace tabs");

    public bool SelectWorkspaceTabAt(int zeroBasedIndex)
    {
        if (zeroBasedIndex < 0 || zeroBasedIndex >= WorkspaceTabs.Count)
        {
            return false;
        }

        SelectedWorkspaceTab = WorkspaceTabs[zeroBasedIndex];
        return ReferenceEquals(SelectedWorkspaceTab, WorkspaceTabs[zeroBasedIndex]);
    }

    public string AssetName
    {
        get => assetName;
        set
        {
            if (SetProperty(ref assetName, value))
            {
                SaveAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string AssetEditorStatus
    {
        get => assetEditorStatus;
        private set => SetProperty(ref assetEditorStatus, value);
    }

    public string Host
    {
        get => host;
        set
        {
            if (SetProperty(ref host, value))
            {
                RefreshCommands();
                SaveAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string PortText
    {
        get => portText;
        set
        {
            if (SetProperty(ref portText, value))
            {
                RefreshCommands();
                SaveAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string Username
    {
        get => username;
        set
        {
            if (SetProperty(ref username, value))
            {
                RefreshCommands();
                SaveAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string Password
    {
        get => password;
        set
        {
            if (SetProperty(ref password, value))
            {
                RefreshCommands();
            }
        }
    }

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public string SecurityStatus
    {
        get => securityStatus;
        private set => SetProperty(ref securityStatus, value);
    }

    public string CommandText
    {
        get => commandText;
        set
        {
            if (SetProperty(ref commandText, value))
            {
                SendCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string PasteSafetyStatus
    {
        get => pasteSafetyStatus;
        private set
        {
            if (SetProperty(ref pasteSafetyStatus, value))
            {
                OnPropertyChanged(nameof(TerminalInputHint));
            }
        }
    }

    public string SessionActionSummary
    {
        get => sessionActionSummary;
        private set => SetProperty(ref sessionActionSummary, value);
    }

    public bool IsConnected
    {
        get => isConnected;
        private set
        {
            if (SetProperty(ref isConnected, value))
            {
                RefreshCommands();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public bool HasHostKeyChallenge
    {
        get => hasHostKeyChallenge;
        private set
        {
            if (SetProperty(ref hasHostKeyChallenge, value))
            {
                TrustHostKeyCommand.RaiseCanExecuteChanged();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public string HostKeySummary => pendingChallenge is null
        ? "No pending challenge"
        : string.Concat(pendingChallenge.KeyAlgorithm, "  ", pendingChallenge.FingerprintSha256);

    public string WorkspaceTitle => SelectedAsset?.Name ?? AssetName;

    public string WorkspaceSubtitle => string.Concat(Username.Trim(), "@", Host.Trim(), ":", PortText.Trim());

    public string ConnectionStateLabel
    {
        get
        {
            if (IsConnected)
            {
                return "Verified SSH";
            }

            return HasHostKeyChallenge ? "Host review" : "Disconnected";
        }
    }

    public string SecurityBadgeText
    {
        get
        {
            if (HasHostKeyChallenge)
            {
                return "Review required";
            }

            return IsConnected ? "Host key verified" : "Waiting";
        }
    }

    public bool IsTerminalOpen => terminalLease is not null;

    public string TerminalStateLabel => terminalLease is null
        ? "No terminal channel"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"PTY {terminalLease.Size.Columns}x{terminalLease.Size.Rows}");

    public string TerminalTitle => terminalLease is null
        ? "Terminal"
        : string.Concat(terminalLease.Host, ":", terminalLease.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));

    public string TerminalSubtitle => terminalLease is null
        ? "Open a verified session terminal to begin."
        : string.Concat(
            "Channel ",
            terminalLease.TerminalChannelId.ToString(System.Globalization.CultureInfo.InvariantCulture));

    public string ActivitySummary => TerminalLines.Count == 0
        ? "No terminal activity"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{TerminalLines.Count} terminal events");

    public bool HasTerminalOutput => TerminalLines.Count > 0;

    public string TerminalOutputSummary
    {
        get
        {
            if (TerminalLines.Count == 0)
            {
                return "No visible output";
            }

            if (hiddenTerminalLineCount == 0)
            {
                return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{TerminalLines.Count} visible lines");
            }

            return string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{TerminalLines.Count} visible, {hiddenTerminalLineCount} hidden");
        }
    }

    public bool IsAutoScrollEnabled
    {
        get => isAutoScrollEnabled;
        set => SetProperty(ref isAutoScrollEnabled, value);
    }

    public string CommandHistorySummary => commandHistory.Count == 0
        ? "No command history"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{commandHistory.Count} commands in history");

    public string TerminalInputHint
    {
        get
        {
            if (!IsTerminalOpen)
            {
                return "Open a terminal to enable input";
            }

            return "Ready for input";
        }
    }

    public bool IsSftpOpen => sftpLease is not null;

    public string SftpStateLabel => sftpLease is null
        ? "No SFTP channel"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"SFTP {sftpLease.SftpSessionId}");

    public string SftpStatus
    {
        get => sftpStatus;
        private set => SetProperty(ref sftpStatus, value);
    }

    public string SftpPathText
    {
        get => sftpPathText;
        set => SetProperty(ref sftpPathText, value);
    }

    public string SftpBrowserStatus
    {
        get => sftpBrowserStatus;
        private set => SetProperty(ref sftpBrowserStatus, value);
    }

    public string SftpOperationStatus
    {
        get => sftpOperationStatus;
        private set => SetProperty(ref sftpOperationStatus, value);
    }

    public string SftpPreviewStatus
    {
        get => sftpPreviewStatus;
        private set => SetProperty(ref sftpPreviewStatus, value);
    }

    public string SftpPreviewText
    {
        get => sftpPreviewText;
        set
        {
            if (SetProperty(ref sftpPreviewText, value))
            {
                OnPropertyChanged(nameof(HasSftpPreview));
                OnPropertyChanged(nameof(IsSftpPreviewDirty));
                OnPropertyChanged(nameof(CanSaveSftpPreview));
                OnPropertyChanged(nameof(CanMutateSelectedSftpEntry));
                OnPropertyChanged(nameof(CanChangeSelectedSftpPermissions));
                RefreshCommands();
            }
        }
    }

    public bool HasSftpPreview => sftpPreviewPath is not null;

    public bool CanEditSftpPreview => sftpPreviewSnapshot is not null;

    public bool IsSftpPreviewReadOnly => !CanEditSftpPreview;

    public bool IsSftpPreviewDirty =>
        CanEditSftpPreview && !string.Equals(SftpPreviewText, sftpPreviewOriginalText, StringComparison.Ordinal);

    public bool CanSaveSftpPreview => IsSftpPreviewDirty &&
        System.Text.Encoding.UTF8.GetByteCount(SftpPreviewText) <= 2 * 1024 * 1024 &&
        !SftpPreviewText.Contains('\0');

    public void RevertSftpPreviewChanges()
    {
        if (CanEditSftpPreview)
        {
            SftpPreviewText = sftpPreviewOriginalText;
            SftpOperationStatus = "Unsaved text changes reverted";
        }
    }

    public string SftpListingSummary
    {
        get
        {
            if (sftpLease is null)
            {
                return "No SFTP listing";
            }

            return SftpEntries.Count == 0
                ? "Directory listing empty"
                : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{SftpEntries.Count} SFTP entries");
        }
    }

    public string DiagnosticsStatus
    {
        get => diagnosticsStatus;
        private set => SetProperty(ref diagnosticsStatus, value);
    }

    public string MonitorStatus
    {
        get => monitorStatus;
        private set => SetProperty(ref monitorStatus, value);
    }

    public string MonitorSummary
    {
        get => monitorSummary;
        private set => SetProperty(ref monitorSummary, value);
    }

    public string DockerStatus
    {
        get => dockerStatus;
        private set => SetProperty(ref dockerStatus, value);
    }

    public string DockerSummary
    {
        get => dockerSummary;
        private set => SetProperty(ref dockerSummary, value);
    }

    public string DockerStatsSummary
    {
        get => dockerStatsSummary;
        private set => SetProperty(ref dockerStatsSummary, value);
    }

    public string DockerLogStatus
    {
        get => dockerLogStatus;
        private set => SetProperty(ref dockerLogStatus, value);
    }

    public string DockerLogText
    {
        get => dockerLogText;
        private set => SetProperty(ref dockerLogText, value);
    }

    public string BatchCommandText
    {
        get => batchCommandText;
        set
        {
            if (SetProperty(ref batchCommandText, value))
            {
                RunBatchCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BatchStatus
    {
        get => batchStatus;
        private set => SetProperty(ref batchStatus, value);
    }

    public string BatchOutputText
    {
        get => batchOutputText;
        private set => SetProperty(ref batchOutputText, value);
    }

    public string SnippetStatus
    {
        get => snippetStatus;
        private set => SetProperty(ref snippetStatus, value);
    }

    public AsyncRelayCommand LoadAssetsCommand { get; }

    public AsyncRelayCommand LoadSnippetsCommand { get; }

    public AsyncRelayCommand NewAssetCommand { get; }

    public AsyncRelayCommand SaveAssetCommand { get; }

    public AsyncRelayCommand DeleteAssetCommand { get; }

    public AsyncRelayCommand OpenWorkspaceTabCommand { get; }

    public AsyncRelayCommand CloseWorkspaceTabCommand { get; }

    public AsyncRelayCommand DisconnectAndCloseWorkspaceTabCommand { get; }

    public AsyncRelayCommand ConnectCommand { get; }

    public AsyncRelayCommand TrustHostKeyCommand { get; }

    public AsyncRelayCommand EndSessionCommand { get; }

    public AsyncRelayCommand OpenTerminalCommand { get; }

    public AsyncRelayCommand OpenSftpCommand { get; }

    public AsyncRelayCommand RefreshMonitorSnapshotCommand { get; }

    public AsyncRelayCommand RefreshDockerContainersCommand { get; }

    public AsyncRelayCommand RefreshDockerStatsCommand { get; }

    public AsyncRelayCommand PreviewDockerLogsCommand { get; }

    public AsyncRelayCommand StartDockerContainerCommand { get; }

    public AsyncRelayCommand StopDockerContainerCommand { get; }

    public AsyncRelayCommand RestartDockerContainerCommand { get; }

    public AsyncRelayCommand RunBatchCommand { get; }

    public AsyncRelayCommand DeleteSnippetCommand { get; }

    public AsyncRelayCommand InsertSnippetCommand { get; }

    public AsyncRelayCommand ExecuteSnippetCommand { get; }

    public AsyncRelayCommand FillBatchFromSnippetCommand { get; }

    public AsyncRelayCommand PrepareSftpBrowseCommand { get; }

    public AsyncRelayCommand RefreshSftpBrowseCommand { get; }

    public AsyncRelayCommand GoParentSftpCommand { get; }

    public AsyncRelayCommand OpenSelectedSftpEntryCommand { get; }

    public AsyncRelayCommand PreviewSftpTextCommand { get; }

    public AsyncRelayCommand SendCommand { get; }

    public AsyncRelayCommand CloseTerminalCommand { get; }

    public AsyncRelayCommand ClearTerminalCommand { get; }

    public AsyncRelayCommand PreviousCommandHistoryCommand { get; }

    public AsyncRelayCommand NextCommandHistoryCommand { get; }

    private async Task LoadSnippetsAsync(CancellationToken cancellationToken)
    {
        SnippetStatus = "Loading snippets";
        IReadOnlyList<SnippetRecord> records;
        try
        {
            records = await snippetStore.LoadAsync(cancellationToken).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            Snippets.Clear();
            SnippetGroups.Clear();
            SelectedSnippet = null;
            SnippetStatus = "Snippets could not be loaded";
            return;
        }
        Snippets.Clear();
        foreach (var record in records)
        {
            Snippets.Add(SnippetViewModel.FromRecord(record));
        }

        RefreshSnippetGroups();
        SelectedSnippet = Snippets.FirstOrDefault();
        SnippetStatus = Snippets.Count == 0
            ? "No saved snippets"
            : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"Loaded {Snippets.Count} snippets");
    }

    public async Task SaveSnippetAsync(
        Guid? id,
        string title,
        string command,
        string category,
        CancellationToken cancellationToken)
    {
        title = title.Trim();
        command = command.Trim();
        category = category.Trim();
        if (title.Length is < 1 or > 120 || command.Length is < 1 or > 8192 ||
            category.Length > 80 || command.Any(char.IsControl))
        {
            SnippetStatus = "Snippet rejected: check title, command, and category limits";
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var existing = id is { } value ? Snippets.FirstOrDefault(item => item.Id == value) : null;
        var saved = new SnippetViewModel(
            existing?.Id ?? Guid.NewGuid(),
            title,
            command,
            category.Length == 0 ? "Uncategorized" : category,
            existing?.CreatedAt ?? now,
            now);
        var existingIndex = existing is null ? -1 : Snippets.IndexOf(existing);
        if (existing is not null)
        {
            Snippets.Remove(existing);
        }

        Snippets.Insert(0, saved);
        if (!await TryPersistSnippetsAsync(cancellationToken).ConfigureAwait(true))
        {
            Snippets.Remove(saved);
            if (existing is not null)
            {
                Snippets.Insert(Math.Max(0, existingIndex), existing);
            }
            RefreshSnippetGroups();
            return;
        }
        RefreshSnippetGroups();
        SelectedSnippet = saved;
        SnippetStatus = existing is null ? "Snippet created" : "Snippet updated";
    }

    private async Task DeleteSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        if (SelectedSnippet is not { } selected)
        {
            return;
        }

        var selectedIndex = Snippets.IndexOf(selected);
        Snippets.Remove(selected);
        if (!await TryPersistSnippetsAsync(cancellationToken).ConfigureAwait(true))
        {
            Snippets.Insert(Math.Max(0, selectedIndex), selected);
            SelectedSnippet = selected;
            RefreshSnippetGroups();
            return;
        }
        RefreshSnippetGroups();
        SelectedSnippet = Snippets.FirstOrDefault();
        SnippetStatus = "Snippet deleted";
    }

    private Task InsertSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (SelectedSnippet is { } selected)
        {
            if (SnippetVariableResolver.Extract(selected.Command).Count > 0)
            {
                SnippetStatus = "Resolve Snippet variables before terminal insertion";
                return Task.CompletedTask;
            }
            CommandText = selected.Command;
            SnippetStatus = "Snippet inserted into terminal input";
        }

        return Task.CompletedTask;
    }

    private async Task ExecuteSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        if (SelectedSnippet is not { } selected || terminalLease is null)
        {
            return;
        }

        if (SnippetVariableResolver.Extract(selected.Command).Count > 0)
        {
            SnippetStatus = "Resolve Snippet variables before terminal sending";
            return;
        }

        CommandText = selected.Command;
        await SendAsync(cancellationToken).ConfigureAwait(true);
        SnippetStatus = "Snippet sent to terminal";
    }

    private Task FillBatchFromSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (SelectedSnippet is { } selected)
        {
            if (SnippetVariableResolver.Extract(selected.Command).Count > 0)
            {
                SnippetStatus = "Resolve Snippet variables before Batch reuse";
                return Task.CompletedTask;
            }
            BatchCommandText = selected.Command;
            SnippetStatus = "Snippet copied to Batch command";
        }

        return Task.CompletedTask;
    }

    public void InsertResolvedSnippet(string command)
    {
        ValidateResolvedSnippet(command);
        CommandText = command;
        SnippetStatus = "Resolved Snippet inserted into terminal input";
    }

    public async Task ExecuteResolvedSnippetAsync(string command, CancellationToken cancellationToken)
    {
        ValidateResolvedSnippet(command);
        if (terminalLease is null)
        {
            SnippetStatus = "Open a terminal before sending a Snippet";
            return;
        }

        CommandText = command;
        await SendAsync(cancellationToken).ConfigureAwait(true);
        SnippetStatus = "Resolved Snippet sent to terminal";
    }

    public void FillBatchFromResolvedSnippet(string command)
    {
        ValidateResolvedSnippet(command);
        BatchCommandText = command;
        SnippetStatus = "Resolved Snippet copied to Batch command";
    }

    private static void ValidateResolvedSnippet(string command)
    {
        if (string.IsNullOrWhiteSpace(command) || command.Length > 8192 ||
            command.Any(char.IsControl) || SnippetVariableResolver.Extract(command).Count > 0)
        {
            throw new ArgumentException("Resolved Snippet command is invalid.", nameof(command));
        }
    }

    private void RefreshSnippetGroups()
    {
        var query = SnippetQuery.Trim();
        var filtered = Snippets.Where(item =>
            query.Length == 0 ||
            item.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
            item.Command.Contains(query, StringComparison.OrdinalIgnoreCase) ||
            item.Category.Contains(query, StringComparison.OrdinalIgnoreCase));

        SnippetGroups.Clear();
        foreach (var group in filtered
                     .OrderBy(item => item.Category, StringComparer.OrdinalIgnoreCase)
                     .ThenBy(item => item.Title, StringComparer.OrdinalIgnoreCase)
                     .GroupBy(item => item.Category, StringComparer.OrdinalIgnoreCase))
        {
            SnippetGroups.Add(new SnippetGroupViewModel(group.Key, group));
        }

        if (SelectedSnippet is not null && !filtered.Contains(SelectedSnippet))
        {
            SelectedSnippet = null;
        }
    }

    private async Task<bool> TryPersistSnippetsAsync(CancellationToken cancellationToken)
    {
        try
        {
            await snippetStore.SaveAsync(
                Snippets.Select(item => item.ToRecord()).ToArray(),
                cancellationToken).ConfigureAwait(true);
            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            SnippetStatus = "Snippets could not be saved";
            return false;
        }
    }

    private async Task LoadAssetsAsync(CancellationToken cancellationToken)
    {
        AssetEditorStatus = "Loading local assets";
        var records = await assetStore.LoadAsync(cancellationToken).ConfigureAwait(true);
        Assets.Clear();
        foreach (var record in records)
        {
            Assets.Add(AssetViewModel.FromRecord(record));
        }

        SelectedAsset = Assets.FirstOrDefault();
        if (SelectedAsset is null)
        {
            ResetDraftAsset();
            AssetEditorStatus = "No local assets";
        }
        else
        {
            AssetEditorStatus = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"Loaded {Assets.Count} local assets");
        }

        NotifyWorkbenchStateChanged();
        RefreshCommands();
    }

    private Task OpenWorkspaceTabAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SyncSelectedWorkspaceTabFromDraft();

        var tab = CreateWorkspaceTabFromDraft();
        WorkspaceTabs.Add(tab);
        SelectedWorkspaceTab = tab;
        Status = "Workspace tab opened";
        SaveRuntimeStateToSelectedWorkspaceTab();
        OnPropertyChanged(nameof(WorkspaceTabSummary));
        RefreshCommands();
        return Task.CompletedTask;
    }

    private Task CloseWorkspaceTabAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        CloseSelectedWorkspaceTabCore();
        return Task.CompletedTask;
    }

    private async Task DisconnectAndCloseWorkspaceTabAsync(CancellationToken cancellationToken)
    {
        if (SelectedWorkspaceTab is null)
        {
            return;
        }

        if (HasActiveRuntime)
        {
            await EndSessionCoreAsync(cancellationToken, "Session ended before closing tab").ConfigureAwait(true);
        }

        CloseSelectedWorkspaceTabCore();
    }

    private void CloseSelectedWorkspaceTabCore()
    {
        if (SelectedWorkspaceTab is null)
        {
            return;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        var index = WorkspaceTabs.IndexOf(SelectedWorkspaceTab);
        WorkspaceTabs.Remove(SelectedWorkspaceTab);
        if (WorkspaceTabs.Count == 0)
        {
            ResetDraftAsset();
            var replacement = CreateWorkspaceTabFromDraft();
            WorkspaceTabs.Add(replacement);
            selectedWorkspaceTab = replacement;
            OnPropertyChanged(nameof(SelectedWorkspaceTab));
            RestoreRuntimeStateFromWorkspaceTab(replacement);
            Status = "Workspace tab reset";
        }
        else
        {
            SelectedWorkspaceTab = WorkspaceTabs[Math.Clamp(index, 0, WorkspaceTabs.Count - 1)];
            Status = "Workspace tab closed";
        }

        OnPropertyChanged(nameof(WorkspaceTabSummary));
        RefreshCommands();
    }

    private Task NewAssetAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SelectedAsset = null;
        ResetDraftAsset();
        AssetEditorStatus = "New asset draft";
        SyncSelectedWorkspaceTabFromDraft();
        NotifyWorkbenchStateChanged();
        RefreshCommands();
        return Task.CompletedTask;
    }

    private async Task SaveAssetAsync(CancellationToken cancellationToken)
    {
        var record = CreateCurrentAssetRecord();
        if (record is null)
        {
            AssetEditorStatus = "Asset details incomplete";
            RefreshCommands();
            return;
        }

        var existing = Assets.FirstOrDefault(asset => asset.Id == record.Id);
        var viewModel = AssetViewModel.FromRecord(record);
        if (existing is null)
        {
            Assets.Add(viewModel);
        }
        else
        {
            var index = Assets.IndexOf(existing);
            Assets[index] = viewModel;
        }

        await assetStore.SaveAsync(Assets.Select(asset => asset.ToRecord()).ToArray(), cancellationToken).ConfigureAwait(true);
        SelectedAsset = viewModel;
        AssetEditorStatus = "Asset saved";
        RefreshCommands();
    }

    private async Task DeleteAssetAsync(CancellationToken cancellationToken)
    {
        if (SelectedAsset is null)
        {
            return;
        }

        var asset = SelectedAsset;
        Assets.Remove(asset);
        await assetStore.SaveAsync(Assets.Select(item => item.ToRecord()).ToArray(), cancellationToken).ConfigureAwait(true);
        await credentialVault.DeleteAsync(asset.CredentialId, cancellationToken).ConfigureAwait(true);

        SelectedAsset = Assets.FirstOrDefault();
        if (SelectedAsset is null)
        {
            ResetDraftAsset();
        }

        AssetEditorStatus = "Asset deleted";
        RefreshCommands();
    }

    private async Task ConnectAsync(CancellationToken cancellationToken)
    {
        if (IsConnected || terminalLease is not null || sftpLease is not null)
        {
            await EndSessionCoreAsync(cancellationToken, "Previous session ended before reconnect").ConfigureAwait(true);
        }

        Status = "Connecting";
        SessionActionSummary = "Connecting";
        SecurityStatus = "Checking host identity";
        pendingChallenge = null;
        HasHostKeyChallenge = false;
        OnPropertyChanged(nameof(HostKeySummary));

        var asset = new ServerAsset(
            draftAssetId,
            draftCredentialId,
            string.IsNullOrWhiteSpace(AssetName) ? Host.Trim() : AssetName.Trim(),
            "Default",
            Host.Trim(),
            ParsedPort,
            Username.Trim(),
            ServerAuthMethod.Password,
            ServerTransport.Ssh,
            false);

        await credentialVault.SaveAsync(
            draftCredentialId,
            new CredentialMaterial(Password, string.Empty, string.Empty),
            cancellationToken).ConfigureAwait(true);

        var result = await orchestrator.ConnectAsync(CurrentWorkspaceId, asset, cancellationToken).ConfigureAwait(true);
        ApplyConnectResult(result);
        SaveRuntimeStateToSelectedWorkspaceTab();
    }

    private async Task TrustHostKeyAsync(CancellationToken cancellationToken)
    {
        if (pendingChallenge is null)
        {
            return;
        }

        Status = "Saving host trust";
        var result = await orchestrator.TrustHostKeyAsync(
            pendingChallenge,
            "OrbitTerm Windows",
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case HostKeyTrustResult.Persisted persisted:
                Status = string.Concat("Trusted ", persisted.NormalizedHost);
                SecurityStatus = "Host key saved";
                SessionActionSummary = "Host trust saved";
                pendingChallenge = null;
                HasHostKeyChallenge = false;
                OnPropertyChanged(nameof(HostKeySummary));
                NotifyWorkbenchStateChanged();
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case HostKeyTrustResult.Failed failed:
                Status = failed.MessageKey;
                SecurityStatus = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }
    }

    private async Task OpenTerminalAsync(CancellationToken cancellationToken)
    {
        var result = await orchestrator.OpenTerminalAsync(
            CurrentWorkspaceId,
            draftAssetId,
            TerminalSize.Default,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case TerminalOpenResult.Opened opened:
                terminalLease = opened.Lease;
                AppendTerminalLine(new TerminalLineViewModel(string.Concat("Connected to ", opened.Lease.Host), false));
                Status = "Terminal open";
                NotifyTerminalStateChanged();
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case TerminalOpenResult.Failed failed:
                Status = failed.MessageKey;
                SecurityStatus = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task PreviewSftpTextAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (sftpLease is null)
        {
            SftpPreviewStatus = "Open SFTP before preview";
            RefreshCommands();
            return;
        }

        var normalized = NormalizeSftpPath(SftpPathText);
        if (normalized is null)
        {
            SftpPreviewStatus = "SFTP path rejected";
            SftpOperationStatus = "Use an absolute file path without control characters, backslashes, or parent traversal";
            RefreshCommands();
            return;
        }

        var editCandidate = SelectedSftpEntry is { IsDirectory: false } selected &&
            string.Equals(selected.Path, normalized, StringComparison.Ordinal) &&
            (selected.PermissionsOctal & 0xF000U) == 0x8000U
                ? selected
                : null;
        ResetSftpEditor();
        SftpPathText = normalized;
        SftpPreviewStatus = string.Concat("Previewing ", normalized);
        var result = await orchestrator.ReadSftpTextFileAsync(
            sftpLease,
            normalized,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case SftpTextPreviewResult.Previewed previewed:
                sftpPreviewPath = previewed.Path;
                sftpPreviewSnapshot = editCandidate is null ? null : ToSftpMutationSnapshot(editCandidate);
                sftpPreviewOriginalText = previewed.Content;
                SftpPreviewText = previewed.Content;
                SftpPreviewStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Previewed {previewed.ByteLength} B from {previewed.Path}");
                SftpOperationStatus = editCandidate is null
                    ? "Text preview is read-only"
                    : "Text editor ready";
                NotifySftpEditorStateChanged();
                break;
            case SftpTextPreviewResult.Failed failed:
                SftpPreviewText = string.Empty;
                SftpPreviewStatus = failed.MessageKey;
                SftpOperationStatus = failed.Code;
                break;
        }

        RefreshCommands();
    }

    public async Task SaveSftpPreviewAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null || sftpPreviewPath is null || sftpPreviewSnapshot is null || !CanSaveSftpPreview)
        {
            SftpOperationStatus = "No valid changed SFTP text editor is ready to save";
            return;
        }

        var savedPath = sftpPreviewPath;
        var result = await orchestrator.WriteSftpTextFileAsync(
            sftpLease,
            savedPath,
            SftpPreviewText,
            sftpPreviewSnapshot,
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed:
                sftpPreviewOriginalText = SftpPreviewText;
                sftpPreviewSnapshot = null;
                SftpOperationStatus = string.Concat("Saved ", savedPath);
                SftpPreviewStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Saved {System.Text.Encoding.UTF8.GetByteCount(SftpPreviewText)} B to {savedPath}");
                NotifySftpEditorStateChanged();
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public string PrepareSftpPreviewCopy()
    {
        return SftpPreviewText;
    }

    private async Task OpenSftpAsync(CancellationToken cancellationToken)
    {
        SftpStatus = "Opening SFTP";
        var result = await orchestrator.OpenSftpAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case SftpOpenResult.Opened opened:
                sftpLease = opened.Lease;
                SftpStatus = "SFTP channel open";
                SftpBrowserStatus = "SFTP browser ready";
                SftpOperationStatus = "Validate a remote path before directory operations";
                SessionActionSummary = "SFTP ready";
                NotifySftpStateChanged();
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case SftpOpenResult.Failed failed:
                SftpStatus = failed.MessageKey;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task RefreshMonitorSnapshotAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected)
        {
            MonitorStatus = "Connect before monitor refresh";
            MonitorSummary = "No verified session";
            RefreshCommands();
            return;
        }

        MonitorStatus = "Refreshing monitor snapshot";
        var result = await orchestrator.CaptureMonitorSnapshotAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case MonitorSnapshotResult.Captured captured:
                MonitorStatus = FormatMonitorStatus(captured.Snapshot);
                MonitorSummary = FormatMonitorSummary(captured.Snapshot);
                SessionActionSummary = "Monitor snapshot ready";
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case MonitorSnapshotResult.Failed failed:
                MonitorStatus = failed.MessageKey;
                MonitorSummary = failed.Code;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task RefreshDockerContainersAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected)
        {
            DockerStatus = "Connect before Docker refresh";
            DockerSummary = "No verified session";
            RefreshCommands();
            return;
        }

        DockerStatus = "Refreshing Docker containers";
        var result = await orchestrator.ListDockerContainersAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case DockerContainersResult.Listed listed:
                DockerContainers.Clear();
                foreach (var container in listed.Containers)
                {
                    DockerContainers.Add(ToDockerContainerViewModel(container));
                }

                DockerStatus = "Docker containers refreshed";
                DockerSummary = DockerContainers.Count == 0
                    ? "No Docker containers"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{DockerContainers.Count} Docker containers");
                SessionActionSummary = "Docker list ready";
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerContainersResult.Failed failed:
                DockerContainers.Clear();
                DockerStatus = failed.MessageKey;
                DockerSummary = failed.Code;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task RefreshDockerStatsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected)
        {
            DockerStatus = "Connect before Docker stats refresh";
            DockerStatsSummary = "No verified session";
            RefreshCommands();
            return;
        }

        DockerStatus = "Refreshing Docker stats";
        var result = await orchestrator.CaptureDockerStatsAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case DockerStatsResult.Captured captured:
                DockerStats.Clear();
                foreach (var item in captured.Stats)
                {
                    DockerStats.Add(ToDockerStatsViewModel(item));
                }

                DockerStatus = "Docker stats refreshed";
                DockerStatsSummary = DockerStats.Count == 0
                    ? "No Docker stats"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{DockerStats.Count} Docker stats");
                SessionActionSummary = "Docker stats ready";
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerStatsResult.Failed failed:
                DockerStats.Clear();
                DockerStatus = failed.MessageKey;
                DockerStatsSummary = failed.Code;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task PreviewDockerLogsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected || SelectedDockerContainer is null)
        {
            DockerLogStatus = "Select a Docker container after connecting";
            RefreshCommands();
            return;
        }

        DockerLogStatus = "Refreshing Docker log preview";
        var result = await orchestrator.CaptureDockerLogsAsync(
            CurrentWorkspaceId,
            draftAssetId,
            SelectedDockerContainer.Id,
            100,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case DockerLogsResult.Captured captured:
                DockerLogText = captured.Logs;
                DockerLogStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Docker log preview {captured.ContainerId[..Math.Min(12, captured.ContainerId.Length)]}");
                SessionActionSummary = "Docker logs ready";
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerLogsResult.Failed failed:
                DockerLogText = string.Empty;
                DockerLogStatus = failed.Code;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task RunDockerActionAsync(string action, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected || SelectedDockerContainer is null)
        {
            DockerStatus = "Select a Docker container after connecting";
            RefreshCommands();
            return;
        }

        DockerStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"Running Docker {action}");
        var result = await orchestrator.RunDockerActionAsync(
            CurrentWorkspaceId,
            draftAssetId,
            SelectedDockerContainer.Id,
            action,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case DockerActionResult.Completed completed:
                var refreshed = await RefreshDockerContainersAfterActionAsync(
                    completed.ContainerId,
                    completed.Action,
                    cancellationToken)
                    .ConfigureAwait(true);
                if (refreshed)
                {
                    DockerStatus = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"Docker {completed.Action} completed; containers refreshed");
                }

                SessionActionSummary = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Docker {completed.Action} ready");
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerActionResult.Failed failed:
                DockerStatus = failed.Code;
                SessionActionSummary = failed.Code;
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
    }

    private async Task<bool> RefreshDockerContainersAfterActionAsync(
        string containerId,
        string action,
        CancellationToken cancellationToken)
    {
        var result = await orchestrator.ListDockerContainersAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case DockerContainersResult.Listed listed:
                DockerContainers.Clear();
                DockerContainerViewModel? selected = null;
                foreach (var container in listed.Containers)
                {
                    var viewModel = ToDockerContainerViewModel(container);
                    DockerContainers.Add(viewModel);
                    if (string.Equals(viewModel.Id, containerId, StringComparison.OrdinalIgnoreCase))
                    {
                        selected = viewModel;
                    }
                }

                SelectedDockerContainer = selected;
                DockerSummary = DockerContainers.Count == 0
                    ? "No Docker containers"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{DockerContainers.Count} Docker containers");
                return true;
            case DockerContainersResult.Failed failed:
                DockerStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Docker {action} completed; refresh failed");
                DockerSummary = failed.Code;
                return false;
        }

        return false;
    }

    private bool CanRunBatchCommand()
    {
        return IsConnected &&
            !string.IsNullOrWhiteSpace(BatchCommandText) &&
            System.Text.Encoding.UTF8.GetByteCount(BatchCommandText) <= 8 * 1024 &&
            !BatchCommandText.Any(char.IsControl);
    }

    private async Task RunBatchCommandAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CanRunBatchCommand())
        {
            BatchStatus = "Connect and enter one bounded command";
            RefreshCommands();
            return;
        }

        BatchStatus = "Running checked batch command";
        BatchOutputText = string.Empty;
        var result = await orchestrator.RunBatchCommandAsync(
            CurrentWorkspaceId,
            draftAssetId,
            BatchCommandText,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case BatchExecResult.Completed completed:
                BatchStatus = "Batch command completed";
                BatchOutputText = FormatBatchOutput(completed.Stdout, completed.Stderr);
                SessionActionSummary = "Batch result ready";
                break;
            case BatchExecResult.Failed failed:
                BatchStatus = failed.MessageKey;
                BatchOutputText = failed.Code;
                SessionActionSummary = failed.Code;
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    private static string FormatBatchOutput(string stdout, string stderr)
    {
        if (string.IsNullOrEmpty(stderr))
        {
            return stdout;
        }

        return string.IsNullOrEmpty(stdout)
            ? string.Concat("Standard error\n", stderr)
            : string.Concat("Standard output\n", stdout, "\n\nStandard error\n", stderr);
    }

    private async Task PrepareSftpBrowseAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (sftpLease is null)
        {
            SftpBrowserStatus = "Open SFTP before browsing";
            SftpOperationStatus = "No active SFTP channel";
            RefreshCommands();
            return;
        }

        var normalized = NormalizeSftpPath(SftpPathText);
        if (normalized is null)
        {
            SftpBrowserStatus = "SFTP path rejected";
            SftpOperationStatus = "Use an absolute path without control characters, backslashes, or parent traversal";
            RefreshCommands();
            return;
        }

        SftpPathText = normalized;
        ResetSftpEditor();
        SftpBrowserStatus = string.Concat("Listing ", normalized);
        SftpOperationStatus = "Reading directory through checked SFTP";
        var result = await orchestrator.ListSftpDirectoryAsync(
            sftpLease,
            normalized,
            cancellationToken).ConfigureAwait(true);

        SelectedSftpEntry = null;
        switch (result)
        {
            case SftpDirectoryListResult.Listed listed:
                SftpEntries.Clear();
                foreach (var entry in listed.Entries)
                {
                    var entryViewModel = ToSftpEntryViewModel(listed.Path, entry);
                    if (entryViewModel is not null)
                    {
                        SftpEntries.Add(entryViewModel);
                    }
                }

                SftpBrowserStatus = string.Concat("Listed ", listed.Path);
                SftpOperationStatus = "Directory listing complete; upload and download are available";
                break;
            case SftpDirectoryListResult.Failed failed:
                SftpEntries.Clear();
                SftpBrowserStatus = failed.MessageKey;
                SftpOperationStatus = failed.Code;
                break;
        }

        NotifySftpListingChanged();
        RefreshCommands();
    }

    private Task RefreshSftpBrowseAsync(CancellationToken cancellationToken)
    {
        return PrepareSftpBrowseAsync(cancellationToken);
    }

    private async Task GoParentSftpAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var normalized = NormalizeSftpPath(SftpPathText);
        if (normalized is null)
        {
            SftpBrowserStatus = "SFTP path rejected";
            SftpOperationStatus = "Use an absolute path without control characters, backslashes, or parent traversal";
            RefreshCommands();
            return;
        }

        SftpPathText = GetSftpParentPath(normalized);
        await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
    }

    private async Task OpenSelectedSftpEntryAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (SelectedSftpEntry is null)
        {
            SftpOperationStatus = "Select an SFTP entry first";
            RefreshCommands();
            return;
        }

        var selected = SelectedSftpEntry;
        SftpPathText = selected.Path;
        if (selected.IsDirectory)
        {
            await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
            return;
        }

        await PreviewSftpTextAsync(cancellationToken).ConfigureAwait(true);
    }

    public async Task DownloadSelectedSftpEntryAsync(string localPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null || SelectedSftpEntry is not { IsDirectory: false } selected)
        {
            SftpOperationStatus = "Select a file to download";
            OnPropertyChanged(nameof(CanDownloadSelectedSftpEntry));
            return;
        }

        var normalized = NormalizeSftpPath(selected.Path);
        if (normalized is null || !Path.IsPathFullyQualified(localPath) || File.Exists(localPath))
        {
            SftpOperationStatus = "Download destination rejected";
            return;
        }

        SftpOperationStatus = string.Concat("Downloading ", normalized);
        var result = await orchestrator.DownloadSftpFileAsync(
            sftpLease,
            normalized,
            localPath,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case SftpDownloadResult.Downloaded downloaded:
                SftpOperationStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Downloaded {downloaded.ByteLength} B from {downloaded.Path}");
                break;
            case SftpDownloadResult.Failed failed:
                SftpOperationStatus = failed.Code;
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task UploadSftpFileAsync(string localPath, string localFileName, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null)
        {
            SftpOperationStatus = "Open SFTP before uploading";
            return;
        }

        var remotePath = TryCombineSftpChildPath(SftpPathText, localFileName);
        if (remotePath is null || !Path.IsPathFullyQualified(localPath) || !File.Exists(localPath))
        {
            SftpOperationStatus = "Upload source or remote path rejected";
            return;
        }

        SftpOperationStatus = string.Concat("Uploading ", remotePath);
        var result = await orchestrator.UploadSftpFileAsync(
            sftpLease,
            localPath,
            remotePath,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case SftpUploadResult.Uploaded uploaded:
                var uploadSummary = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Uploaded {uploaded.ByteLength} B to {uploaded.Path}");
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = uploadSummary;
                break;
            case SftpUploadResult.Failed failed:
                SftpOperationStatus = failed.Code;
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task CreateSftpDirectoryAsync(string directoryName, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null)
        {
            SftpOperationStatus = "Open SFTP before creating a directory";
            return;
        }

        var remotePath = TryCombineSftpChildPath(SftpPathText, directoryName);
        if (remotePath is null)
        {
            SftpOperationStatus = "Directory name rejected";
            return;
        }

        SftpOperationStatus = string.Concat("Creating ", remotePath);
        var result = await orchestrator.CreateSftpDirectoryAsync(
            sftpLease,
            remotePath,
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed completed:
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("Created folder ", completed.Path);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task CreateSftpFileAsync(string fileName, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null)
        {
            SftpOperationStatus = "Open SFTP before creating a file";
            return;
        }

        var remotePath = TryCombineSftpChildPath(SftpPathText, fileName);
        if (remotePath is null)
        {
            SftpOperationStatus = "File name rejected";
            return;
        }

        SftpOperationStatus = string.Concat("Creating ", remotePath);
        var result = await orchestrator.CreateSftpFileAsync(
            sftpLease,
            remotePath,
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed completed:
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("Created file ", completed.Path);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task RenameSelectedSftpEntryAsync(string newName, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null || SelectedSftpEntry is not { } selected)
        {
            SftpOperationStatus = "Select an SFTP entry to rename";
            return;
        }

        var parentPath = GetSftpParentPath(selected.Path);
        var newRemotePath = TryCombineSftpChildPath(parentPath, newName);
        if (newRemotePath is null || string.Equals(selected.Path, newRemotePath, StringComparison.Ordinal))
        {
            SftpOperationStatus = "Rename target rejected";
            return;
        }

        SftpOperationStatus = string.Concat("Renaming ", selected.Path);
        var result = await orchestrator.RenameSftpEntryAsync(
            sftpLease,
            selected.Path,
            newRemotePath,
            ToSftpMutationSnapshot(selected),
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed completed:
                SftpPathText = parentPath;
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("Renamed to ", completed.DestinationPath);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task RemoveSelectedSftpEntryConfirmedAsync(
        SftpDirectoryEntryViewModel confirmedEntry,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null ||
            SelectedSftpEntry is not { } selected ||
            !Equals(selected, confirmedEntry) ||
            !SftpEntries.Contains(confirmedEntry))
        {
            SftpOperationStatus = "SFTP selection changed; review the entry again";
            return;
        }

        var parentPath = GetSftpParentPath(selected.Path);
        SftpOperationStatus = string.Concat("Removing ", selected.Path);
        var result = await orchestrator.RemoveSftpEntryAsync(
            sftpLease,
            selected.Path,
            ToSftpMutationSnapshot(selected),
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed completed:
                if (string.Equals(SftpPathText, completed.Path, StringComparison.Ordinal))
                {
                    SftpPreviewText = string.Empty;
                    SftpPreviewStatus = "No SFTP text preview";
                }
                SftpPathText = parentPath;
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("Removed ", completed.Path);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task ChangeSelectedSftpPermissionsConfirmedAsync(
        SftpDirectoryEntryViewModel confirmedEntry,
        string modeText,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null ||
            SelectedSftpEntry is not { } selected ||
            !Equals(selected, confirmedEntry) ||
            !SftpEntries.Contains(confirmedEntry))
        {
            SftpOperationStatus = "SFTP selection changed; review the entry again";
            return;
        }

        var trimmedMode = modeText.Trim();
        if (trimmedMode.Length is < 3 or > 4 ||
            trimmedMode.Any(character => character is < '0' or > '7'))
        {
            SftpOperationStatus = "Permissions require three or four octal digits";
            return;
        }

        var mode = Convert.ToUInt32(trimmedMode, 8);
        SftpOperationStatus = string.Concat("Changing permissions for ", selected.Path);
        var result = await orchestrator.ChangeSftpPermissionsAsync(
            sftpLease,
            selected.Path,
            mode,
            ToSftpMutationSnapshot(selected),
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed:
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("Permissions changed to ", trimmedMode);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    private async Task SendAsync(CancellationToken cancellationToken)
    {
        if (terminalLease is null || string.IsNullOrWhiteSpace(CommandText))
        {
            return;
        }

        var command = string.Concat(CommandText, "\n");
        var result = await orchestrator.WriteTerminalAsync(
            terminalLease,
            System.Text.Encoding.UTF8.GetBytes(command),
            cancellationToken).ConfigureAwait(true);

        if (result is TerminalControlOutcome.Succeeded)
        {
            AddCommandToHistory(CommandText);
            AppendTerminalLine(new TerminalLineViewModel(string.Concat("$ ", CommandText), true));
            CommandText = string.Empty;
            Status = "Command sent";
        }
        else if (result is TerminalControlOutcome.Failed failed)
        {
            Status = failed.MessageKey;
        }
    }

    private async Task CloseTerminalAsync(CancellationToken cancellationToken)
    {
        if (terminalLease is null)
        {
            return;
        }

        var result = await orchestrator.CloseTerminalAsync(terminalLease, cancellationToken).ConfigureAwait(true);
        if (result is TerminalControlOutcome.Succeeded)
        {
            terminalLease = null;
            AppendTerminalLine(new TerminalLineViewModel("Terminal closed", false));
            Status = "Terminal closed";
            NotifyTerminalStateChanged();
            SaveRuntimeStateToSelectedWorkspaceTab();
        }
        else if (result is TerminalControlOutcome.Failed failed)
        {
            Status = failed.MessageKey;
            SaveRuntimeStateToSelectedWorkspaceTab();
        }

        RefreshCommands();
    }

    private Task EndSessionAsync(CancellationToken cancellationToken)
    {
        return EndSessionCoreAsync(cancellationToken, "Session ended");
    }

    private async Task EndSessionCoreAsync(CancellationToken cancellationToken, string completionStatus)
    {
        Status = "Ending session";
        SessionActionSummary = "Ending active session";

        if (terminalLease is not null)
        {
            var closeResult = await orchestrator.CloseTerminalAsync(terminalLease, cancellationToken).ConfigureAwait(true);
            if (closeResult is TerminalControlOutcome.Failed failed)
            {
                Status = failed.MessageKey;
                SessionActionSummary = failed.Code;
                RefreshCommands();
                return;
            }

            terminalLease = null;
            AppendTerminalLine(new TerminalLineViewModel("Terminal closed", false));
        }

        var endResult = await orchestrator.EndVerifiedSessionAsync(
            CurrentWorkspaceId,
            draftAssetId,
            cancellationToken).ConfigureAwait(true);

        pendingChallenge = null;
        sftpLease = null;
        ResetSftpBrowserState();
        ResetMonitorState();
        ResetDockerState();
        ResetBatchState();
        HasHostKeyChallenge = false;
        IsConnected = false;
        CommandText = string.Empty;
        SecurityStatus = "No verified session";
        Status = endResult == SessionEndResult.Ended ? completionStatus : "No active session";
        SessionActionSummary = endResult == SessionEndResult.Ended ? completionStatus : "Nothing to end";
        OnPropertyChanged(nameof(HostKeySummary));
        NotifySftpStateChanged();
        NotifyTerminalStateChanged();
        NotifyWorkbenchStateChanged();
        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public CommandTextEdit ApplyCommandPaste(string pastedText, int selectionStart, int selectionLength)
    {
        var paste = SanitizeCommandPaste(pastedText);
        var current = CommandText;
        var safeSelectionStart = Math.Clamp(selectionStart, 0, current.Length);
        var safeSelectionLength = Math.Clamp(selectionLength, 0, current.Length - safeSelectionStart);
        var beforeSelection = current[..safeSelectionStart];
        var afterSelection = current[(safeSelectionStart + safeSelectionLength)..];

        CommandText = string.Concat(beforeSelection, paste.Text, afterSelection);

        if (paste.Text.Length == 0)
        {
            PasteSafetyStatus = "Paste ignored: no command text";
        }
        else if (paste.RemovedControlCharacters && paste.ConvertedMultiline)
        {
            PasteSafetyStatus = "Paste sanitized: controls removed, lines joined";
        }
        else if (paste.RemovedControlCharacters)
        {
            PasteSafetyStatus = "Paste sanitized: controls removed";
        }
        else if (paste.ConvertedMultiline)
        {
            PasteSafetyStatus = "Paste sanitized: lines joined";
        }
        else
        {
            PasteSafetyStatus = "Paste accepted";
        }

        Status = PasteSafetyStatus;
        return new CommandTextEdit(
            safeSelectionStart + paste.Text.Length,
            paste.RemovedControlCharacters,
            paste.ConvertedMultiline);
    }

    private Task ClearTerminalAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        TerminalLines.Clear();
        hiddenTerminalLineCount = 0;
        Status = "Terminal cleared";
        NotifyTerminalStateChanged();
        return Task.CompletedTask;
    }

    public string PrepareTerminalTranscriptCopy()
    {
        if (TerminalLines.Count == 0)
        {
            Status = "No terminal output to copy";
            return string.Empty;
        }

        var transcript = string.Join(
            Environment.NewLine,
            TerminalLines.Select(line => line.Text));
        Status = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"Copied {TerminalLines.Count} visible lines");
        return transcript;
    }

    public string PrepareDiagnosticsBundleCopy()
    {
        var bundle = DiagnosticsBundleFactory.Create(
            CreateDiagnosticsRuntimeSnapshot(),
            CreateDiagnosticsSessionSnapshot(),
            DateTimeOffset.UtcNow);
        var json = bundle.ToJson();
        DiagnosticsStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"Diagnostics copied: {json.Length} chars");
        Status = "Diagnostics copied";
        return json;
    }

    private Task PreviousCommandHistoryAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (commandHistory.Count == 0)
        {
            return Task.CompletedTask;
        }

        if (commandHistoryCursor < 0)
        {
            commandHistoryCursor = commandHistory.Count - 1;
        }
        else if (commandHistoryCursor > 0)
        {
            commandHistoryCursor--;
        }

        CommandText = commandHistory[commandHistoryCursor];
        Status = "History previous";
        return Task.CompletedTask;
    }

    private Task NextCommandHistoryAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (commandHistory.Count == 0 || commandHistoryCursor < 0)
        {
            return Task.CompletedTask;
        }

        if (commandHistoryCursor < commandHistory.Count - 1)
        {
            commandHistoryCursor++;
            CommandText = commandHistory[commandHistoryCursor];
        }
        else
        {
            commandHistoryCursor = -1;
            CommandText = string.Empty;
        }

        Status = "History next";
        return Task.CompletedTask;
    }

    private void ApplyConnectResult(ConnectResult result)
    {
        switch (result)
        {
            case ConnectResult.Connected connected:
                IsConnected = true;
                Status = string.Concat("Connected to ", connected.Lease.Host);
                SecurityStatus = string.Concat(connected.Lease.HostKeyAlgorithm, "  ", connected.Lease.HostKeyFingerprintSha256);
                SessionActionSummary = "Verified session ready";
                NotifyWorkbenchStateChanged();
                break;
            case ConnectResult.RequiresHostKeyTrust challenge:
                IsConnected = false;
                pendingChallenge = challenge.Challenge;
                HasHostKeyChallenge = true;
                Status = "Host key review";
                SecurityStatus = challenge.Challenge.ReasonCode;
                SessionActionSummary = "Host key review required";
                OnPropertyChanged(nameof(HostKeySummary));
                NotifyWorkbenchStateChanged();
                break;
            case ConnectResult.Blocked blocked:
                IsConnected = false;
                Status = blocked.Block.MessageKey;
                SecurityStatus = blocked.Block.ReasonCode;
                SessionActionSummary = blocked.Block.ReasonCode;
                NotifyWorkbenchStateChanged();
                break;
            case ConnectResult.Failed failed:
                IsConnected = false;
                Status = failed.MessageKey;
                SecurityStatus = failed.Code;
                SessionActionSummary = failed.Code;
                NotifyWorkbenchStateChanged();
                break;
        }
    }

    private void OnTerminalOutputReceived(object? sender, TerminalOutputReceivedEventArgs e)
    {
        dispatch(() =>
        {
            var tab = WorkspaceTabs.FirstOrDefault(candidate =>
                candidate.TerminalLease is not null &&
                candidate.TerminalLease.WorkspaceId == e.Lease.WorkspaceId &&
                candidate.TerminalLease.ServerId == e.Lease.ServerId &&
                candidate.TerminalLease.TerminalChannelId == e.Lease.TerminalChannelId);
            if (tab is null)
            {
                return;
            }

            var line = new TerminalLineViewModel(e.Text, false);
            if (ReferenceEquals(tab, SelectedWorkspaceTab))
            {
                AppendTerminalLine(line);
                Status = "Output received";
                SaveRuntimeStateToSelectedWorkspaceTab();
            }
            else
            {
                AppendTerminalLineToWorkspaceTab(tab, line);
                tab.Status = "Output received";
            }
        });
    }

    private bool CanConnect()
    {
        return !string.IsNullOrWhiteSpace(Host) &&
            ParsedPort is > 0 and <= 65535 &&
            !string.IsNullOrWhiteSpace(Username) &&
            !string.IsNullOrEmpty(Password);
    }

    private bool HasActiveRuntime => IsConnected ||
        HasHostKeyChallenge ||
        terminalLease is not null ||
        sftpLease is not null;

    private bool CanCloseSelectedWorkspaceTab()
    {
        return SelectedWorkspaceTab is not null &&
            !SelectedWorkspaceTab.IsConnected &&
            !SelectedWorkspaceTab.HasHostKeyChallenge &&
            SelectedWorkspaceTab.TerminalLease is null &&
            SelectedWorkspaceTab.SftpLease is null;
    }

    private bool CanDisconnectAndCloseSelectedWorkspaceTab()
    {
        return SelectedWorkspaceTab is not null &&
            (SelectedWorkspaceTab.IsConnected ||
                SelectedWorkspaceTab.HasHostKeyChallenge ||
                SelectedWorkspaceTab.TerminalLease is not null ||
                SelectedWorkspaceTab.SftpLease is not null);
    }

    private Guid CurrentWorkspaceId => SelectedWorkspaceTab?.WorkspaceId ?? Guid.Empty;

    private bool CanSaveAsset()
    {
        return !string.IsNullOrWhiteSpace(AssetName) &&
            !string.IsNullOrWhiteSpace(Host) &&
            ParsedPort is > 0 and <= 65535 &&
            !string.IsNullOrWhiteSpace(Username);
    }

    private ServerAssetRecord? CreateCurrentAssetRecord()
    {
        if (!CanSaveAsset())
        {
            return null;
        }

        return new ServerAssetRecord(
            draftAssetId,
            draftCredentialId,
            AssetName.Trim(),
            Host.Trim(),
            ParsedPort,
            Username.Trim(),
            ServerTransport.Ssh,
            false);
    }

    private void ResetDraftAsset()
    {
        draftAssetId = Guid.NewGuid();
        draftCredentialId = Guid.NewGuid();
        AssetName = "New Server";
        Host = string.Empty;
        PortText = "22";
        Username = string.Empty;
        Password = string.Empty;
    }

    private WorkspaceTabViewModel CreateWorkspaceTabFromDraft()
    {
        return new WorkspaceTabViewModel(
            Guid.NewGuid(),
            draftAssetId,
            draftCredentialId,
            AssetName,
            Host,
            PortText,
            Username);
    }

    private void SyncSelectedWorkspaceTabFromDraft()
    {
        if (isRestoringWorkspaceTab || SelectedWorkspaceTab is null)
        {
            return;
        }

        SelectedWorkspaceTab.ApplyDraft(
            draftAssetId,
            draftCredentialId,
            AssetName,
            Host,
            PortText,
            Username);
    }

    private void RestoreWorkspaceTab(WorkspaceTabViewModel tab)
    {
        isRestoringWorkspaceTab = true;
        try
        {
            draftAssetId = tab.AssetId;
            draftCredentialId = tab.CredentialId;
            selectedAsset = Assets.FirstOrDefault(asset => asset.Id == tab.AssetId);
            OnPropertyChanged(nameof(SelectedAsset));
            AssetName = tab.Title;
            Host = tab.Host;
            PortText = tab.PortText;
            Username = tab.Username;
            Password = string.Empty;
        }
        finally
        {
            isRestoringWorkspaceTab = false;
        }
    }

    private void SaveRuntimeStateToSelectedWorkspaceTab()
    {
        if (SelectedWorkspaceTab is null)
        {
            return;
        }

        SelectedWorkspaceTab.TerminalLines.Clear();
        SelectedWorkspaceTab.TerminalLines.AddRange(TerminalLines);
        SelectedWorkspaceTab.SftpEntries.Clear();
        SelectedWorkspaceTab.SftpEntries.AddRange(SftpEntries);
        SelectedWorkspaceTab.DockerContainers.Clear();
        SelectedWorkspaceTab.DockerContainers.AddRange(DockerContainers);
        SelectedWorkspaceTab.DockerStats.Clear();
        SelectedWorkspaceTab.DockerStats.AddRange(DockerStats);
        SelectedWorkspaceTab.CommandHistory.Clear();
        SelectedWorkspaceTab.CommandHistory.AddRange(commandHistory);
        SelectedWorkspaceTab.CommandText = CommandText;
        SelectedWorkspaceTab.Status = Status;
        SelectedWorkspaceTab.SecurityStatus = SecurityStatus;
        SelectedWorkspaceTab.PasteSafetyStatus = PasteSafetyStatus;
        SelectedWorkspaceTab.SessionActionSummary = SessionActionSummary;
        SelectedWorkspaceTab.MonitorStatus = MonitorStatus;
        SelectedWorkspaceTab.MonitorSummary = MonitorSummary;
        SelectedWorkspaceTab.DockerStatus = DockerStatus;
        SelectedWorkspaceTab.DockerSummary = DockerSummary;
        SelectedWorkspaceTab.DockerStatsSummary = DockerStatsSummary;
        SelectedWorkspaceTab.SelectedDockerContainer = SelectedDockerContainer;
        SelectedWorkspaceTab.DockerLogStatus = DockerLogStatus;
        SelectedWorkspaceTab.DockerLogText = DockerLogText;
        SelectedWorkspaceTab.BatchCommandText = BatchCommandText;
        SelectedWorkspaceTab.BatchStatus = BatchStatus;
        SelectedWorkspaceTab.BatchOutputText = BatchOutputText;
        SelectedWorkspaceTab.SftpStatus = SftpStatus;
        SelectedWorkspaceTab.SftpPathText = SftpPathText;
        SelectedWorkspaceTab.SftpBrowserStatus = SftpBrowserStatus;
        SelectedWorkspaceTab.SftpOperationStatus = SftpOperationStatus;
        SelectedWorkspaceTab.SftpPreviewStatus = SftpPreviewStatus;
        SelectedWorkspaceTab.SftpPreviewText = SftpPreviewText;
        SelectedWorkspaceTab.CommandHistoryCursor = commandHistoryCursor;
        SelectedWorkspaceTab.HiddenTerminalLineCount = hiddenTerminalLineCount;
        SelectedWorkspaceTab.IsAutoScrollEnabled = IsAutoScrollEnabled;
        SelectedWorkspaceTab.PendingChallenge = pendingChallenge;
        SelectedWorkspaceTab.TerminalLease = terminalLease;
        SelectedWorkspaceTab.SftpLease = sftpLease;
        SelectedWorkspaceTab.IsConnected = IsConnected;
        SelectedWorkspaceTab.HasHostKeyChallenge = HasHostKeyChallenge;
    }

    private void RestoreRuntimeStateFromWorkspaceTab(WorkspaceTabViewModel tab)
    {
        TerminalLines.Clear();
        foreach (var line in tab.TerminalLines)
        {
            TerminalLines.Add(line);
        }

        SftpEntries.Clear();
        foreach (var entry in tab.SftpEntries)
        {
            SftpEntries.Add(entry);
        }

        DockerContainers.Clear();
        foreach (var container in tab.DockerContainers)
        {
            DockerContainers.Add(container);
        }

        DockerStats.Clear();
        foreach (var item in tab.DockerStats)
        {
            DockerStats.Add(item);
        }

        SelectedDockerContainer = tab.SelectedDockerContainer;
        SelectedSftpEntry = null;
        commandHistory.Clear();
        commandHistory.AddRange(tab.CommandHistory);
        commandHistoryCursor = tab.CommandHistoryCursor;
        hiddenTerminalLineCount = tab.HiddenTerminalLineCount;
        CommandText = tab.CommandText;
        Status = tab.Status;
        SecurityStatus = tab.SecurityStatus;
        PasteSafetyStatus = tab.PasteSafetyStatus;
        SessionActionSummary = tab.SessionActionSummary;
        MonitorStatus = tab.MonitorStatus;
        MonitorSummary = tab.MonitorSummary;
        DockerStatus = tab.DockerStatus;
        DockerSummary = tab.DockerSummary;
        DockerStatsSummary = tab.DockerStatsSummary;
        DockerLogStatus = tab.DockerLogStatus;
        DockerLogText = tab.DockerLogText;
        BatchCommandText = tab.BatchCommandText;
        BatchStatus = tab.BatchStatus;
        BatchOutputText = tab.BatchOutputText;
        ResetSftpEditor();
        SftpStatus = tab.SftpStatus;
        SftpPathText = tab.SftpPathText;
        SftpBrowserStatus = tab.SftpBrowserStatus;
        SftpOperationStatus = tab.SftpOperationStatus;
        SftpPreviewStatus = tab.SftpPreviewStatus;
        SftpPreviewText = tab.SftpPreviewText;
        IsAutoScrollEnabled = tab.IsAutoScrollEnabled;
        pendingChallenge = tab.PendingChallenge;
        terminalLease = tab.TerminalLease;
        sftpLease = tab.SftpLease;
        IsConnected = tab.IsConnected;
        HasHostKeyChallenge = tab.HasHostKeyChallenge;
        OnPropertyChanged(nameof(HostKeySummary));
        NotifyTerminalStateChanged();
        NotifyTerminalOutputChanged();
        NotifySftpStateChanged();
        NotifySftpListingChanged();
    }

    private int ParsedPort => int.TryParse(
        PortText,
        System.Globalization.NumberStyles.None,
        System.Globalization.CultureInfo.InvariantCulture,
        out var parsed)
        ? parsed
        : 0;

    private void RefreshCommands()
    {
        ConnectCommand.RaiseCanExecuteChanged();
        SaveAssetCommand.RaiseCanExecuteChanged();
        DeleteAssetCommand.RaiseCanExecuteChanged();
        OpenWorkspaceTabCommand.RaiseCanExecuteChanged();
        CloseWorkspaceTabCommand.RaiseCanExecuteChanged();
        DisconnectAndCloseWorkspaceTabCommand.RaiseCanExecuteChanged();
        OpenTerminalCommand.RaiseCanExecuteChanged();
        OpenSftpCommand.RaiseCanExecuteChanged();
        RefreshMonitorSnapshotCommand.RaiseCanExecuteChanged();
        RefreshDockerContainersCommand.RaiseCanExecuteChanged();
        RefreshDockerStatsCommand.RaiseCanExecuteChanged();
        PreviewDockerLogsCommand.RaiseCanExecuteChanged();
        StartDockerContainerCommand.RaiseCanExecuteChanged();
        StopDockerContainerCommand.RaiseCanExecuteChanged();
        RestartDockerContainerCommand.RaiseCanExecuteChanged();
        RunBatchCommand.RaiseCanExecuteChanged();
        DeleteSnippetCommand.RaiseCanExecuteChanged();
        InsertSnippetCommand.RaiseCanExecuteChanged();
        ExecuteSnippetCommand.RaiseCanExecuteChanged();
        FillBatchFromSnippetCommand.RaiseCanExecuteChanged();
        EndSessionCommand.RaiseCanExecuteChanged();
        SendCommand.RaiseCanExecuteChanged();
        CloseTerminalCommand.RaiseCanExecuteChanged();
        ClearTerminalCommand.RaiseCanExecuteChanged();
        PreviousCommandHistoryCommand.RaiseCanExecuteChanged();
        NextCommandHistoryCommand.RaiseCanExecuteChanged();
        PrepareSftpBrowseCommand.RaiseCanExecuteChanged();
        RefreshSftpBrowseCommand.RaiseCanExecuteChanged();
        GoParentSftpCommand.RaiseCanExecuteChanged();
        OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
        PreviewSftpTextCommand.RaiseCanExecuteChanged();
    }

    private void NotifyWorkbenchStateChanged()
    {
        OnPropertyChanged(nameof(WorkspaceTitle));
        OnPropertyChanged(nameof(WorkspaceSubtitle));
        OnPropertyChanged(nameof(ConnectionStateLabel));
        OnPropertyChanged(nameof(SecurityBadgeText));
    }

    private void NotifyTerminalStateChanged()
    {
        OnPropertyChanged(nameof(IsTerminalOpen));
        OnPropertyChanged(nameof(TerminalStateLabel));
        OnPropertyChanged(nameof(TerminalTitle));
        OnPropertyChanged(nameof(TerminalSubtitle));
        OnPropertyChanged(nameof(ActivitySummary));
        OnPropertyChanged(nameof(HasTerminalOutput));
        OnPropertyChanged(nameof(TerminalOutputSummary));
        OnPropertyChanged(nameof(CommandHistorySummary));
        OnPropertyChanged(nameof(TerminalInputHint));
        OnPropertyChanged(nameof(CanUseSelectedSnippetInTerminal));
        RefreshCommands();
    }

    private void NotifySftpStateChanged()
    {
        OnPropertyChanged(nameof(IsSftpOpen));
        OnPropertyChanged(nameof(SftpStateLabel));
        OnPropertyChanged(nameof(SftpListingSummary));
        RefreshCommands();
    }

    private bool CanNavigateSftp()
    {
        return sftpLease is not null && !IsSftpPreviewDirty;
    }

    private void ResetSftpBrowserState()
    {
        SftpStatus = "SFTP not open";
        SftpPathText = "/";
        SelectedSftpEntry = null;
        SftpEntries.Clear();
        ResetSftpEditor();
        SftpPreviewStatus = "No SFTP text preview";
        SftpBrowserStatus = "Open SFTP to prepare browsing";
        SftpOperationStatus = "Open a checked SFTP channel to transfer files";
        OnPropertyChanged(nameof(SftpListingSummary));
    }

    private void ResetSftpEditor()
    {
        sftpPreviewPath = null;
        sftpPreviewSnapshot = null;
        sftpPreviewOriginalText = string.Empty;
        SftpPreviewText = string.Empty;
        NotifySftpEditorStateChanged();
    }

    private void NotifySftpEditorStateChanged()
    {
        OnPropertyChanged(nameof(HasSftpPreview));
        OnPropertyChanged(nameof(CanEditSftpPreview));
        OnPropertyChanged(nameof(IsSftpPreviewReadOnly));
        OnPropertyChanged(nameof(IsSftpPreviewDirty));
        OnPropertyChanged(nameof(CanSaveSftpPreview));
    }

    private void ResetMonitorState()
    {
        MonitorStatus = "Monitor idle";
        MonitorSummary = "No monitor snapshot";
    }

    private void ResetDockerState()
    {
        DockerStatus = "Docker idle";
        DockerSummary = "No Docker containers";
        DockerStatsSummary = "No Docker stats";
        DockerLogStatus = "No Docker log preview";
        DockerLogText = string.Empty;
        SelectedDockerContainer = null;
        DockerContainers.Clear();
        DockerStats.Clear();
    }

    private void ResetBatchState()
    {
        BatchCommandText = string.Empty;
        BatchStatus = "Batch ready";
        BatchOutputText = string.Empty;
    }

    private void NotifySftpListingChanged()
    {
        OnPropertyChanged(nameof(SftpListingSummary));
        OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
    }

    private void AppendTerminalLine(TerminalLineViewModel line)
    {
        TerminalLines.Add(line);
        while (TerminalLines.Count > MaximumTerminalLines)
        {
            TerminalLines.RemoveAt(0);
            hiddenTerminalLineCount++;
        }

        NotifyTerminalOutputChanged();
    }

    private static void AppendTerminalLineToWorkspaceTab(WorkspaceTabViewModel tab, TerminalLineViewModel line)
    {
        tab.TerminalLines.Add(line);
        while (tab.TerminalLines.Count > MaximumTerminalLines)
        {
            tab.TerminalLines.RemoveAt(0);
            tab.HiddenTerminalLineCount++;
        }
    }

    private void NotifyTerminalOutputChanged()
    {
        OnPropertyChanged(nameof(ActivitySummary));
        OnPropertyChanged(nameof(HasTerminalOutput));
        OnPropertyChanged(nameof(TerminalOutputSummary));
        ClearTerminalCommand.RaiseCanExecuteChanged();
    }

    private void AddCommandToHistory(string command)
    {
        var normalized = command.Trim();
        if (normalized.Length == 0)
        {
            return;
        }

        if (commandHistory.Count == 0 || !string.Equals(commandHistory[^1], normalized, StringComparison.Ordinal))
        {
            commandHistory.Add(normalized);
            if (commandHistory.Count > 100)
            {
                commandHistory.RemoveAt(0);
            }
        }

        commandHistoryCursor = -1;
        OnPropertyChanged(nameof(CommandHistorySummary));
        PreviousCommandHistoryCommand.RaiseCanExecuteChanged();
        NextCommandHistoryCommand.RaiseCanExecuteChanged();
    }

    private DiagnosticsRuntimeSnapshot CreateDiagnosticsRuntimeSnapshot()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? string.Empty;
        return new DiagnosticsRuntimeSnapshot(
            "OrbitTerm",
            version,
            "local",
            "unpackaged",
            RuntimeInformation.OSDescription,
            RuntimeInformation.OSArchitecture.ToString(),
            false);
    }

    private DiagnosticsSessionSnapshot CreateDiagnosticsSessionSnapshot()
    {
        var leaseHost = terminalLease?.Host ?? sftpLease?.Host;
        var hostKeyAlgorithm = terminalLease?.HostKeyAlgorithm ?? sftpLease?.HostKeyAlgorithm;
        var hostKeyFingerprint = terminalLease?.HostKeyFingerprintSha256 ?? sftpLease?.HostKeyFingerprintSha256;
        if ((hostKeyAlgorithm is null || hostKeyFingerprint is null) &&
            TrySplitSecurityStatus(out var parsedAlgorithm, out var parsedFingerprint))
        {
            hostKeyAlgorithm ??= parsedAlgorithm;
            hostKeyFingerprint ??= parsedFingerprint;
        }

        return new DiagnosticsSessionSnapshot(
            IsConnected,
            terminalLease is not null,
            sftpLease is not null,
            leaseHost ?? Host,
            NormalizeHostForDiagnostics(leaseHost ?? Host),
            Username,
            hostKeyAlgorithm,
            hostKeyFingerprint,
            null,
            SftpPathText,
            commandHistory.Count == 0 ? null : commandHistory[^1],
            TerminalLines.Count,
            hiddenTerminalLineCount,
            MonitorStatus,
            MonitorSummary,
            SftpStatus,
            SftpOperationStatus,
            SftpEntries.Count,
            DockerStatus,
            DockerSummary,
            DockerStatsSummary,
            DockerContainers.Count,
            DockerStats.Count,
            !string.IsNullOrEmpty(DockerLogText));
    }

    private bool TrySplitSecurityStatus(out string? algorithm, out string? fingerprint)
    {
        const string separator = "  ";
        var parts = SecurityStatus.Split(separator, 2, StringSplitOptions.TrimEntries);
        if (parts.Length == 2 && parts[0].Length > 0 && parts[1].Length > 0)
        {
            algorithm = parts[0];
            fingerprint = parts[1];
            return true;
        }

        algorithm = null;
        fingerprint = null;
        return false;
    }

    private static string NormalizeHostForDiagnostics(string? value)
    {
        return string.IsNullOrWhiteSpace(value)
            ? string.Empty
            : value.Trim().ToLowerInvariant();
    }

    private static SanitizedCommandPaste SanitizeCommandPaste(string pastedText)
    {
        var builder = new System.Text.StringBuilder(pastedText.Length);
        var removedControlCharacters = false;
        var convertedMultiline = false;
        var previousWasSeparator = false;

        for (var index = 0; index < pastedText.Length; index++)
        {
            var character = pastedText[index];
            if (character == '\r' || character == '\n')
            {
                convertedMultiline = true;
                AppendSeparator(builder, ref previousWasSeparator);
                continue;
            }

            if (character == '\t')
            {
                AppendSeparator(builder, ref previousWasSeparator);
                continue;
            }

            if (char.IsControl(character))
            {
                removedControlCharacters = true;
                continue;
            }

            builder.Append(character);
            previousWasSeparator = char.IsWhiteSpace(character);
        }

        return new SanitizedCommandPaste(
            builder.ToString().Trim(),
            removedControlCharacters,
            convertedMultiline);
    }

    private static void AppendSeparator(System.Text.StringBuilder builder, ref bool previousWasSeparator)
    {
        if (builder.Length == 0 || previousWasSeparator)
        {
            return;
        }

        builder.Append(' ');
        previousWasSeparator = true;
    }

    private static SftpDirectoryEntryViewModel? ToSftpEntryViewModel(string directoryPath, SftpDirectoryEntry entry)
    {
        var entryPath = TryCombineSftpChildPath(directoryPath, entry.Name);
        if (entryPath is null)
        {
            return null;
        }

        var isDirectory = entry.Permissions.StartsWith("d", StringComparison.Ordinal);
        var kindText = isDirectory ? "Folder" : "File";
        var sizeText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{entry.Size} B");
        var modifiedText = entry.ModifiedAtUnix == 0
            ? "unknown"
            : DateTimeOffset
                .FromUnixTimeSeconds(checked((long)Math.Min(entry.ModifiedAtUnix, (ulong)long.MaxValue)))
                .ToLocalTime()
                .ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        return new SftpDirectoryEntryViewModel(
            entry.Name,
            entryPath,
            kindText,
            isDirectory,
            entry.Size,
            entry.PermissionsOctal,
            entry.ModifiedAtUnix,
            sizeText,
            entry.Permissions,
            modifiedText);
    }

    private static SftpMutationSnapshot ToSftpMutationSnapshot(SftpDirectoryEntryViewModel entry)
    {
        return new SftpMutationSnapshot(
            entry.Size,
            entry.PermissionsOctal,
            entry.ModifiedAtUnix,
            entry.IsDirectory);
    }

    private static string FormatSftpMutationFailure(SftpMutationResult.Failed failed)
    {
        return failed.Code switch
        {
            "sftp_entry_changed" => "Entry changed on the server; refresh before retrying",
            "sftp_target_exists" => "A destination or OrbitTerm recovery file already exists",
            _ => failed.Code,
        };
    }

    private static string FormatMonitorStatus(MonitorSnapshot snapshot)
    {
        var sampled = DateTimeOffset
            .FromUnixTimeSeconds(checked((long)Math.Min(snapshot.SampledAtUnix, (ulong)long.MaxValue)))
            .ToLocalTime()
            .ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
        return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"Monitor snapshot {sampled}");
    }

    private static string FormatMonitorSummary(MonitorSnapshot snapshot)
    {
        var pingText = snapshot.PingLatencyMilliseconds is null
            ? "ping n/a"
            : string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"ping {snapshot.PingLatencyMilliseconds:0.#} ms");
        var diagnosticsText = snapshot.Diagnostics.Count == 0
            ? "no diagnostics"
            : string.Join(", ", snapshot.Diagnostics);

        return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"CPU {snapshot.CpuUsagePercent:0.#}% | MEM {snapshot.MemoryUsedPercent:0.#}% ({snapshot.MemoryAvailableMegabytes} MB free) | Disk {snapshot.DiskUsedPercent:0.#}% | Net {snapshot.ReceiveRateKilobitsPerSecond:0.#}/{snapshot.TransmitRateKilobitsPerSecond:0.#} kbps | {pingText} | {diagnosticsText}");
    }

    private static DockerContainerViewModel ToDockerContainerViewModel(DockerContainer container)
    {
        var shortId = container.Id.Length <= 12 ? container.Id : container.Id[..12];
        return new DockerContainerViewModel(
            shortId,
            container.Name,
            container.Image,
            container.State,
            container.Status,
            container.RunningFor,
            container.Id);
    }

    private static DockerStatsViewModel ToDockerStatsViewModel(DockerStatsItem item)
    {
        var shortId = item.Id.Length <= 12 ? item.Id : item.Id[..12];
        return new DockerStatsViewModel(
            shortId,
            item.Name,
            string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{item.CpuPercent:0.#}%"),
            string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{item.MemoryPercent:0.#}%"),
            item.MemoryUsage,
            item.NetworkIo,
            item.BlockIo,
            item.Pids.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    private static string GetSftpParentPath(string path)
    {
        var normalized = NormalizeSftpPath(path);
        if (normalized is null || normalized == "/")
        {
            return "/";
        }

        var lastSlash = normalized.LastIndexOf('/');
        return lastSlash <= 0 ? "/" : normalized[..lastSlash];
    }

    private static string? TryCombineSftpChildPath(string directoryPath, string childName)
    {
        var normalizedDirectory = NormalizeSftpPath(directoryPath);
        if (normalizedDirectory is null ||
            string.IsNullOrWhiteSpace(childName) ||
            System.Text.Encoding.UTF8.GetByteCount(childName) > 255 ||
            childName is "." or ".." ||
            childName.Contains('/', StringComparison.Ordinal) ||
            childName.Contains('\\', StringComparison.Ordinal))
        {
            return null;
        }

        for (var index = 0; index < childName.Length; index++)
        {
            if (char.IsControl(childName[index]))
            {
                return null;
            }
        }

        var combined = normalizedDirectory == "/"
            ? string.Concat("/", childName)
            : string.Concat(normalizedDirectory, "/", childName);
        return combined.Length > MaximumSftpPathLength ? null : combined;
    }

    private static string? NormalizeSftpPath(string path)
    {
        var trimmed = path.Trim();
        if (trimmed.Length == 0 ||
            trimmed.Length > MaximumSftpPathLength ||
            !trimmed.StartsWith("/", StringComparison.Ordinal) ||
            trimmed.Contains('\\', StringComparison.Ordinal))
        {
            return null;
        }

        var segments = new List<string>();
        foreach (var segment in trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (segment == "..")
            {
                return null;
            }

            if (segment == ".")
            {
                continue;
            }

            for (var index = 0; index < segment.Length; index++)
            {
                if (char.IsControl(segment[index]))
                {
                    return null;
                }
            }

            segments.Add(segment);
        }

        return segments.Count == 0
            ? "/"
            : string.Concat("/", string.Join("/", segments));
    }

    private sealed record SanitizedCommandPaste(
        string Text,
        bool RemovedControlCharacters,
        bool ConvertedMultiline);
}
