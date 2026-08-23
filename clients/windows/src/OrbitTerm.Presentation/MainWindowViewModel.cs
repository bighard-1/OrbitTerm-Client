using System.Collections.ObjectModel;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Diagnostics;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Terminal;

namespace OrbitTerm.Presentation;

public sealed class MainWindowViewModel : ObservableObject
{
    // Keep a useful local scrollback without allowing an unbounded remote
    // stream to exhaust UI memory. This matches the screen model's default.
    private const int MaximumTerminalLines = 5_000;
    private const int MaximumBatchOutputCharacters = 64 * 1024;
    private const int MaximumMonitorHistorySamples = 600;
    private const int MaximumSftpPathLength = 512;
    private const int MaximumSftpBatchDownloadEntries = 2_000;
    private const int MaximumSftpBatchDownloadDepth = 64;
    private const int MaximumRecentSftpOperations = 20;
    private const int MaximumRecentDockerOperations = 20;
    private const int MaximumRemoteProcesses = 2_048;
    private const string RemoteProcessSnapshotCommand =
        "LC_ALL=C ps -eo pid=,ppid=,user=,pcpu=,pmem=,stat=,etimes=,args= --sort=-pcpu 2>/dev/null " +
        "| head -n 2048 | awk 'BEGIN { now=systime() } NF>=8 { command=$8; for(i=9;i<=NF;i++) command=command \" \" $i; " +
        "printf \"%s %s %s %s %s %s %.0f %s\\n\",$1,$2,$3,$4,$5,$6,now-$7,substr(command,1,1024) }'";
    private static readonly string connectionDiagnosticPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "diagnostics",
        "connection.log");

    private readonly SessionOrchestrator orchestrator;
    private readonly ICredentialVault credentialVault;
    private readonly IServerAssetStore assetStore;
    private readonly ISnippetStore snippetStore;
    private readonly IAccountSessionStore accountSessionStore;
    private readonly AccountUnlockController? accountUnlockController;
    private readonly IEncryptedConfigSynchronizer? encryptedConfigSynchronizer;
    private readonly IEncryptedAssetPublisher? encryptedAssetPublisher;
    private readonly IEncryptedSnippetPublisher? encryptedSnippetPublisher;
    private readonly Action<Action> dispatch;
    private readonly Func<DateTimeOffset> utcNow;
    private readonly TimeSpan terminalUiFrameInterval;
    private readonly Func<string, int, CancellationToken, Task<TcpLatencyProbeResult>> tcpLatencyProbe;
    private readonly object terminalUiUpdateGate = new();
    private readonly SemaphoreSlim remoteInspectionGate = new(1, 1);
    private readonly Dictionary<ulong, TerminalOutputReceivedEventArgs> pendingTerminalUiUpdates = [];
    private readonly Dictionary<ulong, BatchContinuousSessionViewModel> batchContinuousSessionsByChannel = [];
    private readonly Dictionary<Guid, BatchContinuousRuntime> batchContinuousRuntimes = [];
    private bool terminalUiUpdateScheduled;
    private readonly List<string> commandHistory = [];
    private readonly Dictionary<Guid, CredentialAvailability> credentialAvailabilityById = [];
    private readonly ObservableCollection<TerminalSplitPaneViewModel> emptyTerminalSplitPanes = [];
    private Guid draftAssetId = Guid.NewGuid();
    private Guid draftCredentialId = Guid.NewGuid();
    private Guid draftJumpCredentialId = Guid.NewGuid();
    private AssetViewModel? selectedAsset;
    private WorkspaceTabViewModel? selectedWorkspaceTab;
    private HostKeyChallengeViewModel? pendingChallenge;
    private TerminalSessionLease? terminalLease;
    private SftpSessionLease? sftpLease;
    private string assetName = "新服务器";
    private string assetEditorStatus = "本地资产已就绪";
    private string host = string.Empty;
    private string portText = "22";
    private string username = string.Empty;
    private string password = string.Empty;
    private string privateKey = string.Empty;
    private string privateKeyPassphrase = string.Empty;
    private bool allowPasswordFallback = true;
    private ServerTransport assetTransport = ServerTransport.Ssh;
    private AssetStorageScope assetStorageScope = AssetStorageScope.LocalOnly;
    private string? draftOwnerAccountScope;
    private string? approvedTelnetTarget;
    private bool isJumpHostEnabled;
    private string jumpHost = string.Empty;
    private string jumpPortText = "22";
    private string jumpUsername = string.Empty;
    private string jumpPassword = string.Empty;
    private string jumpPrivateKey = string.Empty;
    private string jumpPrivateKeyPassphrase = string.Empty;
    private bool jumpAllowPasswordFallback = true;
    private string status = "待命";
    private string securityStatus = "尚未建立已验证会话";
    private string commandText = string.Empty;
    private string pasteSafetyStatus = "粘贴安全检查已就绪";
    private string sessionActionSummary = "会话待命";
    private string monitorStatus = "监控待命";
    private string monitorSummary = "尚无监控快照";
    private string systemOverviewSummary = "尚无硬件概览";
    private string monitorTrendStatus = "暂无趋势采样";
    private string monitorTrendRange = "10 分钟";
    private string monitorLoadStatus = "等待监控采样";
    private readonly List<MonitorSnapshot> monitorHistory = [];
    private MonitorSnapshot? latestRawMonitorSnapshot;
    private DateTimeOffset? lastMonitorRefreshAt;
    private DateTimeOffset? lastSuccessfulMonitorRefreshAt;
    private DateTimeOffset? lastSftpMonitorOverlayAt;
    private int monitorRefreshInFlight;
    private int consecutiveMonitorFailures;
    private int remoteProcessRefreshInFlight;
    private int remoteProcessActionInFlight;
    private string remoteProcessStatus = "等待进程采样";
    private bool isMonitorAutoRefreshEnabled = true;
    private int monitorRefreshIntervalSeconds = 1;
    private string dockerStatus = "Docker 待命";
    private string dockerSummary = "尚无 Docker 容器数据";
    private string dockerStatsSummary = "尚无 Docker 资源数据";
    private int dockerContainerRefreshInFlight;
    private int dockerStatsRefreshInFlight;
    private int dockerInspectorAutoRefreshInFlight;
    private DateTimeOffset? lastDockerContainerRefreshAt;
    private static readonly TimeSpan DockerContainerAutoRefreshInterval = TimeSpan.FromSeconds(10);
    private string dockerLogStatus = "尚无 Docker 日志预览";
    private string dockerLogText = string.Empty;
    private DockerFeedbackKind dockerFeedbackKind;
    private string dockerFeedbackTitle = string.Empty;
    private string dockerFeedbackMessage = string.Empty;
    private int dockerFeedbackGeneration;
    private bool isDockerFeedbackFadingOut;
    private string batchCommandText = string.Empty;
    private string batchStatus = "批量命令待命";
    private string batchOutputText = string.Empty;
    private string batchProgressText = "尚未开始执行";
    private string batchCurrentTarget = "等待选择执行目标";
    private int batchCompletedCount;
    private int batchTotalCount;
    private int batchSucceededCount;
    private bool isBatchContinuousMode;
    private int batchContinuousTimeoutMinutes = 15;
    private int batchResultViewIndex;
    private BatchContinuousSessionViewModel? selectedBatchContinuousSession;
    private string batchResultQuery = string.Empty;
    private bool showOnlyFailedBatchResults;
    private string filteredBatchOutputText = string.Empty;
    private const string AllBatchTargetGroups = "全部分组";
    private string selectedBatchTargetGroup = AllBatchTargetGroups;
    private string batchTargetQuery = string.Empty;
    private string sftpStatus = "SFTP 未打开";
    private string sftpPathText = "/";
    private string sftpBrowserStatus = "打开 SFTP 后即可浏览远程目录";
    private string sftpOperationStatus = "需先打开经验证的 SFTP 通道才能传输文件";
    private string sftpTransferStatus = "暂无传输任务";
    private SftpFeedbackKind sftpFeedbackKind;
    private string sftpFeedbackTitle = string.Empty;
    private string sftpFeedbackMessage = string.Empty;
    private int sftpFeedbackGeneration;
    private bool isSftpFeedbackFadingOut;
    private readonly List<SftpDirectoryEntryViewModel> selectedSftpEntries = [];
    private readonly Dictionary<Guid, SftpTransferQueueContext> sftpTransferContexts = [];
    private const int MaximumSftpTransferTasks = 40;
    private bool isSftpBatchRunning;
    private long sftpBrowseRequestVersion;
    private string sftpPreviewStatus = "尚无 SFTP 文本预览";
    private string sftpPreviewText = string.Empty;
    private string sftpPreviewOriginalText = string.Empty;
    private string? sftpPreviewPath;
    private SftpMutationSnapshot? sftpPreviewSnapshot;
    private string diagnosticsStatus = "诊断信息已就绪";
    private string credentialHealthStatus = "尚未执行本机凭据健康检查。";
    private SftpDirectoryEntryViewModel? selectedSftpEntry;
    private DockerContainerViewModel? selectedDockerContainer;
    private SnippetViewModel? selectedSnippet;
    private string snippetStatus = "快捷指令已就绪";
    private string snippetQuery = string.Empty;
    private string assetSearchQuery = string.Empty;
    private string assetGroupFilter = "全部分组";
    private string assetGroup = "未分组";
    private string assetTagsText = string.Empty;
    private int commandHistoryCursor = -1;
    private int hiddenTerminalLineCount;
    private bool isConnected;
    private bool hasHostKeyChallenge;
    private bool isOpeningVerifiedWorkspace;
    private bool isAutoScrollEnabled = true;
    private bool isRestoringWorkspaceTab;
    private Guid? activeTerminalSplitPaneId;
    private int terminalSplitOutputVersion;
    private CancellationTokenSource? automaticReconnectCts;
    private AccountLockState accountLockState;
    private string accountStatus = "正在检查本机账户状态。";
    private byte[]? sessionMasterPasswordUtf8;

    public MainWindowViewModel(
        SessionOrchestrator orchestrator,
        ICredentialVault credentialVault,
        IServerAssetStore? assetStore = null,
        ISnippetStore? snippetStore = null,
        Action<Action>? dispatch = null,
        IAccountSessionStore? accountSessionStore = null,
        AccountUnlockController? accountUnlockController = null,
        IEncryptedConfigSynchronizer? encryptedConfigSynchronizer = null,
        IEncryptedAssetPublisher? encryptedAssetPublisher = null,
        IEncryptedSnippetPublisher? encryptedSnippetPublisher = null,
        Func<DateTimeOffset>? utcNow = null,
        TimeSpan? terminalUiFrameInterval = null,
        Func<string, int, CancellationToken, Task<TcpLatencyProbeResult>>? tcpLatencyProbe = null)
    {
        this.orchestrator = orchestrator;
        this.credentialVault = credentialVault;
        this.assetStore = assetStore ?? new InMemoryServerAssetStore();
        this.snippetStore = snippetStore ?? new InMemorySnippetStore();
        this.accountSessionStore = accountSessionStore ?? new NullAccountSessionStore();
        this.accountUnlockController = accountUnlockController;
        this.encryptedConfigSynchronizer = encryptedConfigSynchronizer;
        this.encryptedAssetPublisher = encryptedAssetPublisher;
        this.encryptedSnippetPublisher = encryptedSnippetPublisher;
        this.dispatch = dispatch ?? (action => action());
        this.utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
        this.tcpLatencyProbe = tcpLatencyProbe ?? ((targetHost, targetPort, token) =>
            TcpLatencyProbe.MeasureAsync(targetHost, targetPort, TimeSpan.FromSeconds(2), token));
        // Keep cumulative snapshot coalescing, but present remote echo within
        // the next display frame. The previous 33 ms gate plus the renderer's
        // own frame timer made interactive typing visibly trail the keyboard.
        this.terminalUiFrameInterval = terminalUiFrameInterval ?? TimeSpan.FromMilliseconds(8);
        this.orchestrator.TerminalOutputReceived += OnTerminalOutputReceived;

        LoadAssetsCommand = new AsyncRelayCommand(LoadAssetsAsync);
        LoadAccountSessionCommand = new AsyncRelayCommand(LoadAccountSessionAsync);
        CheckCredentialHealthCommand = new AsyncRelayCommand(CheckCredentialHealthAsync);
        LoadSnippetsCommand = new AsyncRelayCommand(LoadSnippetsAsync);
        SaveLatestCommandAsSnippetCommand = new AsyncRelayCommand(SaveLatestCommandAsSnippetAsync, () => commandHistory.Count > 0);
        NewAssetCommand = new AsyncRelayCommand(NewAssetAsync);
        SaveAssetCommand = new AsyncRelayCommand(SaveCurrentAssetAsync, CanSaveAsset);
        DeleteAssetCommand = new AsyncRelayCommand(DeleteAssetAsync, () => SelectedAsset is not null);
        OpenWorkspaceTabCommand = new AsyncRelayCommand(OpenWorkspaceTabAsync);
        CloseWorkspaceTabCommand = new AsyncRelayCommand(CloseWorkspaceTabAsync, CanCloseSelectedWorkspaceTab);
        DisconnectAndCloseWorkspaceTabCommand = new AsyncRelayCommand(
            DisconnectAndCloseWorkspaceTabAsync,
            CanDisconnectAndCloseSelectedWorkspaceTab);
        ConnectCommand = new AsyncRelayCommand(ConnectAsync, CanConnect);
        TrustHostKeyCommand = new AsyncRelayCommand(TrustHostKeyAsync, () => pendingChallenge is not null);
        EndSessionCommand = new AsyncRelayCommand(EndSessionAsync, () => isConnected || terminalLease is not null || sftpLease is not null || pendingChallenge is not null);
        OpenTerminalCommand = new AsyncRelayCommand(OpenTerminalAsync, () => isConnected && terminalLease is null && !isOpeningVerifiedWorkspace && !IsTelnetSession);
        AddTerminalSplitCommand = new AsyncRelayCommand(AddTerminalSplitAsync, () => CanAddTerminalSplit);
        RemoveLastTerminalSplitCommand = new AsyncRelayCommand(RemoveLastTerminalSplitAsync, () => HasTerminalSplits);
        OpenSftpCommand = new AsyncRelayCommand(OpenSftpAsync, () => isConnected && sftpLease is null && !isOpeningVerifiedWorkspace && !IsTelnetSession);
        RefreshMonitorSnapshotCommand = new AsyncRelayCommand(RefreshMonitorDetailsAsync, () => isConnected && !IsTelnetSession);
        RefreshDockerContainersCommand = new AsyncRelayCommand(RefreshDockerContainersAsync, () => isConnected && !IsTelnetSession);
        RefreshDockerStatsCommand = new AsyncRelayCommand(RefreshDockerStatsAsync, () => isConnected && !IsTelnetSession);
        PreviewDockerLogsCommand = new AsyncRelayCommand(PreviewDockerLogsAsync, () => isConnected && !IsTelnetSession && SelectedDockerContainer is not null);
        StartDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("start", cancellationToken), () => CanRunDockerAction(static container => container.CanStart));
        StopDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("stop", cancellationToken), () => CanRunDockerAction(static container => container.CanStop));
        RestartDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("restart", cancellationToken), () => CanRunDockerAction(static container => container.CanRestart));
        PauseDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("pause", cancellationToken), () => CanRunDockerAction(static container => container.CanPause));
        UnpauseDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("unpause", cancellationToken), () => CanRunDockerAction(static container => container.CanUnpause));
        KillDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("kill", cancellationToken), () => CanRunDockerAction(static container => container.CanKill));
        RemoveDockerContainerCommand = new AsyncRelayCommand(cancellationToken => RunDockerActionAsync("remove", cancellationToken), () => CanRunDockerAction(static container => container.CanRemove));
        RunBatchCommand = new AsyncRelayCommand(RunBatchCommandAsync, CanRunBatchCommand);
        CancelBatchCommand = new AsyncRelayCommand(
            CancelBatchCommandAsync,
            () => RunBatchCommand.IsRunning || HasActiveBatchContinuousSessions);
        DeleteSnippetCommand = new AsyncRelayCommand(DeleteSelectedSnippetAsync, () => SelectedSnippet is not null);
        InsertSnippetCommand = new AsyncRelayCommand(InsertSelectedSnippetAsync, () => SelectedSnippet is not null && IsTerminalOpen);
        ExecuteSnippetCommand = new AsyncRelayCommand(ExecuteSelectedSnippetAsync, () => SelectedSnippet is not null && IsTerminalOpen);
        PrepareSftpBrowseCommand = new AsyncRelayCommand(PrepareSftpBrowseAsync, CanNavigateSftp);
        RefreshSftpBrowseCommand = new AsyncRelayCommand(RefreshSftpBrowseAsync, CanNavigateSftp);
        GoParentSftpCommand = new AsyncRelayCommand(GoParentSftpAsync, CanNavigateSftp);
        OpenSelectedSftpEntryCommand = new AsyncRelayCommand(OpenSelectedSftpEntryAsync, () => CanNavigateSftp() && SelectedSftpEntry is not null);
        PreviewSftpTextCommand = new AsyncRelayCommand(PreviewSftpTextAsync, CanNavigateSftp);
        RetryLastSftpTransferCommand = new AsyncRelayCommand(RetryLastSftpTransferAsync, () => CanRetryLastSftpTransfer);
        CancelSftpBatchCommand = new AsyncRelayCommand(CancelSftpBatchAsync, () => IsSftpBatchRunning);
        ClearCompletedSftpTransfersCommand = new AsyncRelayCommand(
            ClearCompletedSftpTransfersAsync,
            () => SftpTransferTasks.Any(static task => IsTerminalSftpTransferState(task.State)));
        SendCommand = new AsyncRelayCommand(SendAsync, () => terminalLease is not null);
        CloseTerminalCommand = new AsyncRelayCommand(CloseTerminalAsync, () => terminalLease is not null);
        ClearTerminalCommand = new AsyncRelayCommand(ClearTerminalAsync, () => TerminalLines.Count > 0);
        PreviousCommandHistoryCommand = new AsyncRelayCommand(PreviousCommandHistoryAsync, () => commandHistory.Count > 0);
        NextCommandHistoryCommand = new AsyncRelayCommand(NextCommandHistoryAsync, () => commandHistory.Count > 0);

        var initialTab = CreateWorkspaceTabFromDraft();
        WorkspaceTabs.Add(initialTab);
        selectedWorkspaceTab = initialTab;
        _ = GetOrCreateSftpTransferContext(initialTab);
        RebuildSftpBreadcrumbs(sftpPathText);
    }

    public ObservableCollection<AssetViewModel> Assets { get; } = [];

    public ObservableCollection<AssetViewModel> FilteredAssets { get; } = [];

    public ObservableCollection<AssetGroupViewModel> AssetGroups { get; } = [];

    public ObservableCollection<string> AssetGroupFilters { get; } = ["全部分组"];

    public ObservableCollection<string> BatchTargetGroups { get; } = [AllBatchTargetGroups];

    public ObservableCollection<BatchAssetTargetViewModel> BatchAssetTargets { get; } = [];

    public ObservableCollection<BatchAssetTargetViewModel> FilteredBatchAssetTargets { get; } = [];

    public ObservableCollection<BatchAssetTargetViewModel> SelectedBatchAssetTargets { get; } = [];

    public ObservableCollection<BatchContinuousSessionViewModel> BatchContinuousSessions { get; } = [];

    public ObservableCollection<BatchCommandReceiptViewModel> BatchCommandReceipts { get; } = [];

    public ObservableCollection<BatchCommandReceiptViewModel> FilteredBatchCommandReceipts { get; } = [];

    public ObservableCollection<int> BatchContinuousTimeoutOptions { get; } = [1, 5, 15, 30, 60, 120];

    public ObservableCollection<WorkspaceTabViewModel> WorkspaceTabs { get; } = [];

    public ObservableCollection<TerminalLineViewModel> TerminalLines { get; } = [];

    public ObservableCollection<SftpDirectoryEntryViewModel> SftpEntries { get; } = [];

    public ObservableCollection<SftpTransferTaskViewModel> SftpTransferTasks { get; } = [];

    public ObservableCollection<SftpTransferTaskViewModel> ActiveSftpTransferTasks { get; } = [];

    public ObservableCollection<SftpTransferTaskViewModel> CompletedSftpTransferTasks { get; } = [];

    public ObservableCollection<SftpRecentOperationViewModel> RecentSftpOperations { get; } = [];

    public ObservableCollection<SftpBreadcrumbSegmentViewModel> SftpBreadcrumbs { get; } = [];

    public ObservableCollection<DockerContainerViewModel> DockerContainers { get; } = [];

    public ObservableCollection<DockerStatsViewModel> DockerStats { get; } = [];

    public ObservableCollection<RemoteProcessViewModel> RemoteProcesses { get; } = [];

    public ObservableCollection<DockerRecentOperationViewModel> RecentDockerOperations { get; } = [];

    public ObservableCollection<SnippetViewModel> Snippets { get; } = [];

    public ObservableCollection<SnippetGroupViewModel> SnippetGroups { get; } = [];

    public ObservableCollection<MonitorTrendMetricViewModel> MonitorTrendMetrics { get; } =
    [
        new("cpu", "CPU", snapshot => snapshot.CpuUsagePercent, MonitorSampleMetrics.Cpu),
        new("memory", "内存", snapshot => snapshot.MemoryUsedPercent, MonitorSampleMetrics.Memory),
        new("disk", "磁盘", snapshot => snapshot.DiskUsedPercent, MonitorSampleMetrics.Disk),
        new("download", "下载", snapshot => snapshot.ReceiveRateKilobitsPerSecond, MonitorSampleMetrics.Download),
        new("upload", "上传", snapshot => snapshot.TransmitRateKilobitsPerSecond, MonitorSampleMetrics.Upload),
        new("latency", "TCP 延迟", snapshot => snapshot.PingLatencyMilliseconds, MonitorSampleMetrics.Latency),
    ];

    public MonitorTrendMetricViewModel CpuMonitorTrend => MonitorTrendMetrics[0];

    public MonitorTrendMetricViewModel MemoryMonitorTrend => MonitorTrendMetrics[1];

    public MonitorTrendMetricViewModel DiskMonitorTrend => MonitorTrendMetrics[2];

    public MonitorTrendMetricViewModel DownloadMonitorTrend => MonitorTrendMetrics[3];

    public MonitorTrendMetricViewModel UploadMonitorTrend => MonitorTrendMetrics[4];

    public MonitorTrendMetricViewModel LatencyMonitorTrend => MonitorTrendMetrics[5];

    public IReadOnlyList<string> MonitorTrendRangeOptions { get; } = ["实时（30 秒）", "5 分钟", "10 分钟"];

    public IReadOnlyList<string> MonitorRefreshIntervalOptions { get; } =
        Enumerable.Range(1, 10).Select(seconds => $"{seconds} 秒").ToArray();

    public string AssetSearchQuery
    {
        get => assetSearchQuery;
        set
        {
            if (SetProperty(ref assetSearchQuery, value))
            {
                RefreshFilteredAssets();
            }
        }
    }

    public string AssetGroupFilter
    {
        get => assetGroupFilter;
        set
        {
            if (SetProperty(ref assetGroupFilter, value))
            {
                RefreshFilteredAssets();
            }
        }
    }

    public string AssetListSummary => Assets.Count(CanAccessAsset) == 0
        ? "暂无已保存服务器"
        : "";

    public bool HasAssetSearchResults => AssetGroups.Count != 0;

    public string AssetEmptyStateTitle => Assets.Count == 0 ? "尚未保存服务器资产" : "未找到匹配的服务器";

    public string AssetEmptyStateDescription => Assets.Count == 0
        ? "选择“新建服务器”添加第一台本地资产。"
        : "请调整关键词或分组筛选条件。";

    public string AssetStorageStatus => string.Concat("仅本地保存 · ", AssetEditorStatus);

    public string SelectedCredentialAvailabilitySummary
    {
        get
        {
            if (SelectedAsset is null)
            {
                return "凭据与资产信息分离保存；新资产连接时可安全保存凭据。";
            }

            return GetCredentialAvailability(SelectedAsset.CredentialId) switch
            {
                CredentialAvailability.Available => "已安全保存凭据；可直接连接。",
                CredentialAvailability.Missing => "尚未保存凭据；连接前需要输入密码或导入私钥。",
                CredentialAvailability.Unavailable => "无法读取本机凭据；请重新输入并保存。",
                _ => "正在检查本机凭据可用性。",
            };
        }
    }

    public string CredentialProtectionStatus =>
        "凭据由 Windows DPAPI 保护，仅当前 Windows 用户可解密；资产元数据不含密码或私钥。";

    public string CredentialHealthStatus
    {
        get => credentialHealthStatus;
        private set => SetProperty(ref credentialHealthStatus, value);
    }

    public AccountLockState AccountLockState
    {
        get => accountLockState;
        private set => SetProperty(ref accountLockState, value);
    }

    public string AccountStatus
    {
        get => accountStatus;
        private set
        {
            if (SetProperty(ref accountStatus, value))
            {
                OnPropertyChanged(nameof(AssetSynchronizationStatus));
            }
        }
    }

    public bool IsAccountSignedIn => AccountLockState is
        OrbitTerm.Application.Accounts.AccountLockState.SignedInLocked or
        OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked;

    public string AccountEntryLabel => IsAccountSignedIn ? "个人中心" : "登录";

    public bool IsAccountLocked => AccountLockState == OrbitTerm.Application.Accounts.AccountLockState.SignedInLocked;

    public bool IsAccountUnlocked => AccountLockState == OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked;

    public string AccountUsername => accountUnlockController?.Username ?? string.Empty;

    public string AssetSynchronizationStatus => AccountLockState switch
    {
        OrbitTerm.Application.Accounts.AccountLockState.SignedOut => "本机资产 · 登录后启用加密同步",
        OrbitTerm.Application.Accounts.AccountLockState.SignedInLocked => "已登录 · 等待本次启动解锁",
        OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked when AccountStatus.Contains("同步完成", StringComparison.Ordinal) => "云端已同步 · 本机队列已处理",
        OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked when AccountStatus.Contains("云端变更已确认", StringComparison.Ordinal) => "云端已同步 · 本机队列待重试",
        OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked when
            AccountStatus.Contains("无法连接", StringComparison.Ordinal) ||
            AccountStatus.Contains("未完成", StringComparison.Ordinal) ||
            AccountStatus.Contains("暂时不可用", StringComparison.Ordinal) => "同步服务暂不可用 · 本机变更已保留",
        OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked => "加密同步已启用",
        _ => "正在读取同步状态",
    };

    public string AssetConflictPolicy => "冲突策略：保留双方并要求人工处理（接入同步服务后生效）";

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
                OnPropertyChanged(nameof(DockerSelectionSummary));
                PreviewDockerLogsCommand.RaiseCanExecuteChanged();
                StartDockerContainerCommand.RaiseCanExecuteChanged();
                StopDockerContainerCommand.RaiseCanExecuteChanged();
                RestartDockerContainerCommand.RaiseCanExecuteChanged();
                PauseDockerContainerCommand.RaiseCanExecuteChanged();
                UnpauseDockerContainerCommand.RaiseCanExecuteChanged();
                KillDockerContainerCommand.RaiseCanExecuteChanged();
                RemoveDockerContainerCommand.RaiseCanExecuteChanged();
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
                OnPropertyChanged(nameof(HasSelectedSftpEntry));
                OnPropertyChanged(nameof(SftpSelectionSummary));
                OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(CanDownloadSelectedSftpEntry));
                OnPropertyChanged(nameof(CanPreviewSelectedSftpText));
                OnPropertyChanged(nameof(CanMutateSelectedSftpEntry));
                OnPropertyChanged(nameof(CanChangeSelectedSftpPermissions));
                OnPropertyChanged(nameof(CanDownloadSelectedSftpEntries));
                OnPropertyChanged(nameof(CanDeleteSelectedSftpEntries));
            }
        }
    }

    public IReadOnlyList<SftpDirectoryEntryViewModel> SelectedSftpEntries => selectedSftpEntries;

    public bool HasSelectedSftpEntry => SelectedSftpEntry is not null;

    public int SelectedSftpEntryCount => selectedSftpEntries.Count;

    public bool IsSftpBatchRunning
    {
        get => isSftpBatchRunning;
        private set
        {
            if (SetProperty(ref isSftpBatchRunning, value))
            {
                OnPropertyChanged(nameof(CanDownloadSelectedSftpEntries));
                OnPropertyChanged(nameof(CanDeleteSelectedSftpEntries));
                OnPropertyChanged(nameof(HasActiveSftpTransfers));
                OnPropertyChanged(nameof(ActiveSftpTransferCount));
                OnPropertyChanged(nameof(SftpExitProtectionMessage));
                CancelSftpBatchCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SftpTransferQueueSummary => SftpTransferTasks.Count == 0
        ? "暂无传输任务"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"传输任务 {SftpTransferTasks.Count} 项 · 当前队列 {ActiveSftpTransferTasks.Count} 项 · 已完成 {CompletedSftpTransferTasks.Count} 项");

    public string CompletedSftpTransferSummary => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"已完成（{CompletedSftpTransferTasks.Count}）");

    public string ActiveSftpTransferSummary => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"进行中（{ActiveSftpTransferTasks.Count}）");

    public int ActiveSftpTransferCount => SftpTransferTasks.Count(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused);

    public bool HasActiveSftpTransfers => sftpTransferContexts.Values.Any(static context =>
        context.IsBatchRunning ||
        context.Tasks.Any(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused));

    private bool HasActiveSftpTransfersForCurrentContext =>
        GetCurrentSftpTransferContext().IsBatchRunning || ActiveSftpTransferCount > 0;

    public string SftpExitProtectionMessage => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"仍有 {Math.Max(1, GetTotalActiveSftpTransferCount())} 项 SFTP 传输正在进行。退出会安全取消未完成任务，远程临时文件可能需要稍后检查。");

    public bool CanDownloadSelectedSftpEntry =>
        sftpLease is not null &&
        SelectedSftpEntryCount <= 1 &&
        SelectedSftpEntry is { IsDirectory: false };

    public bool CanDownloadSelectedSftpEntries =>
        sftpLease is not null &&
        !IsSftpBatchRunning &&
        GetEffectiveSftpSelection().Count > 0;

    public bool CanDeleteSelectedSftpEntries =>
        sftpLease is not null &&
        !IsSftpBatchRunning &&
        GetEffectiveSftpSelection().Count > 0 &&
        !IsSftpPreviewDirty;

    public bool CanPreviewSelectedSftpText =>
        sftpLease is not null &&
        SelectedSftpEntryCount <= 1 &&
        SelectedSftpEntry is { IsDirectory: false };

    public string DockerSelectionSummary => SelectedDockerContainer is null
        ? "未选择容器。请选择一项后再预览日志或执行操作。"
        : string.Concat("已选择：", SelectedDockerContainer.Name, "（", SelectedDockerContainer.Image, "）");

    public string SftpSelectionSummary => SelectedSftpEntry is null
        ? "未选择远程项目。选择文件后可下载、预览或修改。"
        : SelectedSftpEntryCount > 1
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已选择 {SelectedSftpEntryCount} 项，可批量下载文件或删除所选项目。")
        : string.Concat(
            "已选择：", SelectedSftpEntry.Name,
            SelectedSftpEntry.IsDirectory ? "（文件夹）" : "（文件）",
            " · 权限 ", SelectedSftpEntry.Permissions);

    public bool CanMutateSelectedSftpEntry =>
        sftpLease is not null && SelectedSftpEntryCount <= 1 && SelectedSftpEntry is not null && !IsSftpPreviewDirty;

    public bool CanChangeSelectedSftpPermissions =>
        sftpLease is not null &&
        !IsSftpPreviewDirty &&
        SelectedSftpEntryCount <= 1 &&
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
                    AssetTransport = value.Transport;
                    AssetStorageScope = value.StorageScope;
                    draftOwnerAccountScope = value.OwnerAccountScope;
                    AllowPasswordFallback = value.AllowPasswordFallback;
                    AssetGroup = value.Group;
                    AssetTagsText = string.Join("，", value.Tags);
                    LoadJumpHostDraft(value.JumpHost);
                    if (previousAssetId != value.Id)
                    {
                        Password = PrivateKey = PrivateKeyPassphrase = string.Empty;
                    }

                    AssetEditorStatus = "已选择服务器资产";
                }

                DeleteAssetCommand.RaiseCanExecuteChanged();
                NotifyCredentialAvailabilityChanged();
                SyncSelectedWorkspaceTabFromDraft();
                RefreshSnippetGroups();
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
                RestoreSftpTransferContext(value);
                NotifyTerminalSplitStateChanged();
                RefreshCommands();
                NotifyWorkbenchStateChanged();
                OnPropertyChanged(nameof(CurrentConnectedHost));
            }
        }
    }

    public string WorkspaceTabSummary => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"{WorkspaceTabs.Count} 个会话标签");

    public bool SelectWorkspaceTabAt(int zeroBasedIndex)
    {
        if (zeroBasedIndex < 0 || zeroBasedIndex >= WorkspaceTabs.Count)
        {
            return false;
        }

        SelectedWorkspaceTab = WorkspaceTabs[zeroBasedIndex];
        return ReferenceEquals(SelectedWorkspaceTab, WorkspaceTabs[zeroBasedIndex]);
    }

    public Task DisconnectSelectedWorkspaceAsync(CancellationToken cancellationToken) =>
        EndSessionCoreAsync(cancellationToken, "会话已断开");

    public async Task ReconnectSelectedWorkspaceAsync(CancellationToken cancellationToken)
    {
        CancelAutomaticReconnect();
        if (HasActiveRuntime)
        {
            await EndSessionCoreAsync(cancellationToken, "正在重新连接").ConfigureAwait(true);
        }

        await ConnectAsync(cancellationToken).ConfigureAwait(true);
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
        private set
        {
            if (SetProperty(ref assetEditorStatus, value))
            {
                OnPropertyChanged(nameof(AssetStorageStatus));
            }
        }
    }

    public string AssetGroup
    {
        get => assetGroup;
        set
        {
            if (SetProperty(ref assetGroup, value))
            {
                SaveAssetCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string AssetTagsText
    {
        get => assetTagsText;
        set
        {
            if (SetProperty(ref assetTagsText, value))
            {
                SaveAssetCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string? ValidateAssetEditorInput(
        string name,
        string hostName,
        string port,
        string userName,
        string group,
        string tags)
    {
        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(hostName) || string.IsNullOrWhiteSpace(userName))
        {
            return "请填写名称、主机和用户。";
        }

        if (!int.TryParse(port, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var portValue) ||
            portValue is <= 0 or > 65535)
        {
            return "端口必须是 1 到 65535 之间的数字。";
        }

        if (group.Any(char.IsControl) || group.Trim().Length > 64)
        {
            return "分组不能包含控制字符，且最长为 64 个字符。";
        }

        var seenTags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var tagCount = 0;
        foreach (var rawTag in tags.Split([',', '，', ';', '；'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (rawTag.Any(char.IsControl) || rawTag.Length > 32)
            {
                return "每个标签不能包含控制字符，且最长为 32 个字符。";
            }

            if (!seenTags.Add(rawTag))
            {
                return "标签不能重复。";
            }

            if (++tagCount > 16)
            {
                return "每台服务器最多可设置 16 个标签。";
            }
        }

        return null;
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

    public ServerTransport AssetTransport
    {
        get => assetTransport;
        set
        {
            if (SetProperty(ref assetTransport, value))
            {
                if (value != ServerTransport.Ssh)
                {
                    IsJumpHostEnabled = false;
                }
                SaveAssetCommand.RaiseCanExecuteChanged();
                SyncSelectedWorkspaceTabFromDraft();
                NotifyWorkbenchStateChanged();
            }
        }
    }

    public AssetStorageScope AssetStorageScope
    {
        get => assetStorageScope;
        set => SetProperty(ref assetStorageScope, value);
    }

    public string CurrentAccountScope => accountUnlockController?.AccountScope ?? string.Empty;

    public bool CanAccessAsset(AssetViewModel asset)
    {
        ArgumentNullException.ThrowIfNull(asset);
        if (asset.StorageScope == AssetStorageScope.LocalOnly)
        {
            return true;
        }

        // Test hosts and lightweight embeddings may intentionally omit account
        // services. Production Windows always supplies the controller.
        if (accountUnlockController is null)
        {
            return true;
        }

        return IsAccountUnlocked &&
            (string.IsNullOrWhiteSpace(asset.OwnerAccountScope) ||
             string.Equals(asset.OwnerAccountScope, CurrentAccountScope, StringComparison.Ordinal));
    }

    public bool IsTelnetSession => terminalLease?.HostKeyAlgorithm == "telnet-insecure";

    public void AuthorizeTelnetConnection(Guid assetId, string hostName, int port)
    {
        approvedTelnetTarget = BuildTelnetTargetKey(assetId, hostName, port);
    }

    public async Task DisableTelnetConnectionsAsync(CancellationToken cancellationToken)
    {
        approvedTelnetTarget = null;
        await orchestrator.CloseAllTelnetSessionsAsync(cancellationToken).ConfigureAwait(true);
        foreach (var tab in WorkspaceTabs.Where(tab => tab.Transport == ServerTransport.Telnet))
        {
            tab.TerminalLease = null;
            tab.SftpLease = null;
            tab.IsConnected = false;
            tab.HasHostKeyChallenge = false;
            tab.Status = "Telnet 已关闭";
            tab.SecurityStatus = "明文连接功能已禁用";
            tab.TerminalLines.Add(new TerminalLineViewModel("[安全] Telnet 已关闭，现有明文会话已断开。", false));
        }
        if (SelectedWorkspaceTab?.Transport == ServerTransport.Telnet)
        {
            terminalLease = null;
            sftpLease = null;
            IsConnected = false;
            HasHostKeyChallenge = false;
            Status = "Telnet 已关闭";
            SecurityStatus = "明文连接功能已禁用";
            NotifyTerminalStateChanged();
            NotifySftpStateChanged();
            NotifyWorkbenchStateChanged();
        }
        RefreshCommands();
    }

    public bool IsJumpHostEnabled
    {
        get => isJumpHostEnabled;
        set => SetProperty(ref isJumpHostEnabled, value);
    }

    public string JumpHost { get => jumpHost; set => SetProperty(ref jumpHost, value); }
    public string JumpPortText { get => jumpPortText; set => SetProperty(ref jumpPortText, value); }
    public string JumpUsername { get => jumpUsername; set => SetProperty(ref jumpUsername, value); }
    public string JumpPassword { get => jumpPassword; set => SetProperty(ref jumpPassword, value); }
    public string JumpPrivateKey { get => jumpPrivateKey; set => SetProperty(ref jumpPrivateKey, value); }
    public string JumpPrivateKeyPassphrase { get => jumpPrivateKeyPassphrase; set => SetProperty(ref jumpPrivateKeyPassphrase, value); }
    public bool JumpAllowPasswordFallback { get => jumpAllowPasswordFallback; set => SetProperty(ref jumpAllowPasswordFallback, value); }
    public string PrivateKey
    {
        get => privateKey;
        set
        {
            if (SetProperty(ref privateKey, value))
            {
                RefreshCommands();
            }
        }
    }
    public string PrivateKeyPassphrase { get => privateKeyPassphrase; set => SetProperty(ref privateKeyPassphrase, value); }
    public bool AllowPasswordFallback { get => allowPasswordFallback; set => SetProperty(ref allowPasswordFallback, value); }

    public string? ValidateJumpHostInput(bool enabled, string hostName, string port, string userName)
    {
        if (!enabled)
        {
            return null;
        }
        if (string.IsNullOrWhiteSpace(hostName) || string.IsNullOrWhiteSpace(userName))
        {
            return "启用跳板机后，请填写跳板机主机和用户。";
        }
        if (!int.TryParse(port, out var parsedPort) || parsedPort is < 1 or > 65535)
        {
            return "跳板机端口必须是 1 到 65535 之间的数字。";
        }
        return null;
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
                OnPropertyChanged(nameof(CurrentConnectedHost));
                RefreshCommands();
                NotifyWorkbenchStateChanged();
                NotifyTerminalStateChanged();
            }
        }
    }

    public bool IsConnecting
    {
        get => isOpeningVerifiedWorkspace;
        private set
        {
            if (SetProperty(ref isOpeningVerifiedWorkspace, value))
            {
                OnPropertyChanged(nameof(ConnectionProgressText));
                RefreshCommands();
            }
        }
    }

    public string ConnectionProgressText => AssetTransport == ServerTransport.Telnet
        ? "正在建立 Telnet 连接…"
        : "正在连接并验证服务器…";

    public bool HasHostKeyChallenge
    {
        get => hasHostKeyChallenge;
        private set
        {
            if (SetProperty(ref hasHostKeyChallenge, value))
            {
                TrustHostKeyCommand.RaiseCanExecuteChanged();
                NotifyWorkbenchStateChanged();
                NotifyTerminalStateChanged();
            }
        }
    }

    public string HostKeySummary => pendingChallenge is null
        ? "当前无需确认主机密钥"
        : string.Concat(pendingChallenge.KeyAlgorithm, "  ", pendingChallenge.FingerprintSha256);

    public string WorkspaceTitle => SelectedAsset?.Name ?? "未选择服务器";

    public string WorkspaceSubtitle => SelectedAsset is null
        ? "请选择或新建服务器资产"
        : string.Concat(Username.Trim(), "@", Host.Trim(), ":", PortText.Trim());

    public string CurrentConnectedHost => IsConnected
        ? (terminalLease?.Host ?? sftpLease?.Host ?? SelectedWorkspaceTab?.Host ?? string.Empty).Trim()
        : "未连接";

    public string ConnectionStateLabel
    {
        get
        {
            if (IsConnected)
            {
                return IsTelnetSession ? "Telnet 明文连接" : "SSH 已验证";
            }

            return HasHostKeyChallenge ? "等待主机密钥确认" : "未连接";
        }
    }

    public string SecurityBadgeText
    {
        get
        {
            if (HasHostKeyChallenge)
            {
                return "需要确认";
            }

            return IsConnected
                ? IsTelnetSession ? "无加密 · 未验证身份" : "主机密钥已验证"
                : "等待连接";
        }
    }

    public bool IsTerminalOpen => terminalLease is not null;

    public ObservableCollection<TerminalSplitPaneViewModel> TerminalSplitPanes =>
        SelectedWorkspaceTab?.TerminalSplitPanes ?? emptyTerminalSplitPanes;

    public int TerminalPaneCount => IsTerminalOpen ? TerminalSplitPanes.Count + 1 : 0;

    public bool HasTerminalSplits => TerminalSplitPanes.Count > 0;

    public bool CanAddTerminalSplit =>
        IsConnected && IsTerminalOpen && !IsTelnetSession && TerminalSplitPanes.Count < 3;

    public int TerminalSplitOutputVersion => terminalSplitOutputVersion;

    public string TerminalStateLabel
    {
        get
        {
            if (terminalLease is not null)
            {
                return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"PTY {terminalLease.Size.Columns}x{terminalLease.Size.Rows}");
            }

            return HasHostKeyChallenge ? "等待主机密钥确认" : IsConnected ? "可打开终端" : "尚未连接";
        }
    }

    public string TerminalTitle => terminalLease is null
        ? "终端会话"
        : string.Concat(terminalLease.Host, ":", terminalLease.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));

    public string TerminalSubtitle => terminalLease is not null
        ? string.Concat(
            "终端通道 ",
            terminalLease.TerminalChannelId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            " · ",
            terminalLease.Size.Columns.ToString(System.Globalization.CultureInfo.InvariantCulture),
            " × ",
            terminalLease.Size.Rows.ToString(System.Globalization.CultureInfo.InvariantCulture))
        : HasHostKeyChallenge ? "请先确认这台服务器的主机密钥。"
        : IsConnected ? IsTelnetSession ? "Telnet 明文通道已建立。" : "SSH 已验证，可以安全地打开终端。"
        : "连接并验证服务器后即可开始。";

    public string TerminalEmptyStateLabel => HasHostKeyChallenge
        ? "等待主机密钥确认"
        : IsConnected ? "已准备就绪" : "尚未建立连接";

    public string TerminalEmptyStateDescription => HasHostKeyChallenge
        ? "确认主机密钥后，才能为此服务器打开终端。"
        : IsConnected ? "此服务器已完成验证。打开终端后即可运行命令。"
        : "先从左侧选择服务器并建立连接。";

    public string ActivitySummary => TerminalLines.Count == 0
        ? "暂无终端活动"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{TerminalLines.Count} 条终端事件");

    public bool HasTerminalOutput => TerminalLines.Count > 0;

    public string TerminalOutputSummary
    {
        get
        {
            if (TerminalLines.Count == 0)
            {
                return "暂无终端输出";
            }

            if (hiddenTerminalLineCount == 0)
            {
                return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已显示 {TerminalLines.Count} 行输出");
            }

            return string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"已显示 {TerminalLines.Count} 行，已收起 {hiddenTerminalLineCount} 行");
        }
    }

    public bool IsAutoScrollEnabled
    {
        get => isAutoScrollEnabled;
        set => SetProperty(ref isAutoScrollEnabled, value);
    }

    public void SaveTerminalScrollOffset(double offset)
    {
        if (SelectedWorkspaceTab is not null && double.IsFinite(offset) && offset >= 0)
        {
            SelectedWorkspaceTab.TerminalScrollOffset = offset;
        }
    }

    public string CommandHistorySummary => commandHistory.Count == 0
        ? "暂无命令历史"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"命令历史：{commandHistory.Count} 条");

    public string TerminalInputHint
    {
        get
        {
            if (!IsTerminalOpen)
            {
                return "打开终端后可输入命令";
            }

            return "可以输入命令";
        }
    }

    public bool IsSftpOpen => sftpLease is not null;

    public string SftpStateLabel => sftpLease is null
        ? "SFTP 未打开"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"SFTP 会话 {sftpLease.SftpSessionId}");

    public string SftpInspectorHint => !IsConnected
        ? "请先建立并验证 SSH 连接，再打开 SFTP。"
        : !IsSftpOpen ? "当前会话已验证；打开 SFTP 后可浏览和传输文件。"
        : SftpEntries.Count == 0 ? "当前目录尚无可显示的项目，或尚未列出目录。"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"当前目录已显示 {SftpEntries.Count} 个项目。");

    public string DockerInspectorHint => !IsConnected
        ? "请先建立并验证 SSH 连接，再读取容器信息。"
        : DockerContainers.Count == 0 ? "尚无容器数据。可使用“刷新容器”读取远端 Docker。"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已读取 {DockerContainers.Count} 个容器；选择一个容器后可查看日志或执行操作。");

    public string SftpStatus
    {
        get => sftpStatus;
        private set => SetProperty(ref sftpStatus, value);
    }

    public string SftpPathText
    {
        get => sftpPathText;
        set
        {
            if (SetProperty(ref sftpPathText, value))
            {
                RebuildSftpBreadcrumbs(value);
            }
        }
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

    public string SftpTransferStatus
    {
        get => sftpTransferStatus;
        private set => SetProperty(ref sftpTransferStatus, value);
    }

    public string SftpFeedbackTitle
    {
        get => sftpFeedbackTitle;
        private set => SetProperty(ref sftpFeedbackTitle, value);
    }

    public string SftpFeedbackMessage
    {
        get => sftpFeedbackMessage;
        private set => SetProperty(ref sftpFeedbackMessage, value);
    }

    public bool HasSftpFeedback => sftpFeedbackKind != SftpFeedbackKind.None;

    public bool IsSftpFeedbackInProgress => sftpFeedbackKind == SftpFeedbackKind.InProgress;

    public bool IsSftpFeedbackSuccess => sftpFeedbackKind == SftpFeedbackKind.Success;

    public bool IsSftpFeedbackWarning => sftpFeedbackKind == SftpFeedbackKind.Warning;

    public bool IsSftpFeedbackError => sftpFeedbackKind == SftpFeedbackKind.Error;

    public bool IsSftpFeedbackFadingOut
    {
        get => isSftpFeedbackFadingOut;
        private set => SetProperty(ref isSftpFeedbackFadingOut, value);
    }

    public bool HasRecentSftpOperations => RecentSftpOperations.Count > 0;

    public string RecentSftpOperationSummary => RecentSftpOperations.Count == 0
        ? "本次运行尚无 SFTP 操作记录"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"本次运行最近 {RecentSftpOperations.Count} 条 SFTP 操作");

    public bool CanRetryLastSftpTransfer
    {
        get
        {
            var context = GetCurrentSftpTransferContext();
            return (context.LastTransferRetry is not null || context.LastBatchRetry is not null) &&
                sftpLease is not null &&
                !context.IsBatchRunning;
        }
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

    private void PublishSftpFeedback(
        SftpFeedbackKind kind,
        string title,
        string message)
    {
        sftpFeedbackGeneration++;
        sftpFeedbackKind = kind;
        IsSftpFeedbackFadingOut = false;
        SftpFeedbackTitle = title;
        SftpFeedbackMessage = message;
        NotifySftpFeedbackChanged();

        if (kind is SftpFeedbackKind.Success or SftpFeedbackKind.Warning or SftpFeedbackKind.Error)
        {
            AddRecentSftpOperation(kind, title, message);
            var visibleDuration = kind switch
            {
                SftpFeedbackKind.Success => TimeSpan.FromSeconds(3),
                SftpFeedbackKind.Warning => TimeSpan.FromSeconds(4),
                _ => TimeSpan.FromSeconds(5),
            };
            _ = AutoDismissSftpFeedbackAsync(sftpFeedbackGeneration, visibleDuration);
        }
    }

    private async Task AutoDismissSftpFeedbackAsync(int generation, TimeSpan visibleDuration)
    {
        await Task.Delay(visibleDuration).ConfigureAwait(true);
        if (generation == sftpFeedbackGeneration &&
            sftpFeedbackKind is SftpFeedbackKind.Success or SftpFeedbackKind.Warning or SftpFeedbackKind.Error)
        {
            IsSftpFeedbackFadingOut = true;
            await Task.Delay(TimeSpan.FromMilliseconds(180)).ConfigureAwait(true);
            if (generation == sftpFeedbackGeneration)
            {
                ClearSftpFeedback();
            }
        }
    }

    private void AddRecentSftpOperation(SftpFeedbackKind kind, string title, string message)
    {
        var kindText = kind switch
        {
            SftpFeedbackKind.Success => "成功",
            SftpFeedbackKind.Warning => "注意",
            _ => "失败",
        };
        var contextText = SelectedAsset?.Name ?? SelectedWorkspaceTab?.Title ?? "当前会话";
        RecentSftpOperations.Insert(
            0,
            new SftpRecentOperationViewModel(
                utcNow().ToLocalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture),
                contextText,
                kindText,
                title,
                message));
        while (RecentSftpOperations.Count > MaximumRecentSftpOperations)
        {
            RecentSftpOperations.RemoveAt(RecentSftpOperations.Count - 1);
        }

        OnPropertyChanged(nameof(HasRecentSftpOperations));
        OnPropertyChanged(nameof(RecentSftpOperationSummary));
    }

    private void ClearSftpFeedback()
    {
        sftpFeedbackGeneration++;
        sftpFeedbackKind = SftpFeedbackKind.None;
        IsSftpFeedbackFadingOut = false;
        SftpFeedbackTitle = string.Empty;
        SftpFeedbackMessage = string.Empty;
        NotifySftpFeedbackChanged();
    }

    private void NotifySftpFeedbackChanged()
    {
        OnPropertyChanged(nameof(HasSftpFeedback));
        OnPropertyChanged(nameof(IsSftpFeedbackInProgress));
        OnPropertyChanged(nameof(IsSftpFeedbackSuccess));
        OnPropertyChanged(nameof(IsSftpFeedbackWarning));
        OnPropertyChanged(nameof(IsSftpFeedbackError));
    }

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
                return "尚未打开 SFTP";
            }

            return SftpEntries.Count == 0
                ? "当前目录为空"
                : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{SftpEntries.Count} 个项目");
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

    public string SystemOverviewSummary
    {
        get => systemOverviewSummary;
        private set => SetProperty(ref systemOverviewSummary, value);
    }

    public string MonitorTrendStatus
    {
        get => monitorTrendStatus;
        private set => SetProperty(ref monitorTrendStatus, value);
    }

    public string MonitorTrendRange
    {
        get => monitorTrendRange;
        set
        {
            var normalized = MonitorTrendRangeOptions.Contains(value, StringComparer.Ordinal)
                ? value
                : "10 分钟";
            if (SetProperty(ref monitorTrendRange, normalized))
            {
                UpdateMonitorTrendMetrics();
            }
        }
    }

    public bool IsMonitorAutoRefreshEnabled
    {
        get => isMonitorAutoRefreshEnabled;
        set
        {
            if (SetProperty(ref isMonitorAutoRefreshEnabled, value))
            {
                OnPropertyChanged(nameof(MonitorRefreshModeStatus));
            }
        }
    }

    public string MonitorRefreshModeStatus => IsMonitorAutoRefreshEnabled
        ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"自动刷新已开启 · {monitorRefreshIntervalSeconds} 秒")
        : "自动刷新已暂停";

    public string MonitorRefreshInterval
    {
        get => $"{monitorRefreshIntervalSeconds} 秒";
        set
        {
            if (!int.TryParse(value.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(), out var seconds))
            {
                return;
            }

            seconds = Math.Clamp(seconds, 1, 10);
            if (monitorRefreshIntervalSeconds != seconds)
            {
                monitorRefreshIntervalSeconds = seconds;
                OnPropertyChanged();
                OnPropertyChanged(nameof(MonitorRefreshModeStatus));
            }
        }
    }

    public string MonitorLoadStatus
    {
        get => monitorLoadStatus;
        private set => SetProperty(ref monitorLoadStatus, value);
    }

    public int MonitorTrendPointCount => GetVisibleMonitorHistory().Count;

    public string RemoteProcessStatus
    {
        get => remoteProcessStatus;
        private set => SetProperty(ref remoteProcessStatus, value);
    }

    public string DockerStatus
    {
        get => dockerStatus;
        private set
        {
            if (SetProperty(ref dockerStatus, value))
            {
                OnPropertyChanged(nameof(DockerInspectorHint));
            }
        }
    }

    public string DockerSummary
    {
        get => dockerSummary;
        private set
        {
            if (SetProperty(ref dockerSummary, value))
            {
                OnPropertyChanged(nameof(DockerInspectorHint));
            }
        }
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

    public string DockerFeedbackTitle
    {
        get => dockerFeedbackTitle;
        private set => SetProperty(ref dockerFeedbackTitle, value);
    }

    public string DockerFeedbackMessage
    {
        get => dockerFeedbackMessage;
        private set => SetProperty(ref dockerFeedbackMessage, value);
    }

    public bool HasDockerFeedback => dockerFeedbackKind != DockerFeedbackKind.None;

    public bool IsDockerFeedbackInProgress => dockerFeedbackKind == DockerFeedbackKind.InProgress;

    public bool IsDockerFeedbackSuccess => dockerFeedbackKind == DockerFeedbackKind.Success;

    public bool IsDockerFeedbackWarning => dockerFeedbackKind == DockerFeedbackKind.Warning;

    public bool IsDockerFeedbackError => dockerFeedbackKind == DockerFeedbackKind.Error;

    public bool IsDockerFeedbackFadingOut
    {
        get => isDockerFeedbackFadingOut;
        private set => SetProperty(ref isDockerFeedbackFadingOut, value);
    }

    public bool HasRecentDockerOperations => RecentDockerOperations.Count > 0;

    public string RecentDockerOperationSummary => RecentDockerOperations.Count == 0
        ? "本次运行尚无 Docker 操作记录"
        : string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"本次运行最近 {RecentDockerOperations.Count} 条 Docker 操作");

    public string BatchCommandText
    {
        get => batchCommandText;
        set
        {
            if (SetProperty(ref batchCommandText, value))
            {
                OnPropertyChanged(nameof(BatchCommandGuidance));
                RunBatchCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BatchCommandGuidance => IsBatchContinuousMode
        ? "持续任务为每台资产打开独立 PTY，实时显示输出；可单独停止，也会在设定时限自动结束。"
        : IsPotentiallyContinuousBatchCommand(BatchCommandText)
            ? "检测到持续或交互式命令：请启用持续任务模式，否则会等待命令退出后才返回结果。"
            : "适合执行会自行结束的一次性命令；每台资产的结果彼此隔离。";

    public bool IsBatchContinuousMode
    {
        get => isBatchContinuousMode;
        set
        {
            if (!SetProperty(ref isBatchContinuousMode, value))
            {
                return;
            }
            BatchResultViewIndex = value ? 1 : 0;
            OnPropertyChanged(nameof(BatchCommandGuidance));
            RunBatchCommand.RaiseCanExecuteChanged();
        }
    }

    public int BatchContinuousTimeoutMinutes
    {
        get => batchContinuousTimeoutMinutes;
        set => SetProperty(ref batchContinuousTimeoutMinutes, Math.Clamp(value, 1, 120));
    }

    public int BatchResultViewIndex
    {
        get => batchResultViewIndex;
        set => SetProperty(ref batchResultViewIndex, Math.Clamp(value, 0, 1));
    }

    public BatchContinuousSessionViewModel? SelectedBatchContinuousSession
    {
        get => selectedBatchContinuousSession;
        set => SetProperty(ref selectedBatchContinuousSession, value);
    }

    public bool HasActiveBatchContinuousSessions => batchContinuousRuntimes.Count > 0;

    public string BatchContinuousSummary
    {
        get
        {
            var active = BatchContinuousSessions.Count(session => session.IsRunning);
            return BatchContinuousSessions.Count == 0
                ? "尚无持续任务"
                : string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"持续任务 {BatchContinuousSessions.Count} 项 · 运行中 {active} 项");
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

    public string FilteredBatchOutputText
    {
        get => filteredBatchOutputText;
        private set => SetProperty(ref filteredBatchOutputText, value);
    }

    public string BatchResultQuery
    {
        get => batchResultQuery;
        set
        {
            if (SetProperty(ref batchResultQuery, value))
            {
                RefreshBatchResultFilter();
            }
        }
    }

    public bool ShowOnlyFailedBatchResults
    {
        get => showOnlyFailedBatchResults;
        set
        {
            if (SetProperty(ref showOnlyFailedBatchResults, value))
            {
                RefreshBatchResultFilter();
            }
        }
    }

    public string BatchResultFilterSummary
    {
        get
        {
            var failed = BatchCommandReceipts.Count(static receipt => !receipt.IsSuccess);
            return string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"显示 {FilteredBatchCommandReceipts.Count} / {BatchCommandReceipts.Count} 项 · 失败 {failed} 项");
        }
    }

    public string CreateBatchResultExport(bool csv)
    {
        var receipts = FilteredBatchCommandReceipts.Count > 0 ||
            BatchResultQuery.Length > 0 || ShowOnlyFailedBatchResults
            ? FilteredBatchCommandReceipts
            : BatchCommandReceipts;
        if (!csv)
        {
            return string.Join(Environment.NewLine + Environment.NewLine, receipts.Select(static receipt => receipt.DisplayText));
        }

        static string Quote(string value) => string.Concat("\"", value.Replace("\"", "\"\"", StringComparison.Ordinal), "\"");
        var rows = new List<string>(receipts.Count + 1) { "asset,endpoint,status,output" };
        rows.AddRange(receipts.Select(receipt => string.Join(",",
            Quote(receipt.Name), Quote(receipt.Endpoint), Quote(receipt.Status), Quote(receipt.Output))));
        return string.Join(Environment.NewLine, rows);
    }

    public string BatchProgressText
    {
        get => batchProgressText;
        private set => SetProperty(ref batchProgressText, value);
    }

    public string BatchCurrentTarget
    {
        get => batchCurrentTarget;
        private set => SetProperty(ref batchCurrentTarget, value);
    }

    public int BatchCompletedCount
    {
        get => batchCompletedCount;
        private set
        {
            if (SetProperty(ref batchCompletedCount, value))
            {
                OnPropertyChanged(nameof(BatchProgressValue));
            }
        }
    }

    public int BatchTotalCount
    {
        get => batchTotalCount;
        private set
        {
            if (SetProperty(ref batchTotalCount, value))
            {
                OnPropertyChanged(nameof(BatchProgressMaximum));
            }
        }
    }

    public int BatchSucceededCount
    {
        get => batchSucceededCount;
        private set => SetProperty(ref batchSucceededCount, value);
    }

    public double BatchProgressValue => BatchCompletedCount;

    public double BatchProgressMaximum => Math.Max(1, BatchTotalCount);

    public string BatchTargetSummary
    {
        get
        {
            var available = BatchAssetTargets.Count;
            var selected = BatchAssetTargets.Count(target => target.IsSelected);
            return available == 0
                ? "资产库中尚无可用于批量命令的 SSH 资产。"
                : string.Create(System.Globalization.CultureInfo.InvariantCulture,
                    $"已选择 {selected} / {available} 个 SSH 资产；未连接资产将在执行时安全连接。");
        }
    }

    public string BatchTargetFilterSummary => FilteredBatchAssetTargets.Count == 0
        ? "当前筛选没有匹配资产"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $"当前显示 {FilteredBatchAssetTargets.Count} 台；勾选需要执行的资产即可");

    public string BatchTargetQuery
    {
        get => batchTargetQuery;
        set
        {
            if (SetProperty(ref batchTargetQuery, value))
            {
                RefreshBatchTargetFilter();
            }
        }
    }

    public string SelectedBatchTargetGroup
    {
        get => selectedBatchTargetGroup;
        set
        {
            var normalized = string.IsNullOrWhiteSpace(value) ? AllBatchTargetGroups : value;
            if (!SetProperty(ref selectedBatchTargetGroup, normalized))
            {
                return;
            }
            RefreshBatchTargetFilter();
        }
    }

    public string SnippetStatus
    {
        get => snippetStatus;
        private set => SetProperty(ref snippetStatus, value);
    }

    public AsyncRelayCommand LoadAssetsCommand { get; }

    public AsyncRelayCommand LoadAccountSessionCommand { get; }

    public AsyncRelayCommand CheckCredentialHealthCommand { get; }

    public AsyncRelayCommand LoadSnippetsCommand { get; }

    public AsyncRelayCommand SaveLatestCommandAsSnippetCommand { get; }

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

    public AsyncRelayCommand AddTerminalSplitCommand { get; }

    public AsyncRelayCommand RemoveLastTerminalSplitCommand { get; }

    public AsyncRelayCommand OpenSftpCommand { get; }

    public AsyncRelayCommand RefreshMonitorSnapshotCommand { get; }

    public AsyncRelayCommand RefreshDockerContainersCommand { get; }

    public AsyncRelayCommand RefreshDockerStatsCommand { get; }

    public AsyncRelayCommand PreviewDockerLogsCommand { get; }

    public AsyncRelayCommand StartDockerContainerCommand { get; }

    public AsyncRelayCommand StopDockerContainerCommand { get; }

    public AsyncRelayCommand RestartDockerContainerCommand { get; }

    public AsyncRelayCommand PauseDockerContainerCommand { get; }

    public AsyncRelayCommand UnpauseDockerContainerCommand { get; }

    public AsyncRelayCommand KillDockerContainerCommand { get; }

    public AsyncRelayCommand RemoveDockerContainerCommand { get; }

    public AsyncRelayCommand RunBatchCommand { get; }

    public AsyncRelayCommand CancelBatchCommand { get; }

    public AsyncRelayCommand DeleteSnippetCommand { get; }

    public AsyncRelayCommand InsertSnippetCommand { get; }

    public AsyncRelayCommand ExecuteSnippetCommand { get; }

    public AsyncRelayCommand PrepareSftpBrowseCommand { get; }

    public AsyncRelayCommand RefreshSftpBrowseCommand { get; }

    public AsyncRelayCommand GoParentSftpCommand { get; }

    public AsyncRelayCommand OpenSelectedSftpEntryCommand { get; }

    public AsyncRelayCommand PreviewSftpTextCommand { get; }

    public AsyncRelayCommand RetryLastSftpTransferCommand { get; }

    public AsyncRelayCommand CancelSftpBatchCommand { get; }

    public AsyncRelayCommand ClearCompletedSftpTransfersCommand { get; }

    public AsyncRelayCommand SendCommand { get; }

    public AsyncRelayCommand CloseTerminalCommand { get; }

    public AsyncRelayCommand ClearTerminalCommand { get; }

    public AsyncRelayCommand PreviousCommandHistoryCommand { get; }

    public AsyncRelayCommand NextCommandHistoryCommand { get; }

    public void RefreshBatchTargetSelection()
    {
        SelectedBatchAssetTargets.Clear();
        foreach (var target in BatchAssetTargets.Where(target => target.IsSelected))
        {
            SelectedBatchAssetTargets.Add(target);
        }
        foreach (var tab in WorkspaceTabs)
        {
            tab.IsBatchTargetSelected = BatchAssetTargets.Any(target =>
                target.AssetId == tab.AssetId && target.IsSelected);
        }
        OnPropertyChanged(nameof(BatchTargetSummary));
        RunBatchCommand.RaiseCanExecuteChanged();
    }

    public void SelectFilteredBatchTargets(bool isSelected)
    {
        foreach (var target in FilteredBatchAssetTargets)
        {
            target.IsSelected = isSelected;
        }
        RefreshBatchTargetSelection();
    }

    public void UnselectBatchTarget(Guid assetId)
    {
        var target = BatchAssetTargets.FirstOrDefault(candidate => candidate.AssetId == assetId);
        if (target is null)
        {
            return;
        }
        target.IsSelected = false;
        RefreshBatchTargetSelection();
    }

    private void RefreshBatchAssetTargets()
    {
        var selectedIds = BatchAssetTargets
            .Where(target => target.IsSelected)
            .Select(target => target.AssetId)
            .ToHashSet();
        BatchAssetTargets.Clear();
        foreach (var asset in Assets
                     .Where(asset => asset.Transport == ServerTransport.Ssh && CanAccessAsset(asset))
                     .OrderBy(asset => asset.Group, StringComparer.OrdinalIgnoreCase)
                     .ThenBy(asset => asset.Name, StringComparer.OrdinalIgnoreCase))
        {
            var connected = FindVerifiedBatchWorkspace(asset.Id) is not null;
            var hasCredential = GetCredentialAvailability(asset.CredentialId) == CredentialAvailability.Available;
            BatchAssetTargets.Add(new BatchAssetTargetViewModel(
                asset.Id,
                asset.Name,
                string.Concat(asset.Username, "@", asset.Endpoint),
                string.IsNullOrWhiteSpace(asset.Group) ? "未分组" : asset.Group,
                selectedIds.Contains(asset.Id),
                connected,
                connected ? "已连接" : hasCredential ? "可自动连接" : "缺少本机凭据"));
        }
        foreach (var tab in WorkspaceTabs
                     .Where(IsVerifiedBatchTarget)
                     .Where(tab => BatchAssetTargets.All(target => target.AssetId != tab.AssetId)))
        {
            BatchAssetTargets.Add(new BatchAssetTargetViewModel(
                tab.AssetId,
                tab.Title,
                tab.Endpoint,
                "当前会话",
                selectedIds.Contains(tab.AssetId) || tab.IsBatchTargetSelected,
                true,
                "已连接 · 尚未保存资产"));
        }
        RefreshBatchTargetFilter();
        RefreshBatchTargetSelection();
    }

    private void RefreshBatchTargetFilter()
    {
        var query = BatchTargetQuery.Trim();
        var filtered = BatchAssetTargets.Where(target =>
            (SelectedBatchTargetGroup == AllBatchTargetGroups ||
             string.Equals(target.Group, SelectedBatchTargetGroup, StringComparison.OrdinalIgnoreCase)) &&
            (query.Length == 0 ||
             target.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             target.Endpoint.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             target.Group.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             target.StateText.Contains(query, StringComparison.OrdinalIgnoreCase)));

        FilteredBatchAssetTargets.Clear();
        foreach (var target in filtered)
        {
            FilteredBatchAssetTargets.Add(target);
        }
        OnPropertyChanged(nameof(BatchTargetFilterSummary));
    }

    private void RefreshBatchResultFilter()
    {
        var query = BatchResultQuery.Trim();
        var filtered = BatchCommandReceipts.Where(receipt =>
            (!ShowOnlyFailedBatchResults || !receipt.IsSuccess) &&
            (query.Length == 0 ||
             receipt.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             receipt.Endpoint.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             receipt.Status.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             receipt.Output.Contains(query, StringComparison.OrdinalIgnoreCase)));

        FilteredBatchCommandReceipts.Clear();
        foreach (var receipt in filtered)
        {
            FilteredBatchCommandReceipts.Add(receipt);
        }
        FilteredBatchOutputText = BoundBatchOutput(string.Join(
            Environment.NewLine + Environment.NewLine,
            FilteredBatchCommandReceipts.Select(static receipt => receipt.DisplayText)));
        OnPropertyChanged(nameof(BatchResultFilterSummary));
    }

    private WorkspaceTabViewModel? FindVerifiedBatchWorkspace(Guid assetId) =>
        WorkspaceTabs.FirstOrDefault(tab => tab.AssetId == assetId && IsVerifiedBatchTarget(tab));

    private void RefreshBatchTargetGroups()
    {
        var groups = Assets.Where(CanAccessAsset)
            .Select(asset => string.IsNullOrWhiteSpace(asset.Group) ? "未分组" : asset.Group)
            .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToArray();
        BatchTargetGroups.Clear();
        BatchTargetGroups.Add(AllBatchTargetGroups);
        foreach (var group in groups) BatchTargetGroups.Add(group);
        if (!BatchTargetGroups.Contains(SelectedBatchTargetGroup)) SelectedBatchTargetGroup = AllBatchTargetGroups;
        RefreshBatchTargetFilter();
    }

    private async Task LoadSnippetsAsync(CancellationToken cancellationToken)
    {
        SnippetStatus = "正在加载快捷指令";
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
            SnippetStatus = "无法加载快捷指令";
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
            ? "暂无保存的快捷指令"
            : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已加载 {Snippets.Count} 条快捷指令");
    }

    private async Task SaveLatestCommandAsSnippetAsync(CancellationToken cancellationToken)
    {
        if (commandHistory.Count == 0)
        {
            SnippetStatus = "暂无可保存的终端历史";
            return;
        }

        var command = commandHistory[^1];
        var words = command.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(3);
        var title = string.Join(' ', words);
        if (string.IsNullOrWhiteSpace(title)) title = "终端历史";
        await SaveSnippetAsync(null, title, command, "历史", SnippetAssetScope.AllAssets, cancellationToken).ConfigureAwait(true);
        if (SnippetStatus == "快捷指令已创建") SnippetStatus = "已从终端历史保存快捷指令";
    }

    public async Task SaveSnippetAsync(
        Guid? id,
        string title,
        string command,
        string category,
        CancellationToken cancellationToken) =>
        await SaveSnippetAsync(id, title, command, category, null, cancellationToken).ConfigureAwait(true);

    public async Task SaveSnippetAsync(
        Guid? id,
        string title,
        string command,
        string category,
        SnippetAssetScope? assetScope,
        CancellationToken cancellationToken)
    {
        title = title.Trim();
        command = command.Trim();
        category = category.Trim();
        var normalizedScope = SnippetAssetScope.Normalize(assetScope);
        if (title.Length is < 1 or > 120 || command.Length is < 1 or > 8192 ||
            category.Length > 80 || command.Any(char.IsControl) ||
            (normalizedScope.IsRestricted && normalizedScope.AssetIds.Count == 0))
        {
            SnippetStatus = "快捷指令不符合要求，请检查标题、命令和分类长度";
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var existing = id is { } value ? Snippets.FirstOrDefault(item => item.Id == value) : null;
        var saved = new SnippetViewModel(
            existing?.Id ?? Guid.NewGuid(),
            title,
            command,
            category.Length == 0 ? "未分类" : category,
            existing?.CreatedAt ?? now,
            now,
            normalizedScope);
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
        SnippetStatus = existing is null ? "快捷指令已创建" : "快捷指令已更新";
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
        SnippetStatus = "快捷指令已删除";
    }

    private Task InsertSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (SelectedSnippet is { } selected)
        {
            if (!selected.AllowsAsset(draftAssetId))
            {
                SnippetStatus = "此快捷指令仅允许用于指定资产";
                return Task.CompletedTask;
            }
            if (SnippetVariableResolver.Extract(selected.Command).Count > 0)
            {
                SnippetStatus = "请先填充快捷指令变量，再插入终端";
                return Task.CompletedTask;
            }
            CommandText = selected.Command;
            SnippetStatus = "快捷指令已插入终端输入栏";
        }

        return Task.CompletedTask;
    }

    private async Task ExecuteSelectedSnippetAsync(CancellationToken cancellationToken)
    {
        if (SelectedSnippet is not { } selected || terminalLease is null)
        {
            return;
        }

        if (!selected.AllowsAsset(draftAssetId))
        {
            SnippetStatus = "此快捷指令仅允许用于指定资产";
            return;
        }

        if (SnippetVariableResolver.Extract(selected.Command).Count > 0)
        {
            SnippetStatus = "请先填充快捷指令变量，再发送到终端";
            return;
        }

        CommandText = selected.Command;
        await SendAsync(cancellationToken).ConfigureAwait(true);
        SnippetStatus = "快捷指令已发送到终端";
    }

    public void InsertResolvedSnippet(string command)
    {
        ValidateResolvedSnippet(command);
        CommandText = command;
        SnippetStatus = "已解析的快捷指令已插入终端输入栏";
    }

    /// <summary>
    /// Checks an already-resolved snippet against the active session before the
    /// Windows terminal surface writes it to the remote prompt. The caller only
    /// writes bytes when this succeeds, so a scoped snippet cannot leak to a
    /// different asset.
    /// </summary>
    public bool TryPrepareResolvedSnippetForTerminalInput(string command)
    {
        ValidateResolvedSnippet(command);
        if (terminalLease is null)
        {
            SnippetStatus = "请先打开终端，再插入快捷指令";
            return false;
        }

        if (SelectedSnippet is { } selected && !selected.AllowsAsset(draftAssetId))
        {
            SnippetStatus = "此快捷指令仅允许用于指定资产";
            return false;
        }

        CommandText = command;
        SnippetStatus = "快捷指令已写入终端提示符，可编辑后按 Enter 执行";
        return true;
    }

    public async Task ExecuteResolvedSnippetAsync(string command, CancellationToken cancellationToken)
    {
        ValidateResolvedSnippet(command);
        if (terminalLease is null)
        {
            SnippetStatus = "请先打开终端，再发送快捷指令";
            return;
        }

        CommandText = command;
        await SendAsync(cancellationToken).ConfigureAwait(true);
        SnippetStatus = "已解析的快捷指令已发送到终端";
    }

    public void PrepareBatchCommandWorkspace()
    {
        if (!RunBatchCommand.IsRunning && !HasActiveBatchContinuousSessions)
        {
            foreach (var target in BatchAssetTargets)
            {
                target.IsSelected = false;
            }
            selectedBatchTargetGroup = AllBatchTargetGroups;
            OnPropertyChanged(nameof(SelectedBatchTargetGroup));
            batchTargetQuery = string.Empty;
            OnPropertyChanged(nameof(BatchTargetQuery));
        }
        RefreshBatchTargetFilter();
        RefreshBatchTargetSelection();
        BatchStatus = BatchAssetTargets.Count > 0
            ? "输入命令并确认目标；未连接资产将在执行时安全连接"
            : "请先添加至少一个 SSH 资产";
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

    private void RefreshFilteredAssets()
    {
        var query = AssetSearchQuery.Trim();
        RefreshAssetGroupFilters();
        RefreshBatchTargetGroups();
        var filtered = Assets
            .Where(CanAccessAsset)
            .Where(asset => (AssetGroupFilter == "全部分组" ||
                asset.Group.Equals(AssetGroupFilter, StringComparison.OrdinalIgnoreCase)) &&
                (query.Length == 0 ||
                asset.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                asset.Host.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                asset.Username.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                asset.Endpoint.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                asset.Group.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                asset.Tags.Any(tag => tag.Contains(query, StringComparison.OrdinalIgnoreCase))))
            .OrderBy(asset => asset.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(asset => asset.Host, StringComparer.OrdinalIgnoreCase);

        FilteredAssets.Clear();
        foreach (var asset in filtered)
        {
            FilteredAssets.Add(asset);
        }

        AssetGroups.Clear();
        foreach (var group in filtered
                     .GroupBy(asset => asset.Group, StringComparer.OrdinalIgnoreCase)
                     .OrderBy(group => group.Key.Equals("未分组", StringComparison.OrdinalIgnoreCase) ? 1 : 0)
                     .ThenBy(group => group.Key, StringComparer.OrdinalIgnoreCase))
        {
            AssetGroups.Add(new AssetGroupViewModel(group.Key, group));
        }

        OnPropertyChanged(nameof(AssetListSummary));
        OnPropertyChanged(nameof(HasAssetSearchResults));
        OnPropertyChanged(nameof(AssetEmptyStateTitle));
        OnPropertyChanged(nameof(AssetEmptyStateDescription));
        RefreshBatchAssetTargets();
    }

    private void RefreshAssetGroupFilters()
    {
        var selectedGroup = AssetGroupFilter;
        AssetGroupFilters.Clear();
        AssetGroupFilters.Add("全部分组");
        foreach (var group in Assets.Where(CanAccessAsset)
                     .Select(asset => asset.Group)
                     .Distinct(StringComparer.OrdinalIgnoreCase)
                     .OrderBy(group => group.Equals("未分组", StringComparison.OrdinalIgnoreCase) ? 1 : 0)
                     .ThenBy(group => group, StringComparer.OrdinalIgnoreCase))
        {
            AssetGroupFilters.Add(group);
        }

        if (!AssetGroupFilters.Contains(selectedGroup, StringComparer.OrdinalIgnoreCase))
        {
            assetGroupFilter = "全部分组";
            OnPropertyChanged(nameof(AssetGroupFilter));
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
            SnippetStatus = "无法保存快捷指令";
            return false;
        }
    }

    private async Task LoadAssetsAsync(CancellationToken cancellationToken)
    {
        AssetEditorStatus = "正在加载本地资产";
        var selectedAssetId = SelectedAsset?.Id;
        var records = await assetStore.LoadAsync(cancellationToken).ConfigureAwait(true);
        Assets.Clear();
        credentialAvailabilityById.Clear();
        foreach (var record in records)
        {
            Assets.Add(AssetViewModel.FromRecord(record));
            credentialAvailabilityById[record.CredentialId] = await DetectCredentialAvailabilityAsync(
                record.CredentialId,
                cancellationToken).ConfigureAwait(true);
        }

        SelectedAsset = selectedAssetId is { } assetId
            ? Assets.FirstOrDefault(asset => asset.Id == assetId)
            : null;
        if (SelectedAsset is null)
        {
            ResetDraftAsset();
            SyncSelectedWorkspaceTabFromDraft();
            AssetEditorStatus = Assets.Count == 0
                ? "尚无本地资产"
                : string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"已加载 {Assets.Count} 台本地服务器；请选择资产以开始会话");
        }
        else
        {
            AssetEditorStatus = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"已加载 {Assets.Count} 台本地服务器");
        }

        RefreshFilteredAssets();

        NotifyCredentialAvailabilityChanged();
        NotifyWorkbenchStateChanged();
        RefreshCommands();
    }

    private async Task LoadAccountSessionAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (accountUnlockController is not null)
            {
                await accountUnlockController.LoadAsync(cancellationToken).ConfigureAwait(true);
                ApplyAccountState(accountUnlockController.State);
                return;
            }

            var session = await accountSessionStore.ReadAsync(cancellationToken).ConfigureAwait(true);
            if (session is null)
            {
                AccountLockState = OrbitTerm.Application.Accounts.AccountLockState.SignedOut;
                AccountStatus = "尚未登录。账户与同步尚未启用。";
            }
            else
            {
                // The later unlock flow will gate access to encrypted sync data.
                // Tokens remain in platform storage and are never rendered here.
                AccountLockState = OrbitTerm.Application.Accounts.AccountLockState.SignedInLocked;
                AccountStatus = "已登录，本机加密同步数据等待解锁。";
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            AccountLockState = OrbitTerm.Application.Accounts.AccountLockState.SignedOut;
            AccountStatus = "无法读取本机账户会话；请在账户功能启用后重新登录。";
        }
        finally
        {
            NotifyAccountStateChanged();
        }
    }

    public async Task<bool> SignInAccountAsync(string username, string password, CancellationToken cancellationToken)
    {
        if (accountUnlockController is null)
        {
            AccountStatus = "账户服务尚未配置，无法登录。";
            return false;
        }

        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password))
        {
            AccountStatus = "请输入账户名和密码。";
            return false;
        }

        try
        {
            await accountUnlockController.LoginAsync(new AccountLoginRequest(username, password), cancellationToken).ConfigureAwait(true);
            ApplyAccountState(accountUnlockController.State);
            AccountStatus = "登录成功。同步数据仍保持锁定，请输入主密码解锁。";
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            AccountStatus = "无法连接账户服务，请检查网络后重试。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            AccountStatus = "账户名或密码不正确。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is { } status && (int)status >= 500)
        {
            AccountStatus = "账户服务暂时不可用，请稍后重试。";
            return false;
        }
        catch (HttpRequestException)
        {
            AccountStatus = "登录请求未被接受，请检查账户信息后重试。";
            return false;
        }
        catch
        {
            AccountStatus = "登录未完成，请稍后重试。";
            return false;
        }
        finally
        {
            NotifyAccountStateChanged();
        }
    }

    public async Task<bool> RegisterAccountAsync(
        string username,
        string password,
        string inviteCode,
        CancellationToken cancellationToken)
    {
        if (accountUnlockController is null)
        {
            AccountStatus = "账户服务尚未配置，无法注册。";
            return false;
        }

        var canonicalUsername = username.Trim().ToLowerInvariant();
        if (!IsRegistrationEmail(canonicalUsername))
        {
            AccountStatus = "请输入有效的邮箱账号。";
            return false;
        }
        if (!IsStrongAccountPassword(password))
        {
            AccountStatus = "密码至少 12 位，并包含大小写字母、数字和特殊字符。";
            return false;
        }
        if (string.IsNullOrWhiteSpace(inviteCode))
        {
            AccountStatus = "请输入管理员提供的邀请码。";
            return false;
        }

        try
        {
            await accountUnlockController.RegisterAndLoginAsync(
                new AccountRegisterRequest(canonicalUsername, password, inviteCode),
                cancellationToken).ConfigureAwait(true);
            ApplyAccountState(accountUnlockController.State);
            AccountStatus = "注册并登录成功，请设置主密码。";
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            AccountStatus = "无法连接账户服务，请检查网络后重试。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            AccountStatus = "该邮箱已注册，请直接登录。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is System.Net.HttpStatusCode.BadRequest or System.Net.HttpStatusCode.Forbidden)
        {
            AccountStatus = "注册信息或邀请码未被接受，请检查后重试。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is { } status && (int)status >= 500)
        {
            AccountStatus = "账户服务暂时不可用，请稍后重试。";
            return false;
        }
        catch
        {
            AccountStatus = "注册未完成，请稍后重试。";
            return false;
        }
        finally
        {
            NotifyAccountStateChanged();
        }
    }

    public async Task<AccountUnlockResult> InitializeNewAccountMasterPasswordAsync(
        string masterPassword,
        string confirmation,
        CancellationToken cancellationToken)
    {
        if (accountUnlockController is null || !IsAccountSignedIn)
        {
            AccountStatus = "请先完成账户注册和登录。";
            return AccountUnlockResult.ServiceFailure;
        }
        if (masterPassword.Length < 12 || !string.Equals(masterPassword, confirmation, StringComparison.Ordinal))
        {
            AccountStatus = "主密码至少 12 位，且两次输入必须一致。";
            return AccountUnlockResult.InvalidMasterPassword;
        }

        var result = await accountUnlockController
            .InitializeEmptyAccountMasterPasswordAsync(masterPassword, cancellationToken)
            .ConfigureAwait(true);
        ApplyAccountState(accountUnlockController.State);
        if (result == AccountUnlockResult.Unlocked)
        {
            ReplaceSessionMasterPassword(masterPassword);
            AccountStatus = "主密码已设置，正在自动双向同步…";
            await SynchronizeEncryptedConfigsAsync(string.Empty, cancellationToken).ConfigureAwait(true);
        }
        else
        {
            AccountStatus = result switch
            {
                AccountUnlockResult.InvalidMasterPassword => "此账户已有本机或云端加密状态，未创建新的主密码。",
                AccountUnlockResult.NetworkUnavailable => "无法确认云端账户状态，请联网后重试。",
                _ => "暂时无法安全创建主密码，请稍后重试。",
            };
        }
        NotifyAccountStateChanged();
        return result;
    }

    private static bool IsRegistrationEmail(string value)
    {
        var parts = value.Split('@', StringSplitOptions.None);
        return parts.Length == 2 && parts[0].Length > 0 && parts[1].Length > 0;
    }

    private static bool IsStrongAccountPassword(string value) =>
        value.Length >= 12 &&
        value.Any(char.IsUpper) &&
        value.Any(char.IsLower) &&
        value.Any(char.IsDigit) &&
        value.Any(character => !char.IsLetterOrDigit(character) && !char.IsWhiteSpace(character));

    public async Task<AccountUnlockResult> UnlockAccountAsync(string masterPassword, CancellationToken cancellationToken)
    {
        if (accountUnlockController is null)
        {
            AccountStatus = "账户服务尚未配置，无法解锁。";
            return AccountUnlockResult.ServiceFailure;
        }

        if (string.IsNullOrEmpty(masterPassword))
        {
            AccountStatus = "请输入主密码。";
            return AccountUnlockResult.InvalidMasterPassword;
        }

        var result = await accountUnlockController.UnlockAsync(masterPassword, cancellationToken).ConfigureAwait(true);
        ApplyAccountState(accountUnlockController.State);
        if (result == AccountUnlockResult.Unlocked)
        {
            ReplaceSessionMasterPassword(masterPassword);
            await ClaimLegacyAccountAssetsAsync(cancellationToken).ConfigureAwait(true);
            AccountStatus = "已解锁，正在自动双向同步…";
            await SynchronizeEncryptedConfigsAsync(string.Empty, cancellationToken).ConfigureAwait(true);
            NotifyAccountStateChanged();
            return result;
        }
        AccountStatus = result switch
        {
            AccountUnlockResult.InvalidMasterPassword => "主密码不正确，数据仍保持锁定。",
            AccountUnlockResult.VerificationRequiresEncryptedConfig => "账户尚无可验证的加密配置，数据保持锁定。",
            AccountUnlockResult.NetworkUnavailable => "无法连接同步服务，请检查网络后重试。",
            _ => "同步服务暂时无法完成验证，数据仍保持锁定。",
        };
        NotifyAccountStateChanged();
        return result;
    }

    private async Task ClaimLegacyAccountAssetsAsync(CancellationToken cancellationToken)
    {
        var accountScope = CurrentAccountScope;
        if (string.IsNullOrWhiteSpace(accountScope))
        {
            return;
        }

        var changed = false;
        for (var index = 0; index < Assets.Count; index++)
        {
            var asset = Assets[index];
            if (asset.StorageScope != AssetStorageScope.AccountSynced ||
                !string.IsNullOrWhiteSpace(asset.OwnerAccountScope))
            {
                continue;
            }

            Assets[index] = asset with { OwnerAccountScope = accountScope };
            changed = true;
        }

        if (!changed)
        {
            return;
        }

        await assetStore.SaveAsync(
            Assets.Select(asset => asset.ToRecord()).ToArray(),
            cancellationToken).ConfigureAwait(true);
        RefreshFilteredAssets();
    }

    public async Task<EncryptedConfigSynchronizationResult?> SynchronizeEncryptedConfigsAsync(
        string masterPassword,
        CancellationToken cancellationToken,
        bool forceCompleteReconciliation = false)
    {
        if (accountUnlockController is null || encryptedConfigSynchronizer is null || !IsAccountUnlocked)
        {
            AccountStatus = "请先登录并解锁账户，再同步加密配置。";
            NotifyAccountStateChanged();
            return null;
        }

        var effectiveMasterPassword = ResolveSessionMasterPassword(masterPassword);
        if (effectiveMasterPassword is null)
        {
            AccountStatus = "本次启动尚未解锁，请重新打开应用并输入主密码。";
            return null;
        }

        var remoteChangesConfirmed = false;
        try
        {
            var result = await accountUnlockController
                .SynchronizeAsync(
                    encryptedConfigSynchronizer,
                    effectiveMasterPassword,
                    cancellationToken,
                    forceCompleteReconciliation)
                .ConfigureAwait(true);
            ApplyAccountState(accountUnlockController.State);
            if (result.Status == EncryptedConfigSynchronizationStatus.Completed)
            {
                remoteChangesConfirmed = true;
                await LoadAssetsAsync(cancellationToken).ConfigureAwait(true);
                await LoadSnippetsAsync(cancellationToken).ConfigureAwait(true);
                await accountUnlockController.QueueUnsyncedAssetsAsync(
                    encryptedAssetPublisher!,
                    Assets.Where(asset =>
                            asset.StorageScope == AssetStorageScope.AccountSynced &&
                            CanAccessAsset(asset))
                        .Select(asset => asset.Id)
                        .ToArray(),
                    cancellationToken).ConfigureAwait(true);
                var upload = await FlushQueuedAssetChangesAsync(effectiveMasterPassword, cancellationToken).ConfigureAwait(true);
                var snippetsPublished = 0;
                if (encryptedSnippetPublisher is not null)
                {
                    var snippetUpload = await accountUnlockController.PublishSnippetsAsync(
                        encryptedSnippetPublisher,
                        Snippets.Select(item => item.ToRecord()).ToArray(),
                        effectiveMasterPassword,
                        cancellationToken).ConfigureAwait(true);
                    snippetsPublished = snippetUpload.PublishedCount;
                }
                var snippetConflictText = result.ConflictedSnippets == 0
                    ? string.Empty
                    : $"；快捷指令存在 {result.ConflictedSnippets} 项本机优先冲突，请确认后再次同步";
                var sshKeyText = result.AppliedSshKeys == 0 && result.DeletedSshKeys == 0 && result.ConflictedSshKeys == 0
                    ? string.Empty
                    : $"，SSH 密钥下载/更新 {result.AppliedSshKeys} 把、删除 {result.DeletedSshKeys} 把、冲突 {result.ConflictedSshKeys} 把";
                AccountStatus = $"双向同步完成：下载新增 {result.AddedAssets} 项，更新 {result.UpdatedAssets} 项，删除 {result.DeletedAssets} 项；上传 {upload.Published} 项，删除墓碑 {upload.Deleted} 项，快捷指令 {snippetsPublished} 条{sshKeyText}，待确认冲突 {result.ConflictedAssets + upload.Conflicts + result.ConflictedSshKeys} 项{snippetConflictText}。";
            }
            else
            {
                AccountStatus = "发现此版本尚不能安全处理的加密配置；未确认远端变更。";
            }

            NotifyAccountStateChanged();
            return result;
        }
        catch (CryptographicException exception)
        {
            WriteSynchronizationDiagnostic("cryptographic_failure", exception, remoteChangesConfirmed);
            AccountStatus = remoteChangesConfirmed
                ? "云端变更已确认；本机待上传队列暂未完成，已安全保留并将在下次同步重试。"
                : "主密码不正确，未读取或确认新的同步数据。";
            return null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException exception)
        {
            WriteSynchronizationDiagnostic("network_failure", exception, remoteChangesConfirmed);
            if (remoteChangesConfirmed)
            {
                AccountStatus = "云端变更已确认；网络或同步服务暂时不可用，本机待上传队列已保留并将在下次同步重试。";
            }
            else if (exception.StatusCode is { } statusCode)
            {
                AccountStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"同步服务暂时不可用（HTTP {(int)statusCode}），本机变更已安全保留，请稍后重试。");
            }
            else
            {
                AccountStatus = "无法连接同步服务，未确认远端变更；本机变更已安全保留。";
            }
            return null;
        }
        catch (Exception exception)
        {
            WriteSynchronizationDiagnostic("sync_failure", exception, remoteChangesConfirmed);
            AccountStatus = remoteChangesConfirmed
                ? "云端变更已确认；部分本机变更暂未上传，队列已安全保留。"
                : "同步未完成，远端变更未被确认。";
            return null;
        }
    }

    public async Task PublishLocalAssetsAsync(string masterPassword, CancellationToken cancellationToken)
    {
        if (accountUnlockController is null || encryptedAssetPublisher is null || !IsAccountUnlocked)
        {
            AccountStatus = "请先登录并解锁账户，再发布本机资产。";
            return;
        }

        var effectiveMasterPassword = ResolveSessionMasterPassword(masterPassword);
        if (effectiveMasterPassword is null || !accountUnlockController.IsCurrentMasterPassword(effectiveMasterPassword))
        {
            AccountStatus = "主密码不正确，未上传任何资产。";
            return;
        }

        var published = 0;
        var conflicts = 0;
        var unavailableCredentials = 0;
        foreach (var asset in Assets
            .Where(item =>
                item.StorageScope == AssetStorageScope.AccountSynced &&
                CanAccessAsset(item))
            .Select(item => item.ToRecord())
            .ToArray())
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(true);
                var jumpHostCredential = asset.JumpHost is { } jumpHost
                    ? await credentialVault.ReadAsync(jumpHost.CredentialId, cancellationToken).ConfigureAwait(true)
                    : null;
                var outcome = await accountUnlockController
                    .PublishAssetAsync(encryptedAssetPublisher, asset, credential, jumpHostCredential, effectiveMasterPassword, cancellationToken)
                    .ConfigureAwait(true);
                switch (outcome.Status)
                {
                    case EncryptedAssetPublishStatus.Published:
                        published++;
                        break;
                    case EncryptedAssetPublishStatus.Conflict:
                        conflicts++;
                        break;
                    case EncryptedAssetPublishStatus.CredentialUnavailable:
                        unavailableCredentials++;
                        break;
                }
            }
            catch (HttpRequestException)
            {
                AccountStatus = $"已发布 {published} 项；网络或服务异常，剩余资产未上传。";
                return;
            }
        }

        AccountStatus = $"本机资产发布完成：已发布 {published} 项，冲突 {conflicts} 项，缺少凭据 {unavailableCredentials} 项。";
    }

    private async Task<QueuedAssetFlushResult> FlushQueuedAssetChangesAsync(
        string masterPassword,
        CancellationToken cancellationToken)
    {
        if (accountUnlockController is null || encryptedAssetPublisher is null)
        {
            return new QueuedAssetFlushResult(0, 0, 0, 0);
        }

        var operations = await accountUnlockController
            .ReadPendingAssetOperationsAsync(encryptedAssetPublisher, cancellationToken)
            .ConfigureAwait(true);
        if (operations.Count == 0)
        {
            return new QueuedAssetFlushResult(0, 0, 0, 0);
        }

        var currentAssets = Assets.Select(asset => asset.ToRecord()).ToDictionary(asset => asset.Id);
        var published = 0;
        var deleted = 0;
        var conflicts = 0;
        var unavailableCredentials = 0;
        foreach (var (assetId, operation) in operations.OrderBy(item => item.Value.QueuedAtUnix))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (operation.Kind == PendingAssetSyncOperationKind.Conflict)
            {
                conflicts++;
                continue;
            }

            try
            {
                if (operation.Kind == PendingAssetSyncOperationKind.Tombstone)
                {
                    var outcome = await accountUnlockController
                        .TombstoneAssetAsync(encryptedAssetPublisher, assetId, cancellationToken)
                        .ConfigureAwait(true);
                    if (outcome.Status is EncryptedAssetPublishStatus.Deleted or EncryptedAssetPublishStatus.LocalOnlyDeleted)
                    {
                        deleted++;
                    }
                    else if (outcome.Status == EncryptedAssetPublishStatus.Conflict)
                    {
                        conflicts++;
                    }

                    continue;
                }

                if (!currentAssets.TryGetValue(assetId, out var asset))
                {
                    // A subsequent local deletion replaces any earlier upsert intent.
                    await accountUnlockController
                        .QueueAssetTombstoneAsync(encryptedAssetPublisher, assetId, cancellationToken)
                        .ConfigureAwait(true);
                    continue;
                }

                if (asset.StorageScope == AssetStorageScope.LocalOnly ||
                    !string.Equals(asset.OwnerAccountScope, CurrentAccountScope, StringComparison.Ordinal))
                {
                    // A local-only or differently owned asset must never cross
                    // this account's encrypted synchronization boundary.
                    continue;
                }

                var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(true);
                var jumpHostCredential = asset.JumpHost is { } jumpHost
                    ? await credentialVault.ReadAsync(jumpHost.CredentialId, cancellationToken).ConfigureAwait(true)
                    : null;
                var publishedAsset = await accountUnlockController
                    .PublishAssetAsync(encryptedAssetPublisher, asset, credential, jumpHostCredential, masterPassword, cancellationToken)
                    .ConfigureAwait(true);
                switch (publishedAsset.Status)
                {
                    case EncryptedAssetPublishStatus.Published:
                        published++;
                        break;
                    case EncryptedAssetPublishStatus.Conflict:
                        conflicts++;
                        break;
                    case EncryptedAssetPublishStatus.CredentialUnavailable:
                        unavailableCredentials++;
                        break;
                }
            }
            catch (HttpRequestException)
            {
                // Keep all remaining intents in the DPAPI queue for the next explicit sync.
                break;
            }
        }

        return new QueuedAssetFlushResult(published, deleted, conflicts, unavailableCredentials);
    }

    private sealed record QueuedAssetFlushResult(int Published, int Deleted, int Conflicts, int UnavailableCredentials);

    public void LockAccount()
    {
        ClearSessionSecrets();
        accountUnlockController?.Lock();
        if (accountUnlockController is not null)
        {
            ApplyAccountState(accountUnlockController.State);
            AccountStatus = "已锁定。本机不会读取或同步加密配置。";
        }
    }

    public async Task<bool> ChangeAccountPasswordAsync(
        string currentPassword,
        string newPassword,
        string confirmation,
        CancellationToken cancellationToken)
    {
        if (accountUnlockController is null || !IsAccountSignedIn)
        {
            AccountStatus = "请先登录账户。";
            return false;
        }

        if (string.IsNullOrEmpty(currentPassword) || newPassword.Length < 12 || newPassword != confirmation)
        {
            AccountStatus = "请输入当前密码；新密码至少 12 位，且两次输入必须一致。";
            return false;
        }

        try
        {
            await accountUnlockController.ChangeLoginPasswordAsync(currentPassword, newPassword, cancellationToken).ConfigureAwait(true);
            AccountStatus = "已更新登录密码；其他设备需要重新登录。";
            return true;
        }
        catch (HttpRequestException exception) when (exception.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            AccountStatus = "当前登录密码不正确。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            AccountStatus = "无法连接账户服务，请检查网络后重试。";
            return false;
        }
        catch
        {
            AccountStatus = "登录密码未能更新，请稍后重试。";
            return false;
        }
        finally
        {
            NotifyAccountStateChanged();
        }
    }

    public async Task<bool> RotateMasterPasswordAsync(
        string currentMasterPassword,
        string newMasterPassword,
        string confirmation,
        string currentLoginPassword,
        CancellationToken cancellationToken)
    {
        if (accountUnlockController is null || !IsAccountUnlocked)
        {
            AccountStatus = "请先登录并解锁账户。";
            return false;
        }

        if (string.IsNullOrEmpty(currentMasterPassword) ||
            string.IsNullOrEmpty(currentLoginPassword) ||
            newMasterPassword.Length < 12 ||
            newMasterPassword != confirmation ||
            newMasterPassword == currentMasterPassword)
        {
            AccountStatus = "请完整填写密码；新主密码至少 12 位、两次输入一致且不能与当前主密码相同。";
            return false;
        }

        try
        {
            AccountStatus = "正在读取并重新加密完整云端配置，请勿关闭应用…";
            await accountUnlockController.RotateMasterPasswordAsync(
                currentMasterPassword,
                newMasterPassword,
                currentLoginPassword,
                cancellationToken).ConfigureAwait(true);
            ReplaceSessionMasterPassword(newMasterPassword);
            AccountStatus = "已完成主密码轮换；其他设备需要使用新主密码重新解锁。";
            return true;
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            AccountStatus = "当前主密码不正确。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            AccountStatus = "当前登录密码不正确。";
            return false;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            AccountStatus = "网络不可用，主密码未在本机确认更改；请重新解锁确认账户状态。";
            return false;
        }
        catch
        {
            AccountStatus = "主密码轮换未完成。云端数据未被本机确认修改，请先重新同步后再试。";
            return false;
        }
        finally
        {
            NotifyAccountStateChanged();
        }
    }

    public async Task SignOutAccountAsync(CancellationToken cancellationToken)
    {
        await ResetAllWorkspaceSessionsForAccountTransitionAsync(cancellationToken).ConfigureAwait(true);
        await StopAllBatchContinuousSessionsAsync("账户已退出，持续任务已停止").ConfigureAwait(true);
        ClearSessionSecrets();
        if (accountUnlockController is not null)
        {
            await accountUnlockController.SignOutAsync(cancellationToken).ConfigureAwait(true);
            ApplyAccountState(accountUnlockController.State);
        }
    }

    private async Task ResetAllWorkspaceSessionsForAccountTransitionAsync(CancellationToken cancellationToken)
    {
        foreach (var tab in WorkspaceTabs.ToArray())
        {
            cancellationToken.ThrowIfCancellationRequested();
            SelectedWorkspaceTab = tab;
            if (HasActiveRuntime)
            {
                await EndSessionCoreAsync(cancellationToken, "账户状态变化，会话已安全断开").ConfigureAwait(true);
            }
        }

        foreach (var context in sftpTransferContexts.Values)
        {
            context.BatchCancellation?.Cancel();
            context.BatchCancellation?.Dispose();
        }
        sftpTransferContexts.Clear();
        WorkspaceTabs.Clear();
        SelectedAsset = null;
        ResetDraftAsset();
        var replacement = CreateWorkspaceTabFromDraft();
        WorkspaceTabs.Add(replacement);
        selectedWorkspaceTab = replacement;
        OnPropertyChanged(nameof(SelectedWorkspaceTab));
        RestoreRuntimeStateFromWorkspaceTab(replacement);
        RestoreSftpTransferContext(replacement);
        OnPropertyChanged(nameof(WorkspaceTabSummary));
        RefreshCommands();
    }

    private void ApplyAccountState(AccountLockState state)
    {
        AccountLockState = state;
        AccountStatus = state switch
        {
            OrbitTerm.Application.Accounts.AccountLockState.SignedOut => "尚未登录。不会自动联网。",
            OrbitTerm.Application.Accounts.AccountLockState.SignedInLocked => "已登录，本机加密同步数据等待解锁。",
            OrbitTerm.Application.Accounts.AccountLockState.SignedInUnlocked => "已解锁。加密同步数据可用。",
            _ => "账户状态未知。",
        };
        if (SelectedAsset is not null && !CanAccessAsset(SelectedAsset))
        {
            SelectedAsset = null;
        }
        RefreshFilteredAssets();
        NotifyAccountStateChanged();
    }

    private void NotifyAccountStateChanged()
    {
        OnPropertyChanged(nameof(IsAccountSignedIn));
        OnPropertyChanged(nameof(AccountEntryLabel));
        OnPropertyChanged(nameof(IsAccountLocked));
        OnPropertyChanged(nameof(IsAccountUnlocked));
        OnPropertyChanged(nameof(AccountUsername));
        OnPropertyChanged(nameof(AssetSynchronizationStatus));
    }

    public void ClearSessionSecrets()
    {
        CancelAutomaticReconnect();
        if (sessionMasterPasswordUtf8 is { } buffer)
        {
            CryptographicOperations.ZeroMemory(buffer);
            sessionMasterPasswordUtf8 = null;
        }
    }

    private void ReplaceSessionMasterPassword(string masterPassword)
    {
        ClearSessionSecrets();
        sessionMasterPasswordUtf8 = System.Text.Encoding.UTF8.GetBytes(masterPassword);
    }

    private static void WriteSynchronizationDiagnostic(
        string stage,
        Exception exception,
        bool remoteChangesConfirmed)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OrbitTerm",
                "diagnostics");
            Directory.CreateDirectory(directory);
            var statusCode = exception is HttpRequestException { StatusCode: { } status }
                ? ((int)status).ToString(System.Globalization.CultureInfo.InvariantCulture)
                : "none";
            var jsonLocation = exception is JsonException jsonException
                ? string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"{jsonException.Path ?? "unknown"}:{jsonException.LineNumber?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "?"}:{jsonException.BytePositionInLine?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "?"}")
                : "none";
            File.AppendAllText(
                Path.Combine(directory, "sync.log"),
                string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"{DateTimeOffset.UtcNow:O} stage={stage}; type={exception.GetType().FullName}; hresult=0x{exception.HResult:X8}; status={statusCode}; json_location={jsonLocation}; remote_confirmed={remoteChangesConfirmed}{Environment.NewLine}"));
        }
        catch (IOException)
        {
            // A diagnostic must never change the synchronization outcome.
        }
        catch (UnauthorizedAccessException)
        {
            // The user-facing state remains accurate even when diagnostics are unavailable.
        }
    }

    private static void WriteSftpTransferDiagnostic(string direction, Exception exception)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OrbitTerm",
                "diagnostics");
            Directory.CreateDirectory(directory);
            File.AppendAllText(
                Path.Combine(directory, "sftp-transfer.log"),
                string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"{DateTimeOffset.UtcNow:O} direction={direction}; type={exception.GetType().FullName}; hresult=0x{exception.HResult:X8}{Environment.NewLine}"));
        }
        catch (IOException)
        {
            // Transfer diagnostics must never alter queue state.
        }
        catch (UnauthorizedAccessException)
        {
            // The queue still exposes a safe retry state when logging is unavailable.
        }
    }

    private string? ResolveSessionMasterPassword(string supplied)
    {
        if (!string.IsNullOrEmpty(supplied))
        {
            return supplied;
        }

        return sessionMasterPasswordUtf8 is { Length: > 0 } buffer
            ? System.Text.Encoding.UTF8.GetString(buffer)
            : null;
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
        var closingTab = SelectedWorkspaceTab;
        var index = WorkspaceTabs.IndexOf(closingTab);
        WorkspaceTabs.Remove(closingTab);
        if (sftpTransferContexts.Remove(closingTab.Id, out var closingTransferContext))
        {
            closingTransferContext.BatchCancellation?.Cancel();
            closingTransferContext.BatchCancellation?.Dispose();
        }
        if (WorkspaceTabs.Count == 0)
        {
            ResetDraftAsset();
            var replacement = CreateWorkspaceTabFromDraft();
            WorkspaceTabs.Add(replacement);
            selectedWorkspaceTab = replacement;
            OnPropertyChanged(nameof(SelectedWorkspaceTab));
            RestoreRuntimeStateFromWorkspaceTab(replacement);
            RestoreSftpTransferContext(replacement);
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
        AssetEditorStatus = "新服务器草稿";
        SyncSelectedWorkspaceTabFromDraft();
        NotifyCredentialAvailabilityChanged();
        NotifyWorkbenchStateChanged();
        RefreshCommands();
        return Task.CompletedTask;
    }

    public async Task SaveCurrentAssetAsync(CancellationToken cancellationToken)
    {
        var validationError = ValidateAssetEditorInput(
            AssetName,
            Host,
            PortText,
            Username,
            AssetGroup,
            AssetTagsText);
        if (validationError is not null)
        {
            AssetEditorStatus = validationError;
            return;
        }
        var jumpValidationError = ValidateJumpHostInput(IsJumpHostEnabled, JumpHost, JumpPortText, JumpUsername);
        if (jumpValidationError is not null)
        {
            AssetEditorStatus = jumpValidationError;
            return;
        }

        var record = CreateCurrentAssetRecord();
        if (record is null)
        {
            AssetEditorStatus = "服务器信息尚未填写完整";
            RefreshCommands();
            return;
        }

        var existing = Assets.FirstOrDefault(asset => asset.Id == record.Id);
        var previousJumpCredentialId = existing?.JumpHost?.CredentialId;
        var previousStorageScope = existing?.StorageScope;
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
        if (!string.IsNullOrWhiteSpace(Password) || !string.IsNullOrWhiteSpace(PrivateKey))
        {
            try
            {
                var credential = CredentialMaterialPolicy.NormalizeSshCredential(
                    new CredentialMaterial(Password, PrivateKey, PrivateKeyPassphrase));
                await credentialVault.SaveAsync(
                    draftCredentialId,
                    credential,
                    cancellationToken).ConfigureAwait(true);
                credentialAvailabilityById[draftCredentialId] = CredentialAvailability.Available;
                Password = PrivateKey = PrivateKeyPassphrase = string.Empty;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                credentialAvailabilityById[draftCredentialId] = CredentialAvailability.Unavailable;
                AssetEditorStatus = "资产已保存，但无法保存本机凭据；请重新输入凭据后重试。";
                NotifyCredentialAvailabilityChanged();
                return;
            }
        }

        if (record.JumpHost is { } jump &&
            (!string.IsNullOrWhiteSpace(JumpPassword) || !string.IsNullOrWhiteSpace(JumpPrivateKey)))
        {
            try
            {
                var jumpCredential = CredentialMaterialPolicy.NormalizeSshCredential(
                    new CredentialMaterial(JumpPassword, JumpPrivateKey, JumpPrivateKeyPassphrase));
                await credentialVault.SaveAsync(
                    jump.CredentialId,
                    jumpCredential,
                    cancellationToken).ConfigureAwait(true);
                JumpPassword = JumpPrivateKey = JumpPrivateKeyPassphrase = string.Empty;
            }
            catch (OperationCanceledException) { throw; }
            catch
            {
                AssetEditorStatus = "资产已保存，但无法保存跳板机凭据；请重新输入后重试。";
                return;
            }
        }
        if (record.JumpHost is null && previousJumpCredentialId is { } removedJumpCredentialId)
        {
            await credentialVault.DeleteAsync(removedJumpCredentialId, cancellationToken).ConfigureAwait(true);
        }

        SelectedAsset = viewModel;
        if (record.StorageScope == AssetStorageScope.LocalOnly)
        {
            if (previousStorageScope == AssetStorageScope.AccountSynced &&
                IsAccountSignedIn && accountUnlockController is not null && encryptedAssetPublisher is not null)
            {
                await accountUnlockController
                    .QueueAssetTombstoneAsync(encryptedAssetPublisher, record.Id, cancellationToken)
                    .ConfigureAwait(true);
            }
            AssetEditorStatus = "已保存为仅此设备资产；不会进入账户同步或云端备份。";
        }
        else if (IsAccountSignedIn && accountUnlockController is not null && encryptedAssetPublisher is not null)
        {
            await accountUnlockController
                .QueueAssetUpsertAsync(encryptedAssetPublisher, record.Id, cancellationToken)
                .ConfigureAwait(true);
            AssetEditorStatus = IsAccountUnlocked
                ? record.JumpHost is null
                    ? "已保存到本机，已加入下次双向同步队列。"
                    : "资产与跳板机双凭据已安全保存，并加入下次双向同步队列。"
                : "已保存到本机，登录解锁后将加入双向同步队列。";
        }
        else
        {
            AssetEditorStatus = "已保存为随账户同步资产；登录并解锁后会在首次双向同步中发布。";
        }
        NotifyCredentialAvailabilityChanged();
        RefreshFilteredAssets();
        RefreshCommands();
    }

    public async Task<int> ImportAssetsAsync(
        IReadOnlyList<BulkAssetImportItem> items,
        CancellationToken cancellationToken)
    {
        if (items.Count is 0 or > 100)
        {
            throw new ArgumentException("批量导入每次必须包含 1 到 100 台服务器。", nameof(items));
        }

        var records = Assets.Select(asset => asset.ToRecord()).ToList();
        var created = new List<(ServerAssetRecord Record, CredentialMaterial Credential)>();
        var endpoints = new HashSet<string>(
            records.Select(record => $"{record.Host.Trim().ToLowerInvariant()}:{record.Port}:{record.Username.Trim().ToLowerInvariant()}"),
            StringComparer.Ordinal);
        foreach (var item in items)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var validation = ValidateAssetEditorInput(
                item.Name, item.Host, item.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
                item.Username, item.Group, string.Join("，", item.Tags));
            if (validation is not null)
            {
                throw new ArgumentException($"{item.Name}：{validation}", nameof(items));
            }
            var endpointKey = $"{item.Host.Trim().ToLowerInvariant()}:{item.Port}:{item.Username.Trim().ToLowerInvariant()}";
            if (!endpoints.Add(endpointKey))
            {
                continue;
            }
            var record = new ServerAssetRecord(
                Guid.NewGuid(), Guid.NewGuid(), item.Name.Trim(), item.Host.Trim(), item.Port,
                item.Username.Trim(), ServerTransport.Ssh, !string.IsNullOrWhiteSpace(item.Password),
                NormalizeDraftGroup(item.Group), item.Tags);
            var credential = CredentialMaterialPolicy.NormalizeSshCredential(
                new CredentialMaterial(item.Password, item.PrivateKey, item.PrivateKeyPassphrase));
            created.Add((record, credential));
            records.Add(record);
        }

        if (created.Count == 0)
        {
            AssetEditorStatus = "没有可导入的新资产；重复端点已跳过。";
            return 0;
        }

        var savedCredentialIds = new List<Guid>();
        try
        {
            foreach (var item in created)
            {
                if (!item.Credential.IsEmpty)
                {
                    await credentialVault.SaveAsync(item.Record.CredentialId, item.Credential, cancellationToken).ConfigureAwait(true);
                    savedCredentialIds.Add(item.Record.CredentialId);
                }
            }
            await assetStore.SaveAsync(records, cancellationToken).ConfigureAwait(true);
        }
        catch
        {
            foreach (var credentialId in savedCredentialIds)
            {
                try { await credentialVault.DeleteAsync(credentialId, CancellationToken.None).ConfigureAwait(true); }
                catch { }
            }
            throw;
        }

        foreach (var item in created)
        {
            var asset = AssetViewModel.FromRecord(item.Record);
            Assets.Add(asset);
            credentialAvailabilityById[item.Record.CredentialId] = item.Credential.IsEmpty
                ? CredentialAvailability.Missing
                : CredentialAvailability.Available;
        }
        SelectedAsset = Assets.LastOrDefault();
        AssetEditorStatus = $"已批量导入 {created.Count} 台服务器；重复端点已自动跳过。";
        RefreshFilteredAssets();
        NotifyCredentialAvailabilityChanged();
        RefreshCommands();
        return created.Count;
    }

    public async Task ClearCurrentAssetCredentialAsync(CancellationToken cancellationToken)
    {
        if (SelectedAsset is null)
        {
            return;
        }

        await credentialVault.DeleteAsync(SelectedAsset.CredentialId, cancellationToken).ConfigureAwait(true);
        credentialAvailabilityById[SelectedAsset.CredentialId] = CredentialAvailability.Missing;
        Password = string.Empty;
        AssetEditorStatus = "已安全清除本机凭据；资产信息仍保留。";
        NotifyCredentialAvailabilityChanged();
    }

    public async Task<BatchAssetMetadataUpdateResult> UpdateAssetsMetadataAsync(
        IReadOnlyCollection<Guid> assetIds,
        string? targetGroup,
        string tagsToAdd,
        string tagsToRemove,
        CancellationToken cancellationToken)
    {
        var requestedIds = assetIds.Where(id => id != Guid.Empty).ToHashSet();
        var targets = Assets.Where(asset => requestedIds.Contains(asset.Id)).ToArray();
        if (targets.Length == 0)
        {
            AssetEditorStatus = "没有找到可修改的资产。";
            return new BatchAssetMetadataUpdateResult(0, 0, 0);
        }

        var normalizedGroup = targetGroup is null ? null : NormalizeDraftGroup(targetGroup);
        var addedTags = ParseDraftTags(tagsToAdd);
        var removedTags = ParseDraftTags(tagsToRemove);
        if (normalizedGroup is null && addedTags.Count == 0 && removedTags.Count == 0)
        {
            AssetEditorStatus = "没有需要应用的分组或标签变更。";
            return new BatchAssetMetadataUpdateResult(0, 0, 0);
        }

        var replacements = new Dictionary<Guid, AssetViewModel>();
        foreach (var asset in targets)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var tags = asset.Tags
                .Where(tag => !removedTags.Contains(tag, StringComparer.OrdinalIgnoreCase))
                .ToList();
            foreach (var tag in addedTags)
            {
                if (!tags.Contains(tag, StringComparer.OrdinalIgnoreCase))
                {
                    tags.Add(tag);
                }
            }
            if (tags.Count > 16)
            {
                throw new ArgumentException($"资产“{asset.Name}”修改后将超过 16 个标签，请减少新增标签。", nameof(tagsToAdd));
            }

            var updated = asset with
            {
                Group = normalizedGroup ?? asset.Group,
                Tags = tags,
            };
            if (!string.Equals(updated.Group, asset.Group, StringComparison.Ordinal) ||
                !updated.Tags.SequenceEqual(asset.Tags, StringComparer.OrdinalIgnoreCase))
            {
                replacements[asset.Id] = updated;
            }
        }

        if (replacements.Count == 0)
        {
            AssetEditorStatus = "所选资产已经符合指定的分组和标签。";
            return new BatchAssetMetadataUpdateResult(0, 0, 0);
        }

        var records = Assets
            .Select(asset => replacements.TryGetValue(asset.Id, out var updated) ? updated.ToRecord() : asset.ToRecord())
            .ToArray();
        await assetStore.SaveAsync(records, cancellationToken).ConfigureAwait(true);

        foreach (var replacement in replacements.Values)
        {
            var index = Assets.IndexOf(Assets.First(asset => asset.Id == replacement.Id));
            Assets[index] = replacement;
        }
        if (SelectedAsset is not null && replacements.TryGetValue(SelectedAsset.Id, out var selectedReplacement))
        {
            SelectedAsset = selectedReplacement;
        }

        var queued = 0;
        var queueFailures = 0;
        var skippedSync = 0;
        if (IsAccountSignedIn && accountUnlockController is not null && encryptedAssetPublisher is not null)
        {
            foreach (var asset in replacements.Values)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (asset.StorageScope == AssetStorageScope.LocalOnly)
                {
                    skippedSync++;
                    continue;
                }
                try
                {
                    await accountUnlockController
                        .QueueAssetUpsertAsync(encryptedAssetPublisher, asset.Id, cancellationToken)
                        .ConfigureAwait(true);
                    queued++;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    queueFailures++;
                }
            }
        }

        var status = $"已批量更新 {replacements.Count} 个资产的分组或标签。";
        if (queued > 0)
        {
            status += $" {queued} 个资产已加入下次双向同步队列。";
        }
        if (queueFailures > 0)
        {
            status += $" {queueFailures} 个资产暂未加入同步队列，本机修改已保留。";
        }
        if (skippedSync > 0)
        {
            status += $" {skippedSync} 个仅本机资产未进入同步队列。";
        }
        AssetEditorStatus = status;
        RefreshFilteredAssets();
        RefreshCommands();
        return new BatchAssetMetadataUpdateResult(replacements.Count, queueFailures, skippedSync);
    }

    public async Task<BatchAssetDeleteResult> DeleteAssetsAsync(
        IReadOnlyCollection<Guid> assetIds,
        CancellationToken cancellationToken)
    {
        var requestedIds = assetIds.Where(id => id != Guid.Empty).ToHashSet();
        var requestedAssets = Assets.Where(asset => requestedIds.Contains(asset.Id)).ToArray();
        if (requestedAssets.Length == 0)
        {
            AssetEditorStatus = "没有找到可删除的资产。";
            return new BatchAssetDeleteResult(0, 0);
        }

        var deletableAssets = new List<AssetViewModel>(requestedAssets.Length);
        var tombstoneFailures = 0;
        if (IsAccountSignedIn && accountUnlockController is not null && encryptedAssetPublisher is not null)
        {
            foreach (var asset in requestedAssets)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (asset.StorageScope == AssetStorageScope.LocalOnly)
                {
                    deletableAssets.Add(asset);
                    continue;
                }
                try
                {
                    await accountUnlockController
                        .QueueAssetTombstoneAsync(encryptedAssetPublisher, asset.Id, cancellationToken)
                        .ConfigureAwait(true);
                    deletableAssets.Add(asset);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    // A signed-in deletion must fail closed when its cloud
                    // tombstone cannot be recorded, otherwise another device
                    // can silently restore the asset on the next merge.
                    tombstoneFailures++;
                }
            }
        }
        else
        {
            deletableAssets.AddRange(requestedAssets);
        }

        if (deletableAssets.Count == 0)
        {
            AssetEditorStatus = "未能记录删除墓碑；所选资产均保持不变。";
            return new BatchAssetDeleteResult(0, tombstoneFailures);
        }

        var deletableIds = deletableAssets.Select(asset => asset.Id).ToHashSet();
        var remainingRecords = Assets
            .Where(asset => !deletableIds.Contains(asset.Id))
            .Select(asset => asset.ToRecord())
            .ToArray();
        await assetStore.SaveAsync(remainingRecords, cancellationToken).ConfigureAwait(true);

        var credentialCleanupFailures = 0;
        foreach (var asset in deletableAssets)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await credentialVault.DeleteAsync(asset.CredentialId, cancellationToken).ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch
            {
                credentialCleanupFailures++;
            }
            if (asset.JumpHost is { } jump)
            {
                try
                {
                    await credentialVault.DeleteAsync(jump.CredentialId, cancellationToken).ConfigureAwait(true);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    credentialCleanupFailures++;
                }
            }
            credentialAvailabilityById.Remove(asset.CredentialId);
            Assets.Remove(asset);
        }

        if (SelectedAsset is not null && deletableIds.Contains(SelectedAsset.Id))
        {
            SelectedAsset = Assets.FirstOrDefault();
            if (SelectedAsset is null)
            {
                ResetDraftAsset();
            }
        }

        var status = IsAccountSignedIn
            ? $"已删除 {deletableAssets.Count} 个资产，删除墓碑已加入下次双向同步队列。"
            : $"已从本地资产库删除 {deletableAssets.Count} 个资产。";
        if (tombstoneFailures > 0)
        {
            status += $" {tombstoneFailures} 个资产因未能记录删除墓碑而保留。";
        }
        if (credentialCleanupFailures > 0)
        {
            status += " 部分旧凭据未能清理，请在安全诊断中重试。";
        }
        AssetEditorStatus = status;
        NotifyCredentialAvailabilityChanged();
        RefreshFilteredAssets();
        RefreshCommands();
        return new BatchAssetDeleteResult(deletableAssets.Count, tombstoneFailures);
    }

    private async Task DeleteAssetAsync(CancellationToken cancellationToken)
    {
        if (SelectedAsset is null)
        {
            return;
        }

        await DeleteAssetsAsync([SelectedAsset.Id], cancellationToken).ConfigureAwait(true);
    }

    private async Task ConnectAsync(CancellationToken cancellationToken)
    {
        if (AssetTransport == ServerTransport.RemoteDesktop)
        {
            Status = "请从资产列表打开远程桌面";
            SecurityStatus = "RDP 强制使用 NLA；凭据由 Windows DPAPI 保护";
            SessionActionSummary = "未创建 SSH 终端会话";
            return;
        }

        if (AssetTransport == ServerTransport.Telnet)
        {
            var targetKey = BuildTelnetTargetKey(draftAssetId, Host, ParsedPort);
            if (!string.Equals(approvedTelnetTarget, targetKey, StringComparison.Ordinal))
            {
                Status = "Telnet 连接需要先确认明文传输风险。";
                SecurityStatus = "Telnet 未获本次连接授权";
                SessionActionSummary = "未发起网络连接";
                return;
            }
            approvedTelnetTarget = null;
        }

        var alreadyOpen = WorkspaceTabs.FirstOrDefault(tab =>
            tab.AssetId == draftAssetId &&
            (tab.IsConnected || tab.HasHostKeyChallenge || tab.TerminalLease is not null || tab.SftpLease is not null));
        if (alreadyOpen is not null && !ReferenceEquals(alreadyOpen, SelectedWorkspaceTab))
        {
            SelectedWorkspaceTab = alreadyOpen;
            return;
        }

        if (HasActiveRuntime && SelectedWorkspaceTab?.AssetId != draftAssetId)
        {
            // Selecting another asset must never tear down the active verified
            // workspace. Give the new asset its own tab and keep every per-tab
            // terminal, monitor, SFTP, Docker and snippet scope intact.
            var newTab = CreateWorkspaceTabFromDraft();
            WorkspaceTabs.Add(newTab);
            SelectedWorkspaceTab = newTab;
            OnPropertyChanged(nameof(WorkspaceTabSummary));
        }

        if (IsConnected || terminalLease is not null || sftpLease is not null)
        {
            await EndSessionCoreAsync(cancellationToken, "Previous session ended before reconnect").ConfigureAwait(true);
        }

        Status = AssetTransport == ServerTransport.Telnet ? "正在建立 Telnet 明文连接" : "正在连接";
        SessionActionSummary = AssetTransport == ServerTransport.Telnet ? "正在连接已确认的 Telnet 目标" : "正在验证服务器身份";
        SecurityStatus = AssetTransport == ServerTransport.Telnet ? "无加密 · 无服务器身份验证" : "正在检查主机密钥";
        WriteConnectionDiagnostic("command_started");
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
            AssetTransport,
            AssetTransport == ServerTransport.Telnet || AllowPasswordFallback,
            IsJumpHostEnabled && AssetTransport == ServerTransport.Ssh
                ? new JumpHostConfiguration(draftJumpCredentialId, JumpHost.Trim(), ParsedJumpPort, JumpUsername.Trim(), JumpAllowPasswordFallback)
                : null);

        IsConnecting = true;
        RefreshCommands();
        try
        {
            if (!string.IsNullOrWhiteSpace(Password) || !string.IsNullOrWhiteSpace(PrivateKey))
            {
                var credential = CredentialMaterialPolicy.NormalizeSshCredential(
                    new CredentialMaterial(Password, PrivateKey, PrivateKeyPassphrase));
                await credentialVault.SaveAsync(
                    draftCredentialId,
                    credential,
                    cancellationToken).ConfigureAwait(true);
                credentialAvailabilityById[draftCredentialId] = CredentialAvailability.Available;
                NotifyCredentialAvailabilityChanged();
            }
            if (IsJumpHostEnabled && AssetTransport == ServerTransport.Ssh &&
                (!string.IsNullOrWhiteSpace(JumpPassword) || !string.IsNullOrWhiteSpace(JumpPrivateKey)))
            {
                var jumpCredential = CredentialMaterialPolicy.NormalizeSshCredential(
                    new CredentialMaterial(JumpPassword, JumpPrivateKey, JumpPrivateKeyPassphrase));
                await credentialVault.SaveAsync(
                    draftJumpCredentialId,
                    jumpCredential,
                    cancellationToken).ConfigureAwait(true);
            }

            if (asset.Transport == ServerTransport.Telnet)
            {
                var telnetResult = await orchestrator
                    .ConnectTelnetAsync(CurrentWorkspaceId, asset, TerminalSize.Default, cancellationToken)
                    .ConfigureAwait(true);
                switch (telnetResult)
                {
                    case TerminalOpenResult.Opened opened:
                        terminalLease = opened.Lease;
                        IsConnected = true;
                        Status = "Telnet 明文终端已连接";
                        SecurityStatus = "警告：连接未加密，服务器身份未经验证";
                        SessionActionSummary = "Telnet 明文会话活动中";
                        AppendTerminalLine(new TerminalLineViewModel("[安全警告] 当前为 Telnet 明文会话；登录信息、命令和输出可能被监听或篡改。", false));
                        ResetSftpBrowserState();
                        ResetMonitorState();
                        ResetDockerState();
                        SftpStatus = "Telnet 不提供 SFTP";
                        MonitorStatus = "Telnet 不提供系统监控";
                        DockerStatus = "Telnet 不提供 Docker 工具";
                        NotifyTerminalStateChanged();
                        NotifyWorkbenchStateChanged();
                        break;
                    case TerminalOpenResult.Failed failed:
                        Status = failed.MessageKey;
                        SecurityStatus = "Telnet 连接未建立";
                        SessionActionSummary = failed.Code;
                        break;
                }
                SaveRuntimeStateToSelectedWorkspaceTab();
                return;
            }

            // The checked native SSH handshake performs network I/O synchronously.
            // Keep it off the WinUI dispatcher; applying its result stays on the
            // UI context below.
            var result = await Task.Run(
                    async () => await orchestrator
                        .ConnectAsync(CurrentWorkspaceId, asset, cancellationToken)
                        .ConfigureAwait(false),
                    cancellationToken)
                .ConfigureAwait(true);
            WriteConnectionDiagnostic($"native_result={result.GetType().Name}");
            ApplyConnectResult(result);
            if (IsConnected)
            {
                // A verified SSH connection is immediately usable. Opening the
                // terminal here removes the redundant second action while keeping
                // the explicit command available as a recoverable retry path.
                await OpenTerminalAsync(cancellationToken).ConfigureAwait(true);
                // SFTP is part of a verified workstation session, not a second
                // connection the user has to remember to open. Each workspace tab
                // owns its lease and listing, so switching tabs restores the matching
                // asset view without touching another connection.
                await OpenSftpAsync(cancellationToken).ConfigureAwait(true);
                if (sftpLease is not null)
                {
                    await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                }
                // Docker belongs to the same verified workstation context. Load the
                // current asset's containers immediately so the inspector never
                // starts as an empty manual-refresh view.
                await RefreshDockerContainersAsync(cancellationToken).ConfigureAwait(true);
                await RefreshDockerStatsCoreAsync(cancellationToken, publishFeedback: false).ConfigureAwait(true);
            }
            SaveRuntimeStateToSelectedWorkspaceTab();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            WriteConnectionDiagnostic(string.Concat(
                "connection_exception=",
                exception.GetType().Name,
                ";hresult=0x",
                exception.HResult.ToString("X8", System.Globalization.CultureInfo.InvariantCulture),
                ";inner=",
                exception.InnerException?.GetType().Name ?? "none"));
            Status = "连接未完成，请检查网络、凭据或服务器状态后重试";
            SecurityStatus = "connection_failed";
            SessionActionSummary = "未建立已验证会话";
            SaveRuntimeStateToSelectedWorkspaceTab();
        }
        finally
        {
            IsConnecting = false;
            RefreshCommands();
        }
    }

    private static string BuildTelnetTargetKey(Guid assetId, string hostName, int port) =>
        string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{assetId:D}|{hostName.Trim().ToLowerInvariant()}|{port}");

    private async Task TrustHostKeyAsync(CancellationToken cancellationToken)
    {
        if (pendingChallenge is null)
        {
            return;
        }

        Status = "正在保存主机密钥";
        HostKeyTrustResult result;
        try
        {
            result = await orchestrator.TrustHostKeyAsync(
                pendingChallenge,
                "OrbitTerm Windows",
                cancellationToken).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Host-key persistence crosses the native bridge and local known_hosts
            // storage. A failure here must remain a recoverable UI state, never an
            // unobserved exception from the async command.
            Status = "无法保存主机密钥，请检查本机存储后重试";
            SecurityStatus = "host_key_trust_failed";
            SessionActionSummary = "主机密钥未保存";
            SaveRuntimeStateToSelectedWorkspaceTab();
            return;
        }

        switch (result)
        {
            case HostKeyTrustResult.Persisted persisted:
                Status = "主机密钥已保存，正在继续连接";
                SecurityStatus = "主机密钥已保存";
                SessionActionSummary = "主机密钥已确认";
                pendingChallenge = null;
                HasHostKeyChallenge = false;
                OnPropertyChanged(nameof(HostKeySummary));
                NotifyWorkbenchStateChanged();
                SaveRuntimeStateToSelectedWorkspaceTab();
                await ConnectAsync(cancellationToken).ConfigureAwait(true);
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

    private async Task AddTerminalSplitAsync(CancellationToken cancellationToken)
    {
        if (!CanAddTerminalSplit || SelectedWorkspaceTab is null)
        {
            return;
        }

        var result = await orchestrator.OpenTerminalAsync(
            CurrentWorkspaceId,
            draftAssetId,
            terminalLease?.Size ?? TerminalSize.Default,
            cancellationToken).ConfigureAwait(true);

        switch (result)
        {
            case TerminalOpenResult.Opened opened:
                var pane = new TerminalSplitPaneViewModel(
                    Guid.NewGuid(),
                    SelectedWorkspaceTab.TerminalSplitPanes.Count + 2,
                    opened.Lease);
                SelectedWorkspaceTab.TerminalSplitPanes.Add(pane);
                SetActiveTerminalPane(null);
                Status = $"已添加{pane.Label}";
                NotifyTerminalSplitStateChanged();
                break;
            case TerminalOpenResult.Failed failed:
                Status = failed.MessageKey;
                SecurityStatus = failed.Code;
                break;
        }

        RefreshCommands();
    }

    private async Task RemoveLastTerminalSplitAsync(CancellationToken cancellationToken)
    {
        if (SelectedWorkspaceTab?.TerminalSplitPanes.LastOrDefault() is { } pane)
        {
            await CloseTerminalSplitPaneAsync(pane.Id, cancellationToken).ConfigureAwait(true);
        }
    }

    public async Task<bool> CloseTerminalSplitPaneAsync(Guid paneId, CancellationToken cancellationToken)
    {
        var owner = WorkspaceTabs.FirstOrDefault(tab => tab.TerminalSplitPanes.Any(pane => pane.Id == paneId));
        var pane = owner?.TerminalSplitPanes.FirstOrDefault(candidate => candidate.Id == paneId);
        if (owner is null || pane is null)
        {
            return false;
        }

        var result = await orchestrator.CloseTerminalAsync(pane.Lease, cancellationToken).ConfigureAwait(true);
        if (result is TerminalControlOutcome.Failed failed)
        {
            Status = failed.MessageKey;
            return false;
        }

        owner.TerminalSplitPanes.Remove(pane);
        RenumberTerminalSplitPanes(owner);
        if (ReferenceEquals(owner, SelectedWorkspaceTab))
        {
            SetActiveTerminalPane(null);
            Status = $"已关闭{pane.Label}";
            NotifyTerminalSplitStateChanged();
        }

        RefreshCommands();
        return true;
    }

    public async Task<bool> WriteTerminalSplitInputAsync(
        Guid paneId,
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken)
    {
        if (bytes.IsEmpty || FindTerminalSplitPane(paneId) is not { } pane)
        {
            return false;
        }

        TerminalControlOutcome result;
        try
        {
            result = await orchestrator.WriteTerminalAsync(
                    pane.Lease,
                    bytes,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (InvalidOperationException)
        {
            dispatch(() => MarkCurrentConnectionLost("终端会话已断开，请重新连接"));
            return false;
        }
        if (result is TerminalControlOutcome.Succeeded)
        {
            return true;
        }

        if (result is TerminalControlOutcome.Failed failed)
        {
            dispatch(() =>
            {
                Status = failed.MessageKey;
                MarkCurrentConnectionLost("终端通道已断开，请重新连接");
            });
        }

        return false;
    }

    public async Task ResizeTerminalSplitPaneAsync(
        Guid paneId,
        TerminalSize size,
        CancellationToken cancellationToken)
    {
        if (FindTerminalSplitPane(paneId) is not { } pane || pane.Lease.Size == size)
        {
            return;
        }

        var result = await orchestrator.ResizeTerminalAsync(pane.Lease, size, cancellationToken).ConfigureAwait(true);
        if (result is TerminalControlOutcome.Succeeded)
        {
            var resizedLease = pane.Lease with { Size = size };
            pane.UpdateLease(resizedLease);
            ApplyTerminalScreenRows(orchestrator.GetTerminalScreenSnapshot(resizedLease), pane.Lines);
            terminalSplitOutputVersion++;
            OnPropertyChanged(nameof(TerminalSplitOutputVersion));
        }
        else if (result is TerminalControlOutcome.Failed failed)
        {
            Status = failed.MessageKey;
        }
    }

    public void SetActiveTerminalPane(Guid? paneId)
    {
        activeTerminalSplitPaneId = paneId;
        foreach (var pane in TerminalSplitPanes)
        {
            pane.IsActive = pane.Id == paneId;
        }
    }

    public void ClearTerminalSplitPresentation(Guid paneId)
    {
        if (FindTerminalSplitPane(paneId) is not { } pane)
        {
            return;
        }

        var cleared = orchestrator.ClearTerminalPresentation(pane.Lease);
        ApplyTerminalScreenRows(cleared, pane.Lines);
        terminalSplitOutputVersion++;
        OnPropertyChanged(nameof(TerminalSplitOutputVersion));
    }

    private TerminalSplitPaneViewModel? FindTerminalSplitPane(Guid paneId) =>
        WorkspaceTabs.SelectMany(tab => tab.TerminalSplitPanes).FirstOrDefault(pane => pane.Id == paneId);

    private static void RenumberTerminalSplitPanes(WorkspaceTabViewModel tab)
    {
        for (var index = 0; index < tab.TerminalSplitPanes.Count; index++)
        {
            tab.TerminalSplitPanes[index].UpdatePaneNumber(index + 2);
        }
    }

    private void NotifyTerminalSplitStateChanged()
    {
        OnPropertyChanged(nameof(TerminalSplitPanes));
        OnPropertyChanged(nameof(TerminalPaneCount));
        OnPropertyChanged(nameof(HasTerminalSplits));
        OnPropertyChanged(nameof(CanAddTerminalSplit));
        AddTerminalSplitCommand.RaiseCanExecuteChanged();
        RemoveLastTerminalSplitCommand.RaiseCanExecuteChanged();
    }

    public async Task ResizeTerminalAsync(TerminalSize size, CancellationToken cancellationToken)
    {
        if (terminalLease is null || terminalLease.Size == size)
        {
            return;
        }

        var result = await orchestrator.ResizeTerminalAsync(terminalLease, size, cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case TerminalControlOutcome.Succeeded:
                terminalLease = terminalLease with { Size = size };
                if (SelectedWorkspaceTab is { } selectedTab)
                {
                    ApplyTerminalScreen(
                        orchestrator.GetTerminalScreenSnapshot(terminalLease),
                        TerminalLines,
                        true,
                        selectedTab);
                }
                Status = "终端大小已更新";
                NotifyTerminalStateChanged();
                SaveRuntimeStateToSelectedWorkspaceTab();
                break;
            case TerminalControlOutcome.Failed failed:
                Status = failed.MessageKey;
                break;
        }
    }

    public Task PreviewSelectedSftpTextAsync(CancellationToken cancellationToken) =>
        PreviewSftpTextAsync(cancellationToken);

    private async Task PreviewSftpTextAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (sftpLease is null)
        {
            SftpPreviewStatus = "Open SFTP before preview";
            RefreshCommands();
            return;
        }
        // Preview targets the selected file, rather than the directory displayed in
        // the path field. This matters when a file is selected from a listing.
        var selectedEntry = SelectedSftpEntry is { IsDirectory: false } candidate
            ? candidate
            : null;
        var normalized = NormalizeSftpPath(selectedEntry?.Path ?? SftpPathText);
        if (normalized is null)
        {
            SftpPreviewStatus = "SFTP path rejected";
            SftpOperationStatus = "Use an absolute file path without control characters, backslashes, or parent traversal";
            RefreshCommands();
            return;
        }

        var editCandidate = selectedEntry is not null &&
            string.Equals(selectedEntry.Path, normalized, StringComparison.Ordinal)
                ? selectedEntry
                : null;
        ResetSftpEditor();
        SftpPathText = normalized;
        SftpPreviewStatus = string.Concat("Previewing ", normalized);

        // A regular zero-byte file is already fully described by the checked directory
        // listing. Some SFTP servers reject a separate read request for it, but it is
        // still a valid text document and should open as an empty editor.
        if (editCandidate is { Size: 0 })
        {
            sftpPreviewPath = normalized;
            sftpPreviewSnapshot = ToSftpMutationSnapshot(editCandidate);
            sftpPreviewOriginalText = string.Empty;
            SftpPreviewText = string.Empty;
            SftpPreviewStatus = string.Concat("Previewed 0 B from ", normalized);
            SftpOperationStatus = "空文本文件已准备好编辑";
            NotifySftpEditorStateChanged();
            RefreshCommands();
            return;
        }

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
                var transferContext = GetCurrentSftpTransferContext();
                SftpStatus = "SFTP channel open";
                SftpBrowserStatus = "SFTP browser ready";
                SftpOperationStatus = "Validate a remote path before directory operations";
                SessionActionSummary = "SFTP ready";
                if (transferContext.LastTransferRetry is not null || transferContext.LastBatchRetry is not null)
                {
                    SetSftpTransferStatus(transferContext, "连接已恢复，可点击“重试”继续未完成的传输任务");
                }
                NotifySftpStateChanged();
                OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
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

    public async Task RefreshMonitorDetailsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        // The main-window timer and monitor detail window can request a sample
        // at the same time. Never queue competing SSH exec channels; retain the
        // previous graph until the single in-flight sample completes.
        if (Interlocked.CompareExchange(ref monitorRefreshInFlight, 1, 0) != 0)
        {
            return;
        }

        try
        {

        if (!IsConnected)
        {
            MonitorStatus = "等待连接";
            MonitorSummary = "请先建立并验证 SSH 会话";
            RefreshCommands();
            return;
        }

        var now = utcNow();
        // During bulk transfer, a two-second remote sample still produces a
        // useful live curve while leaving more transport turns for terminal
        // I/O. Transfer byte counters continue updating the network cards in
        // between remote CPU/memory/disk samples.
        var effectiveRefreshSeconds = HasActiveSftpTransfersForCurrentContext
            ? Math.Max(2, monitorRefreshIntervalSeconds)
            : monitorRefreshIntervalSeconds;
        var minimumRefreshInterval = TimeSpan.FromSeconds(effectiveRefreshSeconds);
        if (lastMonitorRefreshAt is { } previous && now - previous < minimumRefreshInterval)
        {
            var seconds = Math.Max(1, (int)Math.Ceiling((minimumRefreshInterval - (now - previous)).TotalSeconds));
            MonitorStatus = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"请在 {seconds} 秒后刷新监控");
            RefreshCommands();
            return;
        }

        lastMonitorRefreshAt = now;
        MonitorStatus = "正在刷新监控快照";
        var workspaceId = CurrentWorkspaceId;
        var serverId = draftAssetId;
        var monitoredHost = Host.Trim();
        var monitoredPort = ParsedPort;
        try
        {
            // The checked native monitor call performs a remote SSH exec before
            // it returns its ValueTask. Never invoke it on the WinUI dispatcher:
            // an overloaded host or a slow network would otherwise freeze
            // terminal input, rendering, and window activation while auto-
            // refresh is on.
            var latencyTask = tcpLatencyProbe(
                monitoredHost,
                monitoredPort,
                cancellationToken);
            var result = await RunRemoteInspectionAsync(
                () => orchestrator.CaptureMonitorSnapshotAsync(workspaceId, serverId, cancellationToken).AsTask(),
                cancellationToken).ConfigureAwait(true);
            var tcpLatency = await latencyTask.ConfigureAwait(true);

            // A user may end the session or switch assets while the remote
            // sample is in flight. Do not let an old response repopulate the
            // newly selected workspace.
            if (!IsConnected || CurrentWorkspaceId != workspaceId || draftAssetId != serverId)
            {
                return;
            }

            switch (result)
            {
                case MonitorSnapshotResult.Captured captured:
                    consecutiveMonitorFailures = 0;
                    var monitorDiagnostics = captured.Snapshot.Diagnostics
                        .Where(static item => !string.Equals(item, "ping_unavailable", StringComparison.Ordinal))
                        .ToList();
                    if (!tcpLatency.Connected)
                    {
                        monitorDiagnostics.Add("tcping_unavailable");
                    }
                    var tcpSnapshot = captured.Snapshot with
                    {
                        PingLatencyMilliseconds = tcpLatency.Milliseconds,
                        Diagnostics = monitorDiagnostics,
                        AvailableMetrics = tcpLatency.Connected
                            ? captured.Snapshot.AvailableMetrics | MonitorSampleMetrics.Latency
                            : captured.Snapshot.AvailableMetrics & ~MonitorSampleMetrics.Latency,
                    };
                    latestRawMonitorSnapshot = tcpSnapshot;
                    lastSuccessfulMonitorRefreshAt = now;
                    var displaySnapshot = ApplyActiveSftpTransferRates(tcpSnapshot);
                    MonitorStatus = FormatMonitorStatus(displaySnapshot);
                    MonitorSummary = FormatMonitorSummary(displaySnapshot);
                    SystemOverviewSummary = FormatSystemOverview(displaySnapshot);
                    AppendMonitorSnapshot(displaySnapshot);
                    SessionActionSummary = "监控快照已更新";
                    SaveMonitorRuntimeStateToSelectedWorkspaceTab();
                    break;
                case MonitorSnapshotResult.Failed failed:
                    consecutiveMonitorFailures++;
                    MonitorStatus = "监控刷新失败";
                    MonitorSummary = FormatMonitorFailure(failed.Code);
                    SessionActionSummary = "监控刷新失败";
                    SaveMonitorRuntimeStateToSelectedWorkspaceTab();
                    if (consecutiveMonitorFailures >= 3)
                    {
                        MarkCurrentConnectionLost("远端资产已失去响应，请重新连接");
                    }
                    break;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            consecutiveMonitorFailures++;
            MonitorStatus = "监控刷新失败";
            MonitorSummary = "暂时无法读取远端监控，请检查连接后重试。";
            SessionActionSummary = "监控刷新失败";
            SaveMonitorRuntimeStateToSelectedWorkspaceTab();
            if (consecutiveMonitorFailures >= 3)
            {
                MarkCurrentConnectionLost("远端资产已失去响应，请重新连接");
            }
        }

        RefreshCommands();
        }
        finally
        {
            Volatile.Write(ref monitorRefreshInFlight, 0);
        }
    }

    public async Task RefreshRemoteProcessesAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Volatile.Read(ref remoteProcessActionInFlight) != 0)
        {
            return;
        }
        if (Interlocked.CompareExchange(ref remoteProcessRefreshInFlight, 1, 0) != 0)
        {
            return;
        }

        try
        {
            if (!IsConnected || IsTelnetSession)
            {
                RemoteProcessStatus = "当前会话不支持进程监控";
                return;
            }

            var workspaceId = CurrentWorkspaceId;
            var serverId = draftAssetId;
            var owner = SelectedWorkspaceTab;
            var result = await RunRemoteInspectionAsync(
                () => orchestrator.RunBatchCommandAsync(
                    workspaceId,
                    serverId,
                    RemoteProcessSnapshotCommand,
                    cancellationToken).AsTask(),
                cancellationToken).ConfigureAwait(true);

            if (!IsConnected ||
                !ReferenceEquals(owner, SelectedWorkspaceTab) ||
                CurrentWorkspaceId != workspaceId ||
                draftAssetId != serverId)
            {
                return;
            }

            switch (result)
            {
                case BatchExecResult.Completed completed:
                    var processes = ParseRemoteProcesses(completed.Stdout);
                    SynchronizeRemoteProcesses(processes);
                    RemoteProcessStatus = processes.Count == 0
                        ? "远端未返回可显示的进程"
                        : string.Create(
                            System.Globalization.CultureInfo.InvariantCulture,
                            $"实时更新 · 已采集 {processes.Count} 个进程 · {utcNow().ToLocalTime():HH:mm:ss}");
                    SaveRemoteProcessesToSelectedWorkspaceTab();
                    break;
                case BatchExecResult.Failed:
                    RemoteProcessStatus = "进程采样暂时失败，已保留上一次数据";
                    break;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            if (IsConnected)
            {
                RemoteProcessStatus = "进程采样暂时失败，已保留上一次数据";
            }
        }
        finally
        {
            Volatile.Write(ref remoteProcessRefreshInFlight, 0);
        }
    }

    private static IReadOnlyList<RemoteProcessViewModel> ParseRemoteProcesses(string output)
    {
        var processes = new List<RemoteProcessViewModel>(MaximumRemoteProcesses);
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (processes.Count >= MaximumRemoteProcesses)
            {
                break;
            }

            var fields = line.Split((char[]?)null, 8, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length != 8 ||
                !uint.TryParse(fields[0], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var processId) ||
                processId == 0 ||
                !uint.TryParse(fields[1], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var parentProcessId) ||
                !double.TryParse(fields[3], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var cpuPercent) ||
                !double.TryParse(fields[4], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var memoryPercent) ||
                !long.TryParse(fields[6], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var startIdentity) ||
                startIdentity <= 0 ||
                !double.IsFinite(cpuPercent) || cpuPercent is < 0 or > 10_000 ||
                !double.IsFinite(memoryPercent) || memoryPercent is < 0 or > 100 ||
                !IsSafeProcessText(fields[2], 64) ||
                !IsSafeProcessText(fields[5], 16) ||
                !IsSafeProcessText(fields[7], 1024))
            {
                continue;
            }

            processes.Add(new RemoteProcessViewModel(
                processId,
                parentProcessId,
                fields[2],
                cpuPercent,
                memoryPercent,
                fields[5],
                startIdentity,
                fields[7]));
        }
        return processes;
    }

    private static bool IsSafeProcessText(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        !value.Any(char.IsControl);

    private void SynchronizeRemoteProcesses(IReadOnlyList<RemoteProcessViewModel> processes)
    {
        var desiredIdentities = processes
            .Select(static process => (process.ProcessId, process.StartIdentity))
            .ToHashSet();
        for (var desiredIndex = 0; desiredIndex < processes.Count; desiredIndex++)
        {
            var snapshot = processes[desiredIndex];
            var existing = RemoteProcesses.FirstOrDefault(process =>
                process.ProcessId == snapshot.ProcessId &&
                process.StartIdentity == snapshot.StartIdentity);
            if (existing is null)
            {
                RemoteProcesses.Insert(Math.Min(desiredIndex, RemoteProcesses.Count), snapshot);
            }
            else
            {
                existing.UpdateFrom(snapshot);
                var currentIndex = RemoteProcesses.IndexOf(existing);
                if (currentIndex != desiredIndex)
                {
                    RemoteProcesses.Move(currentIndex, desiredIndex);
                }
            }
        }

        for (var index = RemoteProcesses.Count - 1; index >= 0; index--)
        {
            if (!desiredIdentities.Contains((
                    RemoteProcesses[index].ProcessId,
                    RemoteProcesses[index].StartIdentity)))
            {
                RemoteProcesses.RemoveAt(index);
            }
        }
    }

    public async Task<RemoteProcessActionResult> RunRemoteProcessActionAsync(
        RemoteProcessViewModel process,
        RemoteProcessAction action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(process);
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsConnected || IsTelnetSession)
        {
            return new RemoteProcessActionResult.Failed(
                "process_action_session_unavailable",
                "error.process.action.session_unavailable");
        }
        if (Interlocked.CompareExchange(ref remoteProcessActionInFlight, 1, 0) != 0)
        {
            return new RemoteProcessActionResult.Busy();
        }

        RemoteProcessActionResult result;
        var workspaceId = CurrentWorkspaceId;
        var serverId = draftAssetId;
        var owner = SelectedWorkspaceTab;
        try
        {
            result = await Task.Run(
                    async () => await orchestrator.RunRemoteProcessActionAsync(
                        workspaceId,
                        serverId,
                        process.ProcessId,
                        process.StartIdentity,
                        action,
                        cancellationToken).ConfigureAwait(false),
                    cancellationToken)
                .ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            result = new RemoteProcessActionResult.Failed(
                "process_action_failed",
                "error.process.action.failed");
        }
        finally
        {
            Volatile.Write(ref remoteProcessActionInFlight, 0);
        }

        if (!IsConnected ||
            !ReferenceEquals(owner, SelectedWorkspaceTab) ||
            CurrentWorkspaceId != workspaceId ||
            draftAssetId != serverId)
        {
            return new RemoteProcessActionResult.Failed(
                "process_action_session_changed",
                "error.process.action.session_changed");
        }

        if (result is RemoteProcessActionResult.Completed or
            RemoteProcessActionResult.NotFound or
            RemoteProcessActionResult.IdentityChanged)
        {
            await RefreshRemoteProcessesAsync(cancellationToken).ConfigureAwait(true);
        }
        return result;
    }

    private void SaveRemoteProcessesToSelectedWorkspaceTab()
    {
        if (SelectedWorkspaceTab is not { } tab)
        {
            return;
        }
        tab.RemoteProcesses.Clear();
        tab.RemoteProcesses.AddRange(RemoteProcesses.Select(static process => process.Clone()));
        tab.RemoteProcessStatus = RemoteProcessStatus;
    }

    private Task RefreshDockerContainersAsync(CancellationToken cancellationToken) =>
        RefreshDockerContainersCoreAsync(cancellationToken, publishFeedback: true);

    public async Task RefreshDockerInspectorForAutoRefreshAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.CompareExchange(ref dockerInspectorAutoRefreshInFlight, 1, 0) != 0)
        {
            return;
        }

        try
        {
            var now = utcNow();
            if (DockerContainers.Count == 0 ||
                lastDockerContainerRefreshAt is null ||
                now - lastDockerContainerRefreshAt >= DockerContainerAutoRefreshInterval)
            {
                await RefreshDockerContainersCoreAsync(cancellationToken, publishFeedback: false).ConfigureAwait(true);
            }
            await RefreshDockerStatsCoreAsync(cancellationToken, publishFeedback: false).ConfigureAwait(true);
        }
        finally
        {
            Volatile.Write(ref dockerInspectorAutoRefreshInFlight, 0);
        }
    }

    private async Task RefreshDockerContainersCoreAsync(
        CancellationToken cancellationToken,
        bool publishFeedback)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (Interlocked.CompareExchange(ref dockerContainerRefreshInFlight, 1, 0) != 0)
        {
            return;
        }

        try
        {

        if (!IsConnected)
        {
            DockerStatus = "等待连接";
            DockerSummary = "请先建立并验证 SSH 会话";
            if (publishFeedback)
            {
                PublishDockerFeedback(DockerFeedbackKind.Error, "无法刷新容器", DockerSummary);
            }
            RefreshCommands();
            return;
        }

        if (publishFeedback)
        {
            DockerStatus = "正在刷新 Docker 容器";
            PublishDockerFeedback(DockerFeedbackKind.InProgress, "正在刷新容器", "正在读取远端 Docker 容器列表");
        }
        var workspaceId = CurrentWorkspaceId;
        var serverId = draftAssetId;
        var owner = SelectedWorkspaceTab;
        var result = await RunRemoteInspectionAsync(
            () => orchestrator.ListDockerContainersAsync(
                workspaceId,
                serverId,
                cancellationToken).AsTask(),
            cancellationToken).ConfigureAwait(true);

        if (!IsConnected ||
            !ReferenceEquals(owner, SelectedWorkspaceTab) ||
            CurrentWorkspaceId != workspaceId ||
            draftAssetId != serverId)
        {
            return;
        }

        switch (result)
        {
            case DockerContainersResult.Listed listed:
                var selectedId = SelectedDockerContainer?.Id;
                SynchronizeDockerContainers(listed.Containers, selectedId);
                lastDockerContainerRefreshAt = utcNow();

                DockerStatus = "Docker 容器已刷新";
                DockerSummary = DockerContainers.Count == 0
                    ? "未发现 Docker 容器"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已读取 {DockerContainers.Count} 个 Docker 容器");
                SessionActionSummary = "Docker 容器列表已更新";
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Success, "容器列表已刷新", DockerSummary);
                }
                SaveDockerRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerContainersResult.Failed failed:
                DockerStatus = "无法读取 Docker 容器";
                DockerSummary = FormatDockerFailure(failed.Code);
                SessionActionSummary = DockerStatus;
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Error, DockerStatus, DockerSummary);
                }
                SaveDockerRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            if (IsConnected)
            {
                DockerStatus = "无法读取 Docker 容器";
                DockerSummary = "容器列表刷新暂时失败，已保留上一次数据";
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Error, DockerStatus, DockerSummary);
                }
            }
        }
        finally
        {
            Volatile.Write(ref dockerContainerRefreshInFlight, 0);
        }
    }

    private Task RefreshDockerStatsAsync(CancellationToken cancellationToken) =>
        RefreshDockerStatsCoreAsync(cancellationToken, publishFeedback: true);

    private async Task RefreshDockerStatsCoreAsync(
        CancellationToken cancellationToken,
        bool publishFeedback)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (Interlocked.CompareExchange(ref dockerStatsRefreshInFlight, 1, 0) != 0)
        {
            return;
        }

        try
        {

        if (!IsConnected)
        {
            DockerStatus = "等待连接";
            DockerStatsSummary = "请先建立并验证 SSH 会话";
            if (publishFeedback)
            {
                PublishDockerFeedback(DockerFeedbackKind.Error, "无法刷新资源数据", DockerStatsSummary);
            }
            RefreshCommands();
            return;
        }

        if (publishFeedback)
        {
            DockerStatus = "正在刷新 Docker 资源数据";
            PublishDockerFeedback(DockerFeedbackKind.InProgress, "正在刷新资源数据", "正在读取远端 Docker 资源快照");
        }
        var workspaceId = CurrentWorkspaceId;
        var serverId = draftAssetId;
        var owner = SelectedWorkspaceTab;
        var result = await RunRemoteInspectionAsync(
            () => orchestrator.CaptureDockerStatsAsync(
                workspaceId,
                serverId,
                cancellationToken).AsTask(),
            cancellationToken).ConfigureAwait(true);

        if (!IsConnected ||
            !ReferenceEquals(owner, SelectedWorkspaceTab) ||
            CurrentWorkspaceId != workspaceId ||
            draftAssetId != serverId)
        {
            return;
        }

        switch (result)
        {
            case DockerStatsResult.Captured captured:
                SynchronizeDockerStats(captured.Stats);

                DockerStatus = "Docker 资源数据已刷新";
                DockerStatsSummary = DockerStats.Count == 0
                    ? "未发现 Docker 资源数据"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已读取 {DockerStats.Count} 项 Docker 资源数据");
                MergeDockerStatsIntoContainerCards();
                // Background Docker sampling must not erase a more important
                // monitor/security failure that the user still needs to see.
                if (!SessionActionSummary.EndsWith("失败", StringComparison.Ordinal))
                {
                    SessionActionSummary = "Docker 资源数据已更新";
                }
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Success, "资源数据已刷新", DockerStatsSummary);
                }
                SaveDockerRuntimeStateToSelectedWorkspaceTab();
                break;
            case DockerStatsResult.Failed failed:
                DockerStatus = "无法读取 Docker 资源数据";
                DockerStatsSummary = FormatDockerFailure(failed.Code);
                SessionActionSummary = DockerStatus;
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Error, DockerStatus, DockerStatsSummary);
                }
                SaveDockerRuntimeStateToSelectedWorkspaceTab();
                break;
        }

        RefreshCommands();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            if (IsConnected)
            {
                DockerStatus = "无法读取 Docker 资源数据";
                DockerStatsSummary = "资源刷新暂时失败，已保留上一次数据";
                if (publishFeedback)
                {
                    PublishDockerFeedback(DockerFeedbackKind.Error, DockerStatus, DockerStatsSummary);
                }
            }
        }
        finally
        {
            Volatile.Write(ref dockerStatsRefreshInFlight, 0);
        }
    }

    private void MergeDockerStatsIntoContainerCards()
    {
        if (DockerContainers.Count == 0 || DockerStats.Count == 0)
        {
            return;
        }

        var selectedId = SelectedDockerContainer?.Id;
        var statsById = DockerStats.ToDictionary(
            static item => item.Id,
            StringComparer.OrdinalIgnoreCase);
        DockerContainerViewModel? restoredSelection = null;
        for (var index = 0; index < DockerContainers.Count; index++)
        {
            var container = DockerContainers[index];
            if (statsById.TryGetValue(container.Id, out var stats))
            {
                container.WithStats(stats);
            }
            if (string.Equals(container.Id, selectedId, StringComparison.OrdinalIgnoreCase))
            {
                restoredSelection = container;
            }
        }

        if (selectedId is not null)
        {
            SelectedDockerContainer = restoredSelection;
        }
    }

    private async Task PreviewDockerLogsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var context = CreateSelectedDockerLogSessionContext();
        if (context is null)
        {
            DockerLogStatus = "请先连接并选择一个 Docker 容器";
            PublishDockerFeedback(DockerFeedbackKind.Error, "无法读取日志", DockerLogStatus);
            RefreshCommands();
            return;
        }

        DockerLogStatus = "正在刷新 Docker 日志预览";
        PublishDockerFeedback(DockerFeedbackKind.InProgress, "正在读取容器日志", context.ContainerName);
        var frame = await CaptureDockerLogFrameAsync(context, 100, cancellationToken).ConfigureAwait(true);
        if (!frame.IsError)
        {
            DockerLogText = frame.Text;
            DockerLogStatus = frame.Status;
            SessionActionSummary = "Docker 日志已更新";
            PublishDockerFeedback(DockerFeedbackKind.Success, "容器日志已读取", DockerLogStatus);
        }
        else
        {
            DockerLogText = string.Empty;
            DockerLogStatus = frame.Status;
            SessionActionSummary = "Docker 日志读取失败";
            PublishDockerFeedback(DockerFeedbackKind.Error, "容器日志读取失败", DockerLogStatus);
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public Task PreviewSelectedDockerLogsAsync(CancellationToken cancellationToken) =>
        PreviewDockerLogsAsync(cancellationToken);

    public DockerLogSessionContext? CreateSelectedDockerLogSessionContext()
    {
        if (!IsConnected ||
            IsTelnetSession ||
            SelectedWorkspaceTab is not { IsConnected: true } tab ||
            SelectedDockerContainer is not { } container)
        {
            return null;
        }

        return new DockerLogSessionContext(
            tab.Id,
            tab.WorkspaceId,
            tab.AssetId,
            container.Id,
            container.Name,
            container.Image);
    }

    public bool IsDockerLogSessionContextAvailable(DockerLogSessionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return WorkspaceTabs.Any(tab =>
            tab.Id == context.WorkspaceTabId &&
            tab.WorkspaceId == context.WorkspaceId &&
            tab.AssetId == context.AssetId &&
            tab.IsConnected &&
            tab.Transport == ServerTransport.Ssh);
    }

    public async Task<DockerLogFrame> CaptureDockerLogFrameAsync(
        DockerLogSessionContext context,
        uint tailLines,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();

        try
        {
            var result = await orchestrator.CaptureDockerLogsAsync(
                context.WorkspaceId,
                context.AssetId,
                context.ContainerId,
                tailLines,
                cancellationToken).ConfigureAwait(false);
            return result switch
            {
                DockerLogsResult.Captured captured => new DockerLogFrame(
                    captured.Logs,
                    string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"Docker 日志预览：{captured.ContainerId[..Math.Min(12, captured.ContainerId.Length)]}")),
                DockerLogsResult.Failed failed => new DockerLogFrame(
                    string.Empty,
                    FormatDockerFailure(failed.Code),
                    true),
                _ => new DockerLogFrame(string.Empty, "Docker 日志返回了未知结果。", true),
            };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (InvalidOperationException)
        {
            return new DockerLogFrame(string.Empty, "会话已切换或断开，日志跟随已停止。", true);
        }
        catch
        {
            return new DockerLogFrame(string.Empty, "无法读取 Docker 日志，请检查连接后重试。", true);
        }
    }

    private bool CanRunDockerAction(Func<DockerContainerViewModel, bool> statePolicy) =>
        isConnected &&
        !IsTelnetSession &&
        SelectedDockerContainer is { } container &&
        statePolicy(container);

    private async Task RunDockerActionAsync(string action, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!IsConnected ||
            SelectedWorkspaceTab is not { } owner ||
            SelectedDockerContainer is not { } selectedContainer)
        {
            DockerStatus = "请先连接并选择一个 Docker 容器";
            PublishDockerFeedback(DockerFeedbackKind.Error, "无法执行容器操作", DockerStatus);
            RefreshCommands();
            return;
        }

        var workspaceId = owner.WorkspaceId;
        var serverId = owner.AssetId;
        var containerId = selectedContainer.Id;
        var selectedContainerName = selectedContainer.Name;
        var actionLabel = FormatDockerAction(action);
        DockerStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"正在{actionLabel} Docker 容器");
        PublishDockerFeedback(
            DockerFeedbackKind.InProgress,
            string.Concat("正在", actionLabel, "容器"),
            selectedContainerName);
        var result = await Task.Run(
                async () => await orchestrator.RunDockerActionAsync(
                    workspaceId,
                    serverId,
                    containerId,
                    action,
                    cancellationToken).ConfigureAwait(false),
                cancellationToken)
            .ConfigureAwait(true);

        if (!owner.IsConnected || !WorkspaceTabs.Contains(owner))
        {
            return;
        }

        switch (result)
        {
            case DockerActionResult.Completed completed:
                var refreshed = await RefreshDockerContainersAfterActionAsync(
                    owner,
                    workspaceId,
                    serverId,
                    completed.ContainerId,
                    completed.Action,
                    cancellationToken)
                    .ConfigureAwait(true);
                var completedStatus = refreshed
                    ? string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"Docker 容器已{FormatDockerAction(completed.Action)}，容器列表已刷新")
                    : string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"Docker 容器已{FormatDockerAction(completed.Action)}，切回该会话后将刷新列表");
                var completedSummary = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Docker 容器{FormatDockerAction(completed.Action)}完成");
                owner.DockerStatus = completedStatus;
                owner.SessionActionSummary = completedSummary;
                if (IsDockerOwnerVisible(owner, workspaceId, serverId))
                {
                    DockerStatus = completedStatus;
                    SessionActionSummary = completedSummary;
                    PublishDockerFeedback(
                        refreshed ? DockerFeedbackKind.Success : DockerFeedbackKind.Warning,
                        refreshed
                            ? string.Concat("容器", FormatDockerAction(completed.Action), "完成")
                            : string.Concat("容器", FormatDockerAction(completed.Action), "完成，但刷新失败"),
                        refreshed ? selectedContainerName : completedStatus);
                    SaveRuntimeStateToSelectedWorkspaceTab();
                }
                else
                {
                    AddRecentDockerOperation(
                        refreshed ? DockerFeedbackKind.Success : DockerFeedbackKind.Warning,
                        string.Concat("容器", FormatDockerAction(completed.Action), "完成"),
                        completedStatus,
                        owner.Title);
                }
                break;
            case DockerActionResult.Failed failed:
                var failedStatus = string.Concat("容器", actionLabel, "失败：", FormatDockerFailure(failed.Code));
                var failedSummary = string.Concat("Docker 容器", actionLabel, "失败");
                owner.DockerStatus = failedStatus;
                owner.SessionActionSummary = failedSummary;
                if (IsDockerOwnerVisible(owner, workspaceId, serverId))
                {
                    DockerStatus = failedStatus;
                    SessionActionSummary = failedSummary;
                    PublishDockerFeedback(DockerFeedbackKind.Error, string.Concat("容器", actionLabel, "失败"), failedStatus);
                    SaveRuntimeStateToSelectedWorkspaceTab();
                }
                else
                {
                    AddRecentDockerOperation(
                        DockerFeedbackKind.Error,
                        string.Concat("容器", actionLabel, "失败"),
                        failedStatus,
                        owner.Title);
                }
                break;
        }

        RefreshCommands();
    }

    private void PublishDockerFeedback(DockerFeedbackKind kind, string title, string message)
    {
        dockerFeedbackGeneration++;
        dockerFeedbackKind = kind;
        IsDockerFeedbackFadingOut = false;
        DockerFeedbackTitle = title;
        DockerFeedbackMessage = message;
        NotifyDockerFeedbackChanged();

        if (kind is DockerFeedbackKind.Success or DockerFeedbackKind.Warning or DockerFeedbackKind.Error)
        {
            AddRecentDockerOperation(kind, title, message);
            var visibleDuration = kind switch
            {
                DockerFeedbackKind.Success => TimeSpan.FromSeconds(3),
                DockerFeedbackKind.Warning => TimeSpan.FromSeconds(4),
                _ => TimeSpan.FromSeconds(5),
            };
            _ = AutoDismissDockerFeedbackAsync(dockerFeedbackGeneration, visibleDuration);
        }
    }

    private async Task AutoDismissDockerFeedbackAsync(int generation, TimeSpan visibleDuration)
    {
        await Task.Delay(visibleDuration).ConfigureAwait(true);
        if (generation == dockerFeedbackGeneration &&
            dockerFeedbackKind is DockerFeedbackKind.Success or DockerFeedbackKind.Warning or DockerFeedbackKind.Error)
        {
            IsDockerFeedbackFadingOut = true;
            await Task.Delay(TimeSpan.FromMilliseconds(180)).ConfigureAwait(true);
            if (generation == dockerFeedbackGeneration)
            {
                ClearDockerFeedback();
            }
        }
    }

    private void AddRecentDockerOperation(DockerFeedbackKind kind, string title, string message)
    {
        var contextText = SelectedDockerContainer?.Name ?? SelectedAsset?.Name ?? SelectedWorkspaceTab?.Title ?? "当前会话";
        AddRecentDockerOperation(kind, title, message, contextText);
    }

    private void AddRecentDockerOperation(
        DockerFeedbackKind kind,
        string title,
        string message,
        string contextText)
    {
        var kindText = kind switch
        {
            DockerFeedbackKind.Success => "成功",
            DockerFeedbackKind.Warning => "注意",
            _ => "失败",
        };
        RecentDockerOperations.Insert(
            0,
            new DockerRecentOperationViewModel(
                utcNow().ToLocalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture),
                contextText,
                kindText,
                title,
                message));
        while (RecentDockerOperations.Count > MaximumRecentDockerOperations)
        {
            RecentDockerOperations.RemoveAt(RecentDockerOperations.Count - 1);
        }

        OnPropertyChanged(nameof(HasRecentDockerOperations));
        OnPropertyChanged(nameof(RecentDockerOperationSummary));
    }

    private void ClearDockerFeedback()
    {
        dockerFeedbackGeneration++;
        dockerFeedbackKind = DockerFeedbackKind.None;
        IsDockerFeedbackFadingOut = false;
        DockerFeedbackTitle = string.Empty;
        DockerFeedbackMessage = string.Empty;
        NotifyDockerFeedbackChanged();
    }

    private void NotifyDockerFeedbackChanged()
    {
        OnPropertyChanged(nameof(HasDockerFeedback));
        OnPropertyChanged(nameof(IsDockerFeedbackInProgress));
        OnPropertyChanged(nameof(IsDockerFeedbackSuccess));
        OnPropertyChanged(nameof(IsDockerFeedbackWarning));
        OnPropertyChanged(nameof(IsDockerFeedbackError));
    }

    private async Task<bool> RefreshDockerContainersAfterActionAsync(
        WorkspaceTabViewModel owner,
        Guid workspaceId,
        Guid serverId,
        string containerId,
        string action,
        CancellationToken cancellationToken)
    {
        var result = await Task.Run(
                async () => await orchestrator.ListDockerContainersAsync(
                    workspaceId,
                    serverId,
                    cancellationToken).ConfigureAwait(false),
                cancellationToken)
            .ConfigureAwait(true);

        if (!owner.IsConnected || !WorkspaceTabs.Contains(owner))
        {
            return false;
        }

        switch (result)
        {
            case DockerContainersResult.Listed listed:
                SynchronizeDockerContainersForOwner(owner, listed.Containers, containerId);
                owner.DockerSummary = owner.DockerContainers.Count == 0
                    ? "未发现 Docker 容器"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"已读取 {owner.DockerContainers.Count} 个 Docker 容器");
                if (IsDockerOwnerVisible(owner, workspaceId, serverId))
                {
                    lastDockerContainerRefreshAt = utcNow();
                    DockerSummary = owner.DockerSummary;
                }
                return true;
            case DockerContainersResult.Failed failed:
                owner.DockerStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Docker 容器已{FormatDockerAction(action)}，但刷新容器列表失败");
                owner.DockerSummary = failed.Code;
                if (IsDockerOwnerVisible(owner, workspaceId, serverId))
                {
                    DockerStatus = owner.DockerStatus;
                    DockerSummary = owner.DockerSummary;
                }
                return false;
        }

        return false;
    }

    private bool IsDockerOwnerVisible(WorkspaceTabViewModel owner, Guid workspaceId, Guid serverId) =>
        ReferenceEquals(owner, SelectedWorkspaceTab) &&
        IsConnected &&
        CurrentWorkspaceId == workspaceId &&
        draftAssetId == serverId;

    private void SynchronizeDockerContainersForOwner(
        WorkspaceTabViewModel owner,
        IReadOnlyList<DockerContainer> containers,
        string? selectedContainerId)
    {
        if (ReferenceEquals(owner, SelectedWorkspaceTab))
        {
            SynchronizeDockerContainers(containers, selectedContainerId);
            owner.DockerContainers.Clear();
            owner.DockerContainers.AddRange(DockerContainers);
            owner.SelectedDockerContainer = SelectedDockerContainer;
            return;
        }

        var statsById = owner.DockerStats.ToDictionary(
            static item => item.Id,
            StringComparer.OrdinalIgnoreCase);
        owner.DockerContainers.Clear();
        foreach (var container in containers)
        {
            var item = ToDockerContainerViewModel(container);
            if (statsById.TryGetValue(item.Id, out var stats))
            {
                item.WithStats(stats);
            }
            owner.DockerContainers.Add(item);
        }
        owner.SelectedDockerContainer = selectedContainerId is null
            ? null
            : owner.DockerContainers.FirstOrDefault(item =>
                string.Equals(item.Id, selectedContainerId, StringComparison.OrdinalIgnoreCase));
    }

    private void SynchronizeDockerContainers(
        IReadOnlyList<DockerContainer> containers,
        string? selectedContainerId)
    {
        var statsById = DockerStats.ToDictionary(
            static item => item.Id,
            StringComparer.OrdinalIgnoreCase);
        var desiredIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var desiredIndex = 0; desiredIndex < containers.Count; desiredIndex++)
        {
            var snapshot = ToDockerContainerViewModel(containers[desiredIndex]);
            desiredIds.Add(snapshot.Id);
            var existing = DockerContainers.FirstOrDefault(item =>
                string.Equals(item.Id, snapshot.Id, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                existing = snapshot;
                DockerContainers.Insert(Math.Min(desiredIndex, DockerContainers.Count), existing);
            }
            else
            {
                existing.UpdateContainer(snapshot);
                var currentIndex = DockerContainers.IndexOf(existing);
                if (currentIndex != desiredIndex)
                {
                    DockerContainers.Move(currentIndex, desiredIndex);
                }
            }

            if (statsById.TryGetValue(existing.Id, out var stats))
            {
                existing.WithStats(stats);
            }
        }

        for (var index = DockerContainers.Count - 1; index >= 0; index--)
        {
            if (!desiredIds.Contains(DockerContainers[index].Id))
            {
                DockerContainers.RemoveAt(index);
            }
        }

        SelectedDockerContainer = selectedContainerId is null
            ? null
            : DockerContainers.FirstOrDefault(item =>
                string.Equals(item.Id, selectedContainerId, StringComparison.OrdinalIgnoreCase));
    }

    private void SynchronizeDockerStats(IReadOnlyList<DockerStatsItem> stats)
    {
        var desiredIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var desiredIndex = 0; desiredIndex < stats.Count; desiredIndex++)
        {
            var snapshot = ToDockerStatsViewModel(stats[desiredIndex]);
            desiredIds.Add(snapshot.Id);
            var existingIndex = -1;
            for (var index = 0; index < DockerStats.Count; index++)
            {
                if (string.Equals(DockerStats[index].Id, snapshot.Id, StringComparison.OrdinalIgnoreCase))
                {
                    existingIndex = index;
                    break;
                }
            }

            if (existingIndex < 0)
            {
                DockerStats.Insert(Math.Min(desiredIndex, DockerStats.Count), snapshot);
            }
            else
            {
                if (DockerStats[existingIndex] != snapshot)
                {
                    DockerStats[existingIndex] = snapshot;
                }
                if (existingIndex != desiredIndex)
                {
                    DockerStats.Move(existingIndex, desiredIndex);
                }
            }
        }

        for (var index = DockerStats.Count - 1; index >= 0; index--)
        {
            if (!desiredIds.Contains(DockerStats[index].Id))
            {
                DockerStats.RemoveAt(index);
            }
        }
    }

    private bool CanRunBatchCommand()
    {
        return BatchAssetTargets.Any(target => target.IsSelected) &&
            !string.IsNullOrWhiteSpace(BatchCommandText) &&
            System.Text.Encoding.UTF8.GetByteCount(BatchCommandText) <= 8 * 1024 &&
            !BatchCommandText.Any(char.IsControl) &&
            !HasActiveBatchContinuousSessions;
    }

    private async Task RunBatchCommandAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CanRunBatchCommand())
        {
            BatchStatus = "请选择至少一个 SSH 资产，并输入一条不含换行的命令";
            RefreshCommands();
            return;
        }

        if (IsBatchContinuousMode)
        {
            await StartContinuousBatchCommandAsync(cancellationToken).ConfigureAwait(true);
            return;
        }

        var command = BatchCommandText;
        var targets = BatchAssetTargets
            .Where(target => target.IsSelected)
            .ToArray();
        BatchTotalCount = targets.Length;
        BatchCompletedCount = 0;
        BatchSucceededCount = 0;
        BatchProgressText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"已处理 0 / {targets.Length} · 成功 0");
        BatchCurrentTarget = "正在准备安全执行环境";
        BatchStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"正在向 {targets.Length} 个 SSH 资产执行批量命令");
        BatchOutputText = string.Empty;
        BatchCommandReceipts.Clear();
        RefreshBatchResultFilter();
        var receipts = new List<string>(targets.Length);
        var succeeded = 0;
        var completedCount = 0;
        try
        {
            foreach (var target in targets)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var ordinal = completedCount + 1;
                var asset = Assets.FirstOrDefault(candidate => candidate.Id == target.AssetId);
                void RecordReceipt(bool isSuccess, string output)
                {
                    var receipt = new BatchCommandReceiptViewModel(
                        target.AssetId,
                        target.Name,
                        target.Endpoint,
                        isSuccess,
                        output);
                    BatchCommandReceipts.Add(receipt);
                    receipts.Add(receipt.DisplayText);
                    RefreshBatchResultFilter();
                }
                var activeWorkspace = FindVerifiedBatchWorkspace(target.AssetId);
                var workspaceId = activeWorkspace?.WorkspaceId ?? Guid.NewGuid();
                var temporarySession = false;
                try
                {
                    BatchCurrentTarget = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"第 {ordinal} / {targets.Length} 台 · {target.Name} · 正在检查会话");
                    BatchStatus = string.Concat("正在处理：", target.Name, "（", target.Endpoint, "）");
                    if (asset is null && activeWorkspace is null)
                    {
                        target.SetState("资产已不存在");
                        RecordReceipt(false, "执行未完成：资产已不存在。");
                        continue;
                    }

                    if (activeWorkspace is null)
                    {
                        if (asset is null)
                        {
                            throw new InvalidOperationException("A saved asset is required for an automatic connection.");
                        }
                        target.SetState("正在安全连接");
                        BatchCurrentTarget = string.Create(
                            System.Globalization.CultureInfo.InvariantCulture,
                            $"第 {ordinal} / {targets.Length} 台 · {target.Name} · 正在安全连接");
                        var connectResult = await Task.Run(
                            async () => await orchestrator.ConnectAsync(
                                workspaceId,
                                CreateServerAsset(asset),
                                cancellationToken).ConfigureAwait(false),
                            cancellationToken).ConfigureAwait(true);
                        switch (connectResult)
                        {
                            case ConnectResult.Connected:
                                temporarySession = true;
                                target.SetState("已临时连接 · 正在执行");
                                break;
                            case ConnectResult.RequiresHostKeyTrust:
                                target.SetState("需确认主机密钥");
                                RecordReceipt(false, "未执行：此服务器需要首次确认主机密钥，请先在资产列表中单独连接并确认。");
                                continue;
                            case ConnectResult.Blocked:
                                target.SetState("主机密钥异常 · 已阻止");
                                RecordReceipt(false, "未执行：服务器主机密钥与已保存记录不一致，连接已安全阻止。");
                                continue;
                            case ConnectResult.Failed:
                                target.SetState("连接失败");
                                RecordReceipt(false, "未执行：无法建立安全连接，请检查网络、地址和凭据。");
                                continue;
                        }
                    }
                    else
                    {
                        target.SetState("复用已验证会话 · 正在执行");
                    }

                    BatchCurrentTarget = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"第 {ordinal} / {targets.Length} 台 · {target.Name} · 命令已发送，等待返回");

                    // Native checked execution can block on remote I/O; keep it off the WinUI dispatcher.
                    var result = await Task.Run(
                        async () => await orchestrator.RunBatchCommandAsync(
                            workspaceId,
                            target.AssetId,
                            command,
                            cancellationToken).ConfigureAwait(false),
                        cancellationToken).ConfigureAwait(true);
                    switch (result)
                    {
                        case BatchExecResult.Completed completed:
                            succeeded++;
                            BatchSucceededCount = succeeded;
                            target.SetState(activeWorkspace is null ? "执行成功 · 临时连接已释放" : "执行成功 · 已连接");
                            RecordReceipt(true, FormatBatchOutput(completed.Stdout, completed.Stderr));
                            break;
                        case BatchExecResult.Failed failed:
                            target.SetState("执行失败");
                            RecordReceipt(false, string.Concat("执行失败：", failed.MessageKey));
                            break;
                    }
                }
                catch (OperationCanceledException) { throw; }
                catch (InvalidOperationException)
                {
                    target.SetState("缺少可用凭据");
                    RecordReceipt(false, "未执行：此资产缺少当前 Windows 用户可读取的安全凭据，请先编辑凭据。");
                }
                catch (Exception)
                {
                    target.SetState("执行未完成");
                    RecordReceipt(false, "执行未完成，请检查该会话后重试。");
                }
                finally
                {
                    if (temporarySession)
                    {
                        try
                        {
                            await orchestrator.EndVerifiedSessionAsync(
                                workspaceId,
                                target.AssetId,
                                CancellationToken.None).ConfigureAwait(true);
                        }
                        catch
                        {
                            // The command receipt remains valid. A temporary registry lease
                            // must never turn one target cleanup into a batch-wide failure.
                        }
                    }
                    if (!cancellationToken.IsCancellationRequested)
                    {
                        completedCount++;
                        BatchCompletedCount = completedCount;
                        BatchProgressText = string.Create(
                            System.Globalization.CultureInfo.InvariantCulture,
                            $"已处理 {completedCount} / {targets.Length} · 成功 {succeeded}");
                        BatchOutputText = BoundBatchOutput(string.Join("\n\n", receipts));
                        RefreshBatchResultFilter();
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            BatchCurrentTarget = "执行已取消；未开始的目标不会收到命令";
            BatchProgressText = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"已处理 {completedCount} / {targets.Length} · 成功 {succeeded} · 已取消");
            BatchStatus = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"批量命令已取消：已处理 {completedCount} / {targets.Length} 个目标；其余目标未发送命令");
            BatchOutputText = BoundBatchOutput(string.Join("\n\n", receipts));
            RefreshBatchResultFilter();
            RefreshCommands();
            throw;
        }

        BatchCurrentTarget = "全部目标均已处理";
        BatchProgressText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"已处理 {targets.Length} / {targets.Length} · 成功 {succeeded} · 已完成");
        BatchStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"批量命令已完成：成功 {succeeded} / {targets.Length}");
        BatchOutputText = BoundBatchOutput(string.Join("\n\n", receipts));
        RefreshBatchResultFilter();
        RefreshCommands();
    }

    private async Task StartContinuousBatchCommandAsync(CancellationToken cancellationToken)
    {
        var command = BatchCommandText;
        var targets = BatchAssetTargets.Where(target => target.IsSelected).ToArray();
        var timeout = TimeSpan.FromMinutes(Math.Clamp(BatchContinuousTimeoutMinutes, 1, 120));

        BatchContinuousSessions.Clear();
        SelectedBatchContinuousSession = null;
        BatchTotalCount = targets.Length;
        BatchCompletedCount = 0;
        BatchSucceededCount = 0;
        BatchOutputText = string.Empty;
        BatchCommandReceipts.Clear();
        RefreshBatchResultFilter();
        BatchResultViewIndex = 1;
        BatchStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"正在启动 {targets.Length} 个隔离的持续任务");
        BatchCurrentTarget = "正在准备独立 PTY";
        BatchProgressText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"已启动 0 / {targets.Length}");

        var started = 0;
        var prepared = 0;
        try
        {
            foreach (var target in targets)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var asset = Assets.FirstOrDefault(candidate => candidate.Id == target.AssetId);
                var activeWorkspace = FindVerifiedBatchWorkspace(target.AssetId);
                var workspaceId = activeWorkspace?.WorkspaceId ?? Guid.NewGuid();
                var sessionStartedAt = utcNow();
                var session = new BatchContinuousSessionViewModel(
                    Guid.NewGuid(),
                    target.AssetId,
                    target.Name,
                    target.Endpoint,
                    sessionStartedAt,
                    sessionStartedAt.Add(timeout),
                    IsFullScreenBatchCommand(command));
                BatchContinuousSessions.Add(session);
                SelectedBatchContinuousSession ??= session;
                var temporarySession = false;
                var runtimeRegistered = false;
                try
                {
                    BatchCurrentTarget = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"第 {prepared + 1} / {targets.Length} 台 · {target.Name} · 正在准备");
                    if (asset is null && activeWorkspace is null)
                    {
                        target.SetState("资产已不存在");
                        session.MarkFailed("资产已不存在", utcNow());
                        continue;
                    }

                    if (activeWorkspace is null)
                    {
                        if (asset is null)
                        {
                            throw new InvalidOperationException("A saved asset is required for an automatic connection.");
                        }
                        target.SetState("持续任务 · 正在连接");
                        session.MarkConnecting();
                        var connectResult = await Task.Run(
                            async () => await orchestrator.ConnectAsync(
                                workspaceId,
                                CreateServerAsset(asset),
                                cancellationToken).ConfigureAwait(false),
                            cancellationToken).ConfigureAwait(true);
                        switch (connectResult)
                        {
                            case ConnectResult.Connected:
                                temporarySession = true;
                                break;
                            case ConnectResult.RequiresHostKeyTrust:
                                target.SetState("需先确认主机密钥");
                                session.MarkFailed("需先单独连接并确认主机密钥", utcNow());
                                continue;
                            case ConnectResult.Blocked:
                                target.SetState("主机密钥异常 · 已阻止");
                                session.MarkFailed("主机密钥异常，连接已阻止", utcNow());
                                continue;
                            case ConnectResult.Failed:
                                target.SetState("持续任务连接失败");
                                session.MarkFailed("无法建立安全连接", utcNow());
                                continue;
                        }
                    }

                    BatchCurrentTarget = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"第 {prepared + 1} / {targets.Length} 台 · {target.Name} · 正在打开独立 PTY");
                    var openResult = await Task.Run(
                        async () => await orchestrator.OpenTerminalAsync(
                            workspaceId,
                            target.AssetId,
                            new TerminalSize(120, 32),
                            cancellationToken).ConfigureAwait(false),
                        cancellationToken).ConfigureAwait(true);
                    if (openResult is TerminalOpenResult.Failed failed)
                    {
                        target.SetState("持续任务终端打开失败");
                        session.MarkFailed(failed.MessageKey, utcNow());
                        continue;
                    }

                    var lease = ((TerminalOpenResult.Opened)openResult).Lease;
                    var runtime = new BatchContinuousRuntime(
                        session,
                        lease,
                        workspaceId,
                        target.AssetId,
                        temporarySession);
                    batchContinuousRuntimes[session.Id] = runtime;
                    batchContinuousSessionsByChannel[lease.TerminalChannelId] = session;
                    runtimeRegistered = true;

                    var writeResult = await Task.Run(
                        async () => await orchestrator.WriteTerminalAsync(
                            lease,
                            System.Text.Encoding.UTF8.GetBytes(string.Concat(command, "\n")),
                            cancellationToken).ConfigureAwait(false),
                        cancellationToken).ConfigureAwait(true);
                    if (writeResult is TerminalControlOutcome.Failed writeFailed)
                    {
                        await StopBatchContinuousRuntimeAsync(
                            runtime,
                            string.Concat("命令发送失败：", writeFailed.MessageKey),
                            sendInterrupt: false).ConfigureAwait(true);
                        target.SetState("持续任务发送失败");
                        continue;
                    }

                    target.SetState("持续任务运行中");
                    session.MarkRunning();
                    started++;
                    BatchSucceededCount = started;
                    _ = StopBatchContinuousSessionAfterTimeoutAsync(runtime, timeout);
                    RefreshBatchContinuousState();
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (InvalidOperationException)
                {
                    target.SetState("缺少可用凭据");
                    session.MarkFailed("缺少当前 Windows 用户可读取的安全凭据", utcNow());
                }
                catch (Exception)
                {
                    target.SetState("持续任务启动失败");
                    session.MarkFailed("启动未完成，请检查会话后重试", utcNow());
                }
                finally
                {
                    if (temporarySession && !runtimeRegistered)
                    {
                        try
                        {
                            await orchestrator.EndVerifiedSessionAsync(
                                workspaceId,
                                target.AssetId,
                                CancellationToken.None).ConfigureAwait(true);
                        }
                        catch
                        {
                            // A failed temporary startup is already represented in the task card.
                        }
                    }
                    prepared++;
                    BatchCompletedCount = prepared;
                    BatchProgressText = string.Create(
                        System.Globalization.CultureInfo.InvariantCulture,
                        $"已准备 {prepared} / {targets.Length} · 运行中 {started}");
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await StopAllBatchContinuousSessionsAsync("已统一取消").ConfigureAwait(true);
            BatchStatus = "持续批量任务已取消";
            BatchCurrentTarget = "所有已打开的持续 PTY 均已关闭";
            throw;
        }

        BatchStatus = started > 0
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"持续任务已启动：运行中 {started} / {targets.Length}")
            : "持续任务未能启动，请查看各资产状态";
        BatchCurrentTarget = started > 0
            ? "输出正在按资产隔离接收；可单独停止或统一取消"
            : "没有活动的持续任务";
        BatchProgressText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"已准备 {targets.Length} / {targets.Length} · 运行中 {started}");
        RefreshBatchContinuousState();
        RefreshCommands();
    }

    public async Task StopBatchContinuousSessionAsync(Guid sessionId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (batchContinuousRuntimes.TryGetValue(sessionId, out var runtime))
        {
            await StopBatchContinuousRuntimeAsync(runtime, "已手动停止", sendInterrupt: true).ConfigureAwait(true);
        }
    }

    public Task StopAllBatchContinuousSessionsForApplicationExitAsync() =>
        StopAllBatchContinuousSessionsAsync("应用退出，任务已停止");

    private async Task StopAllBatchContinuousSessionsAsync(string reason)
    {
        foreach (var runtime in batchContinuousRuntimes.Values.ToArray())
        {
            await StopBatchContinuousRuntimeAsync(runtime, reason, sendInterrupt: true).ConfigureAwait(true);
        }
        BatchCurrentTarget = "所有持续任务均已停止";
        RefreshBatchContinuousState();
    }

    private async Task StopBatchContinuousSessionAfterTimeoutAsync(
        BatchContinuousRuntime runtime,
        TimeSpan timeout)
    {
        try
        {
            await Task.Delay(timeout, runtime.TimeoutCancellation.Token).ConfigureAwait(true);
            await StopBatchContinuousRuntimeAsync(runtime, "达到时限，已自动停止", sendInterrupt: true).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (runtime.TimeoutCancellation.IsCancellationRequested)
        {
            // A manual or unified stop owns the final state.
        }
    }

    private async Task StopBatchContinuousRuntimeAsync(
        BatchContinuousRuntime runtime,
        string reason,
        bool sendInterrupt)
    {
        if (!runtime.TryBeginStop())
        {
            return;
        }

        runtime.TimeoutCancellation.Cancel();
        runtime.Session.MarkStopping("正在停止");
        try
        {
            if (sendInterrupt)
            {
                await Task.Run(
                    async () => await orchestrator.WriteTerminalAsync(
                        runtime.Lease,
                        new byte[] { 0x03 },
                        CancellationToken.None).ConfigureAwait(false)).ConfigureAwait(true);
                await Task.Delay(160).ConfigureAwait(true);
            }

            await Task.Run(
                async () => await orchestrator.CloseTerminalAsync(
                    runtime.Lease,
                    CancellationToken.None).ConfigureAwait(false)).ConfigureAwait(true);
        }
        catch (InvalidOperationException)
        {
            // The terminal may already have closed remotely; cleanup below is idempotent.
        }
        finally
        {
            batchContinuousSessionsByChannel.Remove(runtime.Lease.TerminalChannelId);
            batchContinuousRuntimes.Remove(runtime.Session.Id);
            if (runtime.TemporaryVerifiedSession)
            {
                try
                {
                    await orchestrator.EndVerifiedSessionAsync(
                        runtime.WorkspaceId,
                        runtime.AssetId,
                        CancellationToken.None).ConfigureAwait(true);
                }
                catch
                {
                    // The isolated PTY is already closed; session cleanup is best effort.
                }
            }
            runtime.Session.MarkStopped(reason, utcNow());
            runtime.TimeoutCancellation.Dispose();
            var target = BatchAssetTargets.FirstOrDefault(candidate => candidate.AssetId == runtime.AssetId);
            target?.UpdateConnection(FindVerifiedBatchWorkspace(runtime.AssetId) is not null);
            RefreshBatchContinuousState();
        }
    }

    private void RefreshBatchContinuousState()
    {
        OnPropertyChanged(nameof(HasActiveBatchContinuousSessions));
        OnPropertyChanged(nameof(BatchContinuousSummary));
        RunBatchCommand.RaiseCanExecuteChanged();
        CancelBatchCommand.RaiseCanExecuteChanged();
    }

    private static ServerAsset CreateServerAsset(AssetViewModel asset) =>
        new(
            asset.Id,
            asset.CredentialId,
            asset.Name,
            asset.Group,
            asset.Host,
            asset.Port,
            asset.Username,
            ServerAuthMethod.Password,
            asset.Transport,
            asset.AllowPasswordFallback,
            asset.JumpHost is { } jump
                ? new JumpHostConfiguration(
                    jump.CredentialId,
                    jump.Host,
                    jump.Port,
                    jump.Username,
                    jump.AllowPasswordFallback)
                : null);

    private async Task CancelBatchCommandAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (RunBatchCommand.IsRunning)
        {
            RunBatchCommand.Cancel();
        }
        if (HasActiveBatchContinuousSessions)
        {
            BatchStatus = "正在统一停止持续任务";
            await StopAllBatchContinuousSessionsAsync("已统一取消").ConfigureAwait(true);
            BatchStatus = "所有持续任务均已停止";
        }
    }

    private static string FormatBatchOutput(string stdout, string stderr)
    {
        var output = string.IsNullOrEmpty(stderr)
            ? stdout
            : string.IsNullOrEmpty(stdout)
                ? string.Concat("标准错误\n", stderr)
                : string.Concat("标准输出\n", stdout, "\n\n标准错误\n", stderr);

        return BoundBatchOutput(output);
    }

    private static string BoundBatchOutput(string output)
    {
        return output.Length <= MaximumBatchOutputCharacters
            ? output
            : string.Concat(
                output.AsSpan(0, MaximumBatchOutputCharacters),
                "\n\n[为保护界面性能，结果已截断；请缩小命令输出范围后重试。]");
    }

    private static bool IsPotentiallyContinuousBatchCommand(string command)
    {
        var normalized = command.TrimStart();
        while (normalized.StartsWith("sudo ", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized[5..].TrimStart();
        }
        if (normalized.StartsWith("top", StringComparison.OrdinalIgnoreCase))
        {
            return !normalized.Contains(" -n ", StringComparison.OrdinalIgnoreCase) &&
                !normalized.Contains(" --iterations", StringComparison.OrdinalIgnoreCase);
        }
        if (normalized.StartsWith("ping ", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("ping6 ", StringComparison.OrdinalIgnoreCase))
        {
            return !normalized.Contains(" -c ", StringComparison.OrdinalIgnoreCase) &&
                !normalized.Contains(" --count ", StringComparison.OrdinalIgnoreCase);
        }
        return normalized.StartsWith("tail -f ", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("journalctl -f", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("watch ", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsFullScreenBatchCommand(string command)
    {
        var normalized = command.TrimStart();
        while (normalized.StartsWith("sudo ", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized[5..].TrimStart();
        }
        return normalized.Equals("top", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("top ", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("htop", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("htop ", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("watch ", StringComparison.OrdinalIgnoreCase);
    }

    private bool IsVerifiedBatchTarget(WorkspaceTabViewModel tab) =>
        tab.Transport == ServerTransport.Ssh &&
        (tab.IsConnected || (ReferenceEquals(tab, SelectedWorkspaceTab) && IsConnected));

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
        var activeLease = sftpLease;
        var requestVersion = Interlocked.Increment(ref sftpBrowseRequestVersion);
        var result = await Task.Run(
            async () => await orchestrator.ListSftpDirectoryAsync(
                activeLease,
                normalized,
                cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);

        // Rapid folder navigation may leave an older request completing after
        // the user already opened another path. Only the newest request may
        // update the visible directory.
        if (requestVersion != Volatile.Read(ref sftpBrowseRequestVersion) ||
            !ReferenceEquals(sftpLease, activeLease))
        {
            return;
        }

        SetSelectedSftpEntries([]);
        switch (result)
        {
            case SftpDirectoryListResult.Listed listed:
                SftpEntries.Clear();
                var entries = listed.Entries
                    .Select(entry => ToSftpEntryViewModel(listed.Path, entry))
                    .Where(entry => entry is not null)
                    .Cast<SftpDirectoryEntryViewModel>()
                    .OrderBy(entry => entry.IsDirectory ? 0 : 1)
                    .ThenBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase);
                foreach (var entryViewModel in entries)
                {
                    SftpEntries.Add(entryViewModel);
                }

                SftpBrowserStatus = string.Concat("已列出 ", listed.Path);
                SftpOperationStatus = "目录已刷新：文件夹优先，再按名称排序。";
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

    public void SetSelectedSftpEntries(IEnumerable<SftpDirectoryEntryViewModel> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var normalized = entries
            .Where(SftpEntries.Contains)
            .DistinctBy(static entry => entry.Path, StringComparer.Ordinal)
            .ToList();

        selectedSftpEntries.Clear();
        selectedSftpEntries.AddRange(normalized);
        var previousPrimary = SelectedSftpEntry;
        SelectedSftpEntry = normalized.Count == 0
            ? null
            : previousPrimary is not null && normalized.Contains(previousPrimary) ? previousPrimary : normalized[^1];
        OnPropertyChanged(nameof(SelectedSftpEntries));
        OnPropertyChanged(nameof(SelectedSftpEntryCount));
        OnPropertyChanged(nameof(SftpSelectionSummary));
        OnPropertyChanged(nameof(CanDownloadSelectedSftpEntry));
        OnPropertyChanged(nameof(CanPreviewSelectedSftpText));
        OnPropertyChanged(nameof(CanMutateSelectedSftpEntry));
        OnPropertyChanged(nameof(CanChangeSelectedSftpPermissions));
        OnPropertyChanged(nameof(CanDownloadSelectedSftpEntries));
        OnPropertyChanged(nameof(CanDeleteSelectedSftpEntries));
        OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
    }

    private IReadOnlyList<SftpDirectoryEntryViewModel> GetEffectiveSftpSelection()
    {
        if (selectedSftpEntries.Count > 0)
        {
            return selectedSftpEntries;
        }

        return SelectedSftpEntry is null ? [] : [SelectedSftpEntry];
    }

    private SftpTransferQueueContext GetCurrentSftpTransferContext() =>
        GetOrCreateSftpTransferContext(SelectedWorkspaceTab ?? throw new InvalidOperationException("A workspace tab is required for SFTP transfers."));

    private SftpTransferQueueContext GetOrCreateSftpTransferContext(WorkspaceTabViewModel owner)
    {
        if (sftpTransferContexts.TryGetValue(owner.Id, out var existing))
        {
            return existing;
        }

        var created = new SftpTransferQueueContext(owner);
        sftpTransferContexts.Add(owner.Id, created);
        return created;
    }

    private bool IsVisibleSftpTransferContext(SftpTransferQueueContext context) =>
        ReferenceEquals(context.Owner, SelectedWorkspaceTab);

    private void RestoreSftpTransferContext(WorkspaceTabViewModel owner)
    {
        var context = GetOrCreateSftpTransferContext(owner);
        ReplaceCollection(SftpTransferTasks, context.Tasks);
        ReplaceCollection(ActiveSftpTransferTasks, context.ActiveTasks);
        ReplaceCollection(CompletedSftpTransferTasks, context.CompletedTasks);
        IsSftpBatchRunning = context.IsBatchRunning;
        SftpTransferStatus = context.TransferStatus;
        NotifySftpTransferQueueChanged();
        OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
    }

    private static void ReplaceCollection<T>(ObservableCollection<T> target, IEnumerable<T> source)
    {
        target.Clear();
        foreach (var item in source)
        {
            target.Add(item);
        }
    }

    private int GetTotalActiveSftpTransferCount() => sftpTransferContexts.Values.Sum(static context =>
        context.Tasks.Count(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused));

    private void SetSftpBatchRunning(SftpTransferQueueContext context, bool value)
    {
        context.IsBatchRunning = value;
        if (IsVisibleSftpTransferContext(context))
        {
            IsSftpBatchRunning = value;
        }
        else
        {
            OnPropertyChanged(nameof(HasActiveSftpTransfers));
            OnPropertyChanged(nameof(SftpExitProtectionMessage));
        }
    }

    private void SetSftpTransferStatus(SftpTransferQueueContext context, string value)
    {
        context.TransferStatus = value;
        if (IsVisibleSftpTransferContext(context))
        {
            SftpTransferStatus = value;
        }
    }

    private void SetSftpTransferRetries(
        SftpTransferQueueContext context,
        SftpTransferRetryRequest? transferRetry,
        SftpBatchRetryRequest? batchRetry)
    {
        context.LastTransferRetry = transferRetry;
        context.LastBatchRetry = batchRetry;
        if (IsVisibleSftpTransferContext(context))
        {
            OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
        }
    }

    private void PublishSftpFeedbackForContext(
        SftpTransferQueueContext context,
        SftpFeedbackKind kind,
        string title,
        string message)
    {
        if (IsVisibleSftpTransferContext(context))
        {
            PublishSftpFeedback(kind, title, message);
        }
    }

    private SftpTransferTaskViewModel EnqueueSftpTransfer(
        SftpTransferQueueContext context,
        string fileName,
        string remotePath,
        SftpTransferDirection direction,
        string statusText = "等待处理")
    {
        while (context.Tasks.Count >= MaximumSftpTransferTasks)
        {
            var removable = context.Tasks.FirstOrDefault(static task => task.State is not (SftpTransferTaskState.Running or SftpTransferTaskState.Paused));
            if (removable is null)
            {
                break;
            }
            context.Tasks.Remove(removable);
            context.ActiveTasks.Remove(removable);
            context.CompletedTasks.Remove(removable);
        }

        var task = new SftpTransferTaskViewModel(Guid.NewGuid(), fileName, remotePath, direction, statusText);
        context.Tasks.Insert(0, task);
        context.ActiveTasks.Add(task);
        SynchronizeVisibleSftpTransferContext(context);
        return task;
    }

    private void PromoteSftpTransferTask(SftpTransferQueueContext context, SftpTransferTaskViewModel task)
    {
        if (!context.ActiveTasks.Remove(task))
        {
            context.CompletedTasks.Remove(task);
        }
        context.ActiveTasks.Insert(0, task);
        SynchronizeVisibleSftpTransferContext(context);
    }

    private void ArchiveCompletedSftpTransfer(SftpTransferQueueContext context, SftpTransferTaskViewModel task)
    {
        context.ActiveTasks.Remove(task);
        context.CompletedTasks.Remove(task);
        context.CompletedTasks.Insert(0, task);
        while (context.CompletedTasks.Count > MaximumSftpTransferTasks)
        {
            context.CompletedTasks.RemoveAt(context.CompletedTasks.Count - 1);
        }
        SynchronizeVisibleSftpTransferContext(context);
    }

    private void SynchronizeVisibleSftpTransferContext(SftpTransferQueueContext context)
    {
        if (!IsVisibleSftpTransferContext(context))
        {
            OnPropertyChanged(nameof(HasActiveSftpTransfers));
            OnPropertyChanged(nameof(SftpExitProtectionMessage));
            return;
        }

        ReplaceCollection(SftpTransferTasks, context.Tasks);
        ReplaceCollection(ActiveSftpTransferTasks, context.ActiveTasks);
        ReplaceCollection(CompletedSftpTransferTasks, context.CompletedTasks);
        NotifySftpTransferQueueChanged();
    }

    private void NotifySftpTransferQueueChanged()
    {
        OnPropertyChanged(nameof(SftpTransferQueueSummary));
        OnPropertyChanged(nameof(ActiveSftpTransferSummary));
        OnPropertyChanged(nameof(CompletedSftpTransferSummary));
        OnPropertyChanged(nameof(HasActiveSftpTransfers));
        OnPropertyChanged(nameof(ActiveSftpTransferCount));
        OnPropertyChanged(nameof(SftpExitProtectionMessage));
        ClearCompletedSftpTransfersCommand.RaiseCanExecuteChanged();
    }

    private void NotifySftpTransferQueueChanged(SftpTransferQueueContext context)
    {
        if (IsVisibleSftpTransferContext(context))
        {
            NotifySftpTransferQueueChanged();
            return;
        }

        OnPropertyChanged(nameof(HasActiveSftpTransfers));
        OnPropertyChanged(nameof(SftpExitProtectionMessage));
    }

    private static bool IsTerminalSftpTransferState(SftpTransferTaskState state) =>
        state is SftpTransferTaskState.Completed or
            SftpTransferTaskState.Failed or
            SftpTransferTaskState.Cancelled or
            SftpTransferTaskState.Skipped;

    private Task ClearCompletedSftpTransfersAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var transferContext = GetCurrentSftpTransferContext();
        var completedTasks = transferContext.Tasks
            .Where(static task => IsTerminalSftpTransferState(task.State))
            .ToList();
        foreach (var task in completedTasks)
        {
            transferContext.Tasks.Remove(task);
            transferContext.ActiveTasks.Remove(task);
            transferContext.CompletedTasks.Remove(task);
        }
        SynchronizeVisibleSftpTransferContext(transferContext);
        if (completedTasks.Count > 0)
        {
            PublishSftpFeedback(
                SftpFeedbackKind.Success,
                "传输记录已清理",
                string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"已清理 {completedTasks.Count} 项已完成、失败或已停止的传输任务"));
        }
        return Task.CompletedTask;
    }

    public IReadOnlyList<string> GetSftpUploadConflictNames(IReadOnlyList<SftpUploadSource> sources)
    {
        ArgumentNullException.ThrowIfNull(sources);
        var remoteNames = SftpEntries.Select(static entry => entry.Name).ToHashSet(StringComparer.Ordinal);
        var planned = new HashSet<string>(StringComparer.Ordinal);
        return sources
            .Where(source => remoteNames.Contains(source.FileName) || !planned.Add(source.FileName))
            .Select(static source => source.FileName)
            .Distinct(StringComparer.Ordinal)
            .ToList();
    }

    public async Task DownloadSelectedSftpEntryAsync(string localPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null || SelectedSftpEntry is not { IsDirectory: false } selected)
        {
            SftpOperationStatus = "Select a file to download";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法下载", "请先选择需要下载的文件");
            OnPropertyChanged(nameof(CanDownloadSelectedSftpEntry));
            return;
        }

        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);
        var normalized = NormalizeSftpPath(selected.Path);
        if (normalized is null || !Path.IsPathFullyQualified(localPath) || File.Exists(localPath))
        {
            SftpOperationStatus = "Download destination rejected";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法下载", "本地保存位置无效或存在同名文件");
            return;
        }

        SetSftpOperationStatusForOwner(owner, string.Concat("Downloading ", normalized));
        SetSftpTransferStatus(transferContext, string.Concat("正在下载：", selected.Name, "。正在安全传输，请勿关闭会话。"));
        PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.InProgress, "正在下载", selected.Name);
        var activeLease = sftpLease;
        var result = await Task.Run(
            async () => await orchestrator.DownloadSftpFileAsync(
                activeLease,
                normalized,
                localPath,
                cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);

        switch (result)
        {
            case SftpDownloadResult.Downloaded downloaded:
                SetSftpOperationStatusForOwner(owner, string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Downloaded {downloaded.ByteLength} B from {downloaded.Path}"));
                var completedStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"下载完成：{selected.Name}（{downloaded.ByteLength} B）");
                SetSftpTransferStatus(transferContext, completedStatus);
                SetSftpTransferRetries(transferContext, null, null);
                PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Success, "下载完成", completedStatus);
                break;
            case SftpDownloadResult.Failed failed:
                SetSftpOperationStatusForOwner(owner, failed.Code);
                var failedStatus = string.Concat("下载失败：", selected.Name, "。请确认连接状态；如已断线，重新连接原资产后重试。");
                SetSftpTransferStatus(transferContext, failedStatus);
                SetSftpTransferRetries(transferContext, SftpTransferRetryRequest.ForDownload(selected, localPath), null);
                PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Error, "下载失败", failedStatus);
                break;
        }

        if (IsVisibleSftpTransferContext(transferContext))
        {
            SaveRuntimeStateToSelectedWorkspaceTab();
            OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
        }
        RefreshCommands();
    }

    public async Task DownloadSelectedSftpEntriesAsync(string localDirectory, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var selectedEntries = GetEffectiveSftpSelection().ToList();
        if (sftpLease is null || selectedEntries.Count == 0 || !Path.IsPathFullyQualified(localDirectory) || !Directory.Exists(localDirectory))
        {
            SftpOperationStatus = "请选择文件或文件夹，并指定有效的本地下载目录";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
            return;
        }
        var operationLease = sftpLease;
        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);

        var plannedFiles = new List<(SftpDirectoryEntryViewModel Entry, string LocalPath)>();
        var expansionQueue = new Queue<(SftpDirectoryEntryViewModel Entry, string LocalParent, int Depth)>();
        foreach (var entry in selectedEntries)
        {
            expansionQueue.Enqueue((entry, localDirectory, 0));
        }

        while (expansionQueue.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var (entry, localParent, depth) = expansionQueue.Dequeue();
            var localPath = TryCreateSftpDownloadPath(localParent, entry.Name);
            if (localPath is null)
            {
                SftpOperationStatus = string.Concat("本地下载路径无效：", entry.Name);
                PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                return;
            }

            if (entry.IsDirectory)
            {
                if (depth >= MaximumSftpBatchDownloadDepth)
                {
                    SftpOperationStatus = string.Concat("文件夹层级超过安全限制：", entry.Path);
                    PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                    return;
                }

                try
                {
                    Directory.CreateDirectory(localPath);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PathTooLongException)
                {
                    SftpOperationStatus = string.Concat("无法创建本地文件夹：", entry.Name);
                    PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                    return;
                }

                SetSftpTransferStatus(transferContext, string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"正在扫描远程文件夹：{entry.Path}（已发现 {plannedFiles.Count} 个文件）"));
                var listing = await Task.Run(
                    async () => await orchestrator.ListSftpDirectoryAsync(
                        operationLease,
                        entry.Path,
                        cancellationToken).ConfigureAwait(false),
                    CancellationToken.None).ConfigureAwait(true);
                if (listing is not SftpDirectoryListResult.Listed listed)
                {
                    SftpOperationStatus = string.Concat("无法读取远程文件夹：", entry.Path);
                    PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                    return;
                }

                foreach (var child in listed.Entries)
                {
                    var childViewModel = ToSftpEntryViewModel(listed.Path, child);
                    if (childViewModel is null)
                    {
                        SftpOperationStatus = string.Concat("远程文件名不安全，已停止批量下载：", child.Name);
                        PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                        return;
                    }

                    expansionQueue.Enqueue((childViewModel, localPath, depth + 1));
                    if (plannedFiles.Count + expansionQueue.Count > MaximumSftpBatchDownloadEntries)
                    {
                        SftpOperationStatus = string.Create(
                            System.Globalization.CultureInfo.InvariantCulture,
                            $"批量下载超过 {MaximumSftpBatchDownloadEntries} 项安全限制，请缩小选择范围");
                        PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量下载", SftpOperationStatus);
                        return;
                    }
                }
                continue;
            }

            plannedFiles.Add((entry, localPath));
        }

        if (plannedFiles.Count == 0)
        {
            SftpOperationStatus = "所选文件夹为空，本地目录已创建";
            PublishSftpFeedback(SftpFeedbackKind.Success, "文件夹为空", SftpOperationStatus);
            return;
        }

        var pending = plannedFiles
            .Select(item => new SftpBatchDownloadItem(
                item.Entry,
                item.LocalPath,
                EnqueueSftpTransfer(transferContext, item.Entry.Name, item.Entry.Path, SftpTransferDirection.Download)))
            .ToList();
        await RunSftpBatchDownloadAsync(pending, operationLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
    }

    private async Task RunSftpBatchDownloadAsync(
        IReadOnlyList<SftpBatchDownloadItem> pending,
        SftpSessionLease batchLease,
        WorkspaceTabViewModel owner,
        SftpTransferQueueContext transferContext,
        CancellationToken cancellationToken)
    {
        if (pending.Count == 0 || transferContext.IsBatchRunning)
        {
            return;
        }

        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        transferContext.BatchCancellation?.Dispose();
        transferContext.BatchCancellation = linkedCancellation;
        SetSftpBatchRunning(transferContext, true);
        PublishSftpFeedbackForContext(
            transferContext,
            SftpFeedbackKind.InProgress,
            "正在批量下载",
            string.Create(System.Globalization.CultureInfo.InvariantCulture, $"共 {pending.Count} 个文件"));
        SetSftpTransferRetries(transferContext, null, null);
        var failed = new List<SftpBatchDownloadItem>();
        var completed = 0;
        var processed = 0;
        try
        {
            for (var index = 0; index < pending.Count; index++)
            {
                var item = pending[index];
                linkedCancellation.Token.ThrowIfCancellationRequested();
                item.Task.MarkRunning("正在下载");
                PromoteSftpTransferTask(transferContext, item.Task);
                SetSftpTransferStatus(transferContext, string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"批量下载 {index + 1}/{pending.Count}：{item.Entry.Name}"));

                if (File.Exists(item.LocalPath))
                {
                    failed.Add(item);
                    item.Task.MarkFailed("本地存在同名文件");
                    processed++;
                    continue;
                }

                var normalized = NormalizeSftpPath(item.Entry.Path);
                if (normalized is null)
                {
                    failed.Add(item);
                    item.Task.MarkFailed("远程路径无效");
                    processed++;
                    continue;
                }

                SftpDownloadResult result;
                try
                {
                    var progress = CreateSftpProgressReporter(item.Task, transferContext);
                    result = await Task.Run(
                        async () => await orchestrator.DownloadSftpFileAsync(
                            batchLease,
                            normalized,
                            item.LocalPath,
                            linkedCancellation.Token,
                            progress,
                            item.Task.TransferControl).ConfigureAwait(false),
                        CancellationToken.None).ConfigureAwait(true);
                }
                catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception)
                {
                    WriteSftpTransferDiagnostic("download", exception);
                    failed.Add(item);
                    item.Task.MarkFailed("下载异常，确认连接后可重试");
                    NotifySftpTransferQueueChanged(transferContext);
                    processed++;
                    continue;
                }
                if (result is SftpDownloadResult.Downloaded)
                {
                    completed++;
                    item.Task.MarkCompleted("下载完成");
                    ArchiveCompletedSftpTransfer(transferContext, item.Task);
                }
                else
                {
                    failed.Add(item);
                    item.Task.MarkFailed("下载失败，确认连接后可重试");
                }
                NotifySftpTransferQueueChanged(transferContext);
                processed++;
            }

            var completionStatus = failed.Count == 0
                ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量下载完成：成功 {completed}/{pending.Count}")
                : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量下载中断：成功 {completed}/{pending.Count}，失败 {failed.Count}；确认连接或重新连接原资产后可重试");
            SetSftpTransferStatus(transferContext, completionStatus);
            SetSftpOperationStatusForOwner(owner, completionStatus);
            SetSftpTransferRetries(transferContext, null, failed.Count == 0 ? null : SftpBatchRetryRequest.ForDownloads(failed));
            PublishSftpFeedbackForContext(
                transferContext,
                failed.Count == 0 ? SftpFeedbackKind.Success : SftpFeedbackKind.Error,
                failed.Count == 0 ? "批量下载完成" : "批量下载部分失败",
                completionStatus);
        }
        catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
        {
            var remaining = failed.Concat(pending.Skip(processed)).Distinct().ToList();
            foreach (var item in pending.Skip(processed))
            {
                item.Task.MarkCancelled("已取消");
            }
            var cancellationStatus = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量下载已取消：已完成 {completed}/{pending.Count}，可重试未完成项");
            SetSftpTransferRetries(transferContext, null, remaining.Count == 0 ? null : SftpBatchRetryRequest.ForDownloads(remaining));
            SetSftpTransferStatus(transferContext, cancellationStatus);
            SetSftpOperationStatusForOwner(owner, cancellationStatus);
            PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Warning, "批量下载已取消", cancellationStatus);
        }
        finally
        {
            if (ReferenceEquals(transferContext.BatchCancellation, linkedCancellation))
            {
                transferContext.BatchCancellation = null;
            }
            SetSftpBatchRunning(transferContext, false);
            NotifySftpTransferQueueChanged(transferContext);
            SaveSftpBatchResultToOwner(owner, batchLease, transferContext);
            RefreshCommands();
        }
    }

    public async Task UploadSftpFilesAsync(
        IReadOnlyList<SftpUploadSource> sources,
        SftpUploadConflictPolicy conflictPolicy,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(sources);
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null || sources.Count == 0 || sources.Count > 100)
        {
            SftpOperationStatus = "请选择 1–100 个有效本地文件后再上传";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法上传", SftpOperationStatus);
            return;
        }
        var operationLease = sftpLease;
        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);

        var remoteByName = SftpEntries.ToDictionary(static entry => entry.Name, StringComparer.Ordinal);
        var reservedNames = remoteByName.Keys.ToHashSet(StringComparer.Ordinal);
        var pending = new List<SftpBatchUploadItem>();
        foreach (var source in sources)
        {
            if (!Path.IsPathFullyQualified(source.LocalPath) ||
                !File.Exists(source.LocalPath) ||
                !IsSafeSftpChildName(source.FileName))
            {
                var rejectedPath = TryCombineSftpChildPath(SftpPathText, source.FileName) ?? SftpPathText;
                var rejectedTask = EnqueueSftpTransfer(transferContext, source.FileName, rejectedPath, SftpTransferDirection.Upload);
                rejectedTask.MarkFailed("本地文件或远程名称无效");
                continue;
            }

            var requestedRemotePath = TryCombineSftpChildPath(SftpPathText, source.FileName);
            if (requestedRemotePath is null)
            {
                var rejectedTask = EnqueueSftpTransfer(transferContext, source.FileName, SftpPathText, SftpTransferDirection.Upload);
                rejectedTask.MarkFailed("远程路径无效");
                continue;
            }

            remoteByName.TryGetValue(source.FileName, out var existing);
            var isBatchDuplicate = pending.Any(item => string.Equals(item.RequestedFileName, source.FileName, StringComparison.Ordinal));
            if ((existing is not null || isBatchDuplicate) && conflictPolicy == SftpUploadConflictPolicy.Skip)
            {
                var skippedTask = EnqueueSftpTransfer(transferContext, source.FileName, requestedRemotePath, SftpTransferDirection.Upload);
                skippedTask.MarkSkipped("已跳过同名项目");
                ArchiveCompletedSftpTransfer(transferContext, skippedTask);
                continue;
            }

            var targetFileName = source.FileName;
            var replaceExisting = existing;
            if ((existing is not null || isBatchDuplicate) &&
                (conflictPolicy == SftpUploadConflictPolicy.KeepBoth || isBatchDuplicate))
            {
                targetFileName = CreateUniqueSftpFileName(source.FileName, reservedNames);
                replaceExisting = null;
            }

            reservedNames.Add(targetFileName);
            var remotePath = TryCombineSftpChildPath(SftpPathText, targetFileName);
            if (remotePath is null)
            {
                var rejectedTask = EnqueueSftpTransfer(transferContext, source.FileName, SftpPathText, SftpTransferDirection.Upload);
                rejectedTask.MarkFailed("远程路径无效");
                continue;
            }

            var transferTask = EnqueueSftpTransfer(transferContext, source.FileName, remotePath, SftpTransferDirection.Upload);
            pending.Add(new SftpBatchUploadItem(
                source,
                source.FileName,
                remotePath,
                replaceExisting,
                conflictPolicy,
                transferTask));
        }

        NotifySftpTransferQueueChanged(transferContext);
        if (pending.Count == 0)
        {
            const string noFilesStatus = "没有需要上传的文件";
            SetSftpTransferStatus(transferContext, noFilesStatus);
            PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Warning, "没有可上传项目", noFilesStatus);
            return;
        }

        await RunSftpBatchUploadAsync(pending, operationLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
    }

    private async Task RunSftpBatchUploadAsync(
        IReadOnlyList<SftpBatchUploadItem> pending,
        SftpSessionLease batchLease,
        WorkspaceTabViewModel owner,
        SftpTransferQueueContext transferContext,
        CancellationToken cancellationToken)
    {
        if (pending.Count == 0 || transferContext.IsBatchRunning)
        {
            return;
        }

        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        transferContext.BatchCancellation?.Dispose();
        transferContext.BatchCancellation = linkedCancellation;
        SetSftpBatchRunning(transferContext, true);
        PublishSftpFeedbackForContext(
            transferContext,
            SftpFeedbackKind.InProgress,
            "正在批量上传",
            string.Create(System.Globalization.CultureInfo.InvariantCulture, $"共 {pending.Count} 个文件"));
        SetSftpTransferRetries(transferContext, null, null);
        var failed = new List<SftpBatchUploadItem>();
        var completed = 0;
        var processed = 0;
        try
        {
            for (var index = 0; index < pending.Count; index++)
            {
                var item = pending[index];
                linkedCancellation.Token.ThrowIfCancellationRequested();
                item.Task.MarkRunning(item.Existing is null ? "正在上传" : "正在安全替换");
                PromoteSftpTransferTask(transferContext, item.Task);
                SetSftpTransferStatus(transferContext, string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"批量上传 {index + 1}/{pending.Count}：{item.Source.FileName}"));

                SftpUploadItemOutcome outcome;
                try
                {
                    outcome = await ExecuteSftpUploadItemAsync(item, batchLease, transferContext, linkedCancellation.Token).ConfigureAwait(true);
                }
                catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception)
                {
                    WriteSftpTransferDiagnostic("upload", exception);
                    outcome = new SftpUploadItemOutcome(false, "上传异常，确认连接后可重试");
                }
                if (outcome.Succeeded)
                {
                    completed++;
                    item.Task.MarkCompleted(outcome.Status);
                    ArchiveCompletedSftpTransfer(transferContext, item.Task);
                }
                else
                {
                    failed.Add(item);
                    item.Task.MarkFailed(outcome.Status);
                }
                processed++;
                NotifySftpTransferQueueChanged(transferContext);
            }

            var completionStatus = failed.Count == 0
                ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量上传完成：成功 {completed}/{pending.Count}")
                : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量上传中断：成功 {completed}/{pending.Count}，失败 {failed.Count}；确认连接或重新连接原资产后可重试");
            SetSftpTransferStatus(transferContext, completionStatus);
            SetSftpOperationStatusForOwner(owner, completionStatus);
            SetSftpTransferRetries(transferContext, null, failed.Count == 0 ? null : SftpBatchRetryRequest.ForUploads(failed));
            PublishSftpFeedbackForContext(
                transferContext,
                failed.Count == 0 ? SftpFeedbackKind.Success : SftpFeedbackKind.Error,
                failed.Count == 0 ? "批量上传完成" : "批量上传部分失败",
                completionStatus);
        }
        catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
        {
            var remaining = failed.Concat(pending.Skip(processed)).Distinct().ToList();
            foreach (var item in pending.Skip(processed))
            {
                item.Task.MarkCancelled("已取消");
            }
            var cancellationStatus = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量上传已取消：已完成 {completed}/{pending.Count}，可重试未完成项");
            SetSftpTransferRetries(transferContext, null, remaining.Count == 0 ? null : SftpBatchRetryRequest.ForUploads(remaining));
            SetSftpTransferStatus(transferContext, cancellationStatus);
            SetSftpOperationStatusForOwner(owner, cancellationStatus);
            PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Warning, "批量上传已取消", cancellationStatus);
        }
        finally
        {
            if (completed > 0 && IsCurrentSftpContext(owner, batchLease))
            {
                await PrepareSftpBrowseAsync(CancellationToken.None).ConfigureAwait(true);
                SetSftpOperationStatusForOwner(owner, transferContext.TransferStatus);
            }
            if (ReferenceEquals(transferContext.BatchCancellation, linkedCancellation))
            {
                transferContext.BatchCancellation = null;
            }
            SetSftpBatchRunning(transferContext, false);
            NotifySftpTransferQueueChanged(transferContext);
            SaveSftpBatchResultToOwner(owner, batchLease, transferContext);
            RefreshCommands();
        }
    }

    private async Task<SftpUploadItemOutcome> ExecuteSftpUploadItemAsync(
        SftpBatchUploadItem item,
        SftpSessionLease batchLease,
        SftpTransferQueueContext transferContext,
        CancellationToken cancellationToken)
    {
        if (item.Existing is { IsDirectory: true })
        {
            return new SftpUploadItemOutcome(false, "同名目标是文件夹，无法覆盖");
        }

        if (item.Existing is null)
        {
            var progress = CreateSftpProgressReporter(item.Task, transferContext);
            var result = await Task.Run(
                async () => await orchestrator.UploadSftpFileAsync(
                    batchLease,
                    item.Source.LocalPath,
                    item.RemotePath,
                    cancellationToken,
                    progress,
                    item.Task.TransferControl).ConfigureAwait(false),
                CancellationToken.None).ConfigureAwait(true);
            return result is SftpUploadResult.Uploaded uploaded
                ? new SftpUploadItemOutcome(true, string.Create(System.Globalization.CultureInfo.InvariantCulture, $"上传完成 · {uploaded.ByteLength} B"))
                : new SftpUploadItemOutcome(false, "上传失败，确认连接后可重试");
        }

        return await ReplaceSftpFileSafelyAsync(item, batchLease, transferContext, cancellationToken).ConfigureAwait(true);
    }

    private async Task<SftpUploadItemOutcome> ReplaceSftpFileSafelyAsync(
        SftpBatchUploadItem item,
        SftpSessionLease batchLease,
        SftpTransferQueueContext transferContext,
        CancellationToken cancellationToken)
    {
        if (item.Existing is null)
        {
            return new SftpUploadItemOutcome(false, "无法建立安全替换上下文");
        }

        var parentPath = GetSftpParentPath(item.RemotePath);
        var temporaryName = string.Concat(".", item.Source.FileName, ".orbitterm-", Guid.NewGuid().ToString("N"), ".upload");
        var temporaryPath = TryCombineSftpChildPath(parentPath, temporaryName);
        if (temporaryPath is null)
        {
            return new SftpUploadItemOutcome(false, "无法创建安全替换临时路径");
        }

        var progress = CreateSftpProgressReporter(item.Task, transferContext);
        var upload = await Task.Run(
            async () => await orchestrator.UploadSftpFileAsync(
                batchLease,
                item.Source.LocalPath,
                temporaryPath,
                cancellationToken,
                progress,
                item.Task.TransferControl).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);
        if (upload is not SftpUploadResult.Uploaded)
        {
            return new SftpUploadItemOutcome(false, "临时文件上传失败，原文件未修改");
        }

        var listing = await Task.Run(
            async () => await orchestrator.ListSftpDirectoryAsync(batchLease, parentPath, cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);
        if (listing is not SftpDirectoryListResult.Listed listed ||
            listed.Entries.FirstOrDefault(entry => string.Equals(entry.Name, temporaryName, StringComparison.Ordinal)) is not { } temporaryEntry)
        {
            return new SftpUploadItemOutcome(false, string.Concat("无法验证临时文件；请检查：", temporaryPath));
        }

        var temporarySnapshot = new SftpMutationSnapshot(
            temporaryEntry.Size,
            temporaryEntry.PermissionsOctal,
            temporaryEntry.ModifiedAtUnix,
            temporaryEntry.Permissions.StartsWith("d", StringComparison.Ordinal));
        var remove = await Task.Run(
            async () => await orchestrator.RemoveSftpEntryAsync(
                batchLease,
                item.Existing.Path,
                ToSftpMutationSnapshot(item.Existing),
                cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);
        if (remove is not SftpMutationResult.Completed)
        {
            await Task.Run(
                async () => await orchestrator.RemoveSftpEntryAsync(
                    batchLease,
                    temporaryPath,
                    temporarySnapshot,
                    CancellationToken.None).ConfigureAwait(false),
                CancellationToken.None).ConfigureAwait(true);
            return new SftpUploadItemOutcome(false, "远程文件已变化，已保留原文件并取消覆盖");
        }

        var rename = await Task.Run(
            async () => await orchestrator.RenameSftpEntryAsync(
                batchLease,
                temporaryPath,
                item.RemotePath,
                temporarySnapshot,
                cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);
        return rename is SftpMutationResult.Completed
            ? new SftpUploadItemOutcome(true, "安全替换完成")
            : new SftpUploadItemOutcome(false, string.Concat("替换收尾失败；临时文件保留在：", temporaryPath));
    }

    private IProgress<SftpTransferProgress> CreateSftpProgressReporter(
        SftpTransferTaskViewModel task,
        SftpTransferQueueContext transferContext)
    {
        return new Progress<SftpTransferProgress>(progress =>
        {
            task.UpdateProgress(progress.TransferredBytes, progress.TotalBytes);
            NotifySftpTransferQueueChanged(transferContext);
            if (IsVisibleSftpTransferContext(transferContext))
            {
                UpdateMonitorFromSftpTransferProgress();
            }
        });
    }

    public async Task UploadSftpFileAsync(string localPath, string localFileName, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sftpLease is null)
        {
            SftpOperationStatus = "Open SFTP before uploading";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法上传", "请先建立 SFTP 会话");
            return;
        }
        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);

        var remotePath = TryCombineSftpChildPath(SftpPathText, localFileName);
        if (remotePath is null || !Path.IsPathFullyQualified(localPath) || !File.Exists(localPath))
        {
            SftpOperationStatus = "Upload source or remote path rejected";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法上传", "本地文件或远程目标路径无效");
            return;
        }

        SetSftpOperationStatusForOwner(owner, string.Concat("Uploading ", remotePath));
        SetSftpTransferStatus(transferContext, string.Concat("正在上传：", localFileName, "。正在安全传输，请勿关闭会话。"));
        PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.InProgress, "正在上传", localFileName);
        var activeLease = sftpLease;
        var result = await Task.Run(
            async () => await orchestrator.UploadSftpFileAsync(
                activeLease,
                localPath,
                remotePath,
                cancellationToken).ConfigureAwait(false),
            CancellationToken.None).ConfigureAwait(true);

        switch (result)
        {
            case SftpUploadResult.Uploaded uploaded:
                var uploadSummary = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"Uploaded {uploaded.ByteLength} B to {uploaded.Path}");
                if (IsCurrentSftpContext(owner, activeLease))
                {
                    await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                }
                SetSftpOperationStatusForOwner(owner, uploadSummary);
                var completedStatus = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"上传完成：{localFileName}（{uploaded.ByteLength} B）");
                SetSftpTransferStatus(transferContext, completedStatus);
                SetSftpTransferRetries(transferContext, null, null);
                PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Success, "上传完成", completedStatus);
                break;
            case SftpUploadResult.Failed failed:
                SetSftpOperationStatusForOwner(owner, failed.Code);
                var failedStatus = string.Concat("上传失败：", localFileName, "。请确认网络和连接状态；如已断线，重新连接原资产后重试。");
                SetSftpTransferStatus(transferContext, failedStatus);
                SetSftpTransferRetries(transferContext, SftpTransferRetryRequest.ForUpload(localPath, remotePath), null);
                PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Error, "上传失败", failedStatus);
                break;
        }

        if (IsVisibleSftpTransferContext(transferContext))
        {
            SaveRuntimeStateToSelectedWorkspaceTab();
            OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
        }
        RefreshCommands();
    }

    private async Task RetryLastSftpTransferAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);
        if (transferContext.LastBatchRetry is { } batchRetry && sftpLease is { } retryLease)
        {
            if (batchRetry.Uploads.Count > 0)
            {
                await RunSftpBatchUploadAsync(batchRetry.Uploads, retryLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
            }
            else if (batchRetry.Downloads.Count > 0)
            {
                await RunSftpBatchDownloadAsync(batchRetry.Downloads, retryLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
            }
            else if (batchRetry.Deletes.Count > 0)
            {
                await RunSftpBatchDeleteAsync(batchRetry.Deletes, retryLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
            }
            return;
        }

        var retry = transferContext.LastTransferRetry;
        if (retry is null || sftpLease is null)
        {
            return;
        }

        var retryStatus = string.Concat("正在重试", retry.IsUpload ? "上传" : "下载", "：", retry.DisplayName);
        SetSftpTransferStatus(transferContext, retryStatus);
        PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.InProgress, "正在重试", retryStatus);
        if (retry.IsUpload)
        {
            SftpPathText = GetSftpParentPath(retry.RemotePath);
            await UploadSftpFileAsync(
                retry.LocalPath,
                Path.GetFileName(retry.RemotePath),
                cancellationToken).ConfigureAwait(true);
            return;
        }

        SelectedSftpEntry = retry.DownloadEntry;
        await DownloadSelectedSftpEntryAsync(retry.LocalPath, cancellationToken).ConfigureAwait(true);
    }

    private Task CancelSftpBatchAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var transferContext = GetCurrentSftpTransferContext();
        const string status = "正在取消批处理；当前项目完成后停止";
        SetSftpTransferStatus(transferContext, status);
        PublishSftpFeedbackForContext(transferContext, SftpFeedbackKind.Warning, "正在取消", status);
        transferContext.BatchCancellation?.Cancel();
        return Task.CompletedTask;
    }

    public void PauseSftpTransfer(SftpTransferTaskViewModel task)
    {
        var transferContext = GetCurrentSftpTransferContext();
        if (!transferContext.Tasks.Contains(task) || !task.CanPause)
        {
            return;
        }

        task.Pause();
        SetSftpTransferStatus(transferContext, string.Concat("已暂停：", task.FileName));
        NotifySftpTransferQueueChanged(transferContext);
    }

    public void ResumeSftpTransfer(SftpTransferTaskViewModel task)
    {
        var transferContext = GetCurrentSftpTransferContext();
        if (!transferContext.Tasks.Contains(task) || !task.CanResume)
        {
            return;
        }

        task.Resume();
        SetSftpTransferStatus(transferContext, string.Concat("已继续：", task.FileName));
        NotifySftpTransferQueueChanged(transferContext);
    }

    public void CancelSftpTransfer(SftpTransferTaskViewModel task)
    {
        var transferContext = GetCurrentSftpTransferContext();
        if (!transferContext.Tasks.Contains(task) || !task.CanCancel)
        {
            return;
        }

        var status = string.Concat("正在取消：", task.FileName);
        if (!task.BeginCancellation(status))
        {
            return;
        }

        SetSftpTransferStatus(transferContext, status);
        PublishSftpFeedbackForContext(
            transferContext,
            SftpFeedbackKind.Warning,
            task.Direction == SftpTransferDirection.Upload ? "已请求停止上传" : "已请求停止下载",
            status);
        try
        {
            var cancellation = transferContext.BatchCancellation;
            if (cancellation is null)
            {
                task.MarkCancelled("已取消");
            }
            else
            {
                cancellation.Cancel();
            }
        }
        catch (ObjectDisposedException)
        {
            task.MarkCancelled("已取消");
        }
        finally
        {
            // Cancellation must be visible before releasing a paused native
            // progress callback; otherwise one more transfer cycle can win the
            // race and make the first click appear to have been ignored.
            task.ReleasePauseForCancellation();
        }
        NotifySftpTransferQueueChanged(transferContext);
    }

    public async Task StopSftpTransfersForApplicationExitAsync(CancellationToken cancellationToken)
    {
        foreach (var context in sftpTransferContexts.Values.Where(static context => context.IsBatchRunning).ToArray())
        {
            context.BatchCancellation?.Cancel();
        }

        for (var attempt = 0;
             attempt < 60 && sftpTransferContexts.Values.Any(static context => context.IsBatchRunning);
             attempt++)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken).ConfigureAwait(true);
        }

        foreach (var context in sftpTransferContexts.Values)
        {
            foreach (var task in context.Tasks.Where(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused))
            {
                task.MarkCancelled("应用正在退出，可重新连接后重试");
            }
            SetSftpTransferStatus(context, "正在安全停止传输后退出…");
            NotifySftpTransferQueueChanged(context);
        }
    }

    private async Task StopActiveSftpTransfersAsync(string status, CancellationToken cancellationToken)
    {
        var transferContext = GetCurrentSftpTransferContext();
        if (!transferContext.IsBatchRunning &&
            !transferContext.Tasks.Any(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused))
        {
            return;
        }

        SetSftpTransferStatus(transferContext, status);
        transferContext.BatchCancellation?.Cancel();
        for (var attempt = 0; attempt < 60 && transferContext.IsBatchRunning; attempt++)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken).ConfigureAwait(true);
        }

        foreach (var task in transferContext.Tasks.Where(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused))
        {
            task.MarkCancelled("连接已停止，可重新连接后重试");
        }
        NotifySftpTransferQueueChanged(transferContext);
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
            SftpOperationStatus = "请先选择需要重命名的远程项目";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法重命名", SftpOperationStatus);
            return;
        }

        var parentPath = GetSftpParentPath(selected.Path);
        var newRemotePath = TryCombineSftpChildPath(parentPath, newName);
        if (newRemotePath is null || string.Equals(selected.Path, newRemotePath, StringComparison.Ordinal))
        {
            SftpOperationStatus = "新名称无效或与原名称相同";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法重命名", SftpOperationStatus);
            return;
        }

        SftpOperationStatus = string.Concat("正在重命名：", selected.Path);
        PublishSftpFeedback(SftpFeedbackKind.InProgress, "正在重命名", selected.Path);
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
                SftpOperationStatus = string.Concat("重命名成功：", completed.DestinationPath);
                PublishSftpFeedback(
                    SftpFeedbackKind.Success,
                    "重命名完成",
                    completed.DestinationPath ?? newRemotePath);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                PublishSftpFeedback(SftpFeedbackKind.Error, "重命名失败", SftpOperationStatus);
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
            SftpOperationStatus = "SFTP 所选项目已变化，请重新确认目标";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法删除", SftpOperationStatus);
            return;
        }
        var operationLease = sftpLease;

        var parentPath = GetSftpParentPath(selected.Path);
        SftpOperationStatus = string.Concat("正在删除：", selected.Path);
        PublishSftpFeedback(SftpFeedbackKind.InProgress, "正在删除", selected.Path);
        var result = await orchestrator.RemoveSftpEntryAsync(
            operationLease,
            selected.Path,
            ToSftpMutationSnapshot(selected),
            cancellationToken).ConfigureAwait(true);
        switch (result)
        {
            case SftpMutationResult.Completed completed:
                if (string.Equals(SftpPathText, completed.Path, StringComparison.Ordinal))
                {
                    SftpPreviewText = string.Empty;
                    SftpPreviewStatus = "尚无 SFTP 文本预览";
                }
                SftpPathText = parentPath;
                await PrepareSftpBrowseAsync(cancellationToken).ConfigureAwait(true);
                SftpOperationStatus = string.Concat("删除成功：", completed.Path);
                PublishSftpFeedback(SftpFeedbackKind.Success, "删除完成", completed.Path);
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                PublishSftpFeedback(SftpFeedbackKind.Error, "删除失败", SftpOperationStatus);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    public async Task RemoveSelectedSftpEntriesConfirmedAsync(
        IReadOnlyList<SftpDirectoryEntryViewModel> confirmedEntries,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(confirmedEntries);
        cancellationToken.ThrowIfCancellationRequested();
        var currentSelection = GetEffectiveSftpSelection();
        var confirmed = confirmedEntries
            .DistinctBy(static entry => entry.Path, StringComparer.Ordinal)
            .ToList();
        if (sftpLease is null ||
            confirmed.Count == 0 ||
            confirmed.Any(entry => !SftpEntries.Contains(entry)) ||
            !confirmed.Select(static entry => entry.Path).Order(StringComparer.Ordinal)
                .SequenceEqual(currentSelection.Select(static entry => entry.Path).Order(StringComparer.Ordinal), StringComparer.Ordinal))
        {
            SftpOperationStatus = "SFTP 所选项目已变化，请重新确认目标";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法批量删除", SftpOperationStatus);
            return;
        }
        var operationLease = sftpLease;
        var owner = SelectedWorkspaceTab!;
        var transferContext = GetOrCreateSftpTransferContext(owner);

        var pending = confirmed
            .Select(entry => new SftpBatchDeleteItem(
                entry,
                EnqueueSftpTransfer(transferContext, entry.Name, entry.Path, SftpTransferDirection.Delete)))
            .ToList();
        await RunSftpBatchDeleteAsync(pending, operationLease, owner, transferContext, cancellationToken).ConfigureAwait(true);
    }

    private async Task RunSftpBatchDeleteAsync(
        IReadOnlyList<SftpBatchDeleteItem> pending,
        SftpSessionLease batchLease,
        WorkspaceTabViewModel owner,
        SftpTransferQueueContext transferContext,
        CancellationToken cancellationToken)
    {
        if (pending.Count == 0 || transferContext.IsBatchRunning)
        {
            return;
        }

        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        transferContext.BatchCancellation?.Dispose();
        transferContext.BatchCancellation = linkedCancellation;
        SetSftpBatchRunning(transferContext, true);
        PublishSftpFeedbackForContext(
            transferContext,
            SftpFeedbackKind.InProgress,
            "正在批量删除",
            string.Create(System.Globalization.CultureInfo.InvariantCulture, $"共 {pending.Count} 个远程项目"));
        SetSftpTransferRetries(transferContext, null, null);
        var failed = new List<SftpBatchDeleteItem>();
        var unprocessed = new List<SftpBatchDeleteItem>();
        var completed = 0;
        try
        {
            for (var index = 0; index < pending.Count; index++)
            {
                var item = pending[index];
                linkedCancellation.Token.ThrowIfCancellationRequested();
                item.Task.MarkRunning("正在删除");
                PromoteSftpTransferTask(transferContext, item.Task);
                SetSftpTransferStatus(transferContext, string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"批量删除 {index + 1}/{pending.Count}：{item.Entry.Name}"));
                var result = await Task.Run(
                    async () => await orchestrator.RemoveSftpEntryAsync(
                        batchLease,
                        item.Entry.Path,
                        ToSftpMutationSnapshot(item.Entry),
                        linkedCancellation.Token).ConfigureAwait(false),
                    CancellationToken.None).ConfigureAwait(true);
                if (result is SftpMutationResult.Completed)
                {
                    completed++;
                    item.Task.MarkCompleted("删除完成");
                    ArchiveCompletedSftpTransfer(transferContext, item.Task);
                }
                else
                {
                    failed.Add(item);
                    item.Task.MarkFailed("删除失败，可重试");
                }
                NotifySftpTransferQueueChanged(transferContext);
            }

            var completionStatus = failed.Count == 0
                ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量删除完成：成功 {completed}/{pending.Count}")
                : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量删除完成：成功 {completed}/{pending.Count}，失败 {failed.Count}，可重试失败项");
            SetSftpTransferStatus(transferContext, completionStatus);
            SetSftpOperationStatusForOwner(owner, completionStatus);
            SetSftpTransferRetries(transferContext, null, failed.Count == 0 ? null : SftpBatchRetryRequest.ForDeletes(failed));
            PublishSftpFeedbackForContext(
                transferContext,
                failed.Count == 0 ? SftpFeedbackKind.Success : SftpFeedbackKind.Error,
                failed.Count == 0 ? "批量删除完成" : "批量删除部分失败",
                completionStatus);
        }
        catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
        {
            var processedCount = completed + failed.Count;
            unprocessed.AddRange(pending.Skip(processedCount));
            foreach (var item in unprocessed)
            {
                item.Task.MarkCancelled("已取消");
            }
            var retryItems = failed.Concat(unprocessed).Distinct().ToList();
            var cancellationStatus = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"批量删除已取消：已完成 {completed}/{pending.Count}，可重试未完成项");
            SetSftpTransferRetries(transferContext, null, retryItems.Count == 0 ? null : SftpBatchRetryRequest.ForDeletes(retryItems));
            SetSftpTransferStatus(transferContext, cancellationStatus);
            SetSftpOperationStatusForOwner(owner, cancellationStatus);
            PublishSftpFeedbackForContext(
                transferContext,
                SftpFeedbackKind.Warning,
                "批量删除已取消",
                cancellationStatus);
        }
        finally
        {
            if (completed > 0 && IsCurrentSftpContext(owner, batchLease))
            {
                await PrepareSftpBrowseAsync(CancellationToken.None).ConfigureAwait(true);
                SetSftpOperationStatusForOwner(owner, transferContext.TransferStatus);
            }
            if (ReferenceEquals(transferContext.BatchCancellation, linkedCancellation))
            {
                transferContext.BatchCancellation = null;
            }
            SetSftpBatchRunning(transferContext, false);
            NotifySftpTransferQueueChanged(transferContext);
            SaveSftpBatchResultToOwner(owner, batchLease, transferContext);
            RefreshCommands();
        }
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
            SftpOperationStatus = "SFTP 所选项目已变化，请重新确认目标";
            PublishSftpFeedback(SftpFeedbackKind.Error, "无法修改权限", SftpOperationStatus);
            return;
        }

        var trimmedMode = modeText.Trim();
        if (trimmedMode.Length is < 3 or > 4 ||
            trimmedMode.Any(character => character is < '0' or > '7'))
        {
            SftpOperationStatus = "权限必须是三位或四位八进制数字";
            PublishSftpFeedback(SftpFeedbackKind.Error, "权限格式无效", SftpOperationStatus);
            return;
        }

        var mode = Convert.ToUInt32(trimmedMode, 8);
        SftpOperationStatus = string.Concat("正在修改权限：", selected.Path);
        PublishSftpFeedback(SftpFeedbackKind.InProgress, "正在修改权限", selected.Path);
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
                SftpOperationStatus = string.Concat("权限已修改为：", trimmedMode);
                PublishSftpFeedback(
                    SftpFeedbackKind.Success,
                    "权限修改完成",
                    string.Concat(selected.Path, " · ", trimmedMode));
                break;
            case SftpMutationResult.Failed failed:
                SftpOperationStatus = FormatSftpMutationFailure(failed);
                PublishSftpFeedback(SftpFeedbackKind.Error, "权限修改失败", SftpOperationStatus);
                break;
        }

        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    private async Task SendAsync(CancellationToken cancellationToken)
    {
        var owner = SelectedWorkspaceTab;
        var targetPaneId = activeTerminalSplitPaneId;
        var targetLease = targetPaneId is { } activePaneId
            ? FindTerminalSplitPane(activePaneId)?.Lease
            : terminalLease;
        if (targetLease is null)
        {
            return;
        }

        var commandText = CommandText;
        var command = string.Concat(commandText, "\r");
        var targetLines = targetPaneId is { } paneId
            ? FindTerminalSplitPane(paneId)?.Lines
            : TerminalLines;
        if (commandText.Length > 0)
        {
            targetLines?.LastOrDefault(static line => line.IsCursorRow)
                ?.TryPreviewInputAtCursor(commandText);
        }

        if (!string.IsNullOrWhiteSpace(commandText))
        {
            AddCommandToHistory(commandText);
        }
        CommandText = string.Empty;
        Status = "正在发送命令";
        // Any intentional input returns the active terminal to its live cursor.
        // This replaces the intrusive floating "return latest" button while
        // preserving deliberate scrollback browsing until the user types.
        IsAutoScrollEnabled = true;
        NotifyTerminalOutputChanged();

        // Let WinUI paint the prompt-local preview before entering the native
        // write. SFTP traffic can temporarily contend for the same checked SSH
        // session, so the synchronous FFI call must not block the dispatcher.
        await Task.Yield();
        TerminalControlOutcome result;
        try
        {
            result = await Task.Run(
                    async () => await orchestrator.WriteTerminalAsync(
                        targetLease,
                        System.Text.Encoding.UTF8.GetBytes(command),
                        cancellationToken).ConfigureAwait(false),
                    cancellationToken)
                .ConfigureAwait(true);
        }
        catch (InvalidOperationException)
        {
            // A tab can be disconnected while its background write is waiting
            // behind SFTP traffic. Treat that race as a recoverable send failure
            // instead of allowing an async-void command to terminate the app.
            SetTerminalStatusForOwner(owner, "命令未发送，终端会话已断开");
            MarkCurrentConnectionLost("终端会话已断开，请重新连接");
            return;
        }

        if (result is TerminalControlOutcome.Succeeded)
        {
            SetTerminalStatusForOwner(owner, "命令已发送");
        }
        else if (result is TerminalControlOutcome.Failed failed)
        {
            SetTerminalStatusForOwner(owner, failed.MessageKey);
            MarkCurrentConnectionLost("终端通道已断开，请重新连接");
        }
    }

    private void SetTerminalStatusForOwner(WorkspaceTabViewModel? owner, string value)
    {
        if (owner is not null)
        {
            owner.Status = value;
        }
        if (ReferenceEquals(owner, SelectedWorkspaceTab))
        {
            Status = value;
        }
    }

    private async Task CloseTerminalAsync(CancellationToken cancellationToken)
    {
        if (terminalLease is null)
        {
            return;
        }

        if (!await CloseAllTerminalSplitPanesAsync(SelectedWorkspaceTab, cancellationToken).ConfigureAwait(true))
        {
            RefreshCommands();
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
        CancelAutomaticReconnect();
        var transferContext = GetCurrentSftpTransferContext();
        var preserveSftpRecovery = HasActiveSftpTransfersForCurrentContext ||
            transferContext.LastTransferRetry is not null ||
            transferContext.LastBatchRetry is not null;
        if (HasActiveSftpTransfersForCurrentContext)
        {
            await StopActiveSftpTransfersAsync(
                "连接正在断开；正在安全停止传输…",
                cancellationToken).ConfigureAwait(true);
            preserveSftpRecovery = true;
        }

        Status = "Ending session";
        SessionActionSummary = "Ending active session";
        var endedTelnetTerminal = false;

        if (!await CloseAllTerminalSplitPanesAsync(SelectedWorkspaceTab, cancellationToken).ConfigureAwait(true))
        {
            RefreshCommands();
            return;
        }

        if (terminalLease is not null)
        {
            endedTelnetTerminal = IsTelnetSession;
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
        ResetSftpBrowserState(preserveSftpRecovery);
        ResetMonitorState();
        ResetDockerState();
        HasHostKeyChallenge = false;
        if (SelectedWorkspaceTab is not null)
        {
            SelectedWorkspaceTab.IsBatchTargetSelected = false;
        }
        OnPropertyChanged(nameof(BatchTargetSummary));
        CommandText = string.Empty;
        SecurityStatus = "No verified session";
        var sessionEnded = endResult == SessionEndResult.Ended || endedTelnetTerminal;
        Status = sessionEnded ? completionStatus : "No active session";
        SessionActionSummary = sessionEnded ? completionStatus : "Nothing to end";
        // Publish the disconnected state only after all visible session summaries have
        // reached their final values. This prevents observers from seeing a disconnected
        // workspace while a queued background inspection still owns the previous summary.
        IsConnected = false;
        RefreshBatchAssetTargets();
        OnPropertyChanged(nameof(HostKeySummary));
        NotifySftpStateChanged();
        NotifyTerminalStateChanged();
        NotifyWorkbenchStateChanged();
        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshCommands();
    }

    private async Task<bool> CloseAllTerminalSplitPanesAsync(
        WorkspaceTabViewModel? tab,
        CancellationToken cancellationToken)
    {
        if (tab is null || tab.TerminalSplitPanes.Count == 0)
        {
            return true;
        }

        foreach (var pane in tab.TerminalSplitPanes.Reverse().ToArray())
        {
            var result = await orchestrator.CloseTerminalAsync(pane.Lease, cancellationToken).ConfigureAwait(true);
            if (result is TerminalControlOutcome.Failed failed)
            {
                Status = failed.MessageKey;
                return false;
            }

            tab.TerminalSplitPanes.Remove(pane);
        }

        SetActiveTerminalPane(null);
        NotifyTerminalSplitStateChanged();
        return true;
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

    public void ClearCommandInput()
    {
        if (CommandText.Length == 0)
        {
            return;
        }

        CommandText = string.Empty;
        Status = "已清除当前命令输入";
        SaveRuntimeStateToSelectedWorkspaceTab();
    }

    public async Task<bool> InterruptTerminalAsync(CancellationToken cancellationToken)
    {
        if (terminalLease is null)
        {
            return false;
        }

        var result = await orchestrator.WriteTerminalAsync(
            terminalLease,
            new byte[] { 0x03 },
            cancellationToken).ConfigureAwait(true);
        if (result is TerminalControlOutcome.Succeeded)
        {
            Status = "已发送终端中断信号";
            SaveRuntimeStateToSelectedWorkspaceTab();
            return true;
        }

        if (result is TerminalControlOutcome.Failed failed)
        {
            Status = failed.MessageKey;
        }

        return false;
    }

    /// <summary>
    /// Writes already-translated terminal input bytes without constructing a
    /// local command line. The native terminal surface renders only PTY state,
    /// so the remote shell remains the single authority for echo and editing.
    /// </summary>
    public async Task<bool> WriteTerminalInputAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
    {
        var targetLease = activeTerminalSplitPaneId is { } activePaneId
            ? FindTerminalSplitPane(activePaneId)?.Lease
            : terminalLease;
        if (targetLease is null || bytes.IsEmpty)
        {
            return false;
        }

        TerminalControlOutcome result;
        try
        {
            result = await orchestrator.WriteTerminalAsync(
                    targetLease,
                    bytes,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (InvalidOperationException)
        {
            dispatch(() => MarkCurrentConnectionLost("终端会话已断开，请重新连接"));
            return false;
        }
        if (result is TerminalControlOutcome.Succeeded)
        {
            return true;
        }

        if (result is TerminalControlOutcome.Failed failed)
        {
            dispatch(() =>
            {
                Status = failed.MessageKey;
                MarkCurrentConnectionLost("终端通道已断开，请重新连接");
            });
        }

        return false;
    }

    private Task ClearTerminalAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (terminalLease is not null)
        {
            var cleared = orchestrator.ClearTerminalPresentation(terminalLease);
            ApplyTerminalScreen(cleared, TerminalLines, true, SelectedWorkspaceTab!);
        }
        else
        {
            TerminalLines.Clear();
            hiddenTerminalLineCount = 0;
        }

        Status = "终端输出已清除";
        NotifyTerminalStateChanged();
        SaveRuntimeStateToSelectedWorkspaceTab();
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
                if (SelectedWorkspaceTab is not null)
                {
                    SelectedWorkspaceTab.IsBatchTargetSelected = true;
                }
                OnPropertyChanged(nameof(BatchTargetSummary));
                Status = string.Concat("Connected to ", connected.Lease.Host);
                SecurityStatus = string.Concat(connected.Lease.HostKeyAlgorithm, "  ", connected.Lease.HostKeyFingerprintSha256);
                SessionActionSummary = "Verified session ready";
                NotifyWorkbenchStateChanged();
                break;
            case ConnectResult.RequiresHostKeyTrust challenge:
                IsConnected = false;
                pendingChallenge = challenge.Challenge;
                HasHostKeyChallenge = true;
                Status = "等待确认主机密钥";
                SecurityStatus = challenge.Challenge.ReasonCode;
                SessionActionSummary = "需要确认主机密钥";
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
        RefreshBatchAssetTargets();
        if (result is ConnectResult.Connected && SelectedWorkspaceTab is { } selectedTab)
        {
            var target = BatchAssetTargets.FirstOrDefault(candidate => candidate.AssetId == selectedTab.AssetId);
            if (target is not null)
            {
                target.IsSelected = true;
                RefreshBatchTargetSelection();
            }
        }
    }

    private void OnTerminalOutputReceived(object? sender, TerminalOutputReceivedEventArgs e)
    {
        var shouldSchedule = false;
        lock (terminalUiUpdateGate)
        {
            // A terminal screen snapshot is cumulative. Keep only the newest
            // snapshot per channel until the dispatcher gets a turn instead of
            // queueing a full XAML redraw for every network packet.
            pendingTerminalUiUpdates[e.Lease.TerminalChannelId] = e;
            if (!terminalUiUpdateScheduled)
            {
                terminalUiUpdateScheduled = true;
                shouldSchedule = true;
            }
        }

        if (shouldSchedule)
        {
            if (terminalUiFrameInterval <= TimeSpan.Zero)
            {
                dispatch(DrainPendingTerminalUiUpdates);
            }
            else
            {
                _ = DispatchTerminalUiUpdateAfterFrameAsync();
            }
        }
    }

    private async Task DispatchTerminalUiUpdateAfterFrameAsync()
    {
        await Task.Delay(terminalUiFrameInterval).ConfigureAwait(false);
        dispatch(DrainPendingTerminalUiUpdates);
    }

    private void DrainPendingTerminalUiUpdates()
    {
        TerminalOutputReceivedEventArgs[] pending;
        lock (terminalUiUpdateGate)
        {
            pending = pendingTerminalUiUpdates.Values.ToArray();
            pendingTerminalUiUpdates.Clear();
            terminalUiUpdateScheduled = false;
        }

        foreach (var update in pending)
        {
            ApplyTerminalUiUpdate(update);
        }
    }

    private void ApplyTerminalUiUpdate(TerminalOutputReceivedEventArgs update)
    {
        if (batchContinuousSessionsByChannel.TryGetValue(
                update.Lease.TerminalChannelId,
                out var continuousSession))
        {
            continuousSession.ApplyScreen(update.Screen);
            if (SelectedBatchContinuousSession is null)
            {
                SelectedBatchContinuousSession = continuousSession;
            }
            return;
        }

        var splitOwner = WorkspaceTabs.FirstOrDefault(candidate =>
            candidate.TerminalSplitPanes.Any(pane =>
                pane.Lease.WorkspaceId == update.Lease.WorkspaceId &&
                pane.Lease.ServerId == update.Lease.ServerId &&
                pane.Lease.TerminalChannelId == update.Lease.TerminalChannelId));
        var splitPane = splitOwner?.TerminalSplitPanes.FirstOrDefault(pane =>
            pane.Lease.TerminalChannelId == update.Lease.TerminalChannelId);
        if (splitPane is not null)
        {
            splitOwner?.ApplyRemoteTerminalTitle(update.Screen.WindowTitle);
            ApplyTerminalScreenRows(update.Screen, splitPane.Lines);
            if (ReferenceEquals(splitOwner, SelectedWorkspaceTab))
            {
                terminalSplitOutputVersion++;
                OnPropertyChanged(nameof(TerminalSplitOutputVersion));
                Status = $"{splitPane.Label}已接收终端输出";
            }
            else if (splitOwner is not null)
            {
                splitOwner.Status = $"{splitPane.Label}已接收终端输出";
            }
            return;
        }

        var tab = WorkspaceTabs.FirstOrDefault(candidate =>
            candidate.TerminalLease is not null &&
            candidate.TerminalLease.WorkspaceId == update.Lease.WorkspaceId &&
            candidate.TerminalLease.ServerId == update.Lease.ServerId &&
            candidate.TerminalLease.TerminalChannelId == update.Lease.TerminalChannelId);
        if (tab is null)
        {
            return;
        }

        tab.ApplyRemoteTerminalTitle(update.Screen.WindowTitle);

        if (ReferenceEquals(tab, SelectedWorkspaceTab))
        {
            ApplyTerminalScreen(update.Screen, TerminalLines, true, tab);
            Status = "已接收终端输出";
            SaveTerminalRuntimeStateToSelectedWorkspaceTab();
        }
        else
        {
            ApplyTerminalScreen(update.Screen, tab.TerminalLines, false, tab);
            tab.Status = "已接收终端输出";
        }
    }

    private bool CanConnect()
    {
        return !string.IsNullOrWhiteSpace(Host) &&
            ParsedPort is > 0 and <= 65535 &&
            !string.IsNullOrWhiteSpace(Username) &&
            (!string.IsNullOrEmpty(Password) ||
             !string.IsNullOrEmpty(PrivateKey) ||
             GetCredentialAvailability(draftCredentialId) == CredentialAvailability.Available);
    }

    private static void WriteConnectionDiagnostic(string phase)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(connectionDiagnosticPath)!);
            File.AppendAllText(
                connectionDiagnosticPath,
                $"{DateTimeOffset.UtcNow:O} phase={phase}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // Diagnostics are best-effort and must never affect a connection attempt.
        }
        catch (UnauthorizedAccessException)
        {
            // Diagnostics are best-effort and must never affect a connection attempt.
        }
    }

    private async ValueTask<CredentialAvailability> DetectCredentialAvailabilityAsync(
        Guid credentialId,
        CancellationToken cancellationToken)
    {
        try
        {
            var credential = await credentialVault.ReadAsync(credentialId, cancellationToken).ConfigureAwait(true);
            return credential.IsEmpty ? CredentialAvailability.Missing : CredentialAvailability.Available;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // Do not surface a platform error or sensitive storage detail in the UI.
            return CredentialAvailability.Unavailable;
        }
    }

    private CredentialAvailability GetCredentialAvailability(Guid credentialId) =>
        credentialAvailabilityById.GetValueOrDefault(credentialId, CredentialAvailability.Missing);

    private void NotifyCredentialAvailabilityChanged()
    {
        OnPropertyChanged(nameof(SelectedCredentialAvailabilitySummary));
        OnPropertyChanged(nameof(CredentialProtectionStatus));
        RefreshBatchAssetTargets();
        RefreshCommands();
    }

    private async Task CheckCredentialHealthAsync(CancellationToken cancellationToken)
    {
        var available = 0;
        var missing = 0;
        var unavailable = 0;

        foreach (var asset in Assets)
        {
            var availability = await DetectCredentialAvailabilityAsync(asset.CredentialId, cancellationToken).ConfigureAwait(true);
            credentialAvailabilityById[asset.CredentialId] = availability;
            switch (availability)
            {
                case CredentialAvailability.Available:
                    available++;
                    break;
                case CredentialAvailability.Missing:
                    missing++;
                    break;
                case CredentialAvailability.Unavailable:
                    unavailable++;
                    break;
            }
        }

        CredentialHealthStatus = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"本机凭据健康检查完成：已保护 {available}，缺失 {missing}，无法读取 {unavailable}。未读取或导出凭据内容。");
        NotifyCredentialAvailabilityChanged();
    }

    private enum CredentialAvailability
    {
        Available,
        Missing,
        Unavailable,
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
            !string.IsNullOrWhiteSpace(Username) &&
            (!IsJumpHostEnabled ||
                (!string.IsNullOrWhiteSpace(JumpHost) &&
                 ParsedJumpPort is > 0 and <= 65535 &&
                 !string.IsNullOrWhiteSpace(JumpUsername)));
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
            AssetTransport,
            AssetTransport == ServerTransport.Telnet || AllowPasswordFallback,
            NormalizeDraftGroup(AssetGroup),
            ParseDraftTags(AssetTagsText),
            IsJumpHostEnabled && AssetTransport == ServerTransport.Ssh
                ? new JumpHostRecord(draftJumpCredentialId, JumpHost.Trim(), ParsedJumpPort, JumpUsername.Trim(), JumpAllowPasswordFallback)
                : null,
            AssetStorageScope,
            AssetStorageScope == AssetStorageScope.LocalOnly
                ? null
                : !string.IsNullOrWhiteSpace(CurrentAccountScope)
                    ? CurrentAccountScope
                    : draftOwnerAccountScope);
    }

    private void ResetDraftAsset()
    {
        draftAssetId = Guid.NewGuid();
        draftCredentialId = Guid.NewGuid();
        AssetName = "新建服务器草稿";
        Host = string.Empty;
        PortText = "22";
        Username = string.Empty;
        AssetTransport = ServerTransport.Ssh;
        AssetStorageScope = IsAccountSignedIn
            ? AssetStorageScope.AccountSynced
            : AssetStorageScope.LocalOnly;
        draftOwnerAccountScope = AssetStorageScope == AssetStorageScope.AccountSynced
            ? CurrentAccountScope
            : null;
        AssetGroup = "未分组";
        AssetTagsText = string.Empty;
        Password = PrivateKey = PrivateKeyPassphrase = string.Empty;
        AllowPasswordFallback = true;
        LoadJumpHostDraft(null);
    }

    private int ParsedJumpPort => int.TryParse(JumpPortText, out var value) ? value : 0;

    private void LoadJumpHostDraft(JumpHostRecord? jump)
    {
        IsJumpHostEnabled = jump is not null;
        draftJumpCredentialId = jump?.CredentialId ?? Guid.NewGuid();
        JumpHost = jump?.Host ?? string.Empty;
        JumpPortText = (jump?.Port ?? 22).ToString(System.Globalization.CultureInfo.InvariantCulture);
        JumpUsername = jump?.Username ?? string.Empty;
        JumpAllowPasswordFallback = jump?.AllowPasswordFallback ?? true;
        JumpPassword = JumpPrivateKey = JumpPrivateKeyPassphrase = string.Empty;
    }

    private static string NormalizeDraftGroup(string value)
    {
        var cleaned = RemoveControlCharacters(value).Trim();
        return string.IsNullOrWhiteSpace(cleaned) ? "未分组" : cleaned[..Math.Min(cleaned.Length, 64)];
    }

    private static IReadOnlyList<string> ParseDraftTags(string value)
    {
        var tags = new List<string>();
        foreach (var rawTag in value.Split([',', '，', ';', '；'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var tag = RemoveControlCharacters(rawTag).Trim();
            if (tag.Length > 0 && !tags.Contains(tag, StringComparer.OrdinalIgnoreCase))
            {
                tags.Add(tag[..Math.Min(tag.Length, 32)]);
            }

            if (tags.Count == 16)
            {
                break;
            }
        }

        return tags;
    }

    private static string RemoveControlCharacters(string value) => new(value.Where(character => !char.IsControl(character)).ToArray());

    private WorkspaceTabViewModel CreateWorkspaceTabFromDraft()
    {
        return new WorkspaceTabViewModel(
            Guid.NewGuid(),
            draftAssetId,
            draftCredentialId,
            AssetName,
            Host,
            PortText,
            Username,
            AssetTransport);
    }

    private void SyncSelectedWorkspaceTabFromDraft()
    {
        if (isRestoringWorkspaceTab || SelectedWorkspaceTab is null)
        {
            return;
        }

        // Asset selection is allowed while another tab remains connected. In
        // that case the draft belongs to a future tab, not to the active one.
        if (HasActiveRuntime && SelectedWorkspaceTab.AssetId != draftAssetId)
        {
            return;
        }

        SelectedWorkspaceTab.ApplyDraft(
            draftAssetId,
            draftCredentialId,
            AssetName,
            Host,
            PortText,
            Username,
            AssetTransport);
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
            LoadJumpHostDraft(selectedAsset?.JumpHost);
            AssetName = tab.Title;
            Host = tab.Host;
            PortText = tab.PortText;
            Username = tab.Username;
            AssetTransport = tab.Transport;
            Password = string.Empty;
        }
        finally
        {
            isRestoringWorkspaceTab = false;
        }

        RefreshSnippetGroups();
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
        SelectedWorkspaceTab.RemoteProcesses.Clear();
        SelectedWorkspaceTab.RemoteProcesses.AddRange(RemoteProcesses.Select(static process => process.Clone()));
        SelectedWorkspaceTab.CommandHistory.Clear();
        SelectedWorkspaceTab.CommandHistory.AddRange(commandHistory);
        SelectedWorkspaceTab.MonitorHistory.Clear();
        SelectedWorkspaceTab.MonitorHistory.AddRange(monitorHistory);
        SelectedWorkspaceTab.LastSuccessfulMonitorRefreshAt = lastSuccessfulMonitorRefreshAt;
        SelectedWorkspaceTab.CommandText = CommandText;
        SelectedWorkspaceTab.Status = Status;
        SelectedWorkspaceTab.SecurityStatus = SecurityStatus;
        SelectedWorkspaceTab.PasteSafetyStatus = PasteSafetyStatus;
        SelectedWorkspaceTab.SessionActionSummary = SessionActionSummary;
        SelectedWorkspaceTab.MonitorStatus = MonitorStatus;
        SelectedWorkspaceTab.MonitorSummary = MonitorSummary;
        SelectedWorkspaceTab.SystemOverviewSummary = SystemOverviewSummary;
        SelectedWorkspaceTab.DockerStatus = DockerStatus;
        SelectedWorkspaceTab.DockerSummary = DockerSummary;
        SelectedWorkspaceTab.DockerStatsSummary = DockerStatsSummary;
        SelectedWorkspaceTab.RemoteProcessStatus = RemoteProcessStatus;
        SelectedWorkspaceTab.SelectedDockerContainer = SelectedDockerContainer;
        SelectedWorkspaceTab.DockerLogStatus = DockerLogStatus;
        SelectedWorkspaceTab.DockerLogText = DockerLogText;
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

    private void SaveTerminalRuntimeStateToSelectedWorkspaceTab()
    {
        if (SelectedWorkspaceTab is not { } tab)
        {
            return;
        }

        SynchronizeTerminalLineReferences(tab.TerminalLines, TerminalLines);
        tab.HiddenTerminalLineCount = hiddenTerminalLineCount;
        tab.IsAutoScrollEnabled = IsAutoScrollEnabled;
        tab.TerminalLease = terminalLease;
        tab.Status = Status;
        tab.SessionActionSummary = SessionActionSummary;
    }

    private static void SynchronizeTerminalLineReferences(
        List<TerminalLineViewModel> target,
        IReadOnlyList<TerminalLineViewModel> source)
    {
        var sharedCount = Math.Min(target.Count, source.Count);
        for (var index = 0; index < sharedCount; index++)
        {
            if (!ReferenceEquals(target[index], source[index]))
            {
                target[index] = source[index];
            }
        }

        if (target.Count > source.Count)
        {
            target.RemoveRange(source.Count, target.Count - source.Count);
        }
        else
        {
            for (var index = target.Count; index < source.Count; index++)
            {
                target.Add(source[index]);
            }
        }
    }

    private void SaveMonitorRuntimeStateToSelectedWorkspaceTab()
    {
        if (SelectedWorkspaceTab is not { } tab)
        {
            return;
        }

        tab.MonitorStatus = MonitorStatus;
        tab.MonitorSummary = MonitorSummary;
        tab.SystemOverviewSummary = SystemOverviewSummary;
        tab.MonitorHistory.Clear();
        tab.MonitorHistory.AddRange(monitorHistory);
        tab.LastSuccessfulMonitorRefreshAt = lastSuccessfulMonitorRefreshAt;
        tab.SessionActionSummary = SessionActionSummary;
    }

    private bool IsCurrentSftpContext(WorkspaceTabViewModel? owner, SftpSessionLease lease) =>
        owner is not null &&
        ReferenceEquals(owner, SelectedWorkspaceTab) &&
        Equals(sftpLease, lease);

    private void SetSftpOperationStatusForOwner(WorkspaceTabViewModel? owner, string value)
    {
        if (owner is not null)
        {
            owner.SftpOperationStatus = value;
        }
        if (ReferenceEquals(owner, SelectedWorkspaceTab))
        {
            SftpOperationStatus = value;
        }
    }

    private void SaveSftpBatchResultToOwner(
        WorkspaceTabViewModel? owner,
        SftpSessionLease lease,
        SftpTransferQueueContext transferContext)
    {
        if (owner is null)
        {
            return;
        }

        owner.SftpOperationStatus = transferContext.TransferStatus;
        owner.SessionActionSummary = transferContext.TransferStatus;
        if (IsCurrentSftpContext(owner, lease))
        {
            SaveRuntimeStateToSelectedWorkspaceTab();
        }
    }

    private async Task<TResult> RunRemoteInspectionAsync<TResult>(
        Func<Task<TResult>> operation,
        CancellationToken cancellationToken)
    {
        await remoteInspectionGate.WaitAsync(cancellationToken).ConfigureAwait(true);
        try
        {
            return await Task.Run(operation, cancellationToken).ConfigureAwait(true);
        }
        finally
        {
            remoteInspectionGate.Release();
        }
    }

    private void SaveDockerRuntimeStateToSelectedWorkspaceTab()
    {
        if (SelectedWorkspaceTab is not { } tab)
        {
            return;
        }

        tab.DockerContainers.Clear();
        tab.DockerContainers.AddRange(DockerContainers);
        tab.DockerStats.Clear();
        tab.DockerStats.AddRange(DockerStats);
        tab.SelectedDockerContainer = SelectedDockerContainer;
        tab.DockerStatus = DockerStatus;
        tab.DockerSummary = DockerSummary;
        tab.DockerStatsSummary = DockerStatsSummary;
        tab.SessionActionSummary = SessionActionSummary;
    }

    private void RestoreRuntimeStateFromWorkspaceTab(WorkspaceTabViewModel tab)
    {
        lastDockerContainerRefreshAt = null;
        activeTerminalSplitPaneId = null;
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

        RemoteProcesses.Clear();
        foreach (var process in tab.RemoteProcesses)
        {
            RemoteProcesses.Add(process.Clone());
        }

        SelectedDockerContainer = tab.SelectedDockerContainer;
        SetSelectedSftpEntries([]);
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
        SystemOverviewSummary = tab.SystemOverviewSummary;
        monitorHistory.Clear();
        monitorHistory.AddRange(tab.MonitorHistory.TakeLast(MaximumMonitorHistorySamples));
        latestRawMonitorSnapshot = monitorHistory.LastOrDefault(static snapshot =>
            snapshot.AvailableMetrics.HasFlag(MonitorSampleMetrics.System));
        lastSuccessfulMonitorRefreshAt = tab.LastSuccessfulMonitorRefreshAt;
        lastMonitorRefreshAt = null;
        UpdateMonitorTrendMetrics();
        DockerStatus = tab.DockerStatus;
        DockerSummary = tab.DockerSummary;
        DockerStatsSummary = tab.DockerStatsSummary;
        ClearDockerFeedback();
        RemoteProcessStatus = tab.RemoteProcessStatus;
        DockerLogStatus = tab.DockerLogStatus;
        DockerLogText = tab.DockerLogText;
        ResetSftpEditor();
        SftpStatus = tab.SftpStatus;
        SftpPathText = tab.SftpPathText;
        SftpBrowserStatus = tab.SftpBrowserStatus;
        SftpOperationStatus = tab.SftpOperationStatus;
        ClearSftpFeedback();
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
        AddTerminalSplitCommand.RaiseCanExecuteChanged();
        RemoveLastTerminalSplitCommand.RaiseCanExecuteChanged();
        OpenSftpCommand.RaiseCanExecuteChanged();
        RefreshMonitorSnapshotCommand.RaiseCanExecuteChanged();
        RefreshDockerContainersCommand.RaiseCanExecuteChanged();
        RefreshDockerStatsCommand.RaiseCanExecuteChanged();
        PreviewDockerLogsCommand.RaiseCanExecuteChanged();
        StartDockerContainerCommand.RaiseCanExecuteChanged();
        StopDockerContainerCommand.RaiseCanExecuteChanged();
        RestartDockerContainerCommand.RaiseCanExecuteChanged();
        PauseDockerContainerCommand.RaiseCanExecuteChanged();
        UnpauseDockerContainerCommand.RaiseCanExecuteChanged();
        KillDockerContainerCommand.RaiseCanExecuteChanged();
        RemoveDockerContainerCommand.RaiseCanExecuteChanged();
        RunBatchCommand.RaiseCanExecuteChanged();
        CancelBatchCommand.RaiseCanExecuteChanged();
        DeleteSnippetCommand.RaiseCanExecuteChanged();
        InsertSnippetCommand.RaiseCanExecuteChanged();
        ExecuteSnippetCommand.RaiseCanExecuteChanged();
        EndSessionCommand.RaiseCanExecuteChanged();
        SendCommand.RaiseCanExecuteChanged();
        CloseTerminalCommand.RaiseCanExecuteChanged();
        ClearTerminalCommand.RaiseCanExecuteChanged();
        PreviousCommandHistoryCommand.RaiseCanExecuteChanged();
        NextCommandHistoryCommand.RaiseCanExecuteChanged();
        SaveLatestCommandAsSnippetCommand.RaiseCanExecuteChanged();
        PrepareSftpBrowseCommand.RaiseCanExecuteChanged();
        RefreshSftpBrowseCommand.RaiseCanExecuteChanged();
        GoParentSftpCommand.RaiseCanExecuteChanged();
        OpenSelectedSftpEntryCommand.RaiseCanExecuteChanged();
        PreviewSftpTextCommand.RaiseCanExecuteChanged();
        RetryLastSftpTransferCommand.RaiseCanExecuteChanged();
        CancelSftpBatchCommand.RaiseCanExecuteChanged();
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
        OnPropertyChanged(nameof(IsTelnetSession));
        OnPropertyChanged(nameof(ConnectionStateLabel));
        OnPropertyChanged(nameof(SecurityBadgeText));
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
        OnPropertyChanged(nameof(TerminalPaneCount));
        OnPropertyChanged(nameof(CanAddTerminalSplit));
        AddTerminalSplitCommand.RaiseCanExecuteChanged();
        RemoveLastTerminalSplitCommand.RaiseCanExecuteChanged();
        RefreshCommands();
    }

    private void NotifySftpStateChanged()
    {
        OnPropertyChanged(nameof(IsSftpOpen));
        OnPropertyChanged(nameof(SftpStateLabel));
        OnPropertyChanged(nameof(SftpInspectorHint));
        OnPropertyChanged(nameof(SftpListingSummary));
        RefreshCommands();
    }

    private bool CanNavigateSftp()
    {
        return sftpLease is not null && !IsSftpPreviewDirty;
    }

    private void ResetSftpBrowserState(bool preserveTransferRecovery = false)
    {
        Interlocked.Increment(ref sftpBrowseRequestVersion);
        var transferContext = GetCurrentSftpTransferContext();
        transferContext.BatchCancellation?.Cancel();
        transferContext.BatchCancellation?.Dispose();
        transferContext.BatchCancellation = null;
        SetSftpBatchRunning(transferContext, false);
        if (!preserveTransferRecovery)
        {
            transferContext.LastTransferRetry = null;
            transferContext.LastBatchRetry = null;
            transferContext.Tasks.Clear();
            transferContext.ActiveTasks.Clear();
            transferContext.CompletedTasks.Clear();
            SetSftpTransferStatus(transferContext, "暂无传输任务");
        }
        else
        {
            foreach (var task in transferContext.Tasks.Where(static task => task.State is SftpTransferTaskState.Running or SftpTransferTaskState.Paused))
            {
                task.MarkCancelled("连接已断开，可重新连接后重试");
            }
            SetSftpTransferStatus(transferContext, "连接已断开；重新连接原资产后可重试未完成的传输任务");
        }
        SetSftpTransferRetries(transferContext, transferContext.LastTransferRetry, transferContext.LastBatchRetry);
        SynchronizeVisibleSftpTransferContext(transferContext);
        SftpStatus = "SFTP not open";
        SftpPathText = "/";
        SetSelectedSftpEntries([]);
        SftpEntries.Clear();
        ResetSftpEditor();
        SftpPreviewStatus = "No SFTP text preview";
        SftpBrowserStatus = "Open SFTP to prepare browsing";
        SftpOperationStatus = "Open a checked SFTP channel to transfer files";
        OnPropertyChanged(nameof(SftpListingSummary));
        OnPropertyChanged(nameof(CanRetryLastSftpTransfer));
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
        consecutiveMonitorFailures = 0;
        MonitorStatus = "监控待命";
        MonitorSummary = "尚无监控快照";
        SystemOverviewSummary = "尚无硬件概览";
        monitorHistory.Clear();
        latestRawMonitorSnapshot = null;
        lastMonitorRefreshAt = null;
        lastSuccessfulMonitorRefreshAt = null;
        lastSftpMonitorOverlayAt = null;
        RemoteProcesses.Clear();
        RemoteProcessStatus = "等待进程采样";
        UpdateMonitorTrendMetrics();
    }

    private void MarkCurrentConnectionLost(string message)
    {
        if (!IsConnected)
        {
            return;
        }

        var reconnectOwner = SelectedWorkspaceTab;
        var reconnectAssetId = draftAssetId;
        var requestedSplitCount = TerminalSplitPanes.Count;
        var mayReconnect = reconnectOwner is not null &&
            AssetTransport == ServerTransport.Ssh &&
            !HasHostKeyChallenge;

        orchestrator.AbandonSession(CurrentWorkspaceId, draftAssetId);
        terminalLease = null;
        sftpLease = null;
        TerminalSplitPanes.Clear();
        activeTerminalSplitPaneId = null;
        IsConnected = false;
        HasHostKeyChallenge = false;
        SecurityStatus = "远端连接已中断";
        Status = message;
        SessionActionSummary = "连接已断开";
        ResetSftpBrowserState(preserveTransferRecovery: true);
        ResetMonitorState();
        ResetDockerState();
        NotifyTerminalSplitStateChanged();
        NotifyTerminalStateChanged();
        NotifyWorkbenchStateChanged();
        SaveRuntimeStateToSelectedWorkspaceTab();
        RefreshBatchAssetTargets();
        RefreshCommands();

        if (mayReconnect && reconnectOwner is not null)
        {
            StartAutomaticReconnect(reconnectOwner, reconnectAssetId, requestedSplitCount);
        }
    }

    private void StartAutomaticReconnect(
        WorkspaceTabViewModel owner,
        Guid assetId,
        int requestedSplitCount)
    {
        CancelAutomaticReconnect();
        automaticReconnectCts = new CancellationTokenSource();
        _ = RunAutomaticReconnectAsync(
            owner,
            assetId,
            Math.Clamp(requestedSplitCount, 0, 3),
            automaticReconnectCts.Token);
    }

    private async Task RunAutomaticReconnectAsync(
        WorkspaceTabViewModel owner,
        Guid assetId,
        int requestedSplitCount,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= AutomaticReconnectPolicy.MaximumAttempts; attempt++)
        {
            try
            {
                await Task.Delay(AutomaticReconnectPolicy.DelayBeforeAttempt(attempt), cancellationToken)
                    .ConfigureAwait(true);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            if (!WorkspaceTabs.Contains(owner) || owner.AssetId != assetId)
            {
                return;
            }

            // Runtime fields are intentionally scoped to the selected tab. Do
            // not switch the user's workspace behind their back; keep waiting
            // until the affected tab is active again.
            if (!ReferenceEquals(SelectedWorkspaceTab, owner))
            {
                owner.Status = "连接已中断；切回此标签后将自动重连";
                continue;
            }

            Status = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"正在自动重连（{attempt}/{AutomaticReconnectPolicy.MaximumAttempts}）");
            SessionActionSummary = "正在恢复终端、监控与会话工具";
            SaveRuntimeStateToSelectedWorkspaceTab();

            try
            {
                await ConnectAsync(cancellationToken).ConfigureAwait(true);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            if (HasHostKeyChallenge)
            {
                Status = "服务器身份发生变化，自动重连已暂停，请手动确认主机密钥";
                return;
            }

            if (!IsConnected || terminalLease is null)
            {
                continue;
            }

            for (var splitIndex = 0;
                 splitIndex < requestedSplitCount && CanAddTerminalSplit;
                 splitIndex++)
            {
                await AddTerminalSplitAsync(cancellationToken).ConfigureAwait(true);
            }
            Status = "已自动重连";
            SecurityStatus = "SSH 已重新验证";
            SessionActionSummary = "终端、监控与会话工具已恢复";
            SaveRuntimeStateToSelectedWorkspaceTab();
            return;
        }

        if (ReferenceEquals(SelectedWorkspaceTab, owner) && !IsConnected)
        {
            Status = "自动重连未成功，请检查网络或服务器状态后手动重试";
            SessionActionSummary = "自动重连已停止";
            SaveRuntimeStateToSelectedWorkspaceTab();
        }
    }

    private void CancelAutomaticReconnect()
    {
        var current = Interlocked.Exchange(ref automaticReconnectCts, null);
        if (current is null)
        {
            return;
        }
        current.Cancel();
        current.Dispose();
    }

    private void AppendMonitorSnapshot(MonitorSnapshot snapshot)
    {
        monitorHistory.Add(snapshot);
        while (monitorHistory.Count > MaximumMonitorHistorySamples)
        {
            monitorHistory.RemoveAt(0);
        }

        UpdateMonitorTrendMetrics();
    }

    private MonitorSnapshot ApplyActiveSftpTransferRates(MonitorSnapshot snapshot)
    {
        // The remote /proc/net/dev sample can miss short transfers between
        // monitor intervals. While a transfer is active, its byte-accurate
        // progress is the authoritative rate for that direction. Do not take
        // Math.Max against an earlier overlaid point: doing so permanently
        // pinned the graph to the transfer's initial buffered burst.
        var activeDownloads = ActiveSftpTransferTasks
            .Where(static task =>
                task.State == SftpTransferTaskState.Running &&
                task.Direction == SftpTransferDirection.Download)
            .ToArray();
        var activeUploads = ActiveSftpTransferTasks
            .Where(static task =>
                task.State == SftpTransferTaskState.Running &&
                task.Direction == SftpTransferDirection.Upload)
            .ToArray();
        var downloadKilobitsPerSecond = activeDownloads
            .Sum(static task => task.BytesPerSecond * 8d / 1000d);
        var uploadKilobitsPerSecond = activeUploads
            .Sum(static task => task.BytesPerSecond * 8d / 1000d);

        return snapshot with
        {
            ReceiveRateKilobitsPerSecond = activeDownloads.Length == 0
                ? snapshot.ReceiveRateKilobitsPerSecond
                : downloadKilobitsPerSecond,
            TransmitRateKilobitsPerSecond = activeUploads.Length == 0
                ? snapshot.TransmitRateKilobitsPerSecond
                : uploadKilobitsPerSecond,
        };
    }

    private void UpdateMonitorFromSftpTransferProgress()
    {
        if (monitorHistory.Count == 0 && latestRawMonitorSnapshot is null)
        {
            return;
        }

        var now = utcNow();
        if (lastSftpMonitorOverlayAt is { } previous &&
            now - previous < TimeSpan.FromSeconds(1))
        {
            return;
        }

        lastSftpMonitorOverlayAt = now;
        var sourceSnapshot = latestRawMonitorSnapshot ?? monitorHistory.LastOrDefault(static snapshot =>
            snapshot.AvailableMetrics.HasFlag(MonitorSampleMetrics.System));
        if (sourceSnapshot is null)
        {
            return;
        }
        var sampledAtUnix = (ulong)Math.Max(0, now.ToUnixTimeSeconds());
        if (monitorHistory.Count > 0 && sampledAtUnix <= monitorHistory[^1].SampledAtUnix)
        {
            sampledAtUnix = monitorHistory[^1].SampledAtUnix + 1;
        }
        var availableMetrics = MonitorSampleMetrics.None;
        if (ActiveSftpTransferTasks.Any(static task =>
                task.State == SftpTransferTaskState.Running &&
                task.Direction == SftpTransferDirection.Download))
        {
            availableMetrics |= MonitorSampleMetrics.Download;
        }
        if (ActiveSftpTransferTasks.Any(static task =>
                task.State == SftpTransferTaskState.Running &&
                task.Direction == SftpTransferDirection.Upload))
        {
            availableMetrics |= MonitorSampleMetrics.Upload;
        }
        if (availableMetrics == MonitorSampleMetrics.None)
        {
            return;
        }

        var displaySnapshot = ApplyActiveSftpTransferRates(sourceSnapshot with
        {
            SampledAtUnix = sampledAtUnix,
            AvailableMetrics = availableMetrics,
        });
        AppendMonitorSnapshot(displaySnapshot);
        var freshnessLimit = TimeSpan.FromSeconds(Math.Max(6, monitorRefreshIntervalSeconds * 3));
        MonitorStatus = lastSuccessfulMonitorRefreshAt is { } refreshedAt && now - refreshedAt <= freshnessLimit
            ? "系统指标持续采样 · 传输速率实时"
            : "系统指标采样延迟 · 传输速率实时";
    }

    private void UpdateMonitorTrendMetrics()
    {
        var visibleHistory = GetVisibleMonitorHistory();
        foreach (var metric in MonitorTrendMetrics)
        {
            metric.Update(visibleHistory);
        }

        MonitorTrendStatus = monitorHistory.Count == 0
            ? "暂无趋势采样"
            : string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"显示 {visibleHistory.Count} 个采样点 · 已保留 {monitorHistory.Count}/{MaximumMonitorHistorySamples} · 自动刷新可暂停");
        UpdateMonitorLoadStatus(visibleHistory);
        OnPropertyChanged(nameof(MonitorTrendPointCount));
    }

    private IReadOnlyList<MonitorSnapshot> GetVisibleMonitorHistory()
    {
        var seconds = MonitorTrendRange switch
        {
            "实时（30 秒）" => 30,
            "5 分钟" => 5 * 60,
            _ => 10 * 60,
        };
        if (monitorHistory.Count == 0)
        {
            return [];
        }

        // Server sample timestamps are authoritative; using the latest point
        // keeps tests and delayed responses stable even when the UI was paused.
        var cutoff = monitorHistory[^1].SampledAtUnix > (ulong)seconds
            ? monitorHistory[^1].SampledAtUnix - (ulong)seconds
            : 0;
        return monitorHistory.Where(point => point.SampledAtUnix >= cutoff).ToArray();
    }

    private void UpdateMonitorLoadStatus(IReadOnlyList<MonitorSnapshot> visibleHistory)
    {
        if (visibleHistory.Count == 0)
        {
            MonitorLoadStatus = "等待监控采样";
            return;
        }

        var latest = visibleHistory.LastOrDefault(static snapshot =>
            snapshot.AvailableMetrics.HasFlag(MonitorSampleMetrics.System));
        if (latest is null)
        {
            MonitorLoadStatus = "系统指标采样延迟";
            return;
        }
        var warnings = new List<string>();
        if (latest.CpuUsagePercent >= 85)
        {
            warnings.Add($"CPU {latest.CpuUsagePercent:0.#}%");
        }
        if (latest.MemoryUsedPercent >= 90)
        {
            warnings.Add($"内存 {latest.MemoryUsedPercent:0.#}%");
        }
        if (latest.DiskUsedPercent >= 90)
        {
            warnings.Add($"磁盘 {latest.DiskUsedPercent:0.#}%");
        }
        if (latest.PingLatencyMilliseconds is >= 300)
        {
            warnings.Add($"TCP 延迟 {latest.PingLatencyMilliseconds:0.#} ms");
        }

        MonitorLoadStatus = warnings.Count == 0
            ? "负载正常"
            : string.Concat("负载较高：", string.Join("、", warnings));
    }

    private void ResetDockerState()
    {
        lastDockerContainerRefreshAt = null;
        DockerStatus = "Docker 待命";
        DockerSummary = "尚无 Docker 容器数据";
        DockerStatsSummary = "尚无 Docker 资源数据";
        DockerLogStatus = "尚无 Docker 日志预览";
        DockerLogText = string.Empty;
        SelectedDockerContainer = null;
        DockerContainers.Clear();
        DockerStats.Clear();
    }

    private void NotifySftpListingChanged()
    {
        OnPropertyChanged(nameof(SftpListingSummary));
        OnPropertyChanged(nameof(SftpInspectorHint));
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

    private void ApplyTerminalScreen(
        TerminalScreenSnapshot screen,
        IList<TerminalLineViewModel> target,
        bool isSelectedTab,
        WorkspaceTabViewModel tab)
    {
        var hiddenCount = ApplyTerminalScreenRows(screen, target);
        if (isSelectedTab)
        {
            hiddenTerminalLineCount = hiddenCount;
            NotifyTerminalOutputChanged();
        }

        tab.HiddenTerminalLineCount = hiddenCount;
    }

    private static int ApplyTerminalScreenRows(
        TerminalScreenSnapshot screen,
        IList<TerminalLineViewModel> target)
    {
        var display = TerminalRowReflow.Reflow(screen);
        var firstVisibleRow = Math.Max(0, display.Rows.Count - MaximumTerminalLines);
        var visibleCount = display.Rows.Count - firstVisibleRow;
        var cursorIndex = display.CursorRow - firstVisibleRow;

        while (target.Count > visibleCount)
        {
            target.RemoveAt(target.Count - 1);
        }

        for (var index = 0; index < visibleCount; index++)
        {
            var row = display.Rows[index + firstVisibleRow];
            var isCursorRow = index == cursorIndex;
            if (index < target.Count)
            {
                target[index].Apply(row, isCursorRow, display.CursorColumn);
            }
            else
            {
                target.Add(new TerminalLineViewModel(row.Text, false, row.Runs, isCursorRow, isCursorRow ? display.CursorColumn : -1));
            }
        }

        return screen.DiscardedHistoryLines + firstVisibleRow;
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
        var kindText = isDirectory ? "文件夹" : "文件";
        // Directory entry sizes are server/filesystem implementation details
        // (often inode blocks rather than useful content size). Only files
        // expose a user-facing size, consistently with the Apple clients.
        var sizeText = isDirectory ? string.Empty : FormatSftpSize(entry.Size);
        var modifiedText = entry.ModifiedAtUnix == 0
            ? "未知时间"
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

    private static string FormatSftpSize(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }

        return index == 0
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{bytes} B")
            : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{value:0.#} {units[index]}");
    }

    private void RebuildSftpBreadcrumbs(string path)
    {
        SftpBreadcrumbs.Clear();
        var normalized = NormalizeSftpPath(path) ?? "/";
        SftpBreadcrumbs.Add(new SftpBreadcrumbSegmentViewModel("根目录", "/"));

        var current = string.Empty;
        foreach (var segment in normalized.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            current = string.Concat(current, "/", segment);
            SftpBreadcrumbs.Add(new SftpBreadcrumbSegmentViewModel(segment, current));
        }
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
            $"采样于 {sampled}");
    }

    private static string FormatMonitorSummary(MonitorSnapshot snapshot)
    {
        var pingText = snapshot.PingLatencyMilliseconds is null
            ? "TCP 延迟暂无"
            : string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"TCP 延迟 {snapshot.PingLatencyMilliseconds:0.#} ms");
        var diagnosticsText = snapshot.Diagnostics.Count == 0
            ? "运行正常"
            : string.Join(", ", snapshot.Diagnostics.Select(static item => item switch
            {
                "tcping_unavailable" => "SSH 端口 TCP 延迟暂不可用",
                "ping_unavailable" => "延迟暂不可用",
                _ => item,
            }));

        return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"CPU {snapshot.CpuUsagePercent:0.#}%  ·  内存 {snapshot.MemoryUsedPercent:0.#}%（可用 {snapshot.MemoryAvailableMegabytes} MB）  ·  磁盘 {snapshot.DiskUsedPercent:0.#}%  ·  网络 ↓{FormatMonitorNetworkRate(snapshot.ReceiveRateKilobitsPerSecond)}/↑{FormatMonitorNetworkRate(snapshot.TransmitRateKilobitsPerSecond)}  ·  {pingText}  ·  {diagnosticsText}");
    }

    private static string FormatMonitorNetworkRate(double kilobitsPerSecond)
    {
        var safeValue = Math.Max(0, kilobitsPerSecond);
        return safeValue switch
        {
            >= 1_000_000 => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue / 1_000_000:0.##} Gbps"),
            >= 1_000 => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue / 1_000:0.##} Mbps"),
            _ => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue:0.#} Kbps"),
        };
    }

    private static string FormatSystemOverview(MonitorSnapshot snapshot)
    {
        if (snapshot.SystemInfo is not { } info)
        {
            return "硬件信息暂不可用";
        }

        var memoryGigabytes = info.MemoryTotalMegabytes / 1024d;
        var diskCapacity = FormatCapacity(info.DiskTotalMegabytes);
        var swapCapacity = info.SwapTotalMegabytes == 0
            ? "未配置"
            : FormatCapacity(info.SwapTotalMegabytes);
        return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{info.OsName} · CPU {info.CpuCoreCount} 核 / {info.CpuThreadCount} 线程 · 内存 {memoryGigabytes:0.#} GB · 磁盘总容量 {diskCapacity} · Swap {swapCapacity}");
    }

    private static string FormatCapacity(ulong megabytes) => megabytes >= 1024UL * 1024UL
        ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{megabytes / (1024d * 1024d):0.##} TB")
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{megabytes / 1024d:0.#} GB");

    private static string FormatMonitorFailure(string code) => code switch
    {
        "session_not_found" or "session_not_verified" => "SSH 会话已不可用，请重新连接并验证主机密钥。",
        "monitor_snapshot_mismatch" or "invalid_monitor_snapshot_kind" => "收到的监控数据无法安全验证，请重试；若持续出现，请导出脱敏诊断。",
        _ => "暂时无法获取监控数据，请检查 SSH 连接后重试。",
    };

    private static string FormatDockerAction(string action) => action switch
    {
        "start" => "启动",
        "stop" => "停止",
        "restart" => "重启",
        "pause" => "暂停",
        "unpause" => "恢复运行",
        "kill" => "强制终止",
        "remove" => "删除",
        _ => action,
    };

    private static string FormatDockerFailure(string code) => code switch
    {
        "session_not_found" or "session_not_verified" => "SSH 会话不可用，请重新连接并验证主机密钥。",
        "docker_not_available" or "docker_command_failed" => "远端 Docker 不可用，或当前用户没有 Docker 操作权限。",
        "docker_container_not_found" => "目标容器已不存在，请刷新容器列表。",
        _ => "操作未完成，请检查 SSH 连接、Docker 服务状态和当前用户权限后重试。",
    };

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
            item.Pids.ToString(System.Globalization.CultureInfo.InvariantCulture),
            item.Id);
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

    private static string? TryCreateSftpDownloadPath(string localDirectory, string remoteName)
    {
        if (string.IsNullOrWhiteSpace(remoteName) ||
            remoteName is "." or ".." ||
            remoteName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            remoteName.Contains('/') ||
            remoteName.Contains('\\'))
        {
            return null;
        }

        try
        {
            var directory = Path.GetFullPath(localDirectory);
            var candidate = Path.GetFullPath(Path.Combine(directory, remoteName));
            return string.Equals(Path.GetDirectoryName(candidate), directory, StringComparison.OrdinalIgnoreCase)
                ? candidate
                : null;
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    private static bool IsSafeSftpChildName(string name) =>
        !string.IsNullOrWhiteSpace(name) &&
        name is not "." and not ".." &&
        !name.Contains('/') &&
        !name.Contains('\\') &&
        !name.Any(char.IsControl);

    private static string CreateUniqueSftpFileName(string originalName, ISet<string> reservedNames)
    {
        var extension = Path.GetExtension(originalName);
        var stem = extension.Length == 0 ? originalName : originalName[..^extension.Length];
        for (var index = 1; index <= 9999; index++)
        {
            var candidate = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{stem} ({index}){extension}");
            if (!reservedNames.Contains(candidate))
            {
                return candidate;
            }
        }

        return string.Concat(stem, "-", Guid.NewGuid().ToString("N"), extension);
    }

    private sealed class BatchContinuousRuntime(
        BatchContinuousSessionViewModel session,
        TerminalSessionLease lease,
        Guid workspaceId,
        Guid assetId,
        bool temporaryVerifiedSession)
    {
        private int stopStarted;

        public BatchContinuousSessionViewModel Session { get; } = session;

        public TerminalSessionLease Lease { get; } = lease;

        public Guid WorkspaceId { get; } = workspaceId;

        public Guid AssetId { get; } = assetId;

        public bool TemporaryVerifiedSession { get; } = temporaryVerifiedSession;

        public CancellationTokenSource TimeoutCancellation { get; } = new();

        public bool TryBeginStop() => Interlocked.CompareExchange(ref stopStarted, 1, 0) == 0;
    }

    private sealed class SftpTransferQueueContext(WorkspaceTabViewModel owner)
    {
        public WorkspaceTabViewModel Owner { get; } = owner;

        public List<SftpTransferTaskViewModel> Tasks { get; } = [];

        public List<SftpTransferTaskViewModel> ActiveTasks { get; } = [];

        public List<SftpTransferTaskViewModel> CompletedTasks { get; } = [];

        public CancellationTokenSource? BatchCancellation { get; set; }

        public bool IsBatchRunning { get; set; }

        public string TransferStatus { get; set; } = "暂无传输任务";

        public SftpTransferRetryRequest? LastTransferRetry { get; set; }

        public SftpBatchRetryRequest? LastBatchRetry { get; set; }
    }

    private sealed record SftpTransferRetryRequest(
        bool IsUpload,
        string LocalPath,
        string RemotePath,
        string DisplayName,
        SftpDirectoryEntryViewModel? DownloadEntry)
    {
        public static SftpTransferRetryRequest ForDownload(SftpDirectoryEntryViewModel entry, string localPath) =>
            new(false, localPath, entry.Path, entry.Name, entry);

        public static SftpTransferRetryRequest ForUpload(string localPath, string remotePath) =>
            new(true, localPath, remotePath, Path.GetFileName(remotePath), null);
    }

    private sealed record SftpBatchDownloadItem(
        SftpDirectoryEntryViewModel Entry,
        string LocalPath,
        SftpTransferTaskViewModel Task);

    private sealed record SftpBatchDeleteItem(
        SftpDirectoryEntryViewModel Entry,
        SftpTransferTaskViewModel Task);

    private sealed record SftpBatchUploadItem(
        SftpUploadSource Source,
        string RequestedFileName,
        string RemotePath,
        SftpDirectoryEntryViewModel? Existing,
        SftpUploadConflictPolicy ConflictPolicy,
        SftpTransferTaskViewModel Task);

    private sealed record SftpUploadItemOutcome(bool Succeeded, string Status);

    private sealed record SftpBatchRetryRequest(
        IReadOnlyList<SftpBatchUploadItem> Uploads,
        IReadOnlyList<SftpBatchDownloadItem> Downloads,
        IReadOnlyList<SftpBatchDeleteItem> Deletes)
    {
        public static SftpBatchRetryRequest ForUploads(IReadOnlyList<SftpBatchUploadItem> uploads) =>
            new(uploads.ToList(), [], []);

        public static SftpBatchRetryRequest ForDownloads(IReadOnlyList<SftpBatchDownloadItem> downloads) =>
            new([], downloads.ToList(), []);

        public static SftpBatchRetryRequest ForDeletes(IReadOnlyList<SftpBatchDeleteItem> deletes) =>
            new([], [], deletes.ToList());
    }

    private sealed record SanitizedCommandPaste(
        string Text,
        bool RemovedControlCharacters,
        bool ConvertedMultiline);
}

public readonly record struct BatchAssetDeleteResult(int DeletedCount, int FailedCount);

public readonly record struct BatchAssetMetadataUpdateResult(int UpdatedCount, int QueueFailures, int SkippedSyncCount);
