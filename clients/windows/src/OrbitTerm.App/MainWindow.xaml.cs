using System.Reflection;
using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Input;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;
using WinRT.Interop;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Shortcuts;
using OrbitTerm.App.Controls;
using OrbitTerm.NativeBridge;
using OrbitTerm.Presentation;
using OrbitTerm.Terminal;

namespace OrbitTerm.App;

public sealed partial class MainWindow : Window
{
    public const int MinimumWindowWidth = 980;
    public const int MinimumWindowHeight = 700;
    private const int DefaultWindowWidth = 1280;
    private const int DefaultWindowHeight = 800;
    private static readonly ApplicationPaletteOption[] ApplicationPaletteOptions =
    [
        new("天空糖果"),
        new("翡翠流光"),
        new("蜜桃晨光"),
        new("薰衣草雾"),
        new("冰川薄荷"),
    ];

    private bool isSftpDialogOpen;
    private bool isSnippetDialogOpen;
    private bool isDockerDialogOpen;
    private DockerLogWindow? activeDockerLogWindow;
    private bool isAssetDialogOpen;
    private bool isAssetManagementDialogOpen;
    private bool isSettingsDialogOpen;
    private bool isHostKeyDialogOpen;
    private bool isExitConfirmationOpen;
    private bool allowApplicationClose;
    private MonitorDetailsWindow? monitorDetailsWindow;
    private BatchCommandWindow? batchCommandWindow;
    private readonly SshKeyLibraryService sshKeyLibrary;
    private readonly SshPublicKeyDeploymentService sshPublicKeyDeployment;
    private readonly ICredentialVault credentialVault;
    private readonly OrbitBackupService backupService;
    private readonly SessionOrchestrator remoteAccessOrchestrator;
    private bool isSshKeyLibraryOpen;
    private bool hasPromptedForAccountUnlockThisLaunch;
    private readonly HashSet<string> confirmedTelnetTargets = new(StringComparer.Ordinal);
    private bool toolInspectorAutomaticallyCollapsed;
    private bool assetSidebarAutomaticallyCollapsed;
    private Expander? expandedAssetGroup;
    private readonly IntPtr windowHandle;
    private readonly WindowSubclassProc windowSubclassProc;
    private const double CollapsedPaneWidth = 0;
    private const double DefaultAssetSidebarWidth = 300;
    private const double DefaultToolInspectorWidth = 328;
    private const double AssetSidebarWindowRatio = 0.234375;
    private const double ToolInspectorWindowRatio = 0.25625;
    private const double MinimumAssetSidebarWidth = 220;
    private const double MaximumAssetSidebarWidth = 320;
    private const double MinimumToolInspectorWidth = 280;
    private const double MaximumToolInspectorWidth = 420;
    private const double MinimumTerminalWorkspaceWidth = 560;
    private const double TerminalHorizontalPadding = 30;
    private const double TerminalVerticalPadding = 30;
    private const double TerminalCellWidth = 7.8;
    private const double TerminalCellHeight = 18;
    private const double TerminalSplitDividerThickness = 8;
    private const double MinimumTerminalSplitRatio = 0.2;
    private const double MaximumTerminalSplitRatio = 0.8;
    private double assetSidebarExpandedWidth = DefaultAssetSidebarWidth;
    private double toolInspectorExpandedWidth = DefaultToolInspectorWidth;
    private bool assetSidebarFollowsWindow = true;
    private bool toolInspectorFollowsWindow = true;
    private double terminalSplitTopRatio = 0.5;
    private double terminalSplitLeftRatio = 0.5;
    private readonly string layoutStatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm", "window-layout.json");
    private readonly DispatcherQueueTimer terminalResizeTimer;
    private readonly DispatcherQueueTimer terminalAutoScrollTimer;
    private readonly DispatcherQueueTimer terminalScrollRestoreTimer;
    private readonly DispatcherQueueTimer monitorRefreshTimer;
    private readonly DispatcherQueueTimer dockerRefreshTimer;
    private bool isDockerInspectorVisible;
    private bool isMainWindowActive = true;
    private double pendingTerminalViewportWidth;
    private double pendingTerminalViewportHeight;
    private double pendingTerminalScrollOffset;
    private readonly string terminalAppearancePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "terminal-appearance.json");
    private readonly string monitorPreferencesPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "monitor-preferences.json");
    private readonly string keyboardShortcutPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "keyboard-shortcuts.json");
    private Dictionary<AppShortcutAction, KeyboardShortcutGesture?> keyboardShortcuts =
        KeyboardShortcutCatalog.CreateDefaults();
    private readonly Dictionary<KeyboardAccelerator, AppShortcutAction> shortcutAcceleratorActions = [];
    private bool suppressAppShortcuts;
    private TerminalAppearanceSettings terminalAppearance = new(13, TerminalColorTheme.Dark);
    private readonly Dictionary<Guid, TerminalSplitSurface> terminalSplitSurfaces = [];
    private NativeTerminalView? activeTerminalView;
    private bool terminalWasOpen;
    private bool isTerminalFullscreen;
    private Visibility assetSidebarVisibilityBeforeTerminalFullscreen;
    private Visibility toolInspectorVisibilityBeforeTerminalFullscreen;
    private GridLength assetSidebarWidthBeforeTerminalFullscreen;
    private GridLength toolInspectorWidthBeforeTerminalFullscreen;
    private PointInt32 windowPositionBeforeTerminalFullscreen;
    private SizeInt32 windowSizeBeforeTerminalFullscreen;
    private bool windowWasMaximizedBeforeTerminalFullscreen;
    private double restoredWindowWidth = DefaultWindowWidth;
    private double restoredWindowHeight = DefaultWindowHeight;
    private bool restoreWindowMaximized;

    public MainWindow(
        SessionOrchestrator orchestrator,
        ICredentialVault credentialVault,
        IServerAssetStore serverAssetStore,
        ISnippetStore snippetStore,
        IAccountSessionStore accountSessionStore,
        AccountUnlockController accountUnlockController,
        IEncryptedConfigSynchronizer encryptedConfigSynchronizer,
        IEncryptedAssetPublisher encryptedAssetPublisher,
        IEncryptedSnippetPublisher encryptedSnippetPublisher,
        SshKeyLibraryService sshKeyLibrary,
        PortForwardProfileLibrary portForwardProfileLibrary)
    {
        remoteAccessOrchestrator = orchestrator;
        this.credentialVault = credentialVault;
        this.sshKeyLibrary = sshKeyLibrary;
        this.portForwardProfileLibrary = portForwardProfileLibrary;
        sshPublicKeyDeployment = new SshPublicKeyDeploymentService(orchestrator, credentialVault, sshKeyLibrary);
        backupService = new OrbitBackupService(serverAssetStore, snippetStore, credentialVault, sshKeyLibrary);
        InitializeComponent();
        ConfigureWindowChrome();
        NativeWindowCornerService.Apply(this);
        terminalResizeTimer = DispatcherQueue.CreateTimer();
        terminalResizeTimer.Interval = TimeSpan.FromMilliseconds(160);
        terminalResizeTimer.Tick += TerminalResizeTimerTick;
        terminalAutoScrollTimer = DispatcherQueue.CreateTimer();
        terminalAutoScrollTimer.Interval = TimeSpan.FromMilliseconds(80);
        terminalAutoScrollTimer.Tick += TerminalAutoScrollTimerTick;
        terminalScrollRestoreTimer = DispatcherQueue.CreateTimer();
        terminalScrollRestoreTimer.Interval = TimeSpan.FromMilliseconds(80);
        terminalScrollRestoreTimer.Tick += TerminalScrollRestoreTimerTick;
        monitorRefreshTimer = DispatcherQueue.CreateTimer();
        monitorRefreshTimer.Interval = TimeSpan.FromSeconds(1);
        monitorRefreshTimer.Tick += MonitorRefreshTimerTick;
        dockerRefreshTimer = DispatcherQueue.CreateTimer();
        dockerRefreshTimer.Interval = TimeSpan.FromSeconds(2);
        dockerRefreshTimer.Tick += DockerRefreshTimerTick;
        Activated += MainWindowActivated;
        AppWindow.Changed += MainAppWindowChanged;
        // NativeTerminalView owns pointer capture and focus. Handling the same
        // pointer press again on the viewport makes drag selection feel sticky.
        windowHandle = WindowNative.GetWindowHandle(this);
        windowSubclassProc = WindowSubclass;
        if (!SetWindowSubclass(windowHandle, windowSubclassProc, UIntPtr.Zero, IntPtr.Zero))
        {
            throw new InvalidOperationException("无法为主窗口设置最小尺寸限制。");
        }

        RestorePaneLayout();
        var initialDpiScale = GetDpiScale(windowHandle);
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var requestedWidth = (int)Math.Ceiling(restoredWindowWidth * initialDpiScale);
        var requestedHeight = (int)Math.Ceiling(restoredWindowHeight * initialDpiScale);
        AppWindow.Resize(new SizeInt32(
            Math.Min(workArea.Width, Math.Max((int)Math.Ceiling(MinimumWindowWidth * initialDpiScale), requestedWidth)),
            Math.Min(workArea.Height, Math.Max((int)Math.Ceiling(MinimumWindowHeight * initialDpiScale), requestedHeight))));
        ViewModel = new MainWindowViewModel(
            orchestrator,
            credentialVault,
            serverAssetStore,
            snippetStore,
            action => DispatcherQueue.TryEnqueue(() => action()),
            accountSessionStore,
            accountUnlockController,
            encryptedConfigSynchronizer,
            encryptedAssetPublisher,
            encryptedSnippetPublisher);
        keyboardShortcuts = LoadKeyboardShortcuts();
        ConfigureKeyboardShortcuts();
        AppWindow.Closing += MainAppWindowClosing;
        Closed += (_, _) =>
        {
            CloseRemoteDesktopWindows();
            activeDockerLogWindow?.StopAndClose();
            activeDockerLogWindow = null;
            monitorDetailsWindow?.Close();
            monitorDetailsWindow = null;
            batchCommandWindow?.Close();
            batchCommandWindow = null;
            foreach (var tunnel in activeLocalTunnels.Values.ToArray())
                _ = remoteAccessOrchestrator.StopLocalTunnelAsync(tunnel, CancellationToken.None);
            activeLocalTunnels.Clear();
            monitorRefreshTimer.Stop();
            dockerRefreshTimer.Stop();
            ViewModel.ClearSessionSecrets();
        };
        ApplyMonitorPreferences(LoadMonitorPreferences());
        Root.DataContext = ViewModel;
        SftpRecentOperationsFlyoutContent.DataContext = ViewModel;
        DockerRecentOperationsFlyoutContent.DataContext = ViewModel;
        Root.ActualThemeChanged += RootActualThemeChanged;
        ViewModel.PropertyChanged += ViewModelPropertyChanged;
        ViewModel.TerminalLines.CollectionChanged += TerminalLinesCollectionChanged;
        NativeTerminalView.Bind(ViewModel.TerminalLines);
        NativeTerminalView.AttachScrollHost(TerminalScrollViewer);
        terminalAppearance = LoadTerminalAppearance();
        ApplyApplicationTheme(terminalAppearance.AppTheme);
        ApplyApplicationPalette(terminalAppearance.AppPalette);
        ApplyTerminalAppearance(NativeTerminalView, terminalAppearance);
        NativeTerminalView.SendInputAsync = bytes =>
            ViewModel.WriteTerminalInputAsync(bytes, CancellationToken.None);
        NativeTerminalView.TryHandleApplicationShortcut = TryHandleTerminalApplicationShortcut;
        NativeTerminalView.PasteRequested += NativeTerminalViewPasteRequested;
        NativeTerminalView.SearchRequested += (_, _) => ToggleTerminalSearchClick(this, new RoutedEventArgs());
        NativeTerminalView.AppearanceRequested += (_, _) => ShowTerminalAppearanceDialogClick(this, new RoutedEventArgs());
        NativeTerminalView.ClearRequested += (_, _) =>
        {
            if (ViewModel.ClearTerminalCommand.CanExecute(null))
            {
                ViewModel.ClearTerminalCommand.Execute(null);
            }
        };
        NativeTerminalView.CopyTranscriptRequested += (_, _) => CopyTerminalOutputClick(this, new RoutedEventArgs());
        NativeTerminalView.SelectionStarted += (_, _) => NativeTerminalView.PauseFollowingLatestOutput();
        NativeTerminalView.FollowLatestChanged += PrimaryTerminalFollowLatestChanged;
        NativeTerminalView.Activated += (_, _) => SetActiveTerminalSurface(NativeTerminalView, null);
        TerminalViewport.AddHandler(
            UIElement.PointerPressedEvent,
            new PointerEventHandler(TerminalViewportPointerPressed),
            true);
        activeTerminalView = NativeTerminalView;
        RebuildTerminalSplitLayout();
        UpdateTerminalEmptyState();
        UpdateToolInspectorSessionState();
        UpdateAssetEmptyState();
        ViewModel.LoadAssetsCommand.Execute(null);
        ViewModel.LoadAccountSessionCommand.Execute(null);
        ViewModel.LoadSnippetsCommand.Execute(null);
        Root.Loaded += RootLoaded;
    }

    public MainWindowViewModel ViewModel { get; }

    private void RootLoaded(object sender, RoutedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(
            Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () => NativeWindowCornerService.ApplyVisibleFrameTheme(
                this,
                Root.ActualTheme == ElementTheme.Dark || terminalAppearance.AppTheme == "深色"));
        UpdateMonitorRefreshTimer();
        EnsurePrimaryPanesExpanded();
        if (restoreWindowMaximized && AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Maximize();
        }
        ApplyResponsivePaneRules(Root.ActualWidth);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (ViewModel.IsTerminalOpen)
            {
                NativeTerminalView.FocusTerminal();
            }
            else
            {
                AssetSearchBox.Focus(FocusState.Programmatic);
            }
        });
        TryPromptForStartupUnlock();
    }

    private void TryPromptForStartupUnlock()
    {
        if (hasPromptedForAccountUnlockThisLaunch || !ViewModel.IsAccountLocked || Root.XamlRoot is null)
        {
            return;
        }
        hasPromptedForAccountUnlockThisLaunch = true;
        DispatcherQueue.TryEnqueue(async () => await ShowAccountUnlockDialogAsync());
    }

    private void ToolInspectorTabClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tool })
        {
            SelectToolInspector(tool);
        }
    }

    private void SelectToolInspector(string tool)
    {
        var showSftp = string.Equals(tool, "SFTP", StringComparison.Ordinal);
        var showDocker = string.Equals(tool, "Docker", StringComparison.Ordinal);
        var showSnippets = string.Equals(tool, "Snippets", StringComparison.Ordinal);
        if (!showSftp && !showDocker && !showSnippets)
        {
            showSftp = true;
        }

        SftpToolPanel.Visibility = showSftp ? Visibility.Visible : Visibility.Collapsed;
        DockerToolPanel.Visibility = showDocker ? Visibility.Visible : Visibility.Collapsed;
        SnippetsToolPanel.Visibility = showSnippets ? Visibility.Visible : Visibility.Collapsed;
        SftpToolTabButton.IsChecked = showSftp;
        DockerToolTabButton.IsChecked = showDocker;
        SnippetsToolTabButton.IsChecked = showSnippets;
        isDockerInspectorVisible = showDocker;
        UpdateDockerRefreshTimer();
    }

    private void MainWindowActivated(object sender, WindowActivatedEventArgs args)
    {
        // Monitor sampling remains independent because its detail window can
        // stay open. Docker card polling pauses whenever the workstation is not
        // active and resumes when focus returns, avoiding background SSH work.
        isMainWindowActive = args.WindowActivationState != WindowActivationState.Deactivated;
        UpdateMonitorRefreshTimer();
        UpdateDockerRefreshTimer();
    }

    private void MainAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidSizeChange && !isTerminalFullscreen &&
            sender.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
        {
            var dpiScale = GetDpiScale(windowHandle);
            restoredWindowWidth = Math.Max(MinimumWindowWidth, sender.Size.Width / dpiScale);
            restoredWindowHeight = Math.Max(MinimumWindowHeight, sender.Size.Height / dpiScale);
        }
        if (args.DidPresenterChange)
        {
            UpdateMonitorRefreshTimer();
            UpdateDockerRefreshTimer();
        }
    }

    private void MonitorRefreshTimerTick(DispatcherQueueTimer sender, object args)
    {
        if (!ViewModel.IsMonitorAutoRefreshEnabled ||
            !ViewModel.RefreshMonitorSnapshotCommand.CanExecute(null))
        {
            return;
        }

        ViewModel.RefreshMonitorSnapshotCommand.Execute(null);
    }

    private void UpdateMonitorRefreshTimer()
    {
        var isMinimized = AppWindow.Presenter is OverlappedPresenter
        {
            State: OverlappedPresenterState.Minimized,
        };
        if (ViewModel.IsMonitorAutoRefreshEnabled && ViewModel.IsConnected && !isMinimized)
        {
            monitorRefreshTimer.Start();
        }
        else
        {
            monitorRefreshTimer.Stop();
        }
    }

    private async void DockerRefreshTimerTick(DispatcherQueueTimer sender, object args)
    {
        if (!isDockerInspectorVisible ||
            !ViewModel.IsConnected ||
            ViewModel.IsTelnetSession ||
            ViewModel.RefreshMonitorSnapshotCommand.IsRunning)
        {
            return;
        }

        await ViewModel.RefreshDockerInspectorForAutoRefreshAsync(CancellationToken.None);
    }

    private void UpdateDockerRefreshTimer()
    {
        var isMinimized = AppWindow.Presenter is OverlappedPresenter
        {
            State: OverlappedPresenterState.Minimized,
        };
        if (isDockerInspectorVisible &&
            isMainWindowActive &&
            ViewModel.IsConnected &&
            !ViewModel.IsTelnetSession &&
            !isMinimized)
        {
            dockerRefreshTimer.Start();
        }
        else
        {
            dockerRefreshTimer.Stop();
        }
    }

    private void ToggleAssetSidebarClick(object sender, RoutedEventArgs e)
    {
        assetSidebarAutomaticallyCollapsed = false;
        TogglePane(
            AssetSidebar,
            AssetSidebarColumn,
            MinimumAssetSidebarWidth,
            MaximumAssetSidebarWidth,
            ref assetSidebarExpandedWidth);
        ProtectTerminalWorkspace(PanePreference.AssetSidebar);
        UpdateAssetSidebarVisualState();
        UpdateToolInspectorVisualState();
    }

    private void ToggleToolInspectorClick(object sender, RoutedEventArgs e)
    {
        toolInspectorAutomaticallyCollapsed = false;
        TogglePane(
            ToolInspector,
            ToolInspectorColumn,
            MinimumToolInspectorWidth,
            MaximumToolInspectorWidth,
            ref toolInspectorExpandedWidth);
        ProtectTerminalWorkspace(PanePreference.ToolInspector);
        UpdateAssetSidebarVisualState();
        UpdateToolInspectorVisualState();
    }

    private void AssetGroupExpanderExpanding(Expander sender, ExpanderExpandingEventArgs e)
    {
        if (expandedAssetGroup is not null && !ReferenceEquals(expandedAssetGroup, sender))
        {
            expandedAssetGroup.IsExpanded = false;
        }
        expandedAssetGroup = sender;
        DispatcherQueue.TryEnqueue(() =>
        {
            sender.StartBringIntoView(new BringIntoViewOptions
            {
                AnimationDesired = true,
                VerticalAlignmentRatio = 0,
            });
        });
    }

    private void AssetGroupExpanderCollapsed(Expander sender, ExpanderCollapsedEventArgs e)
    {
        if (ReferenceEquals(expandedAssetGroup, sender))
        {
            expandedAssetGroup = null;
        }
    }

    private async void FocusAssetManagementClick(object sender, RoutedEventArgs e)
    {
        if (isAssetManagementDialogOpen)
        {
            return;
        }

        isAssetManagementDialogOpen = true;
        try
        {
            var query = string.Empty;
            var groupFilter = "全部分组";
            var selectedIds = new HashSet<Guid>();
            if (ViewModel.SelectedAsset is { } currentAsset)
            {
                selectedIds.Add(currentAsset.Id);
            }

            while (true)
            {
                string? action = null;
                Guid[] actionAssetIds = [];
                ContentDialog? dialog = null;
                var managerGroups = new ObservableCollection<AssetGroupViewModel>();
                var visibleAssets = new List<AssetViewModel>();
                var isRefreshing = false;
                var groupedSource = new CollectionViewSource
                {
                    Source = managerGroups,
                    IsSourceGrouped = true,
                    ItemsPath = new PropertyPath(nameof(AssetGroupViewModel.Items)),
                };
                var list = new ListView
                {
                    ItemsSource = groupedSource.View,
                    ItemTemplate = (DataTemplate)Root.Resources["AssetManagerItemTemplate"],
                    ItemContainerStyle = (Style)Root.Resources["AssetManagerListViewItemStyle"],
                    MinHeight = 300,
                    MaxHeight = 440,
                    SelectionMode = ListViewSelectionMode.Multiple,
                    IsMultiSelectCheckBoxEnabled = true,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                };
                list.GroupStyle.Add(new GroupStyle
                {
                    HeaderTemplate = (DataTemplate)Root.Resources["AssetManagerGroupHeaderTemplate"],
                    HidesIfEmpty = true,
                });

                var search = new TextBox
                {
                    Text = query,
                    PlaceholderText = "搜索名称、主机、用户名、分组或标签",
                    MinWidth = 0,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                };
                var groupOptions = new[] { "全部分组" }
                    .Concat(ViewModel.Assets.Where(ViewModel.CanAccessAsset).Select(asset => asset.Group)
                        .Where(group => !string.IsNullOrWhiteSpace(group))
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderBy(group => group, StringComparer.CurrentCultureIgnoreCase))
                    .ToArray();
                if (!groupOptions.Contains(groupFilter, StringComparer.OrdinalIgnoreCase))
                {
                    groupFilter = "全部分组";
                }
                var groupPicker = new ComboBox
                {
                    ItemsSource = groupOptions,
                    SelectedItem = groupFilter,
                    MinWidth = 140,
                    HorizontalAlignment = HorizontalAlignment.Right,
                };
                AutomationProperties.SetName(groupPicker, "资产分组筛选");
                var resultSummary = new TextBlock
                {
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = ResourceBrush("OrbitMutedTextBrush"),
                };
                var selectionSummary = new TextBlock
                {
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = ResourceBrush("OrbitMutedTextBrush"),
                };
                var emptyState = new TextBlock
                {
                    Text = "当前筛选条件下没有资产。",
                    Margin = new Thickness(12, 36, 12, 36),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    TextAlignment = TextAlignment.Center,
                    Foreground = ResourceBrush("OrbitMutedTextBrush"),
                    Visibility = Visibility.Collapsed,
                };

                Button ActionButton(string label, string requestedAction)
                {
                    var button = new Button
                    {
                        Content = label,
                        Style = ResourceStyle("OrbitModuleButtonStyle"),
                        HorizontalContentAlignment = HorizontalAlignment.Center,
                    };
                    button.Click += (_, _) =>
                    {
                        action = requestedAction;
                        actionAssetIds = selectedIds.ToArray();
                        dialog?.Hide();
                    };
                    return button;
                }

                var addButton = ActionButton("添加", "create");
                var bulkAddButton = ActionButton("批量添加", "bulk-create");
                var editButton = ActionButton("编辑所选", "edit");
                var selectVisibleButton = new Button
                {
                    Content = "选择当前结果",
                    Style = ResourceStyle("OrbitModuleButtonStyle"),
                };
                var clearSelectionButton = new Button
                {
                    Content = "取消选择",
                    Style = ResourceStyle("OrbitModuleButtonStyle"),
                };
                var moveGroupButton = ActionButton("移动分组", "move-group");
                var editTagsButton = ActionButton("修改标签", "edit-tags");
                var deleteButton = ActionButton("删除所选", "delete");

                void UpdateSelectionState()
                {
                    var count = selectedIds.Count;
                    selectionSummary.Text = count == 0 ? "尚未选择资产" : $"已选择 {count} 个资产";
                    editButton.IsEnabled = count == 1;
                    clearSelectionButton.IsEnabled = count > 0;
                    moveGroupButton.IsEnabled = count > 0;
                    editTagsButton.IsEnabled = count > 0;
                    deleteButton.IsEnabled = count > 0;
                }

                void RefreshManagerGroups()
                {
                    query = search.Text.Trim();
                    groupFilter = groupPicker.SelectedItem as string ?? "全部分组";
                    var normalizedQuery = query;
                    visibleAssets = ViewModel.Assets
                        .Where(ViewModel.CanAccessAsset)
                        .Where(asset => groupFilter == "全部分组" ||
                            string.Equals(asset.Group, groupFilter, StringComparison.OrdinalIgnoreCase))
                        .Where(asset => normalizedQuery.Length == 0 ||
                            asset.Name.Contains(normalizedQuery, StringComparison.CurrentCultureIgnoreCase) ||
                            asset.Host.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase) ||
                            asset.Username.Contains(normalizedQuery, StringComparison.CurrentCultureIgnoreCase) ||
                            asset.Endpoint.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase) ||
                            asset.Group.Contains(normalizedQuery, StringComparison.CurrentCultureIgnoreCase) ||
                            asset.Tags.Any(tag => tag.Contains(normalizedQuery, StringComparison.CurrentCultureIgnoreCase)))
                        .OrderBy(asset => asset.Group, StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(asset => asset.Name, StringComparer.CurrentCultureIgnoreCase)
                        .ToList();
                    var visibleIds = visibleAssets.Select(asset => asset.Id).ToHashSet();
                    selectedIds.IntersectWith(visibleIds);
                    isRefreshing = true;
                    list.SelectedItems.Clear();
                    managerGroups.Clear();
                    foreach (var group in visibleAssets.GroupBy(asset => asset.Group, StringComparer.CurrentCultureIgnoreCase))
                    {
                        managerGroups.Add(new AssetGroupViewModel(group.Key, group));
                    }
                    foreach (var asset in visibleAssets.Where(asset => selectedIds.Contains(asset.Id)))
                    {
                        list.SelectedItems.Add(asset);
                    }
                    isRefreshing = false;
                    resultSummary.Text = $"当前结果 {visibleAssets.Count} 个 · 共 {ViewModel.Assets.Count(ViewModel.CanAccessAsset)} 个可用资产";
                    list.Visibility = visibleAssets.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
                    emptyState.Visibility = visibleAssets.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                    UpdateSelectionState();
                }

                list.SelectionChanged += (_, _) =>
                {
                    if (isRefreshing)
                    {
                        return;
                    }
                    selectedIds.Clear();
                    foreach (var asset in list.SelectedItems.OfType<AssetViewModel>())
                    {
                        selectedIds.Add(asset.Id);
                    }
                    UpdateSelectionState();
                };
                list.DoubleTapped += (_, _) =>
                {
                    if (list.SelectedItems.Count != 1)
                    {
                        return;
                    }
                    action = "edit";
                    actionAssetIds = selectedIds.ToArray();
                    dialog?.Hide();
                };
                search.TextChanged += (_, _) => RefreshManagerGroups();
                groupPicker.SelectionChanged += (_, _) => RefreshManagerGroups();
                selectVisibleButton.Click += (_, _) =>
                {
                    isRefreshing = true;
                    list.SelectedItems.Clear();
                    selectedIds.Clear();
                    foreach (var asset in visibleAssets)
                    {
                        selectedIds.Add(asset.Id);
                        list.SelectedItems.Add(asset);
                    }
                    isRefreshing = false;
                    UpdateSelectionState();
                };
                clearSelectionButton.Click += (_, _) =>
                {
                    selectedIds.Clear();
                    list.SelectedItems.Clear();
                    UpdateSelectionState();
                };

                var filterRow = new Grid { ColumnSpacing = 8 };
                filterRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                filterRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                Grid.SetColumn(groupPicker, 1);
                filterRow.Children.Add(search);
                filterRow.Children.Add(groupPicker);

                var topActions = new Grid { ColumnSpacing = 8, RowSpacing = 6 };
                topActions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                topActions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                topActions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                topActions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                topActions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                topActions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                Grid.SetColumn(bulkAddButton, 1);
                Grid.SetColumn(editButton, 2);
                Grid.SetRow(resultSummary, 1);
                Grid.SetColumnSpan(resultSummary, 4);
                topActions.Children.Add(addButton);
                topActions.Children.Add(bulkAddButton);
                topActions.Children.Add(editButton);
                topActions.Children.Add(resultSummary);

                var listSurface = new Grid
                {
                    MinHeight = 300,
                    MaxHeight = 440,
                    Background = ResourceBrush("OrbitPanelBrush"),
                };
                listSurface.Children.Add(list);
                listSurface.Children.Add(emptyState);

                var selectionBar = new Grid
                {
                    Padding = new Thickness(10, 8, 10, 8),
                    Background = ResourceBrush("OrbitMetricBrush"),
                    ColumnSpacing = 8,
                    RowSpacing = 6,
                };
                selectionBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                selectionBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                selectionBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                selectionBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                selectionBar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                selectionBar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                selectionBar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                Grid.SetColumnSpan(selectionSummary, 4);
                Grid.SetRow(selectVisibleButton, 1);
                Grid.SetRow(clearSelectionButton, 1);
                Grid.SetColumn(clearSelectionButton, 1);
                Grid.SetRow(moveGroupButton, 2);
                Grid.SetRow(editTagsButton, 2);
                Grid.SetColumn(editTagsButton, 1);
                Grid.SetRow(deleteButton, 2);
                Grid.SetColumn(deleteButton, 2);
                selectionBar.Children.Add(selectionSummary);
                selectionBar.Children.Add(selectVisibleButton);
                selectionBar.Children.Add(clearSelectionButton);
                selectionBar.Children.Add(moveGroupButton);
                selectionBar.Children.Add(editTagsButton);
                selectionBar.Children.Add(deleteButton);

                var content = new StackPanel
                {
                    Spacing = 10,
                    MinWidth = 480,
                    MaxWidth = 560,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                };
                content.Children.Add(filterRow);
                content.Children.Add(topActions);
                content.Children.Add(listSurface);
                content.Children.Add(selectionBar);
                content.Children.Add(new TextBlock
                {
                    Text = ViewModel.AssetEditorStatus,
                    FontSize = 11,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = ResourceBrush("OrbitMutedTextBrush"),
                });

                RefreshManagerGroups();
                dialog = CreateThemedDialog("资产管理", content, closeButtonText: "关闭");
                await dialog.ShowAsync();

                if (action is null)
                {
                    break;
                }

                var selectedAssets = ViewModel.Assets
                    .Where(ViewModel.CanAccessAsset)
                    .Where(asset => actionAssetIds.Contains(asset.Id))
                    .ToArray();
                switch (action)
                {
                    case "create":
                        await ShowAssetEditorAsync(null);
                        selectedIds.Clear();
                        break;
                    case "bulk-create":
                        await ShowBulkAssetImportAsync();
                        selectedIds.Clear();
                        break;
                    case "edit" when selectedAssets.Length == 1:
                        ViewModel.SelectedAsset = selectedAssets[0];
                        await ShowAssetEditorAsync(selectedAssets[0]);
                        selectedIds.Clear();
                        selectedIds.Add(ViewModel.SelectedAsset?.Id ?? selectedAssets[0].Id);
                        break;
                    case "move-group" when selectedAssets.Length > 0:
                        var commonGroup = selectedAssets
                            .Select(asset => asset.Group)
                            .Distinct(StringComparer.OrdinalIgnoreCase)
                            .Count() == 1
                                ? selectedAssets[0].Group
                                : string.Empty;
                        var groupInput = new TextBox
                        {
                            Header = "目标分组",
                            Text = commonGroup,
                            PlaceholderText = "输入新分组名称；留空将移动到“未分组”",
                            MaxLength = 64,
                        };
                        var moveDialog = CreateThemedDialog(
                            $"移动 {selectedAssets.Length} 个资产",
                            groupInput,
                            "应用",
                            "取消");
                        if (await moveDialog.ShowAsync() == ContentDialogResult.Primary)
                        {
                            await ViewModel.UpdateAssetsMetadataAsync(
                                actionAssetIds,
                                groupInput.Text,
                                string.Empty,
                                string.Empty,
                                CancellationToken.None);
                        }
                        break;
                    case "edit-tags" when selectedAssets.Length > 0:
                        var addTagsInput = new TextBox
                        {
                            Header = "新增标签",
                            PlaceholderText = "多个标签使用逗号或分号分隔",
                            MaxLength = 528,
                        };
                        var removeTagsInput = new TextBox
                        {
                            Header = "移除标签",
                            PlaceholderText = "仅从所选资产移除匹配标签",
                            MaxLength = 528,
                        };
                        var tagFields = new StackPanel { Spacing = 10 };
                        tagFields.Children.Add(addTagsInput);
                        tagFields.Children.Add(removeTagsInput);
                        tagFields.Children.Add(new TextBlock
                        {
                            Text = "标签匹配不区分大小写；每个资产最多保留 16 个标签。",
                            TextWrapping = TextWrapping.Wrap,
                            FontSize = 11,
                            Foreground = ResourceBrush("OrbitMutedTextBrush"),
                        });
                        var tagsDialog = CreateThemedDialog(
                            $"修改 {selectedAssets.Length} 个资产的标签",
                            tagFields,
                            "应用",
                            "取消");
                        if (await tagsDialog.ShowAsync() == ContentDialogResult.Primary)
                        {
                            try
                            {
                                await ViewModel.UpdateAssetsMetadataAsync(
                                    actionAssetIds,
                                    null,
                                    addTagsInput.Text,
                                    removeTagsInput.Text,
                                    CancellationToken.None);
                            }
                            catch (ArgumentException exception)
                            {
                                await ShowAccountMessageAsync("无法批量修改标签", exception.Message);
                            }
                        }
                        break;
                    case "delete" when selectedAssets.Length > 0:
                        var preview = string.Join("、", selectedAssets.Take(3).Select(asset => asset.Name));
                        if (selectedAssets.Length > 3)
                        {
                            preview += " 等";
                        }
                        var confirmation = CreateThemedDialog(
                            $"删除所选的 {selectedAssets.Length} 个资产？",
                            new TextBlock
                            {
                                Text = $"将删除：{preview}\n\n本机资产记录和已保存凭据会被清理；已登录时会为每项资产记录同步删除墓碑。此操作不会连接或修改远端服务器。",
                                TextWrapping = TextWrapping.Wrap,
                            },
                            "删除",
                            "取消");
                        confirmation.DefaultButton = ContentDialogButton.Close;
                        if (await confirmation.ShowAsync() == ContentDialogResult.Primary)
                        {
                            await ViewModel.DeleteAssetsAsync(actionAssetIds, CancellationToken.None);
                            selectedIds.Clear();
                        }
                        break;
                }
            }
        }
        finally
        {
            isAssetManagementDialogOpen = false;
        }
    }

    private async void CopyCurrentHostClick(object sender, RoutedEventArgs e)
    {
        var host = ViewModel.CurrentConnectedHost.Trim();
        if (string.IsNullOrEmpty(host) || host == "未连接")
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(host);
        Clipboard.SetContent(package);
        CurrentHostCopyGlyph.Glyph = "\uE73E";
        ToolTipService.SetToolTip(CurrentHostCopyButton, "已复制当前资产 IP");
        AutomationProperties.SetHelpText(CurrentHostCopyButton, "当前资产 IP 已复制");
        await Task.Delay(1200);
        CurrentHostCopyGlyph.Glyph = "\uE8C8";
        ToolTipService.SetToolTip(CurrentHostCopyButton, "复制当前资产 IP");
    }

    private void ShowMonitorDetailsClick(object sender, RoutedEventArgs e)
    {
        if (monitorDetailsWindow is not null)
        {
            monitorDetailsWindow.Activate();
            return;
        }

        var details = new MonitorDetailsWindow(ViewModel, windowHandle, Root.ActualTheme);
        monitorDetailsWindow = details;
        details.Closed += (_, _) => monitorDetailsWindow = null;
        details.ShowOwned();
    }

    private void RootSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (isTerminalFullscreen)
        {
            DispatcherQueue.TryEnqueue(QueueTerminalResizeAfterDpiChange);
            return;
        }
        ApplyResponsivePaneRules(e.NewSize.Width);
        ProtectTerminalWorkspace(PanePreference.None);
    }

    private void ToggleTerminalFullscreenClick(object sender, RoutedEventArgs e) =>
        ToggleTerminalFullscreen();

    private void ToggleTerminalFullscreen()
    {
        if (!isTerminalFullscreen)
        {
            if (!ViewModel.IsTerminalOpen)
            {
                return;
            }

            isTerminalFullscreen = true;
            assetSidebarVisibilityBeforeTerminalFullscreen = AssetSidebar.Visibility;
            toolInspectorVisibilityBeforeTerminalFullscreen = ToolInspector.Visibility;
            assetSidebarWidthBeforeTerminalFullscreen = AssetSidebarColumn.Width;
            toolInspectorWidthBeforeTerminalFullscreen = ToolInspectorColumn.Width;
            windowPositionBeforeTerminalFullscreen = AppWindow.Position;
            windowSizeBeforeTerminalFullscreen = AppWindow.Size;
            windowWasMaximizedBeforeTerminalFullscreen = AppWindow.Presenter is OverlappedPresenter
            {
                State: OverlappedPresenterState.Maximized,
            };

            AppTitleBar.Visibility = Visibility.Collapsed;
            TitleBarRow.Height = new GridLength(0);
            MonitorOverviewBand.Visibility = Visibility.Collapsed;
            MonitorOverviewRow.Height = new GridLength(0);
            AssetSidebar.Visibility = Visibility.Collapsed;
            ToolInspector.Visibility = Visibility.Collapsed;
            AssetSidebarColumn.Width = new GridLength(0);
            ToolInspectorColumn.Width = new GridLength(0);
            AssetSidebarRail.Visibility = Visibility.Collapsed;
            ToolInspectorRail.Visibility = Visibility.Collapsed;
            AssetSidebarSplitter.Visibility = Visibility.Collapsed;
            ToolInspectorSplitter.Visibility = Visibility.Collapsed;
            SynchronizationStatusFooter.Visibility = Visibility.Collapsed;
            TerminalFullscreenButton.Content = "退出全屏";
            AutomationProperties.SetName(TerminalFullscreenButton, "退出终端全屏");
            AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        }
        else
        {
            isTerminalFullscreen = false;
            AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
            if (windowWasMaximizedBeforeTerminalFullscreen && AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.Maximize();
            }
            else
            {
                AppWindow.Move(windowPositionBeforeTerminalFullscreen);
                AppWindow.Resize(windowSizeBeforeTerminalFullscreen);
            }

            AppTitleBar.Visibility = Visibility.Visible;
            TitleBarRow.Height = new GridLength(36);
            MonitorOverviewBand.Visibility = Visibility.Visible;
            MonitorOverviewRow.Height = GridLength.Auto;
            SynchronizationStatusFooter.Visibility = Visibility.Visible;
            AssetSidebar.Visibility = assetSidebarVisibilityBeforeTerminalFullscreen;
            ToolInspector.Visibility = toolInspectorVisibilityBeforeTerminalFullscreen;
            AssetSidebarColumn.Width = assetSidebarWidthBeforeTerminalFullscreen;
            ToolInspectorColumn.Width = toolInspectorWidthBeforeTerminalFullscreen;
            TerminalFullscreenButton.Content = "全屏";
            AutomationProperties.SetName(TerminalFullscreenButton, "终端全屏");
            UpdateAssetSidebarVisualState();
            UpdateToolInspectorVisualState();
            ApplyResponsivePaneRules(Root.ActualWidth);
        }

        DispatcherQueue.TryEnqueue(() =>
        {
            QueueTerminalResizeAfterDpiChange();
            ActiveTerminalView.FocusTerminal();
        });
    }

    private void EnsurePrimaryPanesExpanded()
    {
        assetSidebarAutomaticallyCollapsed = false;
        toolInspectorAutomaticallyCollapsed = false;
        AssetSidebar.Visibility = Visibility.Visible;
        ToolInspector.Visibility = Visibility.Visible;
        AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
        ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
        UpdateAssetSidebarVisualState();
        UpdateToolInspectorVisualState();
    }

    private void TerminalViewportSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!ViewModel.IsTerminalOpen || e.NewSize.Width <= TerminalHorizontalPadding || e.NewSize.Height <= TerminalVerticalPadding)
        {
            return;
        }

        pendingTerminalViewportWidth = e.NewSize.Width;
        pendingTerminalViewportHeight = e.NewSize.Height;
        terminalResizeTimer.Stop();
        terminalResizeTimer.Start();
    }

    private void QueueTerminalResizeAfterDpiChange()
    {
        if (!ViewModel.IsTerminalOpen ||
            TerminalViewport.ActualWidth <= TerminalHorizontalPadding ||
            TerminalViewport.ActualHeight <= TerminalVerticalPadding)
        {
            return;
        }

        pendingTerminalViewportWidth = TerminalViewport.ActualWidth;
        pendingTerminalViewportHeight = TerminalViewport.ActualHeight;
        terminalResizeTimer.Stop();
        terminalResizeTimer.Start();
    }

    private void TerminalViewportPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (TerminalSearchPanel.Visibility == Visibility.Visible &&
            e.OriginalSource is DependencyObject source &&
            IsVisualDescendantOf(source, TerminalSearchPanel))
        {
            return;
        }

        if (ViewModel.IsTerminalOpen)
        {
            SetActiveTerminalSurface(NativeTerminalView, null);
            NativeTerminalView.FocusTerminal();
        }
    }

    private static bool IsVisualDescendantOf(DependencyObject candidate, DependencyObject ancestor)
    {
        for (DependencyObject? current = candidate; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (ReferenceEquals(current, ancestor))
            {
                return true;
            }
        }
        return false;
    }

    private NativeTerminalView ActiveTerminalView => activeTerminalView ?? NativeTerminalView;

    private void SetActiveTerminalSurface(NativeTerminalView view, Guid? paneId)
    {
        activeTerminalView = view;
        ViewModel.SetActiveTerminalPane(paneId);
        UpdateTerminalSplitActiveState(paneId);
    }

    private void RebuildTerminalSplitLayout()
    {
        activeTerminalView = NativeTerminalView;
        ViewModel.SetActiveTerminalPane(null);
        terminalSplitSurfaces.Clear();
        for (var index = TerminalSplitHost.Children.Count - 1; index >= 0; index--)
        {
            if (!ReferenceEquals(TerminalSplitHost.Children[index], TerminalViewport))
            {
                TerminalSplitHost.Children.RemoveAt(index);
            }
        }
        TerminalSplitHost.RowDefinitions.Clear();
        TerminalSplitHost.ColumnDefinitions.Clear();
        TerminalSplitHost.RowSpacing = 0;
        TerminalSplitHost.ColumnSpacing = 0;

        var panes = ViewModel.TerminalSplitPanes.ToArray();
        var total = panes.Length + 1;
        if (total == 1)
        {
            TerminalSplitHost.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            TerminalSplitHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            AddPrimaryTerminalToSplitHost(0, 0, 1);
            UpdateTerminalSplitActiveState(null);
            return;
        }

        AddTerminalSplitRows();
        if (total == 2)
        {
            TerminalSplitHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            AddPrimaryTerminalToSplitHost(0, 0, 1);
            AddAuxiliaryTerminalToSplitHost(panes[0], 2, 0);
            AddTerminalHorizontalSplitter(0, 1);
            UpdateTerminalSplitActiveState(null);
            return;
        }

        AddTerminalSplitColumns();
        if (total == 3)
        {
            AddPrimaryTerminalToSplitHost(0, 0, 3);
            AddAuxiliaryTerminalToSplitHost(panes[0], 2, 0);
            AddAuxiliaryTerminalToSplitHost(panes[1], 2, 2);
            AddTerminalHorizontalSplitter(0, 3);
            AddTerminalVerticalSplitter(2, 1);
            UpdateTerminalSplitActiveState(null);
            return;
        }

        AddPrimaryTerminalToSplitHost(0, 0, 1);
        AddAuxiliaryTerminalToSplitHost(panes[0], 0, 2);
        AddAuxiliaryTerminalToSplitHost(panes[1], 2, 0);
        AddAuxiliaryTerminalToSplitHost(panes[2], 2, 2);
        AddTerminalVerticalSplitter(0, 3);
        AddTerminalHorizontalSplitter(0, 3);
        UpdateTerminalSplitActiveState(null);
    }

    private void AddTerminalSplitRows()
    {
        TerminalSplitHost.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(terminalSplitTopRatio, GridUnitType.Star),
        });
        TerminalSplitHost.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(TerminalSplitDividerThickness),
        });
        TerminalSplitHost.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1 - terminalSplitTopRatio, GridUnitType.Star),
        });
    }

    private void AddTerminalSplitColumns()
    {
        TerminalSplitHost.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(terminalSplitLeftRatio, GridUnitType.Star),
        });
        TerminalSplitHost.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(TerminalSplitDividerThickness),
        });
        TerminalSplitHost.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1 - terminalSplitLeftRatio, GridUnitType.Star),
        });
    }

    private void AddTerminalHorizontalSplitter(int column, int columnSpan)
    {
        var splitter = CreateTerminalSplitThumb("上下拖动调整分屏高度");
        splitter.DragDelta += TerminalHorizontalSplitterDragDelta;
        splitter.DragCompleted += TerminalSplitterDragCompleted;
        Grid.SetRow(splitter, 1);
        Grid.SetColumn(splitter, column);
        Grid.SetColumnSpan(splitter, columnSpan);
        TerminalSplitHost.Children.Add(splitter);
    }

    private void AddTerminalVerticalSplitter(int row, int rowSpan)
    {
        var splitter = CreateTerminalSplitThumb("左右拖动调整分屏宽度");
        splitter.DragDelta += TerminalVerticalSplitterDragDelta;
        splitter.DragCompleted += TerminalSplitterDragCompleted;
        Grid.SetRow(splitter, row);
        Grid.SetRowSpan(splitter, rowSpan);
        Grid.SetColumn(splitter, 1);
        TerminalSplitHost.Children.Add(splitter);
    }

    private Thumb CreateTerminalSplitThumb(string accessibleName)
    {
        var splitter = new Thumb
        {
            Background = ResourceBrush("OrbitPanelStrokeBrush"),
            Opacity = 0.32,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsTabStop = false,
        };
        var dragging = false;
        splitter.PointerEntered += (_, _) =>
        {
            if (!dragging)
            {
                SetTerminalSplitterVisualState(splitter, emphasized: true);
            }
        };
        splitter.PointerExited += (_, _) =>
        {
            if (!dragging)
            {
                SetTerminalSplitterVisualState(splitter, emphasized: false);
            }
        };
        splitter.DragStarted += (_, _) =>
        {
            dragging = true;
            SetTerminalSplitterVisualState(splitter, emphasized: true);
        };
        splitter.DragCompleted += (_, _) =>
        {
            dragging = false;
            SetTerminalSplitterVisualState(splitter, emphasized: false);
        };
        AutomationProperties.SetName(splitter, accessibleName);
        AutomationProperties.SetHelpText(splitter, "拖动后自动保存分屏比例");
        ToolTipService.SetToolTip(splitter, accessibleName);
        return splitter;
    }

    private void SetTerminalSplitterVisualState(Thumb splitter, bool emphasized)
    {
        splitter.Background = ResourceBrush(emphasized ? "OrbitAccentBrush" : "OrbitPanelStrokeBrush");
        splitter.Opacity = emphasized ? 0.9 : 0.32;
    }

    private void TerminalHorizontalSplitterDragDelta(object sender, DragDeltaEventArgs e)
    {
        if (TerminalSplitHost.RowDefinitions.Count != 3)
        {
            return;
        }

        var availableHeight = Math.Max(
            1,
            TerminalSplitHost.ActualHeight - TerminalSplitDividerThickness);
        terminalSplitTopRatio = Math.Clamp(
            (TerminalSplitHost.RowDefinitions[0].ActualHeight + e.VerticalChange) / availableHeight,
            MinimumTerminalSplitRatio,
            MaximumTerminalSplitRatio);
        TerminalSplitHost.RowDefinitions[0].Height = new GridLength(terminalSplitTopRatio, GridUnitType.Star);
        TerminalSplitHost.RowDefinitions[2].Height = new GridLength(1 - terminalSplitTopRatio, GridUnitType.Star);
    }

    private void TerminalVerticalSplitterDragDelta(object sender, DragDeltaEventArgs e)
    {
        if (TerminalSplitHost.ColumnDefinitions.Count != 3)
        {
            return;
        }

        var availableWidth = Math.Max(
            1,
            TerminalSplitHost.ActualWidth - TerminalSplitDividerThickness);
        terminalSplitLeftRatio = Math.Clamp(
            (TerminalSplitHost.ColumnDefinitions[0].ActualWidth + e.HorizontalChange) / availableWidth,
            MinimumTerminalSplitRatio,
            MaximumTerminalSplitRatio);
        TerminalSplitHost.ColumnDefinitions[0].Width = new GridLength(terminalSplitLeftRatio, GridUnitType.Star);
        TerminalSplitHost.ColumnDefinitions[2].Width = new GridLength(1 - terminalSplitLeftRatio, GridUnitType.Star);
    }

    private void TerminalSplitterDragCompleted(object sender, DragCompletedEventArgs e)
    {
        PersistPaneLayout();
    }

    private void ResetTerminalSplitLayoutClick(object sender, RoutedEventArgs e)
    {
        terminalSplitTopRatio = 0.5;
        terminalSplitLeftRatio = 0.5;

        if (TerminalSplitHost.RowDefinitions.Count == 3)
        {
            TerminalSplitHost.RowDefinitions[0].Height = new GridLength(0.5, GridUnitType.Star);
            TerminalSplitHost.RowDefinitions[2].Height = new GridLength(0.5, GridUnitType.Star);
        }

        if (TerminalSplitHost.ColumnDefinitions.Count == 3)
        {
            TerminalSplitHost.ColumnDefinitions[0].Width = new GridLength(0.5, GridUnitType.Star);
            TerminalSplitHost.ColumnDefinitions[2].Width = new GridLength(0.5, GridUnitType.Star);
        }

        PersistPaneLayout();
    }

    private void AddPrimaryTerminalToSplitHost(int row, int column, int columnSpan)
    {
        Grid.SetRow(TerminalViewport, row);
        Grid.SetColumn(TerminalViewport, column);
        Grid.SetColumnSpan(TerminalViewport, columnSpan);
        if (!TerminalSplitHost.Children.Contains(TerminalViewport))
        {
            TerminalSplitHost.Children.Add(TerminalViewport);
        }
    }

    private void AddAuxiliaryTerminalToSplitHost(TerminalSplitPaneViewModel pane, int row, int column)
    {
        var terminalView = new NativeTerminalView
        {
            IsInputEnabled = true,
            CanCloseSplitPane = true,
        };
        terminalView.Bind(pane.Lines);
        ApplyTerminalAppearance(terminalView, terminalAppearance);
        terminalView.SendInputAsync = bytes =>
            ViewModel.WriteTerminalSplitInputAsync(pane.Id, bytes, CancellationToken.None);
        terminalView.TryHandleApplicationShortcut = TryHandleTerminalApplicationShortcut;
        terminalView.PasteRequested += NativeTerminalViewPasteRequested;
        terminalView.Activated += (_, _) => SetActiveTerminalSurface(terminalView, pane.Id);
        terminalView.SearchRequested += (_, _) =>
        {
            SetActiveTerminalSurface(terminalView, pane.Id);
            ToggleTerminalSearchClick(this, new RoutedEventArgs());
        };
        terminalView.AppearanceRequested += (_, _) => ShowTerminalAppearanceDialogClick(this, new RoutedEventArgs());
        terminalView.ClearRequested += (_, _) => ViewModel.ClearTerminalSplitPresentation(pane.Id);
        terminalView.CopyTranscriptRequested += (_, _) => CopyTerminalLinesToClipboard(pane.Lines);
        terminalView.CloseSplitPaneRequested += async (_, _) =>
            await ViewModel.CloseTerminalSplitPaneAsync(pane.Id, CancellationToken.None);

        var scrollViewer = new ScrollViewer
        {
            Padding = new Thickness(0),
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        scrollViewer.Content = terminalView;
        terminalView.AttachScrollHost(scrollViewer);
        var content = new Grid();
        content.Children.Add(scrollViewer);
        var border = new Border
        {
            CornerRadius = (CornerRadius)Microsoft.UI.Xaml.Application.Current.Resources["OrbitCornerRadius"],
            Background = ResourceBrush("OrbitTerminalBackgroundBrush"),
            BorderBrush = ResourceBrush("OrbitTerminalBorderBrush"),
            BorderThickness = new Thickness(1),
            Child = content,
        };
        border.AddHandler(
            UIElement.PointerPressedEvent,
            new PointerEventHandler((_, _) =>
            {
                SetActiveTerminalSurface(terminalView, pane.Id);
                terminalView.FocusTerminal();
            }),
            true);
        border.SizeChanged += async (_, args) =>
        {
            if (args.NewSize.Width <= TerminalHorizontalPadding || args.NewSize.Height <= TerminalVerticalPadding)
            {
                return;
            }

            var columns = (uint)Math.Clamp(
                (int)Math.Floor((args.NewSize.Width - TerminalHorizontalPadding) / TerminalCellWidth),
                20,
                500);
            var rows = (uint)Math.Clamp(
                (int)Math.Floor((args.NewSize.Height - TerminalVerticalPadding) / TerminalCellHeight),
                4,
                300);
            await ViewModel.ResizeTerminalSplitPaneAsync(
                pane.Id,
                new TerminalSize(columns, rows),
                CancellationToken.None);
        };
        Grid.SetRow(border, row);
        Grid.SetColumn(border, column);
        TerminalSplitHost.Children.Add(border);
        terminalSplitSurfaces[pane.Id] = new TerminalSplitSurface(pane, border, scrollViewer, terminalView);
    }

    private void PrimaryTerminalFollowLatestChanged(object? sender, EventArgs e)
    {
        var following = NativeTerminalView.IsFollowingLatestOutput;
        ViewModel.IsAutoScrollEnabled = following;
    }

    private void UpdateTerminalSplitActiveState(Guid? activePaneId)
    {
        var hasSplits = terminalSplitSurfaces.Count > 0 || ViewModel.HasTerminalSplits;
        TerminalViewport.BorderBrush = ResourceBrush(hasSplits && activePaneId is null
            ? "OrbitAccentBrush"
            : "OrbitTerminalBorderBrush");
        TerminalViewport.BorderThickness = new Thickness(activePaneId is null && hasSplits ? 2 : 1);

        foreach (var (paneId, surface) in terminalSplitSurfaces)
        {
            var active = paneId == activePaneId;
            surface.Border.BorderBrush = ResourceBrush(active ? "OrbitAccentBrush" : "OrbitTerminalBorderBrush");
            surface.Border.BorderThickness = new Thickness(active ? 2 : 1);
        }
    }

    private void ScrollTerminalSplitSurfacesToEnd()
    {
        foreach (var surface in terminalSplitSurfaces.Values)
        {
            surface.TerminalView.RequestAutoScrollToLatestOutput();
        }
    }

    private static void CopyTerminalLinesToClipboard(IEnumerable<TerminalLineViewModel> lines)
    {
        var text = string.Join(Environment.NewLine, lines.Select(line => line.Text));
        if (text.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    private void ToggleTerminalSearchClick(object sender, RoutedEventArgs e)
    {
        var opening = TerminalSearchPanel.Visibility != Visibility.Visible;
        TerminalSearchPanel.Visibility = opening ? Visibility.Visible : Visibility.Collapsed;
        if (opening)
        {
            DispatcherQueue.TryEnqueue(() => TerminalSearchBox.Focus(FocusState.Programmatic));
        }
        else
        {
            ClearTerminalSearch();
        }
    }

    private async void ShowAboutOrbitTermClick(object sender, RoutedEventArgs e)
    {
        var version = Windows.ApplicationModel.Package.Current.Id.Version;
        var versionText = $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}";
        var content = new StackPanel { Spacing = 10, MinWidth = 360 };
        content.Children.Add(new TextBlock
        {
            Text = "OrbitTerm",
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        content.Children.Add(new TextBlock { Text = $"版本 {versionText}" });
        content.Children.Add(new TextBlock
        {
            Text = "面向多设备资产管理、安全远程会话、SFTP、Docker、监控与批量运维的桌面客户端。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        var dialog = CreateThemedDialog("关于 OrbitTerm", content, closeButtonText: "完成");
        await dialog.ShowAsync();
    }

    private async void ShowTermsClick(object sender, RoutedEventArgs e)
    {
        const string terms = """
            OrbitTerm 使用条款、免责声明与隐私说明
            生效日期：2026-08-21

            1. 授权范围
            您只能连接、管理您拥有、管理或已取得明确合法授权的设备、账户、网络及数据。不得将本软件用于未授权访问、规避安全控制、破坏服务或其他违法活动。

            2. 账户与安全责任
            您负责妥善保管账户密码、主密码、SSH 私钥、令牌和远程资产凭据，并负责由您的账户或设备发起的操作。主密码和端到端加密密钥无法由 OrbitTerm 代为恢复；遗失可能导致加密数据无法解密。

            3. 同步、备份与数据
            跨设备同步采用端到端加密，但同步服务不等同于完整备份或长期托管。您应自行保留必要的独立备份，并在删除、覆盖、权限修改、批量命令、端口映射、进程终止等操作前核对目标与影响。

            4. 高风险操作与远端结果
            SSH、Telnet、RDP、SFTP、Docker、批量命令及端口映射会直接影响远端系统。网络中断、权限、系统差异、第三方组件或远端配置可能导致失败、重复、部分完成或数据损失。

            5. 隐私与诊断
            OrbitTerm 按最小必要原则处理数据。脱敏诊断不应包含密码、私钥、令牌、命令正文、终端内容或远端文件内容；导出、复制、截图或分享前，您仍应检查并移除敏感信息。

            6. 第三方服务与开源组件
            操作系统能力、网络、远端服务及开源组件的可用性、安全策略和许可由相应提供者负责，OrbitTerm 不保证其持续可用或完全兼容。

            7. 免责声明与责任限制
            在适用法律允许的最大范围内，本软件按“现状”和“可用状态”提供，不对不间断运行、无错误、适用于特定目的或绝对安全作出保证。开发者不对间接、附带、特殊、惩罚性或后果性损失承担责任；法律不允许排除的法定责任不受本条限制。

            8. 更新、暂停与联系
            为安全、兼容或合规需要，功能、协议和条款可能更新。严重滥用或违法使用时，相关服务可被限制。问题、权利请求或安全报告可通过应用内“帮助与反馈”联系维护者。

            继续使用即表示您已阅读并同意上述条款；若不同意，请停止使用相关功能。
            """;
        var content = new ScrollViewer
        {
            MinWidth = 480,
            MaxHeight = 560,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new TextBlock
            {
                Text = terms,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            },
        };
        var dialog = CreateThemedDialog("OrbitTerm 使用条款", content, closeButtonText: "我已阅读");
        await dialog.ShowAsync();
    }

    private async void CheckForUpdatesClick(object sender, RoutedEventArgs e)
    {
        var version = Windows.ApplicationModel.Package.Current.Id.Version;
        var versionText = $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}";
        await ShowAccountMessageAsync(
            "检查更新",
            $"当前版本：{versionText}\n\n当前测试签名包尚未配置正式 HTTPS 更新源。正式发布后，MSIX 将通过签名 App Installer 通道检查并安装更新；当前不会连接非官方地址。");
    }

    private async Task ExportPortableBackupAsync()
    {
        var passwordBox = new PasswordBox { Header = "备份密码（至少 12 个字符）" };
        var confirmBox = new PasswordBox { Header = "再次输入备份密码" };
        var includeCredentials = new CheckBox
        {
            Content = "在加密备份中包含连接凭据与 SSH 密钥库（高敏感）",
        };
        var validation = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitDangerBrush"),
            Visibility = Visibility.Collapsed,
        };
        var content = new StackPanel { Spacing = 10, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = "备份包含资产和快捷指令。备份密码不会保存，遗忘后无法恢复。",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(passwordBox);
        content.Children.Add(confirmBox);
        content.Children.Add(includeCredentials);
        content.Children.Add(new TextBlock
        {
            Text = "无论是否包含高敏感数据，账户令牌、主密码验证器和主机信任都不会导出。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(validation);
        var dialog = CreateThemedDialog("导出加密备份", content, "选择保存位置", "取消");
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (passwordBox.Password.Length < 12)
            {
                args.Cancel = true;
                validation.Text = "备份密码至少需要 12 个字符。";
                validation.Visibility = Visibility.Visible;
            }
            else if (!string.Equals(passwordBox.Password, confirmBox.Password, StringComparison.Ordinal))
            {
                args.Cancel = true;
                validation.Text = "两次输入的备份密码不一致。";
                validation.Visibility = Visibility.Visible;
            }
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        try
        {
            var backup = await backupService.ExportAsync(
                passwordBox.Password,
                includeCredentials.IsChecked == true,
                CancellationToken.None);
            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName = $"OrbitTerm-备份-{DateTime.Now:yyyyMMdd-HHmm}",
            };
            picker.FileTypeChoices.Add("OrbitTerm 加密备份", new List<string> { OrbitBackupService.FileExtension });
            InitializeWithWindow.Initialize(picker, windowHandle);
            var file = await picker.PickSaveFileAsync();
            if (file is null)
            {
                return;
            }
            await FileIO.WriteBytesAsync(file, backup);
            await ShowAccountMessageAsync("备份已安全导出", $"已保存为 {file.Name}。请将备份文件与备份密码分开保管。");
        }
        catch
        {
            await ShowAccountMessageAsync("无法导出备份", "本机数据未改变。请确认存储位置可用后重试。");
        }
        finally
        {
            passwordBox.Password = string.Empty;
            confirmBox.Password = string.Empty;
        }
    }

    private async Task RestorePortableBackupAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(OrbitBackupService.FileExtension);
        InitializeWithWindow.Initialize(picker, windowHandle);
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }
        var passwordBox = new PasswordBox { Header = "备份密码" };
        var modeBox = new ComboBox
        {
            Header = "恢复方式",
            ItemsSource = new[] { "合并到现有数据（推荐）", "替换当前账户与本机范围数据" },
            SelectedIndex = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var passwordContent = new StackPanel { Spacing = 10, MinWidth = 420 };
        passwordContent.Children.Add(new TextBlock
        {
            Text = "恢复前会先验证密码并显示备份摘要，不会立即覆盖数据。",
            TextWrapping = TextWrapping.Wrap,
        });
        passwordContent.Children.Add(passwordBox);
        passwordContent.Children.Add(modeBox);
        var passwordDialog = CreateThemedDialog("打开 OrbitTerm 备份", passwordContent, "验证并预览", "取消");
        if (await passwordDialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        try
        {
            var backup = await File.ReadAllBytesAsync(file.Path);
            var summary = await backupService.InspectAsync(
                backup,
                passwordBox.Password,
                ViewModel.CurrentAccountScope,
                CancellationToken.None);
            var lockedNotice = summary.LockedAssetCount == 0
                ? string.Empty
                : $"\n有 {summary.LockedAssetCount} 项账户资产不属于当前已解锁账户，将安全跳过。";
            var confirmation = CreateThemedDialog(
                "确认恢复备份？",
                new TextBlock
                {
                    Text = $"创建时间：{summary.CreatedAt.LocalDateTime:g}\n资产：{summary.AssetCount} 项\n快捷指令：{summary.SnippetCount} 条\n连接凭据：{(summary.IncludesCredentials ? $"{summary.CredentialCount} 项（加密）" : "未包含")}\nSSH 密钥：{(summary.IncludesCredentials ? $"{summary.SshKeyCount} 把（加密）" : "未包含")}{lockedNotice}\n\n恢复后不会自动连接任何远程主机。",
                    TextWrapping = TextWrapping.Wrap,
                },
                "确认恢复",
                "取消");
            confirmation.DefaultButton = ContentDialogButton.Close;
            if (await confirmation.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
            var mode = modeBox.SelectedIndex == 1
                ? OrbitBackupRestoreMode.ReplaceCurrentScope
                : OrbitBackupRestoreMode.Merge;
            var result = await backupService.RestoreAsync(
                backup,
                passwordBox.Password,
                ViewModel.CurrentAccountScope,
                mode,
                CancellationToken.None);
            await ViewModel.LoadAssetsCommand.ExecuteAsync(null);
            await ViewModel.LoadSnippetsCommand.ExecuteAsync(null);
            await ShowAccountMessageAsync(
                "备份恢复完成",
                $"已恢复 {result.RestoredAssets} 项资产、{result.RestoredSnippets} 条快捷指令、{result.RestoredCredentials} 项加密凭据和 {result.RestoredSshKeys} 把 SSH 密钥。" +
                (result.SkippedLockedAssets == 0 ? string.Empty : $"已跳过 {result.SkippedLockedAssets} 项其他账户的资产。"));
        }
        catch
        {
            await ShowAccountMessageAsync("无法恢复备份", "备份密码不正确、文件已损坏，或备份版本不受支持。现有数据未改变。");
        }
        finally
        {
            passwordBox.Password = string.Empty;
        }
    }

    private FrameworkElement CreateKeyboardShortcutEditor(
        Dictionary<AppShortcutAction, KeyboardShortcutGesture?> draft,
        TextBlock validationText)
    {
        var editor = new StackPanel { Spacing = 8 };
        var rows = new Dictionary<AppShortcutAction, (Border Container, TextBox Input, KeyboardShortcutDefinition Definition)>();
        AppShortcutAction? selectedAction = null;

        var filterGrid = new Grid { ColumnSpacing = 8 };
        filterGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filterGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(132) });
        var searchBox = new TextBox
        {
            PlaceholderText = "搜索操作或快捷键",
            Height = 34,
        };
        var groupBox = new ComboBox
        {
            ItemsSource = new[] { "全部分类" }.Concat(
                KeyboardShortcutCatalog.Definitions.Select(item => item.Group).Distinct()).ToArray(),
            SelectedIndex = 0,
            Height = 34,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Grid.SetColumn(groupBox, 1);
        filterGrid.Children.Add(searchBox);
        filterGrid.Children.Add(groupBox);

        var statusText = new TextBlock
        {
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var rowsHost = new StackPanel { Spacing = 3 };
        var resetSelected = new Button { Content = "恢复所选默认", MinWidth = 112, IsEnabled = false };
        var clearSelected = new Button { Content = "清除所选", MinWidth = 92, IsEnabled = false };
        var resetAll = new Button { Content = "全部恢复默认", MinWidth = 112 };

        void RefreshInputs()
        {
            foreach (var pair in rows)
            {
                pair.Value.Input.Text = draft.GetValueOrDefault(pair.Key)?.DisplayText ?? "未设置";
            }
        }

        void RefreshSelection()
        {
            resetSelected.IsEnabled = selectedAction is not null;
            clearSelected.IsEnabled = selectedAction is not null;
            foreach (var pair in rows)
            {
                pair.Value.Container.Background = selectedAction == pair.Key
                    ? ResourceBrush("OrbitAccentSoftBrush")
                    : new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            }
        }

        void RefreshFilter()
        {
            var query = searchBox.Text.Trim();
            var selectedGroup = groupBox.SelectedItem as string ?? "全部分类";
            var visibleCount = 0;
            foreach (var pair in rows.Values)
            {
                var gesture = draft.GetValueOrDefault(pair.Definition.Action)?.DisplayText ?? "未设置";
                var groupMatches = selectedGroup == "全部分类" || pair.Definition.Group == selectedGroup;
                var queryMatches = query.Length == 0 ||
                    pair.Definition.Label.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    pair.Definition.Group.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    gesture.Contains(query, StringComparison.OrdinalIgnoreCase);
                pair.Container.Visibility = groupMatches && queryMatches
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                if (pair.Container.Visibility == Visibility.Visible)
                {
                    visibleCount++;
                }
            }
            statusText.Text = $"显示 {visibleCount} / {rows.Count} 项；选择一行后可恢复或清除。";
        }

        void ShowValidation(string? message)
        {
            validationText.Text = message ?? string.Empty;
            validationText.Visibility = string.IsNullOrEmpty(message)
                ? Visibility.Collapsed
                : Visibility.Visible;
        }

        var header = new Grid { ColumnSpacing = 8, Padding = new Thickness(10, 0, 10, 2) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(156) });
        var categoryHeader = new TextBlock { Text = "分类", FontSize = 12, Foreground = ResourceBrush("OrbitMutedTextBrush") };
        var actionHeader = new TextBlock { Text = "操作", FontSize = 12, Foreground = ResourceBrush("OrbitMutedTextBrush") };
        var shortcutHeader = new TextBlock { Text = "快捷键", FontSize = 12, Foreground = ResourceBrush("OrbitMutedTextBrush") };
        Grid.SetColumn(actionHeader, 1);
        Grid.SetColumn(shortcutHeader, 2);
        header.Children.Add(categoryHeader);
        header.Children.Add(actionHeader);
        header.Children.Add(shortcutHeader);

        foreach (var definition in KeyboardShortcutCatalog.Definitions)
        {
            var row = new Grid { ColumnSpacing = 8, MinHeight = 38 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(156) });
            var group = new TextBlock
            {
                Text = definition.Group,
                FontSize = 12,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var label = new TextBlock
            {
                Text = definition.Label,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            var input = new TextBox
            {
                Text = draft.GetValueOrDefault(definition.Action)?.DisplayText ?? "未设置",
                IsReadOnly = true,
                Height = 30,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Center,
                PlaceholderText = "点击后按组合键",
            };
            AutomationProperties.SetName(input, $"{definition.Label}快捷键");
            input.GotFocus += (_, _) =>
            {
                selectedAction = definition.Action;
                RefreshSelection();
                ShowValidation("直接按下新的组合键；Backspace/Delete 清除，Esc 取消录入。");
                input.SelectAll();
            };
            input.KeyDown += (_, args) =>
            {
                args.Handled = true;
                if (args.Key == VirtualKey.Escape)
                {
                    FocusManager.TryMoveFocus(FocusNavigationDirection.Next);
                    ShowValidation(null);
                    return;
                }

                var modifiers = GetPressedShortcutModifiers();
                if (args.Key is VirtualKey.Back or VirtualKey.Delete && modifiers == ShortcutModifiers.None)
                {
                    draft[definition.Action] = null;
                    RefreshInputs();
                    RefreshFilter();
                    ShowValidation(null);
                    return;
                }

                if (IsWindowsKeyDown())
                {
                    ShowValidation("Windows 徽标键组合由系统保留，OrbitTerm 不会注册或覆盖。");
                    return;
                }

                var gesture = new KeyboardShortcutGesture(args.Key.ToString(), modifiers);
                var result = KeyboardShortcutPolicy.ValidateAssignment(definition.Action, gesture, draft);
                if (!result.IsValid)
                {
                    ShowValidation(result.Message);
                    return;
                }

                draft[definition.Action] = gesture;
                RefreshInputs();
                RefreshFilter();
                ShowValidation(null);
            };

            Grid.SetColumn(label, 1);
            Grid.SetColumn(input, 2);
            row.Children.Add(group);
            row.Children.Add(label);
            row.Children.Add(input);
            var container = new Border
            {
                Padding = new Thickness(10, 3, 10, 3),
                CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1),
                BorderBrush = ResourceBrush("OrbitPanelStrokeBrush"),
                Child = row,
            };
            container.Tapped += (_, _) => input.Focus(FocusState.Programmatic);
            rowsHost.Children.Add(container);
            rows[definition.Action] = (container, input, definition);
        }

        resetSelected.Click += (_, _) =>
        {
            if (selectedAction is not { } action) return;
            var definition = rows[action].Definition;
            var result = KeyboardShortcutPolicy.ValidateAssignment(action, definition.DefaultGesture, draft);
            if (!result.IsValid)
            {
                ShowValidation(result.Message);
                return;
            }
            draft[action] = definition.DefaultGesture;
            RefreshInputs();
            RefreshFilter();
            ShowValidation(null);
        };
        clearSelected.Click += (_, _) =>
        {
            if (selectedAction is not { } action) return;
            draft[action] = null;
            RefreshInputs();
            RefreshFilter();
            ShowValidation(null);
        };
        resetAll.Click += (_, _) =>
        {
            draft.Clear();
            foreach (var pair in KeyboardShortcutCatalog.CreateDefaults())
            {
                draft[pair.Key] = pair.Value;
            }
            RefreshInputs();
            RefreshFilter();
            ShowValidation(null);
        };

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(resetSelected);
        actions.Children.Add(clearSelected);
        actions.Children.Add(resetAll);
        searchBox.TextChanged += (_, _) => RefreshFilter();
        groupBox.SelectionChanged += (_, _) => RefreshFilter();

        editor.Children.Add(filterGrid);
        editor.Children.Add(statusText);
        editor.Children.Add(header);
        editor.Children.Add(new ScrollViewer
        {
            MaxHeight = 300,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = rowsHost,
        });
        editor.Children.Add(actions);
        RefreshInputs();
        RefreshFilter();
        RefreshSelection();
        return editor;
    }

    private void ConfigureKeyboardShortcuts()
    {
        foreach (var accelerator in shortcutAcceleratorActions.Keys.ToArray())
        {
            Root.KeyboardAccelerators.Remove(accelerator);
        }
        shortcutAcceleratorActions.Clear();

        foreach (var pair in keyboardShortcuts)
        {
            if (pair.Value is not { } gesture ||
                !Enum.TryParse<VirtualKey>(gesture.Key, ignoreCase: true, out var key) ||
                key == VirtualKey.None)
            {
                continue;
            }

            var accelerator = new KeyboardAccelerator
            {
                Key = key,
                Modifiers = ToVirtualKeyModifiers(gesture.Modifiers),
            };
            accelerator.Invoked += AppShortcutInvoked;
            shortcutAcceleratorActions[accelerator] = pair.Key;
            Root.KeyboardAccelerators.Add(accelerator);
        }

        var focusGesture = keyboardShortcuts.GetValueOrDefault(AppShortcutAction.FocusCommandInput)?.DisplayText ?? "未设置";
        var sendGesture = keyboardShortcuts.GetValueOrDefault(AppShortcutAction.SendCommandInput)?.DisplayText ?? "未设置";
        AutomationProperties.SetHelpText(
            TerminalPreInputBox,
            $"{focusGesture} 聚焦；上、下方向键浏览历史；Enter 发送；Esc 返回终端");
        ToolTipService.SetToolTip(TerminalSendButton, $"发送命令（Enter；应用快捷键：{sendGesture}）");
    }

    private void AppShortcutInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (suppressAppShortcuts || !isMainWindowActive || !shortcutAcceleratorActions.TryGetValue(sender, out var action))
        {
            return;
        }

        // Assigned application shortcuts take priority only while OrbitTerm is
        // foreground. Unassigned combinations never reach this handler and are
        // left to TextBox editing or the active remote terminal.
        args.Handled = ExecuteApplicationShortcut(action);
    }

    private bool TryHandleTerminalApplicationShortcut(
        VirtualKey key,
        bool control,
        bool shift,
        bool alt)
    {
        if (suppressAppShortcuts || !isMainWindowActive)
        {
            return false;
        }

        var modifiers = ShortcutModifiers.None;
        if (control) modifiers |= ShortcutModifiers.Control;
        if (shift) modifiers |= ShortcutModifiers.Shift;
        if (alt) modifiers |= ShortcutModifiers.Alt;
        var keyName = key.ToString();
        var assignment = keyboardShortcuts.FirstOrDefault(pair =>
            pair.Value is { } gesture &&
            gesture.Modifiers == modifiers &&
            string.Equals(gesture.Key, keyName, StringComparison.OrdinalIgnoreCase));
        return assignment.Value is not null && ExecuteApplicationShortcut(assignment.Key);
    }

    private bool ExecuteApplicationShortcut(AppShortcutAction action)
    {
        switch (action)
        {
            case AppShortcutAction.NewWorkspaceTab:
                ExecuteIfAvailable(ViewModel.OpenWorkspaceTabCommand);
                break;
            case AppShortcutAction.CloseWorkspaceTab:
                ExecuteIfAvailable(ViewModel.CloseWorkspaceTabCommand);
                break;
            case AppShortcutAction.DisconnectAndCloseWorkspaceTab:
                ExecuteIfAvailable(ViewModel.DisconnectAndCloseWorkspaceTabCommand);
                break;
            case AppShortcutAction.SearchTerminal:
                if (ViewModel.IsTerminalOpen) ToggleTerminalSearchClick(this, new RoutedEventArgs());
                break;
            case AppShortcutAction.FocusCommandInput:
                if (ViewModel.IsTerminalOpen) TerminalPreInputBox.Focus(FocusState.Keyboard);
                break;
            case AppShortcutAction.SendCommandInput:
                ExecuteIfAvailable(ViewModel.SendCommand);
                break;
            case AppShortcutAction.OpenSettings:
                ShowTerminalAppearanceDialogClick(this, new RoutedEventArgs());
                break;
            case AppShortcutAction.OpenBatchCommand:
                OpenBatchCommandClick(this, new RoutedEventArgs());
                break;
            case AppShortcutAction.ToggleAssetSidebar:
                ToggleAssetSidebarClick(this, new RoutedEventArgs());
                break;
            case AppShortcutAction.ToggleToolInspector:
                ToggleToolInspectorClick(this, new RoutedEventArgs());
                break;
            case AppShortcutAction.ToggleTerminalFullscreen:
                if (ViewModel.IsTerminalOpen) ToggleTerminalFullscreen();
                break;
            default:
                var tabIndex = (int)action - (int)AppShortcutAction.SelectWorkspaceTab1;
                if (tabIndex is >= 0 and < 9)
                {
                    ViewModel.SelectWorkspaceTabAt(tabIndex);
                    break;
                }
                var paneIndex = (int)action - (int)AppShortcutAction.SelectTerminalPane1;
                if (paneIndex is >= 0 and < 4) ActivateTerminalPaneAt(paneIndex);
                break;
        }
        return true;
    }

    private bool ActivateTerminalPaneAt(int zeroBasedIndex)
    {
        if (!ViewModel.IsTerminalOpen || zeroBasedIndex is < 0 or > 3)
        {
            return false;
        }

        if (zeroBasedIndex == 0)
        {
            SetActiveTerminalSurface(NativeTerminalView, null);
            NativeTerminalView.FocusTerminal();
            return true;
        }

        var pane = ViewModel.TerminalSplitPanes.ElementAtOrDefault(zeroBasedIndex - 1);
        if (pane is null || !terminalSplitSurfaces.TryGetValue(pane.Id, out var surface))
        {
            return false;
        }

        SetActiveTerminalSurface(surface.TerminalView, pane.Id);
        surface.TerminalView.FocusTerminal();
        return true;
    }

    private static void ExecuteIfAvailable(ICommand command)
    {
        if (command.CanExecute(null)) command.Execute(null);
    }

    private Dictionary<AppShortcutAction, KeyboardShortcutGesture?> LoadKeyboardShortcuts()
    {
        var defaults = KeyboardShortcutCatalog.CreateDefaults();
        try
        {
            if (!File.Exists(keyboardShortcutPath)) return defaults;
            var document = JsonSerializer.Deserialize<KeyboardShortcutSettingsDocument>(
                File.ReadAllText(keyboardShortcutPath));
            if (document is null || document.Version != 1) return defaults;

            foreach (var definition in KeyboardShortcutCatalog.Definitions)
            {
                if (!document.Bindings.TryGetValue(definition.Action.ToString(), out var gesture)) continue;
                if (gesture is not null &&
                    (!Enum.TryParse<VirtualKey>(gesture.Key, ignoreCase: true, out var key) || key == VirtualKey.None))
                {
                    return defaults;
                }
                defaults[definition.Action] = gesture;
            }
            return KeyboardShortcutPolicy.ValidateAll(defaults).IsValid ? defaults : KeyboardShortcutCatalog.CreateDefaults();
        }
        catch (IOException)
        {
            return defaults;
        }
        catch (JsonException)
        {
            return defaults;
        }
    }

    private void SaveKeyboardShortcuts(IReadOnlyDictionary<AppShortcutAction, KeyboardShortcutGesture?> shortcuts)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(keyboardShortcutPath)!);
            var bindings = shortcuts.ToDictionary(pair => pair.Key.ToString(), pair => pair.Value);
            File.WriteAllText(
                keyboardShortcutPath,
                JsonSerializer.Serialize(new KeyboardShortcutSettingsDocument(1, bindings)));
        }
        catch (IOException)
        {
            // A read-only profile must not interrupt an active remote session.
        }
    }

    private static ShortcutModifiers GetPressedShortcutModifiers()
    {
        var modifiers = ShortcutModifiers.None;
        if (IsVirtualKeyDown(VirtualKey.Control)) modifiers |= ShortcutModifiers.Control;
        if (IsVirtualKeyDown(VirtualKey.Shift)) modifiers |= ShortcutModifiers.Shift;
        if (IsVirtualKeyDown(VirtualKey.Menu)) modifiers |= ShortcutModifiers.Alt;
        return modifiers;
    }

    private static bool IsWindowsKeyDown() =>
        IsVirtualKeyDown(VirtualKey.LeftWindows) || IsVirtualKeyDown(VirtualKey.RightWindows);

    private static bool IsVirtualKeyDown(VirtualKey key) =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;

    private static VirtualKeyModifiers ToVirtualKeyModifiers(ShortcutModifiers modifiers)
    {
        var result = VirtualKeyModifiers.None;
        if (modifiers.HasFlag(ShortcutModifiers.Control)) result |= VirtualKeyModifiers.Control;
        if (modifiers.HasFlag(ShortcutModifiers.Shift)) result |= VirtualKeyModifiers.Shift;
        if (modifiers.HasFlag(ShortcutModifiers.Alt)) result |= VirtualKeyModifiers.Menu;
        return result;
    }

    private async void ShowTerminalAppearanceDialogClick(object sender, RoutedEventArgs e)
    {
        if (isSettingsDialogOpen)
        {
            return;
        }
        isSettingsDialogOpen = true;
        suppressAppShortcuts = true;
        var originalAppearance = terminalAppearance;
        var shortcutDraft = keyboardShortcuts.ToDictionary(pair => pair.Key, pair => pair.Value);
        var shortcutValidation = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitDangerBrush"),
            Visibility = Visibility.Collapsed,
        };
        var shortcutEditor = CreateKeyboardShortcutEditor(shortcutDraft, shortcutValidation);
        var sshKeysForSettings = await sshKeyLibrary.ListAccessibleAsync(
            ViewModel.CurrentAccountScope,
            ViewModel.IsAccountUnlocked,
            CancellationToken.None);
        var synchronizeEntireKeyLibrary = sshKeysForSettings.Count > 0 &&
            sshKeysForSettings.All(item => item.SyncScope == SshKeySyncScope.EndToEndEncrypted);
        var themeBox = new ComboBox
        {
            Header = "终端主题",
            ItemsSource = new[] { "Dracula", "Solarized Dark", "Nord", "Homebrew" },
            SelectedIndex = (int)terminalAppearance.Theme,
        };
        var followAppThemeToggle = new ToggleSwitch
        {
            Header = "终端跟随应用主题",
            IsOn = terminalAppearance.TerminalFollowsApplicationTheme != false,
            OffContent = "使用独立终端主题",
            OnContent = "颜色与界面主题同步",
        };
        themeBox.IsEnabled = !followAppThemeToggle.IsOn;
        followAppThemeToggle.Toggled += (_, _) => themeBox.IsEnabled = !followAppThemeToggle.IsOn;
        var appThemeBox = new ComboBox
        {
            Header = "应用外观模式",
            ItemsSource = new[] { "跟随系统", "浅色", "深色" },
            SelectedItem = terminalAppearance.AppTheme,
        };
        var appPaletteButtons = new List<RadioButton>();
        var appPaletteGrid = CreateApplicationPalettePreviewGrid(
            terminalAppearance.AppPalette,
            appPaletteButtons);
        var sizeLabel = new TextBlock
        {
            Text = $"字号：{terminalAppearance.FontSize:0}",
        };
        var sizeSlider = new Slider
        {
            Header = "终端字号",
            Minimum = 8,
            Maximum = 24,
            StepFrequency = 1,
            Value = terminalAppearance.FontSize,
        };
        sizeSlider.ValueChanged += (_, args) => sizeLabel.Text = $"字号：{args.NewValue:0}";
        var autoRefreshToggle = new ToggleSwitch
        {
            Header = "自动刷新资源趋势",
            IsOn = ViewModel.IsMonitorAutoRefreshEnabled,
        };
        var refreshIntervalBox = new ComboBox
        {
            Header = "监控刷新间隔",
            ItemsSource = new[] { "1 秒", "2 秒", "5 秒" },
            SelectedItem = ViewModel.MonitorRefreshInterval,
        };
        var trendRangeBox = new ComboBox
        {
            Header = "趋势时间范围",
            ItemsSource = ViewModel.MonitorTrendRangeOptions,
            SelectedItem = ViewModel.MonitorTrendRange,
        };
        var telnetToggle = new ToggleSwitch
        {
            Header = "启用 Telnet（明文，仅建议隔离内网）",
            IsOn = terminalAppearance.TelnetEnabled,
            OffContent = "已关闭",
            OnContent = "允许创建和连接 Telnet 资产",
        };
        var sshKeySyncToggle = new ToggleSwitch
        {
            Header = "自动端到端加密同步整个 SSH 密钥库",
            IsOn = synchronizeEntireKeyLibrary,
            OffContent = "逐把密钥决定，默认仅本机",
            OnContent = "当前密钥全部同步",
        };
        var exportBackupButton = new Button { Content = "导出加密备份", MinWidth = 144 };
        var restoreBackupButton = new Button { Content = "从备份恢复", MinWidth = 144 };
        var backupActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        backupActions.Children.Add(exportBackupButton);
        backupActions.Children.Add(restoreBackupButton);
        var aboutButton = new Button { Content = "关于 OrbitTerm", MinWidth = 130 };
        var termsButton = new Button { Content = "使用条款", MinWidth = 130 };
        var updateButton = new Button { Content = "检查更新", MinWidth = 130 };
        var helpActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        helpActions.Children.Add(aboutButton);
        helpActions.Children.Add(termsButton);
        helpActions.Children.Add(updateButton);
        string? pendingSettingsAction = null;
        var content = new StackPanel { Spacing = 12, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = "终端与监控偏好只保存到当前 Windows 用户；不会改变其他设备的配置。",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock { Text = "应用外观", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(appThemeBox);
        content.Children.Add(new TextBlock
        {
            Text = "界面主题",
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(appPaletteGrid);
        content.Children.Add(new TextBlock
        {
            Text = "界面主题与 macOS 使用相同的五套品牌色；Windows 保留原生 Fluent 控件和焦点样式。",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
        });
        content.Children.Add(new TextBlock { Text = "终端外观", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(followAppThemeToggle);
        content.Children.Add(themeBox);
        content.Children.Add(sizeSlider);
        content.Children.Add(sizeLabel);
        content.Children.Add(new TextBlock { Text = "终端与连接", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(telnetToggle);
        content.Children.Add(new TextBlock
        {
            Text = "Telnet 不加密用户名、密码、命令或终端内容，也无法验证服务器身份。SSH 失败时绝不会自动降级为 Telnet。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(new TextBlock { Text = "监控", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(autoRefreshToggle);
        content.Children.Add(refreshIntervalBox);
        content.Children.Add(trendRangeBox);
        content.Children.Add(new TextBlock { Text = "键盘与工作站", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(new TextBlock
        {
            Text = "快捷键仅在 OrbitTerm 主窗口处于前台时生效。Windows 系统保留键优先；复制、粘贴等文本编辑键优先；未分配的组合键继续发送给远端终端。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
        });
        content.Children.Add(shortcutEditor);
        content.Children.Add(shortcutValidation);
        content.Children.Add(new TextBlock { Text = "同步状态", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(new TextBlock
        {
            Text = ViewModel.AccountStatus,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
        });
        content.Children.Add(new TextBlock { Text = "安全与同步", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(sshKeySyncToggle);
        content.Children.Add(new TextBlock
        {
            Text = "开启会把现有密钥全部标记为同步；关闭会改为仅本机，并在下次同步提交远端删除墓碑。也可在“密钥管理”中逐把设置。私钥只以主密码端到端加密后的信封上传。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(new TextBlock
        {
            Text = "账户会话令牌与已验证器受 Windows DPAPI 保护。账户登录、解锁和加密同步仅在用户主动操作时进行。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(new TextBlock { Text = "备份与恢复", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(new TextBlock
        {
            Text = "导出为独立密码加密的便携备份。默认不含连接凭据或 SSH 私钥；只有明确勾选高敏感数据时才会一并加密导出。账户令牌、主密码验证器和主机信任始终排除。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        content.Children.Add(backupActions);
        content.Children.Add(new TextBlock { Text = "帮助与版本", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(helpActions);
        void PreviewApplicationAppearance()
        {
            var previewTheme = appThemeBox.SelectedItem as string ?? "跟随系统";
            var previewPalette = GetSelectedApplicationPalette(appPaletteButtons);
            ApplyApplicationTheme(previewTheme);
            ApplyApplicationPalette(previewPalette, previewTheme);
            var previewTerminal = new TerminalAppearanceSettings(
                Math.Round(sizeSlider.Value),
                (TerminalColorTheme)Math.Clamp(themeBox.SelectedIndex, 0, 3),
                previewTheme,
                previewPalette,
                telnetToggle.IsOn,
                followAppThemeToggle.IsOn);
            ApplyTerminalAppearanceToAll(previewTerminal);
        }
        appThemeBox.SelectionChanged += (_, _) => PreviewApplicationAppearance();
        themeBox.SelectionChanged += (_, _) => PreviewApplicationAppearance();
        followAppThemeToggle.Toggled += (_, _) => PreviewApplicationAppearance();
        sizeSlider.ValueChanged += (_, _) => PreviewApplicationAppearance();
        foreach (var paletteButton in appPaletteButtons)
        {
            paletteButton.Checked += (_, _) => PreviewApplicationAppearance();
        }
        var settingsScroll = new ScrollViewer
        {
            MaxHeight = Math.Clamp(Root.ActualHeight - 210, 360, 620),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = content,
        };
        AutomationProperties.SetName(settingsScroll, "可滚动的设置内容");
        var dialog = CreateThemedDialog("设置", settingsScroll, "应用", "取消");
        exportBackupButton.Click += (_, _) =>
        {
            pendingSettingsAction = "export";
            dialog.Hide();
        };
        restoreBackupButton.Click += (_, _) =>
        {
            pendingSettingsAction = "restore";
            dialog.Hide();
        };
        aboutButton.Click += (_, _) =>
        {
            pendingSettingsAction = "about";
            dialog.Hide();
        };
        termsButton.Click += (_, _) =>
        {
            pendingSettingsAction = "terms";
            dialog.Hide();
        };
        updateButton.Click += (_, _) =>
        {
            pendingSettingsAction = "update";
            dialog.Hide();
        };
        ContentDialogResult settingsResult;
        try
        {
            settingsResult = await dialog.ShowAsync();
        }
        finally
        {
            suppressAppShortcuts = false;
            isSettingsDialogOpen = false;
        }
        if (pendingSettingsAction is not null)
        {
            ApplyApplicationTheme(originalAppearance.AppTheme);
            ApplyApplicationPalette(originalAppearance.AppPalette, originalAppearance.AppTheme);
            if (pendingSettingsAction == "export")
            {
                await ExportPortableBackupAsync();
            }
            else if (pendingSettingsAction == "restore")
            {
                await RestorePortableBackupAsync();
            }
            else if (pendingSettingsAction == "about")
            {
                ShowAboutOrbitTermClick(this, new RoutedEventArgs());
            }
            else if (pendingSettingsAction == "terms")
            {
                ShowTermsClick(this, new RoutedEventArgs());
            }
            else
            {
                CheckForUpdatesClick(this, new RoutedEventArgs());
            }
            return;
        }
        if (settingsResult != ContentDialogResult.Primary)
        {
            ApplyApplicationTheme(originalAppearance.AppTheme);
            ApplyApplicationPalette(originalAppearance.AppPalette, originalAppearance.AppTheme);
            ApplyTerminalAppearanceToAll(originalAppearance);
            return;
        }

        var telnetWasEnabled = terminalAppearance.TelnetEnabled;
        var telnetEnabled = telnetToggle.IsOn;
        if (telnetEnabled && !telnetWasEnabled)
        {
            telnetEnabled = await ConfirmTelnetEnableAsync();
        }
        if (!telnetEnabled && telnetWasEnabled)
        {
            await ViewModel.DisableTelnetConnectionsAsync(CancellationToken.None);
        }

        terminalAppearance = new TerminalAppearanceSettings(
            Math.Round(sizeSlider.Value),
            (TerminalColorTheme)Math.Clamp(themeBox.SelectedIndex, 0, 3),
            appThemeBox.SelectedItem as string ?? "跟随系统",
            GetSelectedApplicationPalette(appPaletteButtons),
            telnetEnabled,
            followAppThemeToggle.IsOn);
        ApplyApplicationTheme(terminalAppearance.AppTheme);
        ApplyApplicationPalette(terminalAppearance.AppPalette, terminalAppearance.AppTheme);
        ApplyTerminalAppearanceToAll(terminalAppearance);
        SaveTerminalAppearance(terminalAppearance);
        ViewModel.IsMonitorAutoRefreshEnabled = autoRefreshToggle.IsOn;
        if (refreshIntervalBox.SelectedItem is string refreshInterval)
        {
            ViewModel.MonitorRefreshInterval = refreshInterval;
        }
        if (trendRangeBox.SelectedItem is string trendRange)
        {
            ViewModel.MonitorTrendRange = trendRange;
        }
        SaveMonitorPreferences();
        UpdateMonitorRefreshTimer();
        keyboardShortcuts = shortcutDraft;
        SaveKeyboardShortcuts(keyboardShortcuts);
        ConfigureKeyboardShortcuts();
        if (sshKeySyncToggle.IsOn != synchronizeEntireKeyLibrary)
        {
            if (sshKeySyncToggle.IsOn && !ViewModel.IsAccountUnlocked)
            {
                await ShowAccountMessageAsync(
                    "尚未启用密钥同步",
                    "请先登录并输入主密码解锁账户，再在设置或密钥管理中启用。其他设置已正常保存。");
                return;
            }
            var nextScope = sshKeySyncToggle.IsOn
                ? SshKeySyncScope.EndToEndEncrypted
                : SshKeySyncScope.LocalOnly;
            foreach (var key in sshKeysForSettings)
            {
                await sshKeyLibrary.SetSyncScopeAsync(
                    key.Id,
                    nextScope,
                    ViewModel.CurrentAccountScope,
                    CancellationToken.None);
            }
            if (ViewModel.IsAccountUnlocked)
            {
                await ViewModel.SynchronizeEncryptedConfigsAsync(string.Empty, CancellationToken.None);
            }
        }
    }

    private TerminalAppearanceSettings LoadTerminalAppearance()
    {
        try
        {
            if (!File.Exists(terminalAppearancePath))
            {
                return new TerminalAppearanceSettings(13, TerminalColorTheme.Dark, "跟随系统", "翡翠流光", false, false);
            }

            var saved = JsonSerializer.Deserialize<TerminalAppearanceSettings>(File.ReadAllText(terminalAppearancePath));
            return saved is not null && Enum.IsDefined(saved.Theme)
                ? new TerminalAppearanceSettings(Math.Clamp(saved.FontSize, 8, 24), saved.Theme, NormalizeAppTheme(saved.AppTheme), NormalizeAppPalette(saved.AppPalette), saved.TelnetEnabled, saved.TerminalFollowsApplicationTheme)
                : new TerminalAppearanceSettings(13, TerminalColorTheme.Dark, "跟随系统", "翡翠流光", false, false);
        }
        catch (IOException)
        {
            return new TerminalAppearanceSettings(13, TerminalColorTheme.Dark, "跟随系统", "翡翠流光", false, false);
        }
        catch (JsonException)
        {
            return new TerminalAppearanceSettings(13, TerminalColorTheme.Dark, "跟随系统", "翡翠流光", false, false);
        }
    }

    private async Task<bool> ConfirmTelnetEnableAsync()
    {
        var dialog = CreateThemedDialog(
            "启用不安全的 Telnet？",
            new TextBlock
            {
                Text = "Telnet 会以明文传输登录信息、命令和终端内容，也无法验证远端设备身份。仅应连接隔离内网或 VPN 内的受信旧设备。\n\n启用后，每个 Telnet 目标在首次连接前仍需单独确认；SSH 连接失败时 OrbitTerm 不会自动切换到 Telnet。",
                TextWrapping = TextWrapping.Wrap,
            },
            "我了解风险，启用",
            "保持关闭");
        dialog.DefaultButton = ContentDialogButton.Close;
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private void ApplyApplicationTheme(string appTheme)
    {
        Root.RequestedTheme = appTheme switch
        {
            "浅色" => ElementTheme.Light,
            "深色" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        DispatcherQueue.TryEnqueue(() =>
        {
            ApplyApplicationPalette(terminalAppearance.AppPalette, appTheme);
            UpdateWindowChromeTheme();
        });
    }

    private bool IsEffectiveApplicationThemeDark(string appTheme) =>
        appTheme == "深色" ||
        (appTheme == "跟随系统" && Root.ActualTheme == ElementTheme.Dark);

    private void ApplyTerminalAppearance(
        NativeTerminalView terminalView,
        TerminalAppearanceSettings appearance)
    {
        terminalView.SetAppearance(
            appearance.FontSize,
            appearance.Theme,
            appearance.TerminalFollowsApplicationTheme != false,
            IsEffectiveApplicationThemeDark(appearance.AppTheme),
            appearance.AppPalette);
    }

    private void ApplyTerminalAppearanceToAll(TerminalAppearanceSettings appearance)
    {
        ApplyTerminalAppearance(NativeTerminalView, appearance);
        foreach (var surface in terminalSplitSurfaces.Values)
        {
            ApplyTerminalAppearance(surface.TerminalView, appearance);
        }
    }

    private static string NormalizeAppTheme(string? appTheme) => appTheme is "浅色" or "深色"
        ? appTheme
        : "跟随系统";

    private static string NormalizeAppPalette(string? palette) =>
        ApplicationPaletteOptions.Any(option => option.Name == palette)
            ? palette!
            : "翡翠流光";

    private void ApplyApplicationPalette(string palette, string? appTheme = null)
    {
        var effectiveTheme = appTheme ?? terminalAppearance.AppTheme;
        var dark = effectiveTheme == "深色" ||
            (effectiveTheme == "跟随系统" && Root.ActualTheme == ElementTheme.Dark);
        var colors = GetApplicationPaletteColors(palette, dark);
        SetSemanticBrush("OrbitAccentBrush", colors.Accent);
        SetSemanticBrush("OrbitWorkbenchBrush", colors.Workbench);
        SetSemanticBrush("OrbitChromeBrush", colors.Chrome);
        SetSemanticBrush("OrbitPanelBrush", colors.Panel);
        SetSemanticBrush("OrbitMetricBrush", colors.Metric);
        SetSemanticBrush("OrbitPanelStrokeBrush", colors.Stroke);
        SetSemanticBrush("OrbitMutedTextBrush", dark
            ? Windows.UI.Color.FromArgb(255, 201, 212, 226)
            : Windows.UI.Color.FromArgb(255, 66, 79, 102));
        SetSemanticBrush("OrbitPrimaryTextBrush", dark
            ? Windows.UI.Color.FromArgb(255, 244, 247, 252)
            : Windows.UI.Color.FromArgb(255, 23, 32, 51));
        SetSemanticBrush("OrbitDialogSurfaceBrush", colors.DialogSurface);
        SetSemanticBrush("OrbitFeatureWindowBrush", colors.FeatureWindow);
        SetSemanticBrush("OrbitFeatureTitleBarBrush", colors.FeatureTitleBar);
        SetSemanticBrush("OrbitFeatureWindowStrokeBrush", colors.FeatureStroke);
        SetSemanticBrush("OrbitFeatureInnerBrush", colors.FeatureInner);
        SetSemanticBrush("OrbitAccentSoftBrush", colors.AccentSoft);
        SetSemanticBrush("OrbitSuccessBrush", dark
            ? Windows.UI.Color.FromArgb(255, 111, 218, 164)
            : Windows.UI.Color.FromArgb(255, 22, 120, 74));
        SetSemanticBrush("OrbitWarningBrush", dark
            ? Windows.UI.Color.FromArgb(255, 249, 196, 102)
            : Windows.UI.Color.FromArgb(255, 138, 90, 0));
        SetSemanticBrush("OrbitDangerBrush", dark
            ? Windows.UI.Color.FromArgb(255, 255, 153, 145)
            : Windows.UI.Color.FromArgb(255, 180, 35, 24));
        SetSemanticBrush("OrbitDangerSoftBrush", dark
            ? Windows.UI.Color.FromArgb(255, 68, 35, 39)
            : Windows.UI.Color.FromArgb(255, 253, 235, 233));
        UpdateWindowChromeTheme();
        activeDockerLogWindow?.ApplyTheme(Root.ActualTheme);
        batchCommandWindow?.ApplyTheme(Root.ActualTheme);
        ApplyTerminalAppearanceToAll(terminalAppearance);
    }

    private static ApplicationPaletteColors GetApplicationPaletteColors(string palette, bool dark) =>
        (palette, dark) switch
        {
            ("天空糖果", false) => new(
                Rgb(18, 97, 194), Rgb(226, 239, 252), Rgb(207, 228, 249),
                Rgb(241, 248, 255), Rgb(218, 235, 251), Rgb(147, 185, 222),
                Rgb(244, 250, 255), Rgb(235, 245, 255), Rgb(199, 224, 248),
                Rgb(92, 145, 198), Rgb(229, 242, 253), Rgb(202, 225, 248)),
            ("天空糖果", true) => new(
                Rgb(108, 182, 255), Rgb(10, 22, 31), Rgb(14, 34, 47),
                Rgb(20, 42, 56), Rgb(26, 51, 66), Rgb(49, 81, 101),
                Rgb(24, 47, 61), Rgb(18, 40, 54), Rgb(22, 55, 72),
                Rgb(83, 135, 170), Rgb(25, 50, 65), Rgb(28, 59, 78)),
            ("蜜桃晨光", false) => new(
                Rgb(156, 51, 51), Rgb(252, 231, 219), Rgb(247, 214, 197),
                Rgb(255, 244, 237), Rgb(249, 222, 208), Rgb(214, 164, 141),
                Rgb(255, 246, 240), Rgb(253, 236, 226), Rgb(244, 205, 185),
                Rgb(174, 109, 82), Rgb(250, 229, 218), Rgb(244, 211, 196)),
            ("蜜桃晨光", true) => new(
                Rgb(242, 160, 122), Rgb(27, 19, 16), Rgb(42, 28, 23),
                Rgb(51, 35, 29), Rgb(61, 43, 35), Rgb(100, 67, 54),
                Rgb(55, 37, 30), Rgb(44, 31, 26), Rgb(59, 40, 31),
                Rgb(151, 96, 72), Rgb(54, 37, 30), Rgb(70, 45, 36)),
            ("薰衣草雾", false) => new(
                Rgb(97, 56, 148), Rgb(237, 229, 248), Rgb(224, 211, 243),
                Rgb(249, 244, 254), Rgb(229, 218, 246), Rgb(184, 159, 215),
                Rgb(250, 246, 254), Rgb(242, 234, 251), Rgb(218, 201, 239),
                Rgb(132, 98, 174), Rgb(237, 226, 249), Rgb(220, 204, 242)),
            ("薰衣草雾", true) => new(
                Rgb(180, 154, 235), Rgb(23, 18, 32), Rgb(35, 27, 49),
                Rgb(44, 35, 62), Rgb(53, 43, 73), Rgb(84, 70, 108),
                Rgb(48, 38, 66), Rgb(38, 30, 53), Rgb(51, 38, 72),
                Rgb(128, 104, 165), Rgb(48, 39, 66), Rgb(62, 47, 85)),
            ("冰川薄荷", false) => new(
                Rgb(5, 99, 115), Rgb(224, 241, 244), Rgb(205, 231, 235),
                Rgb(240, 249, 250), Rgb(214, 236, 239), Rgb(143, 190, 197),
                Rgb(243, 250, 251), Rgb(231, 245, 247), Rgb(197, 227, 231),
                Rgb(76, 143, 153), Rgb(223, 240, 243), Rgb(198, 230, 234)),
            ("冰川薄荷", true) => new(
                Rgb(98, 196, 210), Rgb(10, 23, 26), Rgb(15, 37, 42),
                Rgb(22, 47, 53), Rgb(28, 57, 64), Rgb(52, 88, 95),
                Rgb(26, 52, 58), Rgb(19, 43, 48), Rgb(24, 56, 63),
                Rgb(80, 139, 149), Rgb(25, 52, 58), Rgb(30, 67, 74)),
            ("翡翠流光", true) => new(
                Rgb(95, 208, 154), Rgb(11, 24, 18), Rgb(16, 38, 27),
                Rgb(23, 47, 35), Rgb(29, 57, 42), Rgb(53, 91, 69),
                Rgb(27, 52, 39), Rgb(20, 43, 32), Rgb(25, 58, 41),
                Rgb(78, 143, 105), Rgb(26, 53, 39), Rgb(31, 69, 49)),
            _ => new(
                Rgb(8, 102, 77), Rgb(226, 242, 233), Rgb(208, 232, 218),
                Rgb(242, 250, 246), Rgb(217, 238, 225), Rgb(147, 192, 166),
                Rgb(245, 251, 247), Rgb(233, 246, 239), Rgb(201, 230, 213),
                Rgb(79, 147, 111), Rgb(225, 241, 232), Rgb(202, 233, 216)),
        };

    private static Color Rgb(byte red, byte green, byte blue) =>
        Color.FromArgb(255, red, green, blue);

    private void RootActualThemeChanged(FrameworkElement sender, object args)
    {
        ApplyApplicationPalette(terminalAppearance.AppPalette, terminalAppearance.AppTheme);
        UpdateWindowChromeTheme();
        activeDockerLogWindow?.ApplyTheme(Root.ActualTheme);
        batchCommandWindow?.ApplyTheme(Root.ActualTheme);
    }

    private Brush ResourceBrush(string key) =>
        (Brush)Microsoft.UI.Xaml.Application.Current.Resources[key];

    private Style ResourceStyle(string key) =>
        (Style)Microsoft.UI.Xaml.Application.Current.Resources[key];

    private Grid CreateApplicationPalettePreviewGrid(
        string selectedPalette,
        ICollection<RadioButton> buttons)
    {
        var grid = new Grid
        {
            ColumnSpacing = 8,
            RowSpacing = 8,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        for (var index = 0; index < ApplicationPaletteOptions.Length; index++)
        {
            var option = ApplicationPaletteOptions[index];
            var previewDark = Root.ActualTheme == ElementTheme.Dark;
            var preview = GetApplicationPaletteColors(option.Name, previewDark);
            var previewBorder = new Border
            {
                MinHeight = 46,
                Padding = new Thickness(10, 7, 10, 7),
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(preview.FeatureWindow),
                BorderBrush = new SolidColorBrush(preview.FeatureStroke),
                BorderThickness = new Thickness(1),
            };
            var previewContent = new Grid
            {
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                },
                ColumnSpacing = 8,
            };
            var swatches = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 3,
                VerticalAlignment = VerticalAlignment.Center,
            };
            foreach (var swatch in new[] { preview.Workbench, preview.Panel, preview.Accent })
            {
                swatches.Children.Add(new Border
                {
                    Width = 9,
                    Height = 22,
                    CornerRadius = new CornerRadius(3),
                    Background = new SolidColorBrush(swatch),
                    BorderBrush = new SolidColorBrush(preview.Stroke),
                    BorderThickness = new Thickness(1),
                });
            }
            previewContent.Children.Add(swatches);
            var label = new TextBlock
            {
                Text = option.Name,
                Foreground = new SolidColorBrush(previewDark
                    ? Color.FromArgb(255, 244, 247, 252)
                    : Color.FromArgb(255, 23, 32, 51)),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(label, 1);
            previewContent.Children.Add(label);
            previewBorder.Child = previewContent;

            var radioButton = new RadioButton
            {
                GroupName = "OrbitApplicationPalette",
                Tag = option.Name,
                Content = previewBorder,
                IsChecked = option.Name == selectedPalette,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                MinHeight = 50,
            };
            AutomationProperties.SetName(radioButton, $"界面主题：{option.Name}");
            Grid.SetColumn(radioButton, index % 2);
            Grid.SetRow(radioButton, index / 2);
            buttons.Add(radioButton);
            grid.Children.Add(radioButton);
        }

        return grid;
    }

    private static string GetSelectedApplicationPalette(IEnumerable<RadioButton> buttons) =>
        buttons.FirstOrDefault(button => button.IsChecked == true)?.Tag as string ?? "翡翠流光";

    private ContentDialog CreateThemedDialog(
        string title,
        object content,
        string? primaryButtonText = null,
        string closeButtonText = "关闭")
    {
        return new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = title,
            Content = content,
            PrimaryButtonText = primaryButtonText ?? string.Empty,
            CloseButtonText = closeButtonText,
            DefaultButton = string.IsNullOrEmpty(primaryButtonText) ? ContentDialogButton.Close : ContentDialogButton.Primary,
            CornerRadius = (CornerRadius)Microsoft.UI.Xaml.Application.Current.Resources["OrbitDialogCornerRadius"],
        };
    }

    private Grid CreateMonitorTimeScale()
    {
        var range = ViewModel.MonitorTrendRange switch
        {
            "实时（30 秒）" => ("−30 秒", "−15 秒", "现在"),
            "5 分钟" => ("−5 分钟", "−2.5 分钟", "现在"),
            _ => ("−10 分钟", "−5 分钟", "现在"),
        };
        var scale = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        scale.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        scale.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        scale.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var labels = new[] { range.Item1, range.Item2, range.Item3 };
        for (var index = 0; index < labels.Length; index++)
        {
            var label = new TextBlock
            {
                Text = labels[index],
                FontSize = 10,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
                HorizontalAlignment = index switch
                {
                    0 => HorizontalAlignment.Left,
                    1 => HorizontalAlignment.Center,
                    _ => HorizontalAlignment.Right,
                },
            };
            Grid.SetColumn(label, index);
            scale.Children.Add(label);
        }
        return scale;
    }

    private static void SetSemanticBrush(string key, Windows.UI.Color color)
    {
        if (Microsoft.UI.Xaml.Application.Current.Resources[key] is SolidColorBrush brush)
        {
            brush.Color = color;
        }
    }

    private void SaveTerminalAppearance(TerminalAppearanceSettings appearance)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(terminalAppearancePath)!);
            File.WriteAllText(terminalAppearancePath, JsonSerializer.Serialize(appearance));
        }
        catch (IOException)
        {
            // Appearance persistence is optional and must never interrupt a session.
        }
    }

    private MonitorPreferences LoadMonitorPreferences()
    {
        try
        {
            if (!File.Exists(monitorPreferencesPath))
            {
                return MonitorPreferences.Default;
            }

            var saved = JsonSerializer.Deserialize<MonitorPreferences>(File.ReadAllText(monitorPreferencesPath));
            return saved is null ? MonitorPreferences.Default : NormalizeMonitorPreferences(saved);
        }
        catch (IOException)
        {
            return MonitorPreferences.Default;
        }
        catch (JsonException)
        {
            return MonitorPreferences.Default;
        }
    }

    private void ApplyMonitorPreferences(MonitorPreferences preferences)
    {
        ViewModel.IsMonitorAutoRefreshEnabled = preferences.AutoRefreshEnabled;
        ViewModel.MonitorRefreshInterval = $"{preferences.RefreshIntervalSeconds} 秒";
        ViewModel.MonitorTrendRange = preferences.TrendRange;
    }

    private void SaveMonitorPreferences()
    {
        try
        {
            var interval = int.TryParse(
                ViewModel.MonitorRefreshInterval.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(),
                out var parsed)
                ? Math.Clamp(parsed, 1, 10)
                : 1;
            var preferences = NormalizeMonitorPreferences(new MonitorPreferences(
                ViewModel.IsMonitorAutoRefreshEnabled,
                interval,
                ViewModel.MonitorTrendRange));
            Directory.CreateDirectory(Path.GetDirectoryName(monitorPreferencesPath)!);
            File.WriteAllText(monitorPreferencesPath, JsonSerializer.Serialize(preferences));
        }
        catch (IOException)
        {
            // Preferences improve continuity but must never interrupt a session.
        }
    }

    private static MonitorPreferences NormalizeMonitorPreferences(MonitorPreferences preferences)
    {
        var range = preferences.TrendRange is "实时（30 秒）" or "5 分钟" or "10 分钟"
            ? preferences.TrendRange
            : "10 分钟";
        return new MonitorPreferences(
            preferences.AutoRefreshEnabled,
            Math.Clamp(preferences.RefreshIntervalSeconds, 1, 10),
            range);
    }

    private void TerminalSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        TerminalSearchSummary.Text = ActiveTerminalView.UpdateSearchQuery(TerminalSearchBox.Text);
    }

    private void TerminalSearchBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            TerminalSearchSummary.Text = ActiveTerminalView.MoveSearchMatch(previous: false);
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape)
        {
            TerminalSearchPanel.Visibility = Visibility.Collapsed;
            ClearTerminalSearch();
            ActiveTerminalView.FocusTerminal();
            e.Handled = true;
        }
    }

    private void TerminalPreInputBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (TryGetPreInputControlByte(e.Key, out var controlByte))
        {
            e.Handled = true;
            _ = ViewModel.WriteTerminalInputAsync(new byte[] { controlByte }, CancellationToken.None);
            return;
        }

        if (e.Key == VirtualKey.Up && ViewModel.PreviousCommandHistoryCommand.CanExecute(null))
        {
            ViewModel.PreviousCommandHistoryCommand.Execute(null);
            TerminalPreInputBox.SelectionStart = TerminalPreInputBox.Text.Length;
            e.Handled = true;
            return;
        }

        if (e.Key == VirtualKey.Down && ViewModel.NextCommandHistoryCommand.CanExecute(null))
        {
            ViewModel.NextCommandHistoryCommand.Execute(null);
            TerminalPreInputBox.SelectionStart = TerminalPreInputBox.Text.Length;
            e.Handled = true;
            return;
        }

        if (e.Key == VirtualKey.Escape)
        {
            ActiveTerminalView.FocusTerminal();
            e.Handled = true;
            return;
        }

        if (e.Key != VirtualKey.Enter || !ViewModel.SendCommand.CanExecute(null))
        {
            return;
        }

        e.Handled = true;
        ViewModel.SendCommand.Execute(null);
    }

    private bool TryGetPreInputControlByte(VirtualKey key, out byte controlByte)
    {
        controlByte = 0;
        var controlDown =
            (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0;
        if (!controlDown || key is < VirtualKey.A or > VirtualKey.Z)
        {
            return false;
        }

        var shiftDown =
            (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
        if (!shiftDown)
        {
            // Preserve normal TextBox editing shortcuts whenever they have a
            // meaningful local target. An empty pre-input forwards Ctrl+A-Z
            // directly to the active PTY, matching the terminal surface.
            if (key == VirtualKey.V ||
                (key is VirtualKey.C or VirtualKey.X && TerminalPreInputBox.SelectionLength > 0) ||
                (key is VirtualKey.A or VirtualKey.Y or VirtualKey.Z && TerminalPreInputBox.Text.Length > 0))
            {
                return false;
            }
        }

        controlByte = (byte)(key - VirtualKey.A + 1);
        return true;
    }

    private void PreviousTerminalSearchClick(object sender, RoutedEventArgs e) =>
        TerminalSearchSummary.Text = ActiveTerminalView.MoveSearchMatch(previous: true);

    private void NextTerminalSearchClick(object sender, RoutedEventArgs e) =>
        TerminalSearchSummary.Text = ActiveTerminalView.MoveSearchMatch(previous: false);

    private void CloseTerminalSearchClick(object sender, RoutedEventArgs e)
    {
        TerminalSearchPanel.Visibility = Visibility.Collapsed;
        ClearTerminalSearch();
        ActiveTerminalView.FocusTerminal();
    }

    private void ClearTerminalSearch()
    {
        if (TerminalSearchBox.Text.Length != 0)
        {
            TerminalSearchBox.Text = string.Empty;
        }

        TerminalSearchSummary.Text = ActiveTerminalView.UpdateSearchQuery(string.Empty);
    }

    private async void TerminalResizeTimerTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (!ViewModel.IsTerminalOpen)
        {
            return;
        }

        var columns = (uint)Math.Clamp(
            (int)Math.Floor((pendingTerminalViewportWidth - TerminalHorizontalPadding) / TerminalCellWidth),
            20,
            500);
        var rows = (uint)Math.Clamp(
            (int)Math.Floor((pendingTerminalViewportHeight - TerminalVerticalPadding) / TerminalCellHeight),
            4,
            300);
        await ViewModel.ResizeTerminalAsync(new TerminalSize(columns, rows), CancellationToken.None);
    }

    private IntPtr WindowSubclass(
        IntPtr hWnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        IntPtr referenceData)
    {
        if (message == WindowMessageGetMinMaxInfo)
        {
            var minMaxInfo = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            var dpiScale = GetDpiScale(hWnd);
            minMaxInfo.MinimumTrackingSize = new NativePoint(
                (int)Math.Ceiling(MinimumWindowWidth * dpiScale),
                (int)Math.Ceiling(MinimumWindowHeight * dpiScale));
            Marshal.StructureToPtr(minMaxInfo, lParam, false);
        }
        else if (message == WindowMessageDpiChanged)
        {
            // Keep the PTY geometry correct when the window moves between
            // 100%, 150%, and 200% DPI displays.
            DispatcherQueue.TryEnqueue(QueueTerminalResizeAfterDpiChange);
        }

        return DefSubclassProc(hWnd, message, wParam, lParam);
    }

    private void ApplyResponsivePaneRules(double availableWidth)
    {
        if (isTerminalFullscreen)
        {
            return;
        }

        if (assetSidebarFollowsWindow)
        {
            assetSidebarExpandedWidth = Math.Clamp(
                availableWidth * AssetSidebarWindowRatio,
                MinimumAssetSidebarWidth,
                MaximumAssetSidebarWidth);
            if (AssetSidebar.Visibility == Visibility.Visible)
            {
                AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
            }
        }

        if (toolInspectorFollowsWindow)
        {
            toolInspectorExpandedWidth = Math.Clamp(
                availableWidth * ToolInspectorWindowRatio,
                MinimumToolInspectorWidth,
                MaximumToolInspectorWidth);
            if (ToolInspector.Visibility == Visibility.Visible)
            {
                ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
            }
        }

        if (availableWidth < 1180 && ToolInspector.Visibility == Visibility.Visible)
        {
            toolInspectorExpandedWidth = Math.Clamp(
                ToolInspectorColumn.ActualWidth,
                MinimumToolInspectorWidth,
                MaximumToolInspectorWidth);
            ToolInspector.Visibility = Visibility.Collapsed;
            ToolInspectorColumn.Width = new GridLength(CollapsedPaneWidth);
            toolInspectorAutomaticallyCollapsed = true;
        }
        else if (availableWidth >= 1180 && toolInspectorAutomaticallyCollapsed)
        {
            ToolInspector.Visibility = Visibility.Visible;
            ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
            toolInspectorAutomaticallyCollapsed = false;
        }

        if (availableWidth < 980 && AssetSidebar.Visibility == Visibility.Visible)
        {
            assetSidebarExpandedWidth = Math.Clamp(
                AssetSidebarColumn.ActualWidth,
                MinimumAssetSidebarWidth,
                MaximumAssetSidebarWidth);
            AssetSidebar.Visibility = Visibility.Collapsed;
            AssetSidebarColumn.Width = new GridLength(CollapsedPaneWidth);
            assetSidebarAutomaticallyCollapsed = true;
            UpdateAssetSidebarVisualState();
        }
        else if (availableWidth >= 980 && assetSidebarAutomaticallyCollapsed)
        {
            AssetSidebar.Visibility = Visibility.Visible;
            AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
            assetSidebarAutomaticallyCollapsed = false;
            UpdateAssetSidebarVisualState();
        }

        UpdateToolInspectorVisualState();
        ConstrainVisiblePaneWidths(availableWidth);
    }

    private void ProtectTerminalWorkspace(PanePreference preferredPane)
    {
        var availableWidth = Root.ActualWidth;
        if (availableWidth <= 0)
        {
            return;
        }

        var terminalWidth = availableWidth - GetVisiblePaneWidth(AssetSidebar, AssetSidebarColumn)
            - GetVisiblePaneWidth(ToolInspector, ToolInspectorColumn);
        if (terminalWidth >= MinimumTerminalWorkspaceWidth)
        {
            ConstrainVisiblePaneWidths(availableWidth);
            return;
        }

        // A manually opened pane takes priority. Collapse the opposite pane
        // instead of allowing either inspector to cover the terminal surface.
        if (preferredPane == PanePreference.ToolInspector && AssetSidebar.Visibility == Visibility.Visible)
        {
            assetSidebarExpandedWidth = Math.Clamp(
                GetVisiblePaneWidth(AssetSidebar, AssetSidebarColumn),
                MinimumAssetSidebarWidth,
                MaximumAssetSidebarWidth);
            AssetSidebar.Visibility = Visibility.Collapsed;
            AssetSidebarColumn.Width = new GridLength(CollapsedPaneWidth);
            assetSidebarAutomaticallyCollapsed = true;
        }
        else if (ToolInspector.Visibility == Visibility.Visible)
        {
            toolInspectorExpandedWidth = Math.Clamp(
                GetVisiblePaneWidth(ToolInspector, ToolInspectorColumn),
                MinimumToolInspectorWidth,
                MaximumToolInspectorWidth);
            ToolInspector.Visibility = Visibility.Collapsed;
            ToolInspectorColumn.Width = new GridLength(CollapsedPaneWidth);
            toolInspectorAutomaticallyCollapsed = true;
        }

        ConstrainVisiblePaneWidths(availableWidth);
        UpdateAssetSidebarVisualState();
        UpdateToolInspectorVisualState();
        DispatcherQueue.TryEnqueue(QueueTerminalResizeAfterDpiChange);
    }

    private void ConstrainVisiblePaneWidths(double availableWidth)
    {
        if (availableWidth <= 0)
        {
            return;
        }

        if (AssetSidebar.Visibility == Visibility.Visible)
        {
            var otherWidth = GetVisiblePaneWidth(ToolInspector, ToolInspectorColumn);
            var maximum = Math.Min(
                MaximumAssetSidebarWidth,
                availableWidth - otherWidth - MinimumTerminalWorkspaceWidth);
            if (maximum >= MinimumAssetSidebarWidth)
            {
                assetSidebarExpandedWidth = Math.Clamp(
                    GetVisiblePaneWidth(AssetSidebar, AssetSidebarColumn),
                    MinimumAssetSidebarWidth,
                    maximum);
                AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
            }
        }

        if (ToolInspector.Visibility == Visibility.Visible)
        {
            var otherWidth = GetVisiblePaneWidth(AssetSidebar, AssetSidebarColumn);
            var maximum = Math.Min(
                MaximumToolInspectorWidth,
                availableWidth - otherWidth - MinimumTerminalWorkspaceWidth);
            if (maximum >= MinimumToolInspectorWidth)
            {
                toolInspectorExpandedWidth = Math.Clamp(
                    GetVisiblePaneWidth(ToolInspector, ToolInspectorColumn),
                    MinimumToolInspectorWidth,
                    maximum);
                ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
            }
        }
    }

    private static double GetVisiblePaneWidth(FrameworkElement pane, ColumnDefinition column)
    {
        if (pane.Visibility != Visibility.Visible)
        {
            return 0;
        }

        return column.Width.IsAbsolute && column.Width.Value > 0
            ? column.Width.Value
            : column.ActualWidth;
    }

    private void CloseWorkspaceTabClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: WorkspaceTabViewModel tab })
        {
            return;
        }

        ViewModel.SelectedWorkspaceTab = tab;
        var command = tab.IsConnected || tab.HasHostKeyChallenge || tab.TerminalLease is not null || tab.SftpLease is not null
            ? ViewModel.DisconnectAndCloseWorkspaceTabCommand
            : ViewModel.CloseWorkspaceTabCommand;

        if (command.CanExecute(null))
        {
            command.Execute(null);
        }
    }

    private async void WorkspaceTabContextDisconnectClick(object sender, RoutedEventArgs e)
    {
        if (!SelectContextWorkspaceTab(sender))
        {
            return;
        }

        await ViewModel.DisconnectSelectedWorkspaceAsync(CancellationToken.None);
    }

    private async void WorkspaceTabContextReconnectClick(object sender, RoutedEventArgs e)
    {
        if (!SelectContextWorkspaceTab(sender))
        {
            return;
        }

        if (ViewModel.SelectedAsset is { Transport: ServerTransport.Telnet } telnetAsset)
        {
            await ConnectAssetWithPolicyAsync(telnetAsset);
        }
        else
        {
            await ViewModel.ReconnectSelectedWorkspaceAsync(CancellationToken.None);
        }
    }

    private bool SelectContextWorkspaceTab(object sender)
    {
        if (sender is FrameworkElement { Tag: WorkspaceTabViewModel tab })
        {
            ViewModel.SelectedWorkspaceTab = tab;
            return true;
        }

        return false;
    }

    private void PaneSplitterDragCompleted(object sender, DragCompletedEventArgs e)
    {
        if (AssetSidebar.Visibility == Visibility.Visible)
        {
            assetSidebarExpandedWidth = Math.Clamp(
                AssetSidebarColumn.ActualWidth,
                MinimumAssetSidebarWidth,
                MaximumAssetSidebarWidth);
        }

        if (ToolInspector.Visibility == Visibility.Visible)
        {
            toolInspectorExpandedWidth = Math.Clamp(
                ToolInspectorColumn.ActualWidth,
                MinimumToolInspectorWidth,
                MaximumToolInspectorWidth);
        }

        ConstrainVisiblePaneWidths(Root.ActualWidth);
        DispatcherQueue.TryEnqueue(QueueTerminalResizeAfterDpiChange);
        PersistPaneLayout();
    }

    private void AssetSidebarSplitterDragDelta(object sender, DragDeltaEventArgs e)
    {
        if (AssetSidebar.Visibility != Visibility.Visible) return;
        assetSidebarFollowsWindow = false;
        var toolWidth = GetVisiblePaneWidth(ToolInspector, ToolInspectorColumn);
        var maximum = Math.Max(
            MinimumAssetSidebarWidth,
            Math.Min(MaximumAssetSidebarWidth, Root.ActualWidth - toolWidth - MinimumTerminalWorkspaceWidth));
        assetSidebarExpandedWidth = Math.Clamp(
            AssetSidebarColumn.ActualWidth + e.HorizontalChange,
            MinimumAssetSidebarWidth,
            maximum);
        AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
    }

    private void ToolInspectorSplitterDragDelta(object sender, DragDeltaEventArgs e)
    {
        if (ToolInspector.Visibility != Visibility.Visible) return;
        toolInspectorFollowsWindow = false;
        var assetWidth = GetVisiblePaneWidth(AssetSidebar, AssetSidebarColumn);
        var maximum = Math.Max(
            MinimumToolInspectorWidth,
            Math.Min(MaximumToolInspectorWidth, Root.ActualWidth - assetWidth - MinimumTerminalWorkspaceWidth));
        toolInspectorExpandedWidth = Math.Clamp(
            ToolInspectorColumn.ActualWidth - e.HorizontalChange,
            MinimumToolInspectorWidth,
            maximum);
        ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
    }

    private void TogglePane(FrameworkElement pane, ColumnDefinition column, double minimumWidth, double maximumWidth, ref double expandedWidth)
    {
        var show = pane.Visibility != Visibility.Visible;
        if (!show)
        {
            expandedWidth = Math.Clamp(column.ActualWidth, minimumWidth, maximumWidth);
        }

        pane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        column.Width = new GridLength(show ? expandedWidth : CollapsedPaneWidth);
        PersistPaneLayout();
    }

    private void RestorePaneLayout()
    {
        try
        {
            if (!File.Exists(layoutStatePath))
            {
                ApplyDefaultPaneLayout();
                return;
            }
            var state = JsonSerializer.Deserialize<PaneLayoutState>(File.ReadAllText(layoutStatePath));
            if (state is null)
            {
                ApplyDefaultPaneLayout();
                return;
            }
            assetSidebarExpandedWidth = Math.Clamp(
                state.AssetSidebarWidth,
                MinimumAssetSidebarWidth,
                MaximumAssetSidebarWidth);
            toolInspectorExpandedWidth = Math.Clamp(
                state.ToolInspectorWidth,
                MinimumToolInspectorWidth,
                MaximumToolInspectorWidth);
            assetSidebarFollowsWindow = Math.Abs(state.AssetSidebarWidth - DefaultAssetSidebarWidth) < 0.5;
            toolInspectorFollowsWindow = Math.Abs(state.ToolInspectorWidth - DefaultToolInspectorWidth) < 0.5;
            terminalSplitTopRatio = Math.Clamp(
                state.TerminalSplitTopRatio ?? 0.5,
                MinimumTerminalSplitRatio,
                MaximumTerminalSplitRatio);
            terminalSplitLeftRatio = Math.Clamp(
                state.TerminalSplitLeftRatio ?? 0.5,
                MinimumTerminalSplitRatio,
                MaximumTerminalSplitRatio);
            restoredWindowWidth = Math.Max(
                MinimumWindowWidth,
                state.WindowWidth ?? DefaultWindowWidth);
            restoredWindowHeight = Math.Max(
                MinimumWindowHeight,
                state.WindowHeight ?? DefaultWindowHeight);
            restoreWindowMaximized = state.WindowMaximized ?? false;
            // Restore the user's explicit pane choices. A saved collapsed state
            // must not be silently replaced by the application's first-launch
            // defaults on every restart.
            AssetSidebar.Visibility = state.AssetSidebarVisible
                ? Visibility.Visible
                : Visibility.Collapsed;
            ToolInspector.Visibility = state.ToolInspectorVisible
                ? Visibility.Visible
                : Visibility.Collapsed;
            AssetSidebarColumn.Width = new GridLength(
                state.AssetSidebarVisible ? assetSidebarExpandedWidth : CollapsedPaneWidth);
            ToolInspectorColumn.Width = new GridLength(
                state.ToolInspectorVisible ? toolInspectorExpandedWidth : CollapsedPaneWidth);
            UpdateAssetSidebarVisualState();
            UpdateToolInspectorVisualState();
        }
        catch (IOException) { ApplyDefaultPaneLayout(); }
        catch (JsonException) { ApplyDefaultPaneLayout(); }
    }

    private void ApplyDefaultPaneLayout()
    {
        // Match the desktop information architecture: keep the terminal wide
        // on first launch while leaving session tools immediately available.
        assetSidebarFollowsWindow = true;
        toolInspectorFollowsWindow = true;
        AssetSidebar.Visibility = Visibility.Visible;
        AssetSidebarColumn.Width = new GridLength(assetSidebarExpandedWidth);
        ToolInspector.Visibility = Visibility.Visible;
        ToolInspectorColumn.Width = new GridLength(toolInspectorExpandedWidth);
        UpdateAssetSidebarVisualState();
        UpdateToolInspectorVisualState();
    }

    private void PersistPaneLayout()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(layoutStatePath)!);
            var state = new PaneLayoutState(
                AssetSidebar.Visibility == Visibility.Visible,
                assetSidebarExpandedWidth,
                ToolInspector.Visibility == Visibility.Visible,
                toolInspectorExpandedWidth,
                terminalSplitTopRatio,
                terminalSplitLeftRatio,
                restoredWindowWidth,
                restoredWindowHeight,
                AppWindow.Presenter is OverlappedPresenter
                {
                    State: OverlappedPresenterState.Maximized,
                });
            File.WriteAllText(layoutStatePath, JsonSerializer.Serialize(state));
        }
        catch (IOException) { }
    }

    private void UpdateAssetSidebarVisualState()
    {
        var expanded = AssetSidebar.Visibility == Visibility.Visible;
        AssetSidebarRail.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        AssetSidebarSplitter.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        SynchronizationStatusFooter.Width = double.NaN;
        SynchronizationStatusFooter.HorizontalAlignment = HorizontalAlignment.Stretch;
    }

    private void UpdateToolInspectorVisualState()
    {
        var expanded = ToolInspector.Visibility == Visibility.Visible;
        ToolInspectorRail.Visibility = expanded
            ? Visibility.Collapsed
            : Visibility.Visible;
        ToolInspectorSplitter.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ConfigureWindowChrome()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMaximizable = true;
            presenter.IsMinimizable = true;
        }
        // Use a real Windows title bar: the app owns the left drag surface while
        // Windows continues to own minimize, maximize, close, snapping and system menus.
        ExtendsContentIntoTitleBar = true;
        // Keep every command button in the normal client area. Only the
        // deliberately empty surface participates in title-bar dragging.
        SetTitleBar(TitleBarDragRegion);

        // Merge the native caption buttons with the workstation background instead
        // of rendering an extra, visually disconnected title strip.
        UpdateWindowChromeTheme();
    }

    private async void MainAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        PersistPaneLayout();
        if (allowApplicationClose ||
            (!ViewModel.HasActiveSftpTransfers && !ViewModel.HasActiveBatchContinuousSessions))
        {
            return;
        }

        args.Cancel = true;
        if (isExitConfirmationOpen)
        {
            return;
        }

        isExitConfirmationOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = ViewModel.HasActiveBatchContinuousSessions
                    ? "持续任务仍在进行"
                    : "传输任务仍在进行",
                Content = new TextBlock
                {
                    Text = ViewModel.HasActiveBatchContinuousSessions && ViewModel.HasActiveSftpTransfers
                        ? "关闭应用会停止文件传输与所有批量持续任务，并关闭持续任务的独立终端通道。是否停止任务并退出？"
                        : ViewModel.HasActiveBatchContinuousSessions
                            ? "关闭应用会停止所有批量持续任务并关闭其独立终端通道。是否停止任务并退出？"
                            : ViewModel.SftpExitProtectionMessage,
                    TextWrapping = TextWrapping.Wrap,
                    MaxWidth = 460,
                },
                PrimaryButtonText = "停止任务并退出",
                CloseButtonText = "继续运行",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            if (ViewModel.HasActiveSftpTransfers)
            {
                await ViewModel.StopSftpTransfersForApplicationExitAsync(CancellationToken.None);
            }
            if (ViewModel.HasActiveBatchContinuousSessions)
            {
                await ViewModel.StopAllBatchContinuousSessionsForApplicationExitAsync();
            }
            allowApplicationClose = true;
            Close();
        }
        catch (COMException)
        {
            // WinUI only allows one ContentDialog per XamlRoot. Keep the window
            // open if another modal dialog is active; the next close request can
            // show the transfer warning after that dialog is dismissed.
        }
        finally
        {
            isExitConfirmationOpen = false;
        }
    }

    private void UpdateWindowChromeTheme()
    {
        if (AppWindow?.TitleBar is not { } titleBar)
        {
            return;
        }
        var dark = Root.ActualTheme == ElementTheme.Dark || terminalAppearance.AppTheme == "深色";
        var background = Microsoft.UI.Xaml.Application.Current.Resources["OrbitWorkbenchBrush"] is SolidColorBrush surface
            ? surface.Color
            : (dark ? Color.FromArgb(255, 17, 23, 34) : Color.FromArgb(255, 243, 247, 255));
        var foreground = Microsoft.UI.Xaml.Application.Current.Resources["OrbitPrimaryTextBrush"] is SolidColorBrush primary
            ? primary.Color
            : (dark ? Color.FromArgb(255, 244, 247, 252) : Color.FromArgb(255, 23, 32, 51));
        var inactive = Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"] is SolidColorBrush muted
            ? muted.Color
            : (dark ? Color.FromArgb(255, 167, 178, 194) : Color.FromArgb(255, 91, 102, 117));
        var hover = Microsoft.UI.Xaml.Application.Current.Resources["OrbitAccentSoftBrush"] is SolidColorBrush accentSoft
            ? accentSoft.Color
            : (dark ? Color.FromArgb(255, 53, 64, 82) : Color.FromArgb(255, 221, 230, 243));
        var pressed = Microsoft.UI.Xaml.Application.Current.Resources["OrbitPanelStrokeBrush"] is SolidColorBrush stroke
            ? stroke.Color
            : (dark ? Color.FromArgb(255, 68, 80, 99) : Color.FromArgb(255, 204, 216, 232));
        titleBar.BackgroundColor = background;
        titleBar.InactiveBackgroundColor = background;
        titleBar.ForegroundColor = foreground;
        titleBar.InactiveForegroundColor = inactive;
        titleBar.ButtonBackgroundColor = background;
        titleBar.ButtonInactiveBackgroundColor = background;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = inactive;
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedBackgroundColor = pressed;
        titleBar.ButtonPressedForegroundColor = foreground;
        NativeWindowCornerService.ApplyVisibleFrameTheme(this, dark);
    }

    private sealed record PaneLayoutState(
        bool AssetSidebarVisible,
        double AssetSidebarWidth,
        bool ToolInspectorVisible,
        double ToolInspectorWidth,
        double? TerminalSplitTopRatio = null,
        double? TerminalSplitLeftRatio = null,
        double? WindowWidth = null,
        double? WindowHeight = null,
        bool? WindowMaximized = null);

    private enum PanePreference
    {
        None,
        AssetSidebar,
        ToolInspector,
    }
    private sealed record MonitorPreferences(bool AutoRefreshEnabled, int RefreshIntervalSeconds, string TrendRange)
    {
        public static MonitorPreferences Default { get; } = new(true, 1, "10 分钟");
    }

    private void ViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainWindowViewModel.IsTerminalOpen))
        {
            UpdateTerminalEmptyState();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.IsConnecting))
        {
            ConnectionProgressOverlay.Visibility = ViewModel.IsConnecting
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        if (e.PropertyName == nameof(MainWindowViewModel.ActivitySummary))
        {
            RequestTerminalScrollToEnd();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.IsAutoScrollEnabled) &&
            ViewModel.IsAutoScrollEnabled)
        {
            NativeTerminalView.ScrollToLatestOutput();
        }
        else if (e.PropertyName == nameof(MainWindowViewModel.IsAutoScrollEnabled))
        {
            NativeTerminalView.PauseFollowingLatestOutput();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.HasAssetSearchResults))
        {
            UpdateAssetEmptyState();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.SelectedWorkspaceTab))
        {
            activeDockerLogWindow?.StopAndClose();
            RebuildTerminalSplitLayout();
            SetActiveTerminalSurface(NativeTerminalView, null);
            RestoreTerminalScrollPosition();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.TerminalSplitPanes))
        {
            RebuildTerminalSplitLayout();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.TerminalSplitOutputVersion))
        {
            DispatcherQueue.TryEnqueue(ScrollTerminalSplitSurfacesToEnd);
        }

        if (e.PropertyName == nameof(MainWindowViewModel.IsAccountLocked))
        {
            TryPromptForStartupUnlock();
        }

        if (e.PropertyName is nameof(MainWindowViewModel.IsConnected) or
            nameof(MainWindowViewModel.IsMonitorAutoRefreshEnabled))
        {
            if (e.PropertyName == nameof(MainWindowViewModel.IsConnected) && !ViewModel.IsConnected)
            {
                activeDockerLogWindow?.StopAndClose();
            }
            if (e.PropertyName == nameof(MainWindowViewModel.IsConnected))
            {
                UpdateToolInspectorSessionState();
            }
            UpdateMonitorRefreshTimer();
            UpdateDockerRefreshTimer();
        }

        if (e.PropertyName is nameof(MainWindowViewModel.IsMonitorAutoRefreshEnabled) or
            nameof(MainWindowViewModel.MonitorRefreshInterval) or
            nameof(MainWindowViewModel.MonitorTrendRange))
        {
            SaveMonitorPreferences();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.HasHostKeyChallenge) &&
            ViewModel.HasHostKeyChallenge)
        {
            _ = ShowHostKeyTrustDialogAsync();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.HasSftpFeedback))
        {
            UpdateSftpFeedbackVisual();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.IsSftpFeedbackFadingOut) &&
            ViewModel.HasSftpFeedback)
        {
            AnimateFeedbackOpacity(SftpFeedbackLayer, ViewModel.IsSftpFeedbackFadingOut ? 0 : 1);
        }

        if (e.PropertyName == nameof(MainWindowViewModel.HasDockerFeedback))
        {
            UpdateDockerFeedbackVisual();
        }

        if (e.PropertyName == nameof(MainWindowViewModel.IsDockerFeedbackFadingOut) &&
            ViewModel.HasDockerFeedback)
        {
            AnimateFeedbackOpacity(DockerFeedbackLayer, ViewModel.IsDockerFeedbackFadingOut ? 0 : 1);
        }
    }

    private void UpdateToolInspectorSessionState()
    {
        ConnectedToolInspectorContent.Visibility = ViewModel.IsConnected
            ? Visibility.Visible
            : Visibility.Collapsed;
        DisconnectedToolInspectorContent.Visibility = ViewModel.IsConnected
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void UpdateSftpFeedbackVisual()
    {
        if (ViewModel.HasSftpFeedback)
        {
            SftpRecentOperationsButton.Visibility = Visibility.Collapsed;
            SftpFeedbackHost.Visibility = Visibility.Visible;
            SftpFeedbackLayer.Visibility = Visibility.Visible;
            AnimateFeedbackOpacity(SftpFeedbackLayer, ViewModel.IsSftpFeedbackFadingOut ? 0 : 1);
            return;
        }

        SftpFeedbackLayer.Opacity = 0;
        SftpFeedbackLayer.Visibility = Visibility.Collapsed;
        SftpFeedbackHost.Visibility = Visibility.Collapsed;
        // Recent operations live under the SFTP “更多” menu so the frozen
        // toolbar remains compact at every inspector width.
        SftpRecentOperationsButton.Visibility = Visibility.Collapsed;
    }

    private void UpdateDockerFeedbackVisual()
    {
        if (ViewModel.HasDockerFeedback)
        {
            DockerRecentOperationsButton.Visibility = Visibility.Collapsed;
            DockerFeedbackLayer.Visibility = Visibility.Visible;
            AnimateFeedbackOpacity(DockerFeedbackLayer, ViewModel.IsDockerFeedbackFadingOut ? 0 : 1);
            return;
        }

        DockerFeedbackLayer.Opacity = 0;
        DockerFeedbackLayer.Visibility = Visibility.Collapsed;
        DockerRecentOperationsButton.Visibility = Visibility.Visible;
    }

    private static void AnimateFeedbackOpacity(FrameworkElement target, double targetOpacity)
    {
        var animation = new DoubleAnimation
        {
            To = targetOpacity,
            Duration = new Duration(TimeSpan.FromMilliseconds(targetOpacity > 0 ? 150 : 180)),
            EnableDependentAnimation = true,
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }

    private async Task ShowHostKeyTrustDialogAsync()
    {
        if (isHostKeyDialogOpen || !ViewModel.HasHostKeyChallenge)
        {
            return;
        }

        isHostKeyDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "确认服务器主机密钥",
                Content = new TextBlock
                {
                    Text = string.Concat(
                        "这是首次连接此服务器，或服务器主机密钥发生了变化。请仅在已通过独立渠道核对指纹后继续。\n\n",
                        ViewModel.HostKeySummary,
                        "\n\n确认后，OrbitTerm 会仅为此主机保存该密钥，并继续当前连接。"),
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = "确认并信任",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };

            if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
                ViewModel.TrustHostKeyCommand.CanExecute(null))
            {
                ViewModel.TrustHostKeyCommand.Execute(null);
            }
        }
        finally
        {
            isHostKeyDialogOpen = false;
        }
    }

    private void CopyTerminalOutputClick(object sender, RoutedEventArgs e)
    {
        var transcript = ViewModel.PrepareTerminalTranscriptCopy();
        if (transcript.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(transcript);
        Clipboard.SetContent(package);
    }

    private void CopySftpPreviewClick(object sender, RoutedEventArgs e)
    {
        var preview = ViewModel.PrepareSftpPreviewCopy();
        if (preview.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(preview);
        Clipboard.SetContent(package);
    }

    private async void SaveSftpPreviewClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.CanSaveSftpPreview)
        {
            await ViewModel.SaveSftpPreviewAsync(CancellationToken.None);
        }
    }

    private void RevertSftpPreviewClick(object sender, RoutedEventArgs e)
    {
        ViewModel.RevertSftpPreviewChanges();
    }

    private async void DownloadSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanDownloadSelectedSftpEntries)
        {
            return;
        }

        string? destinationPath;
        try
        {
            var picker = new FolderPicker
            {
                SuggestedStartLocation = PickerLocationId.Downloads,
            };
            // The WinRT folder picker requires at least one filter even though
            // folders themselves do not have a file extension.
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, GetPickerOwnerWindowHandle());
            var folder = await picker.PickSingleFolderAsync();
            destinationPath = folder?.Path;
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            try
            {
                destinationPath = PickDownloadFolderWithDesktopDialog();
            }
            catch (Exception fallbackException)
            {
                await ShowSftpPickerFailureAsync("下载", fallbackException);
                return;
            }
        }

        if (!string.IsNullOrWhiteSpace(destinationPath))
        {
            await ViewModel.DownloadSelectedSftpEntriesAsync(destinationPath, CancellationToken.None);
        }
    }

    private async void UploadSftpFileClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        try
        {
            var picker = new FileOpenPicker
            {
                SuggestedStartLocation = PickerLocationId.Downloads,
            };
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, GetPickerOwnerWindowHandle());
            var files = await picker.PickMultipleFilesAsync();
            await UploadSftpStorageFilesAsync(files.OfType<StorageFile>().ToList());
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            try
            {
                await UploadSftpLocalPathsAsync(PickUploadFilesWithDesktopDialog());
            }
            catch (Exception fallbackException)
            {
                await ShowSftpPickerFailureAsync("上传", fallbackException);
            }
        }
    }

    private string? PickDownloadFolderWithDesktopDialog()
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择 SFTP 文件的本机保存位置",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ShowNewFolderButton = true,
            UseDescriptionForTitle = true,
        };
        var result = dialog.ShowDialog(new PickerWindowOwner(GetPickerOwnerWindowHandle()));
        return result == System.Windows.Forms.DialogResult.OK ? dialog.SelectedPath : null;
    }

    private IReadOnlyList<string> PickUploadFilesWithDesktopDialog()
    {
        using var dialog = new System.Windows.Forms.OpenFileDialog
        {
            CheckFileExists = true,
            Filter = "所有文件 (*.*)|*.*",
            Multiselect = true,
            RestoreDirectory = true,
            Title = "选择要上传到当前 SFTP 目录的文件",
        };
        var result = dialog.ShowDialog(new PickerWindowOwner(GetPickerOwnerWindowHandle()));
        return result == System.Windows.Forms.DialogResult.OK ? dialog.FileNames : [];
    }

    private IntPtr GetPickerOwnerWindowHandle()
    {
        var handle = WindowNative.GetWindowHandle(this);
        if (handle == IntPtr.Zero)
        {
            throw new InvalidOperationException("The main window is not ready for a file picker.");
        }

        return handle;
    }

    private Task ShowSftpPickerFailureAsync(string operation, Exception exception)
    {
        var elevatedPickerFailure = exception is COMException
        {
            HResult: unchecked((int)0x80004005),
        };
        var guidance = elevatedPickerFailure
            ? "Windows 未能打开系统文件选择器。请确认 OrbitTerm 未以管理员身份运行，然后重新打开客户端再试。"
            : "Windows 未能打开系统文件选择器。请确认当前账户可以访问本机文件，并重新尝试。";
        return ShowAccountMessageAsync(string.Concat(operation, "未开始"), guidance);
    }

    private sealed class PickerWindowOwner(IntPtr handle) : System.Windows.Forms.IWin32Window
    {
        public IntPtr Handle { get; } = handle;
    }

    private void SftpUploadDragOver(object sender, DragEventArgs e)
    {
        if (!ViewModel.IsSftpOpen || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }

        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = string.Concat("上传到 ", ViewModel.SftpPathText);
        e.DragUIOverride.IsCaptionVisible = true;
        e.DragUIOverride.IsContentVisible = true;
    }

    private async void SftpUploadDrop(object sender, DragEventArgs e)
    {
        if (!ViewModel.IsSftpOpen || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }

        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            await UploadSftpStorageFilesAsync(items.OfType<StorageFile>().Take(100).ToList());
        }
        catch (Exception)
        {
            await ShowAccountMessageAsync("拖拽上传失败", "无法读取拖入的文件。请确认文件仍存在且当前账户具有读取权限。");
        }
    }

    private async Task UploadSftpStorageFilesAsync(IReadOnlyList<StorageFile> files)
    {
        if (!ViewModel.IsSftpOpen || files.Count == 0)
        {
            return;
        }

        var sources = new List<SftpUploadSource>(files.Count);
        foreach (var file in files.Take(100))
        {
            var properties = await file.GetBasicPropertiesAsync();
            sources.Add(new SftpUploadSource(file.Path, file.Name, properties.Size));
        }

        await UploadSftpSourcesAsync(sources);
    }

    private async Task UploadSftpLocalPathsAsync(IReadOnlyList<string> paths)
    {
        if (!ViewModel.IsSftpOpen || paths.Count == 0)
        {
            return;
        }

        var sources = paths
            .Take(100)
            .Select(path => new FileInfo(path))
            .Where(file => file.Exists)
            .Select(file => new SftpUploadSource(file.FullName, file.Name, (ulong)file.Length))
            .ToList();
        await UploadSftpSourcesAsync(sources);
    }

    private async Task UploadSftpSourcesAsync(IReadOnlyList<SftpUploadSource> sources)
    {
        if (sources.Count == 0)
        {
            return;
        }

        var conflicts = ViewModel.GetSftpUploadConflictNames(sources);
        var policy = conflicts.Count == 0
            ? SftpUploadConflictPolicy.Skip
            : await ChooseSftpUploadConflictPolicyAsync(conflicts);
        if (policy is null)
        {
            return;
        }

        await ViewModel.UploadSftpFilesAsync(sources, policy.Value, CancellationToken.None);
    }

    private async Task<SftpUploadConflictPolicy?> ChooseSftpUploadConflictPolicyAsync(IReadOnlyList<string> conflicts)
    {
        if (isSftpDialogOpen)
        {
            return null;
        }

        isSftpDialogOpen = true;
        try
        {
            var policyPicker = new ComboBox
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                SelectedIndex = 0,
                ItemsSource = new[]
                {
                    "跳过同名项目（推荐）",
                    "保留两者并自动重命名",
                    "安全替换远程文件",
                },
            };
            var content = new StackPanel { Spacing = 10 };
            content.Children.Add(new TextBlock
            {
                Text = string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"发现 {conflicts.Count} 个同名项目：{string.Join("、", conflicts.Take(5))}{(conflicts.Count > 5 ? "…" : string.Empty)}"),
                TextWrapping = TextWrapping.Wrap,
            });
            content.Children.Add(new TextBlock
            {
                Text = "安全替换会先上传临时文件，再校验并删除原文件，最后完成重命名；远程文件若已变化会停止覆盖。",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.72,
            });
            content.Children.Add(policyPicker);

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "处理上传同名冲突",
                Content = content,
                PrimaryButtonText = "继续上传",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return null;
            }

            return policyPicker.SelectedIndex switch
            {
                1 => SftpUploadConflictPolicy.KeepBoth,
                2 => SftpUploadConflictPolicy.Replace,
                _ => SftpUploadConflictPolicy.Skip,
            };
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async void CreateSftpDirectoryClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        var directoryName = await ShowSftpNameDialogAsync(
            "新建远程文件夹",
            "文件夹名称",
            string.Empty,
            "创建",
            "将在当前远程目录中创建文件夹。请仅输入名称，不要包含路径分隔符。");
        if (directoryName is not null)
        {
            await ViewModel.CreateSftpDirectoryAsync(directoryName, CancellationToken.None);
        }
    }

    private async void CreateSftpFileClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        var fileName = await ShowSftpNameDialogAsync(
            "新建远程文件",
            "文件名称",
            string.Empty,
            "创建",
            "将在当前远程目录中创建空文件。请仅输入名称，不要包含路径分隔符。");
        if (fileName is not null)
        {
            await ViewModel.CreateSftpFileAsync(fileName, CancellationToken.None);
        }
    }

    private async void RenameSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanMutateSelectedSftpEntry || selected is null)
        {
            return;
        }

        var newName = await ShowSftpNameDialogAsync(
            "重命名远程项目",
            "新名称",
            selected.Name,
            "重命名",
            string.Concat("目标：", selected.Path, "。此操作会立即修改远端文件或文件夹名称。"));
        if (newName is not null)
        {
            await ViewModel.RenameSelectedSftpEntryAsync(newName, CancellationToken.None);
        }
    }

    private async void RemoveSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        var selectedEntries = ViewModel.SelectedSftpEntries.Count > 0
            ? ViewModel.SelectedSftpEntries.ToList()
            : ViewModel.SelectedSftpEntry is { } selected ? [selected] : [];
        if (!ViewModel.CanDeleteSelectedSftpEntries || selectedEntries.Count == 0 || isSftpDialogOpen)
        {
            return;
        }

        isSftpDialogOpen = true;
        try
        {
            var dialog = CreateThemedDialog(
                selectedEntries.Count == 1
                    ? selectedEntries[0].IsDirectory ? "确认删除远程文件夹？" : "确认删除远程文件？"
                    : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"确认删除 {selectedEntries.Count} 个远程项目？"),
                new TextBlock
                {
                    Text = string.Concat(
                        "目标：\n",
                        string.Join("\n", selectedEntries.Take(6).Select(static entry => string.Concat("• ", entry.Path))),
                        selectedEntries.Count > 6 ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"\n…另有 {selectedEntries.Count - 6} 项") : string.Empty,
                        "\n\n删除会立即作用于远端服务器，无法通过 OrbitTerm 恢复。文件夹仅允许在为空时删除。"),
                    TextWrapping = TextWrapping.Wrap,
                },
                primaryButtonText: "删除",
                closeButtonText: "取消");
            dialog.DefaultButton = ContentDialogButton.Close;
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                if (selectedEntries.Count == 1)
                {
                    await ViewModel.RemoveSelectedSftpEntryConfirmedAsync(selectedEntries[0], CancellationToken.None);
                }
                else
                {
                    await ViewModel.RemoveSelectedSftpEntriesConfirmedAsync(selectedEntries, CancellationToken.None);
                }
            }
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async void ChangeSelectedSftpPermissionsClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanChangeSelectedSftpPermissions || selected is null)
        {
            return;
        }

        var initialMode = Convert.ToString((long)(selected.PermissionsOctal & 0xFFFU), 8)
            .PadLeft(3, '0');
        var mode = await ShowSftpNameDialogAsync(
            "修改远程权限",
            "八进制权限",
            initialMode,
            "应用",
            string.Concat("目标：", selected.Path, "\n\n此操作会立即修改远端权限，可能影响服务访问或其他用户。"));
        if (mode is not null)
        {
            await ViewModel.ChangeSelectedSftpPermissionsConfirmedAsync(
                selected,
                mode,
                CancellationToken.None);
        }
    }

    private async Task ShowSftpPreviewDialogAsync()
    {
        if (isSftpDialogOpen || !ViewModel.HasSftpPreview)
        {
            return;
        }

        isSftpDialogOpen = true;
        try
        {
            var selected = ViewModel.SelectedSftpEntry;
            var status = new TextBlock
            {
                Text = ViewModel.CanEditSftpPreview
                    ? "可编辑文本。保存会直接写入远端文件。"
                    : "只读预览。该文件无法作为安全编辑目标写回。",
                TextWrapping = TextWrapping.Wrap,
            };
            var encoding = new TextBlock
            {
                Text = string.Concat(
                    "编码：UTF-8 · 已读取 ",
                    selected?.SizeText ?? "未知大小",
                    ViewModel.CanEditSftpPreview ? " · 可保存到远端" : " · 只读"),
                Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 96, 108, 124)),
                FontSize = 12,
            };
            var editor = new TextBox
            {
                Text = ViewModel.SftpPreviewText,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                FontFamily = new FontFamily("Cascadia Mono"),
                FontSize = 13,
                IsReadOnly = !ViewModel.CanEditSftpPreview,
                MinHeight = 380,
                MaxHeight = 560,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch,
            };
            editor.TextChanged += (_, _) =>
            {
                ViewModel.SftpPreviewText = editor.Text;
                encoding.Text = string.Concat(
                    "编码：UTF-8 · ",
                    System.Text.Encoding.UTF8.GetByteCount(editor.Text).ToString(System.Globalization.CultureInfo.InvariantCulture),
                    " B",
                    ViewModel.IsSftpPreviewDirty ? " · 有未保存修改" : " · 已与远端读取内容一致");
            };
            var saveButton = new Button
            {
                Content = "保存到远端",
                IsEnabled = ViewModel.CanEditSftpPreview,
                Style = ResourceStyle("OrbitWideActionButtonStyle"),
            };
            var revertButton = new Button
            {
                Content = "还原修改",
                IsEnabled = ViewModel.CanEditSftpPreview,
                Style = ResourceStyle("OrbitWideActionButtonStyle"),
            };
            var copyButton = new Button
            {
                Content = "复制内容",
                Style = ResourceStyle("OrbitWideActionButtonStyle"),
            };
            var discardButton = new Button
            {
                Content = "放弃修改并关闭",
                Visibility = Visibility.Collapsed,
                Style = ResourceStyle("OrbitWideActionButtonStyle"),
            };
            var keepEditingButton = new Button
            {
                Content = "继续编辑",
                Visibility = Visibility.Collapsed,
                Style = ResourceStyle("OrbitWideActionButtonStyle"),
            };

            saveButton.Click += async (_, _) =>
            {
                ViewModel.SftpPreviewText = editor.Text;
                if (!ViewModel.CanSaveSftpPreview)
                {
                    status.Text = "没有可保存的修改，或文件内容不符合安全限制。";
                    return;
                }

                await ViewModel.SaveSftpPreviewAsync(CancellationToken.None);
                status.Text = ViewModel.SftpPreviewStatus;
            };
            revertButton.Click += (_, _) =>
            {
                ViewModel.RevertSftpPreviewChanges();
                editor.Text = ViewModel.SftpPreviewText;
                status.Text = "已还原为远端读取时的内容。";
            };
            copyButton.Click += (_, _) =>
            {
                var package = new DataPackage();
                package.SetText(editor.Text);
                Clipboard.SetContent(package);
                status.Text = "内容已复制到剪贴板。";
            };

            var actions = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            actions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            actions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetColumn(revertButton, 1);
            Grid.SetColumn(copyButton, 2);
            Grid.SetRow(discardButton, 1);
            Grid.SetRow(keepEditingButton, 1);
            Grid.SetColumn(keepEditingButton, 1);
            actions.Children.Add(saveButton);
            actions.Children.Add(revertButton);
            actions.Children.Add(copyButton);
            actions.Children.Add(discardButton);
            actions.Children.Add(keepEditingButton);

            var content = new StackPanel { Spacing = 10, MinWidth = 680 };
            content.Children.Add(new TextBlock
            {
                Text = selected?.Path ?? ViewModel.SftpPathText,
                FontFamily = new FontFamily("Cascadia Mono"),
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            content.Children.Add(encoding);
            content.Children.Add(status);
            content.Children.Add(actions);
            content.Children.Add(editor);

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = string.Concat("文本预览 · ", selected?.Name ?? "远程文件"),
                Content = content,
                CloseButtonText = "关闭编辑器",
                DefaultButton = ContentDialogButton.Close,
            };
            var allowDiscard = false;
            discardButton.Click += (_, _) =>
            {
                allowDiscard = true;
                ViewModel.RevertSftpPreviewChanges();
                dialog.Hide();
            };
            keepEditingButton.Click += (_, _) =>
            {
                discardButton.Visibility = Visibility.Collapsed;
                keepEditingButton.Visibility = Visibility.Collapsed;
                status.Text = "继续编辑。保存后才会写入远端文件。";
                editor.Focus(FocusState.Programmatic);
            };
            dialog.Closing += (_, args) =>
            {
                ViewModel.SftpPreviewText = editor.Text;
                if (allowDiscard || !ViewModel.IsSftpPreviewDirty)
                {
                    return;
                }

                args.Cancel = true;
                status.Text = "存在未保存修改。要关闭并丢弃本次修改吗？";
                discardButton.Visibility = Visibility.Visible;
                keepEditingButton.Visibility = Visibility.Visible;
            };
            await dialog.ShowAsync();
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async Task<string?> ShowSftpNameDialogAsync(
        string title,
        string header,
        string initialValue,
        string primaryButtonText,
        string? description = null)
    {
        if (isSftpDialogOpen)
        {
            return null;
        }

        isSftpDialogOpen = true;
        try
        {
            var input = new TextBox
            {
                Header = header,
                Text = initialValue,
                MaxLength = 255,
            };
            var content = new StackPanel { Spacing = 10 };
            if (!string.IsNullOrWhiteSpace(description))
            {
                content.Children.Add(new TextBlock
                {
                    Text = description,
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            content.Children.Add(input);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = title,
                Content = content,
                PrimaryButtonText = primaryButtonText,
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            return await dialog.ShowAsync() == ContentDialogResult.Primary
                ? input.Text
                : null;
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async void StartDockerContainerClick(object sender, RoutedEventArgs e)
    {
        await ConfirmDockerActionAsync("启动", ViewModel.StartDockerContainerCommand);
    }

    private async void StopDockerContainerClick(object sender, RoutedEventArgs e)
    {
        await ConfirmDockerActionAsync("停止", ViewModel.StopDockerContainerCommand);
    }

    private async void RestartDockerContainerClick(object sender, RoutedEventArgs e)
    {
        await ConfirmDockerActionAsync("重启", ViewModel.RestartDockerContainerCommand);
    }

    private async void DockerContextLogsClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextDockerContainer(sender))
        {
            await OpenSelectedDockerLogsAsync();
        }
    }

    private void DockerCardContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: DockerContainerViewModel container } target)
        {
            return;
        }

        ViewModel.SelectedDockerContainer = container;
        var flyout = CreateDockerOperationsFlyout(container);
        if (e.TryGetPosition(target, out var position))
        {
            flyout.ShowAt(target, position);
        }
        else
        {
            flyout.ShowAt(target);
        }

        e.Handled = true;
        QueueDefaultPointerCursorRestore();
    }

    private MenuFlyout CreateDockerOperationsFlyout(DockerContainerViewModel container)
    {
        var flyout = new MenuFlyout();
        flyout.Items.Add(CreateDockerContextItem("查看日志", container, true, async () =>
            await OpenSelectedDockerLogsAsync()));
        flyout.Items.Add(CreateDockerContextItem("复制容器 ID", container, true, () =>
        {
            var package = new DataPackage();
            package.SetText(container.Id);
            Clipboard.SetContent(package);
            return Task.CompletedTask;
        }));
        flyout.Items.Add(new MenuFlyoutSeparator());

        if (container.CanStart)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "启动",
                container,
                ViewModel.StartDockerContainerCommand));
        }
        if (container.CanUnpause)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "恢复运行",
                container,
                ViewModel.UnpauseDockerContainerCommand));
        }
        if (container.CanStop)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "停止",
                container,
                ViewModel.StopDockerContainerCommand));
        }
        if (container.CanRestart)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "重启",
                container,
                ViewModel.RestartDockerContainerCommand));
        }
        if (container.CanPause)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "暂停",
                container,
                ViewModel.PauseDockerContainerCommand));
        }
        if (container.CanKill)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "强制终止",
                container,
                ViewModel.KillDockerContainerCommand,
                requiresConfirmation: true));
        }
        if (container.CanRemove)
        {
            flyout.Items.Add(CreateDockerActionContextItem(
                "删除容器",
                container,
                ViewModel.RemoveDockerContainerCommand,
                requiresConfirmation: true));
        }

        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(CreateDockerContextItem(
            "刷新容器列表",
            container,
            ViewModel.RefreshDockerContainersCommand.CanExecute(null),
            () =>
            {
                ViewModel.RefreshDockerContainersCommand.Execute(null);
                return Task.CompletedTask;
            }));
        flyout.Opened += (_, _) => QueueDefaultPointerCursorRestore();
        flyout.Closed += (_, _) => QueueDefaultPointerCursorRestore();
        return flyout;
    }

    private MenuFlyoutItem CreateDockerActionContextItem(
        string text,
        DockerContainerViewModel container,
        ICommand command,
        bool requiresConfirmation = false) =>
        CreateDockerContextItem(text, container, command.CanExecute(null), async () =>
        {
            if (requiresConfirmation)
            {
                await ConfirmDockerActionAsync(text, command);
            }
            else if (command.CanExecute(null))
            {
                command.Execute(null);
            }
        });

    private MenuFlyoutItem CreateDockerContextItem(
        string text,
        DockerContainerViewModel container,
        bool isEnabled,
        Func<Task> action)
    {
        var item = new MenuFlyoutItem
        {
            Text = text,
            Tag = container,
            IsEnabled = isEnabled,
        };
        item.Click += (_, _) =>
        {
            // The Docker topology refresh can replace card instances while a
            // context menu is open. Re-select by the menu item's captured
            // container before dispatching the action, then wait until the
            // flyout has closed before opening another popup.
            ViewModel.SelectedDockerContainer = container;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, async () =>
            {
                await action();
            });
        };
        return item;
    }

    private void DockerCardPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border card &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitMetricBrush"] is Brush hoverBrush &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitAccentBrush"] is Brush accentBrush)
        {
            card.Background = hoverBrush;
            card.BorderBrush = accentBrush;
        }
    }

    private void DockerCardPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border card &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitPanelBrush"] is Brush panelBrush &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitPanelStrokeBrush"] is Brush strokeBrush)
        {
            card.Background = panelBrush;
            card.BorderBrush = strokeBrush;
        }
    }

    private async void DockerContextStartClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextDockerContainer(sender))
        {
            await ConfirmDockerActionAsync("启动", ViewModel.StartDockerContainerCommand);
        }
    }

    private async void DockerContextStopClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextDockerContainer(sender))
        {
            await ConfirmDockerActionAsync("停止", ViewModel.StopDockerContainerCommand);
        }
    }

    private async void DockerContextRestartClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextDockerContainer(sender))
        {
            await ConfirmDockerActionAsync("重启", ViewModel.RestartDockerContainerCommand);
        }
    }

    private void DockerContextRefreshClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.RefreshDockerContainersCommand.CanExecute(null))
        {
            ViewModel.RefreshDockerContainersCommand.Execute(null);
        }
    }

    private async void PreviewDockerLogsClick(object sender, RoutedEventArgs e)
    {
        await OpenSelectedDockerLogsAsync();
    }

    private Task OpenSelectedDockerLogsAsync()
    {
        if (ViewModel.CreateSelectedDockerLogSessionContext() is not { } context)
        {
            return Task.CompletedTask;
        }

        try
        {
            activeDockerLogWindow?.StopAndClose();
            var controller = new DockerLogSessionController(
                context,
                cancellationToken => ViewModel.CaptureDockerLogFrameAsync(context, 500, cancellationToken),
                TimeSpan.FromSeconds(2));
            var dockerLogWindow = new DockerLogWindow(
                AppWindow,
                controller,
                Root.ActualTheme);
            activeDockerLogWindow = dockerLogWindow;
            dockerLogWindow.Closed += async (_, _) =>
            {
                if (ReferenceEquals(activeDockerLogWindow, dockerLogWindow))
                {
                    activeDockerLogWindow = null;
                }
                await dockerLogWindow.DisposeAsync();
            };
            dockerLogWindow.Show();
            return Task.CompletedTask;
        }
        catch
        {
            return ShowDockerLogOpenFailureAsync();
        }
    }

    private async Task ShowDockerLogOpenFailureAsync()
    {
        if (Root.XamlRoot is null)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "无法打开容器日志",
            Content = "日志窗口暂时无法打开。请确认当前容器仍属于已连接会话，然后重试。",
            CloseButtonText = "知道了",
            DefaultButton = ContentDialogButton.Close,
        };
        await dialog.ShowAsync();
    }

    private bool SelectContextDockerContainer(object sender)
    {
        if (sender is FrameworkElement { Tag: DockerContainerViewModel container })
        {
            ViewModel.SelectedDockerContainer = container;
            return true;
        }

        return false;
    }

    private async Task ConfirmDockerActionAsync(string action, ICommand command)
    {
        if (isDockerDialogOpen || ViewModel.SelectedDockerContainer is not { } selected || !command.CanExecute(null))
        {
            return;
        }

        isDockerDialogOpen = true;
        try
        {
            var impact = action switch
            {
                "停止" => "停止会中断该容器提供的服务。",
                "重启" => "重启会短暂中断该容器提供的服务。",
                "强制终止" => "强制终止不会等待容器优雅退出，可能造成尚未写入的数据丢失。",
                "删除容器" => "删除会强制移除该容器；此操作无法撤销，请确认容器内没有需要保留的未持久化数据。",
                "暂停" => "暂停会冻结容器内的所有进程，直到恢复运行。",
                "恢复运行" => "恢复后容器内进程会继续运行。",
                _ => "启动会在远端服务器上运行该容器。",
            };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = string.Concat("确认", action, "容器？"),
                Content = new TextBlock
                {
                    Text = string.Concat("容器：", selected.Name, "\n镜像：", selected.Image, "\n\n", impact),
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = action,
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && command.CanExecute(null))
            {
                command.Execute(null);
            }
        }
        finally
        {
            isDockerDialogOpen = false;
        }
    }

    private async void CreateSnippetClick(object sender, RoutedEventArgs e)
    {
        await ShowSnippetEditorAsync(null);
    }

    private async void CreateAssetClick(object sender, RoutedEventArgs e)
    {
        if (isAssetDialogOpen)
        {
            return;
        }
        var choice = CreateThemedDialog(
            "添加服务器",
            new TextBlock
            {
                Text = "单个添加适合完整配置凭据与跳板机；批量添加支持一次导入最多 100 台 SSH 服务器。",
                TextWrapping = TextWrapping.Wrap,
            },
            "单个添加",
            "取消");
        choice.SecondaryButtonText = "批量添加";
        var result = await choice.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ShowAssetEditorAsync(null);
        }
        else if (result == ContentDialogResult.Secondary)
        {
            await ShowBulkAssetImportAsync();
        }
    }

    private async Task ShowBulkAssetImportAsync()
    {
        if (isAssetDialogOpen)
        {
            return;
        }
        isAssetDialogOpen = true;
        try
        {
            var input = new TextBox
            {
                Header = "服务器清单",
                PlaceholderText = "名称,分组,主机,端口,用户名,密码,私钥内容,私钥口令,标签",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                MinWidth = 680,
                MinHeight = 260,
                FontFamily = new FontFamily("Cascadia Mono"),
            };
            var validation = new TextBlock
            {
                Text = "每行一台；支持逗号、分号或 Tab。密码与私钥只写入当前 Windows 用户的 DPAPI 安全存储。以 # 开头的行会被忽略。",
                TextWrapping = TextWrapping.Wrap,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
            };
            var content = new StackPanel { Spacing = 10 };
            content.Children.Add(input);
            content.Children.Add(validation);
            var dialog = CreateThemedDialog("批量添加服务器", content, "导入", "取消");
            dialog.PrimaryButtonClick += (senderDialog, args) =>
            {
                try
                {
                    ParseBulkAssets(input.Text);
                }
                catch (FormatException exception)
                {
                    args.Cancel = true;
                    validation.Text = exception.Message;
                    validation.Foreground = new SolidColorBrush(Color.FromArgb(255, 196, 43, 28));
                }
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
            var imported = await ViewModel.ImportAssetsAsync(ParseBulkAssets(input.Text), CancellationToken.None);
            await ShowAccountMessageAsync("批量添加完成", $"已导入 {imported} 台服务器。重复端点会被安全跳过。");
        }
        catch (Exception exception) when (exception is FormatException or ArgumentException or IOException)
        {
            await ShowAccountMessageAsync("无法批量添加", exception.Message);
        }
        finally
        {
            isAssetDialogOpen = false;
        }
    }

    private static IReadOnlyList<BulkAssetImportItem> ParseBulkAssets(string text)
    {
        var result = new List<BulkAssetImportItem>();
        var lineNumber = 0;
        foreach (var rawLine in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            lineNumber++;
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }
            var delimiter = line.Contains('\t') ? '\t' : line.Contains(';') ? ';' : ',';
            var fields = line.Split(delimiter).Select(value => value.Trim()).ToArray();
            if (fields.Length < 5)
            {
                throw new FormatException($"第 {lineNumber} 行字段不足；至少需要名称、分组、主机、端口和用户名。 ");
            }
            if (lineNumber == 1 && fields[0].Contains("名称", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (!int.TryParse(fields[3], out var port) || port is < 1 or > 65535)
            {
                throw new FormatException($"第 {lineNumber} 行端口无效。 ");
            }
            var tags = fields.Length > 8
                ? fields[8].Split(['|', '、', '，'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Take(16).ToArray()
                : [];
            result.Add(new BulkAssetImportItem(
                fields[0], string.IsNullOrWhiteSpace(fields[1]) ? "未分组" : fields[1], fields[2], port, fields[4],
                fields.ElementAtOrDefault(5) ?? string.Empty,
                (fields.ElementAtOrDefault(6) ?? string.Empty).Replace("\\n", "\n", StringComparison.Ordinal),
                fields.ElementAtOrDefault(7) ?? string.Empty,
                tags));
            if (result.Count > 100)
            {
                throw new FormatException("每次最多批量导入 100 台服务器。 ");
            }
        }
        if (result.Count == 0)
        {
            throw new FormatException("没有找到可导入的服务器记录。 ");
        }
        return result;
    }

    private async void EditAssetClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedAsset;
        if (selected is null)
        {
            selected = await SelectAssetForCredentialEditingAsync();
        }

        if (selected is not null)
        {
            ViewModel.SelectedAsset = selected;
            await ShowAssetEditorAsync(selected);
        }
    }

    private async Task<AssetViewModel?> SelectAssetForCredentialEditingAsync()
    {
        if (ViewModel.Assets.Count == 0)
        {
            await ShowAccountMessageAsync(
                "没有可编辑的资产",
                "请先添加服务器资产；编辑凭据不会连接或修改远端服务器。");
            return null;
        }

        var visibleAssets = new ObservableCollection<AssetViewModel>();
        var search = new TextBox
        {
            Header = "搜索资产",
            PlaceholderText = "名称、主机、用户名、分组或标签",
            MinWidth = 440,
        };
        var summary = new TextBlock
        {
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var list = new ListView
        {
            ItemsSource = visibleAssets,
            SelectionMode = ListViewSelectionMode.Single,
            ItemTemplate = (DataTemplate)Root.Resources["AssetManagerItemTemplate"],
            ItemContainerStyle = (Style)Root.Resources["AssetManagerListViewItemStyle"],
            MinHeight = 260,
            MaxHeight = 420,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(list, "选择要编辑凭据的服务器资产");

        void Refresh(string query)
        {
            var normalized = query.Trim();
            var matches = ViewModel.Assets
                .Where(asset => normalized.Length == 0 ||
                    asset.Name.Contains(normalized, StringComparison.CurrentCultureIgnoreCase) ||
                    asset.Host.Contains(normalized, StringComparison.OrdinalIgnoreCase) ||
                    asset.Username.Contains(normalized, StringComparison.CurrentCultureIgnoreCase) ||
                    asset.Group.Contains(normalized, StringComparison.CurrentCultureIgnoreCase) ||
                    asset.TagsDisplay.Contains(normalized, StringComparison.CurrentCultureIgnoreCase))
                .OrderBy(asset => asset.Group, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(asset => asset.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
            visibleAssets.Clear();
            foreach (var asset in matches)
            {
                visibleAssets.Add(asset);
            }
            summary.Text = matches.Length == 0
                ? "没有匹配的资产。"
                : $"显示 {matches.Length} 台资产；选择后仅编辑本机安全凭据。";
        }

        var content = new Grid
        {
            RowSpacing = 8,
        };
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(search);
        Grid.SetRow(summary, 1);
        content.Children.Add(summary);
        Grid.SetRow(list, 2);
        content.Children.Add(list);

        var dialog = CreateThemedDialog(
            "选择要编辑凭据的资产",
            content,
            primaryButtonText: "编辑凭据",
            closeButtonText: "取消");
        var acceptedByDoubleClick = false;
        dialog.IsPrimaryButtonEnabled = false;
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedItem is AssetViewModel;
        search.TextChanged += (_, _) => Refresh(search.Text);
        list.DoubleTapped += (_, args) =>
        {
            if (list.SelectedItem is AssetViewModel)
            {
                acceptedByDoubleClick = true;
                dialog.Hide();
                args.Handled = true;
            }
        };
        Refresh(string.Empty);

        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary || acceptedByDoubleClick
            ? list.SelectedItem as AssetViewModel
            : null;
    }

    private async void DeleteAssetClick(object sender, RoutedEventArgs e)
    {
        if (isAssetDialogOpen || ViewModel.SelectedAsset is not { } selected)
        {
            return;
        }

        isAssetDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "确认删除本地服务器资产？",
                Content = new TextBlock
                {
                    Text = string.Concat(
                        "服务器：", selected.Name,
                        "\n端点：", selected.Endpoint,
                        "\n分组：", selected.Group,
                        "\n\n此操作将从当前 Windows 设备删除资产记录及其已安全保存的凭据；不会连接或修改远端服务器。"),
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = "删除",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
                ViewModel.SelectedAsset?.Id == selected.Id &&
                ViewModel.DeleteAssetCommand.CanExecute(null))
            {
                ViewModel.DeleteAssetCommand.Execute(null);
            }
        }
        finally
        {
            isAssetDialogOpen = false;
        }
    }

    private async void AssetItemsDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var asset = sender switch
        {
            FrameworkElement { Tag: AssetViewModel taggedAsset } => taggedAsset,
            ListView { SelectedItem: AssetViewModel selectedAsset } => selectedAsset,
            _ => null,
        };
        if (asset is null) return;

        e.Handled = true;
        ViewModel.SelectedAsset = asset;
        await ConnectAssetWithPolicyAsync(asset);
    }

    private async void AssetContextConnectClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextAsset(sender) && ViewModel.SelectedAsset is { } asset)
        {
            await ConnectAssetWithPolicyAsync(asset);
        }
    }

    private async Task ConnectAssetWithPolicyAsync(AssetViewModel asset)
    {
        if (!ViewModel.CanAccessAsset(asset))
        {
            await ShowAccountMessageAsync(
                "资产当前已锁定",
                "该资产属于另一个账户作用域，或当前账户尚未使用主密码解锁。未发起任何网络连接。");
            return;
        }

        if (asset.Transport == ServerTransport.RemoteDesktop)
        {
            ConnectionProgressOverlay.Visibility = Visibility.Visible;
            try
            {
                await LaunchSavedRemoteDesktopAssetAsync(asset);
            }
            finally
            {
                ConnectionProgressOverlay.Visibility = Visibility.Collapsed;
            }
            return;
        }

        if (asset.Transport == ServerTransport.Telnet)
        {
            if (!terminalAppearance.TelnetEnabled)
            {
                await ShowAccountMessageAsync(
                    "Telnet 已关闭",
                    "请先在“设置 > 终端与连接”中启用 Telnet，并确认明文传输风险。未发起任何网络连接。");
                return;
            }

            var targetKey = $"{asset.Id:D}|{asset.Host.Trim().ToLowerInvariant()}|{asset.Port}";
            if (!confirmedTelnetTargets.Contains(targetKey))
            {
                var warning = CreateThemedDialog(
                    "确认明文 Telnet 连接",
                    new TextBlock
                    {
                        Text = $"目标：{asset.Name}\n端点：{asset.Host}:{asset.Port}\n\nTelnet 不提供加密或服务器身份验证。用户名、密码、命令和终端内容可能被读取或篡改。仅在隔离内网或 VPN 内确认连接。",
                        TextWrapping = TextWrapping.Wrap,
                    },
                    "确认并连接",
                    "取消");
                warning.DefaultButton = ContentDialogButton.Close;
                if (await warning.ShowAsync() != ContentDialogResult.Primary)
                {
                    return;
                }
                confirmedTelnetTargets.Add(targetKey);
            }
            ViewModel.AuthorizeTelnetConnection(asset.Id, asset.Host, asset.Port);
        }

        if (ViewModel.ConnectCommand.CanExecute(null))
        {
            ViewModel.ConnectCommand.Execute(null);
        }
    }

    private async void AssetContextEditClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextAsset(sender) && ViewModel.SelectedAsset is { } asset)
        {
            await ShowAssetEditorAsync(asset);
        }
    }

    private void AssetContextDeleteClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextAsset(sender))
        {
            DeleteAssetClick(this, new RoutedEventArgs());
        }
    }

    private bool SelectContextAsset(object sender)
    {
        if (sender is FrameworkElement { Tag: AssetViewModel asset })
        {
            ViewModel.SelectedAsset = asset;
            return true;
        }

        return false;
    }

    private async Task ShowAssetEditorAsync(AssetViewModel? existing)
    {
        if (isAssetDialogOpen)
        {
            return;
        }

        isAssetDialogOpen = true;
        try
        {
            IReadOnlyList<SshKeyRecord> availableSshKeys;
            try
            {
                availableSshKeys = await sshKeyLibrary.ListAccessibleAsync(
                    ViewModel.CurrentAccountScope,
                    ViewModel.IsAccountUnlocked,
                    CancellationToken.None);
            }
            catch
            {
                availableSshKeys = [];
            }
            var previouslyAssignedKey = existing is null
                ? null
                : availableSshKeys.FirstOrDefault(key => key.AssignedAssetIds.Contains(existing.Id));
            var protocolBox = new ComboBox
            {
                Header = "连接协议",
                ItemsSource = new[] { "SSH", "Telnet", "Windows 远程桌面（RDP）" },
                SelectedIndex = existing?.Transport switch
                {
                    ServerTransport.Telnet => 1,
                    ServerTransport.RemoteDesktop => 2,
                    _ => 0,
                },
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            var storageScopeBox = new ComboBox
            {
                Header = "资产保存范围",
                ItemsSource = new[] { "随账户同步", "仅此设备" },
                SelectedIndex = existing?.StorageScope == AssetStorageScope.LocalOnly
                    ? 1
                    : existing is not null || ViewModel.IsAccountSignedIn ? 0 : 1,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            var storageScopeNotice = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
            };
            var nameBox = new TextBox { Header = "名称", MaxLength = 120, Text = existing?.Name ?? "新服务器" };
            var hostBox = new TextBox { Header = "主机", MaxLength = 255, Text = existing?.Host ?? string.Empty };
            var portBox = new TextBox
            {
                Header = "端口（SSH 默认 22）",
                PlaceholderText = "SSH 默认端口：22",
                MaxLength = 5,
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } },
                Text = existing?.Port.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "22",
            };
            var userBox = new TextBox { Header = "用户", MaxLength = 120, Text = existing?.Username ?? string.Empty };
            var groupBox = new TextBox { Header = "分组", MaxLength = 64, PlaceholderText = "例如：生产环境", Text = existing?.Group ?? "未分组" };
            var tagsBox = new TextBox
            {
                Header = "标签",
                MaxLength = 527,
                PlaceholderText = "以逗号分隔，例如：Linux，数据库",
                Text = existing is null ? string.Empty : string.Join("，", existing.Tags),
            };
            var passwordBox = new PasswordBox
            {
                Header = "密码",
                PlaceholderText = existing is null ? "密码或私钥二选一" : "留空则保留已安全保存的凭据",
            };
            var privateKeyBox = new TextBox
            {
                Header = "SSH 私钥",
                PlaceholderText = existing is null
                    ? "粘贴 OpenSSH / PEM 私钥，或从本机文件导入"
                    : "留空则保留已安全保存的私钥",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                MinHeight = 86,
                FontFamily = new FontFamily("Cascadia Mono"),
            };
            var importPrivateKeyButton = new Button
            {
                Content = "从文件导入私钥",
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            var libraryKeyBox = new ComboBox
            {
                Header = "本机 SSH 密钥库（可选）",
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            libraryKeyBox.Items.Add(new ComboBoxItem { Content = "不使用密钥库中的私钥", Tag = null });
            foreach (var key in availableSshKeys.OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                libraryKeyBox.Items.Add(new ComboBoxItem
                {
                    Content = $"{key.Name}  ·  {key.Format}  ·  {key.MaterialFingerprint[..Math.Min(12, key.MaterialFingerprint.Length)]}",
                    Tag = key,
                });
            }
            libraryKeyBox.SelectedIndex = 0;
            if (previouslyAssignedKey is not null)
            {
                var assignedItem = libraryKeyBox.Items
                    .OfType<ComboBoxItem>()
                    .FirstOrDefault(item => item.Tag is SshKeyRecord key && key.Id == previouslyAssignedKey.Id);
                if (assignedItem is not null)
                {
                    libraryKeyBox.SelectedItem = assignedItem;
                }
            }
            var libraryKeyNotice = new TextBlock
            {
                Text = availableSshKeys.Count == 0
                    ? "密钥库尚无密钥；可先从顶部“密钥管理”导入或生成。"
                    : "选择后会将该私钥安全分配给此资产，不会在资产文件或界面中显示私钥。",
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
            };
            var privateKeyPassphraseBox = new PasswordBox
            {
                Header = "私钥口令（可选）",
                PlaceholderText = existing is null ? "仅在私钥已加密时填写" : "与新私钥一同填写；留空不修改",
            };
            var passwordFallbackCheck = new CheckBox
            {
                Content = "私钥认证失败时允许使用密码",
                IsChecked = existing?.AllowPasswordFallback ?? true,
            };
            var privateKeyFields = new StackPanel { Spacing = 8 };
            privateKeyFields.Children.Add(libraryKeyBox);
            privateKeyFields.Children.Add(libraryKeyNotice);
            privateKeyFields.Children.Add(privateKeyBox);
            privateKeyFields.Children.Add(importPrivateKeyButton);
            privateKeyFields.Children.Add(privateKeyPassphraseBox);
            privateKeyFields.Children.Add(passwordFallbackCheck);
            var jumpEnabled = new ToggleSwitch
            {
                Header = "通过跳板机连接",
                IsOn = existing?.JumpHost is not null,
                OffContent = "直接连接",
                OnContent = "启用单跳 ProxyJump",
            };
            var jumpHostBox = new TextBox { Header = "跳板机主机", MaxLength = 255, Text = existing?.JumpHost?.Host ?? string.Empty };
            var jumpPortBox = new TextBox
            {
                Header = "跳板机端口", MaxLength = 5,
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } },
                Text = (existing?.JumpHost?.Port ?? 22).ToString(System.Globalization.CultureInfo.InvariantCulture),
            };
            var jumpUserBox = new TextBox { Header = "跳板机用户", MaxLength = 120, Text = existing?.JumpHost?.Username ?? string.Empty };
            var jumpPasswordBox = new PasswordBox { Header = "跳板机密码", PlaceholderText = existing?.JumpHost is null ? "密码或私钥二选一" : "留空则保留已保存的跳板机凭据" };
            var jumpPrivateKeyBox = new TextBox
            {
                Header = "跳板机私钥",
                PlaceholderText = "可粘贴 OpenSSH 私钥；不会写入资产 JSON",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                MinHeight = 86,
                FontFamily = new FontFamily("Cascadia Mono"),
            };
            var jumpPassphraseBox = new PasswordBox { Header = "私钥口令（可选）" };
            var jumpFallback = new CheckBox
            {
                Content = "私钥失败时允许使用跳板机密码",
                IsChecked = existing?.JumpHost?.AllowPasswordFallback ?? true,
            };
            var jumpFields = new StackPanel { Spacing = 10 };
            jumpFields.Children.Add(jumpHostBox);
            var jumpConnectionRow = new Grid { ColumnSpacing = 10 };
            jumpConnectionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            jumpConnectionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(jumpPortBox, 0);
            Grid.SetColumn(jumpUserBox, 1);
            jumpConnectionRow.Children.Add(jumpPortBox);
            jumpConnectionRow.Children.Add(jumpUserBox);
            jumpFields.Children.Add(jumpConnectionRow);
            jumpFields.Children.Add(jumpPasswordBox);
            jumpFields.Children.Add(jumpPrivateKeyBox);
            jumpFields.Children.Add(jumpPassphraseBox);
            jumpFields.Children.Add(jumpFallback);
            var telnetNotice = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Foreground = ResourceBrush("OrbitMutedTextBrush"),
            };
            void UpdateTransportFields()
            {
                var isTelnet = protocolBox.SelectedIndex == 1;
                var isRemoteDesktop = protocolBox.SelectedIndex == 2;
                if (isRemoteDesktop)
                {
                    storageScopeBox.SelectedIndex = 1;
                    storageScopeBox.IsEnabled = false;
                }
                else
                {
                    storageScopeBox.IsEnabled = true;
                }
                storageScopeNotice.Text = storageScopeBox.SelectedIndex == 1
                    ? "仅保存在当前 Windows 用户的本机资产库，不上传到 OrbitTerm 账户。请使用加密备份防止设备损坏造成数据丢失。"
                    : ViewModel.IsAccountSignedIn
                        ? "登录并解锁后进行端到端加密同步；退出登录后该资产会被锁定。"
                        : "将在以后登录并解锁账户时认领并进入端到端加密同步。";
                portBox.Header = isRemoteDesktop
                    ? "端口（RDP 默认 3389）"
                    : isTelnet
                        ? "端口（Telnet 默认 23）"
                        : "端口（SSH 默认 22）";
                portBox.PlaceholderText = isRemoteDesktop
                    ? "RDP 默认端口：3389"
                    : isTelnet
                        ? "Telnet 默认端口：23"
                        : "SSH 默认端口：22";
                privateKeyFields.Visibility = isTelnet || isRemoteDesktop ? Visibility.Collapsed : Visibility.Visible;
                jumpEnabled.Visibility = isTelnet || isRemoteDesktop ? Visibility.Collapsed : Visibility.Visible;
                jumpFields.Visibility = !isTelnet && !isRemoteDesktop && jumpEnabled.IsOn ? Visibility.Visible : Visibility.Collapsed;
                telnetNotice.Text = isRemoteDesktop
                    ? "双击此资产将直接启动 Windows 远程桌面。强制启用 NLA；密码只保存在当前 Windows 用户的 DPAPI 凭据库中。"
                    : isTelnet
                        ? terminalAppearance.TelnetEnabled
                            ? "Telnet 为明文协议，仅支持密码自动登录和终端；不提供跳板机、SFTP、监控、Docker 或批量命令。"
                            : "Telnet 当前已关闭。请先在“设置 > 终端与连接”阅读风险并手动启用。"
                        : "SSH 始终执行主机密钥验证，并可使用完整会话工具。";
                if (existing is null)
                {
                    if (isTelnet && portBox.Text == "22") portBox.Text = "23";
                    if (isRemoteDesktop && (portBox.Text == "22" || portBox.Text == "23")) portBox.Text = "3389";
                    if (!isTelnet && !isRemoteDesktop && (portBox.Text == "23" || portBox.Text == "3389")) portBox.Text = "22";
                    if (isTelnet && portBox.Text == "3389") portBox.Text = "23";
                }
            }
            jumpEnabled.Toggled += (_, _) => UpdateTransportFields();
            protocolBox.SelectionChanged += (_, _) => UpdateTransportFields();
            storageScopeBox.SelectionChanged += (_, _) => UpdateTransportFields();
            UpdateTransportFields();
            var credentialNotice = new TextBlock
            {
                Text = existing is null
                    ? "资产信息不会包含密码或私钥。输入的密码仅在发起连接时由 Windows DPAPI 保护保存。"
                    : ViewModel.SelectedCredentialAvailabilitySummary,
                TextWrapping = TextWrapping.Wrap,
            };
            var clearCredentialCheck = existing is null
                ? null
                : new CheckBox
                {
                    Content = "同时清除当前 Windows 用户已保存的凭据",
                };
            var validationText = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
            };
            static string? ValidatePrivateKeyMaterial(string privateKey, string passphrase)
            {
                if (string.IsNullOrWhiteSpace(privateKey)) return null;
                try
                {
                    var normalized = SshKeyMaterialPolicy.NormalizePrivateKey(privateKey);
                    _ = SshPrivateKeyInspector.Inspect(normalized, passphrase);
                    return null;
                }
                catch (ArgumentException exception)
                {
                    return exception.Message;
                }
            }
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(protocolBox);
            content.Children.Add(telnetNotice);
            content.Children.Add(storageScopeBox);
            content.Children.Add(storageScopeNotice);
            content.Children.Add(nameBox);
            content.Children.Add(hostBox);
            var connectionRow = new Grid { ColumnSpacing = 10 };
            connectionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
            connectionRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(portBox, 0);
            Grid.SetColumn(userBox, 1);
            connectionRow.Children.Add(portBox);
            connectionRow.Children.Add(userBox);
            content.Children.Add(connectionRow);
            content.Children.Add(groupBox);
            content.Children.Add(tagsBox);
            content.Children.Add(passwordBox);
            content.Children.Add(privateKeyFields);
            content.Children.Add(jumpEnabled);
            content.Children.Add(jumpFields);
            content.Children.Add(credentialNotice);
            if (clearCredentialCheck is not null)
            {
                content.Children.Add(clearCredentialCheck);
            }
            content.Children.Add(validationText);

            importPrivateKeyButton.Click += async (_, _) =>
            {
                var picker = new FileOpenPicker();
                picker.FileTypeFilter.Add(".pem");
                picker.FileTypeFilter.Add(".key");
                picker.FileTypeFilter.Add(".ppk");
                picker.FileTypeFilter.Add("*");
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                var file = await picker.PickSingleFileAsync();
                if (file is null)
                {
                    return;
                }

                try
                {
                    var properties = await file.GetBasicPropertiesAsync();
                    if (properties.Size is 0 or > 1_048_576)
                    {
                        validationText.Text = "私钥文件必须是非空文本，且大小不能超过 1 MB。";
                        validationText.Visibility = Visibility.Visible;
                        return;
                    }
                    var keyText = SshKeyMaterialPolicy.NormalizePrivateKey(
                        await Windows.Storage.FileIO.ReadTextAsync(file));
                    privateKeyBox.Text = keyText;
                    validationText.Text = $"已导入私钥：{file.Name}。内容只会写入 Windows 安全凭据存储。";
                    validationText.Visibility = Visibility.Visible;
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    validationText.Text = "无法导入此私钥。请选择 OpenSSH、PEM、PKCS#8 或 PuTTY PPK 私钥，不要选择 .pub 公钥。";
                    validationText.Visibility = Visibility.Visible;
                }
            };

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = existing is null ? "新建服务器资产" : "编辑服务器资产",
                RequestedTheme = Root.ActualTheme,
                Content = new ScrollViewer
                {
                    MaxHeight = 600,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Content = content,
                },
                PrimaryButtonText = "保存",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
            };
            dialog.PrimaryButtonClick += (_, args) =>
            {
                var validationError = ViewModel.ValidateAssetEditorInput(
                    nameBox.Text,
                    hostBox.Text,
                    portBox.Text,
                    userBox.Text,
                    groupBox.Text,
                    tagsBox.Text);
                var isTelnet = protocolBox.SelectedIndex == 1;
                var isRemoteDesktop = protocolBox.SelectedIndex == 2;
                if (isTelnet && !terminalAppearance.TelnetEnabled)
                {
                    args.Cancel = true;
                    validationText.Text = "请先在设置中启用 Telnet，并确认明文传输风险。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (isTelnet && existing is null && string.IsNullOrEmpty(passwordBox.Password))
                {
                    args.Cancel = true;
                    validationText.Text = "首次创建 Telnet 资产时需要输入用于自动登录的密码。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (isRemoteDesktop && existing is null && string.IsNullOrEmpty(passwordBox.Password))
                {
                    args.Cancel = true;
                    validationText.Text = "首次创建远程桌面资产时需要输入 Windows 登录密码。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (validationError is not null)
                {
                    args.Cancel = true;
                    validationText.Text = validationError;
                    validationText.Visibility = Visibility.Visible;
                }
                else if (!isTelnet && !isRemoteDesktop &&
                    ValidatePrivateKeyMaterial(privateKeyBox.Text, privateKeyPassphraseBox.Password) is { } privateKeyError)
                {
                    args.Cancel = true;
                    validationText.Text = privateKeyError;
                    validationText.Visibility = Visibility.Visible;
                }
                else if (!isTelnet && !isRemoteDesktop && jumpEnabled.IsOn &&
                    ValidatePrivateKeyMaterial(jumpPrivateKeyBox.Text, jumpPassphraseBox.Password) is { } jumpKeyError)
                {
                    args.Cancel = true;
                    validationText.Text = $"跳板机{jumpKeyError}";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (ViewModel.ValidateJumpHostInput(!isTelnet && !isRemoteDesktop && jumpEnabled.IsOn, jumpHostBox.Text, jumpPortBox.Text, jumpUserBox.Text) is { } jumpError)
                {
                    args.Cancel = true;
                    validationText.Text = jumpError;
                    validationText.Visibility = Visibility.Visible;
                }
                else if (!isTelnet && !isRemoteDesktop && jumpEnabled.IsOn && existing?.JumpHost is null &&
                    string.IsNullOrWhiteSpace(jumpPasswordBox.Password) &&
                    string.IsNullOrWhiteSpace(jumpPrivateKeyBox.Text))
                {
                    args.Cancel = true;
                    validationText.Text = "首次配置跳板机时，请输入密码或私钥。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (clearCredentialCheck?.IsChecked == true &&
                    (passwordBox.Password.Length != 0 || privateKeyBox.Text.Length != 0))
                {
                    args.Cancel = true;
                    validationText.Text = "请仅选择“替换凭据”或“清除凭据”其中一项。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (libraryKeyBox.SelectedItem is ComboBoxItem { Tag: SshKeyRecord } &&
                    !string.IsNullOrWhiteSpace(privateKeyBox.Text))
                {
                    args.Cancel = true;
                    validationText.Text = "请仅选择“本机密钥库”或“粘贴/导入新私钥”其中一种方式。";
                    validationText.Visibility = Visibility.Visible;
                }
                else if (clearCredentialCheck?.IsChecked == true &&
                    libraryKeyBox.SelectedItem is ComboBoxItem { Tag: SshKeyRecord })
                {
                    args.Cancel = true;
                    validationText.Text = "选择密钥库私钥时不能同时清除凭据。";
                    validationText.Visibility = Visibility.Visible;
                }
            };

            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            if (existing is not null &&
                (passwordBox.Password.Length != 0 || privateKeyBox.Text.Length != 0) &&
                !await ConfirmCredentialMutationAsync(
                    "确认替换本机凭据？",
                    "新密码或私钥将由 Windows DPAPI 保护，并替换当前 Windows 用户保存的凭据。资产信息不会包含任何密钥材料。",
                    "替换"))
            {
                return;
            }

            if (clearCredentialCheck?.IsChecked == true &&
                !await ConfirmCredentialMutationAsync(
                    "确认清除本机凭据？",
                    "这会删除当前 Windows 用户为该资产保存的密码或私钥。服务器资产信息会保留，但下次连接前需要重新提供凭据。",
                    "清除"))
            {
                return;
            }

            if (existing is null)
            {
                ViewModel.NewAssetCommand.Execute(null);
            }
            else if (ViewModel.SelectedAsset?.Id != existing.Id)
            {
                return;
            }

            ViewModel.AssetName = nameBox.Text;
            ViewModel.Host = hostBox.Text;
            ViewModel.PortText = portBox.Text;
            ViewModel.Username = userBox.Text;
            ViewModel.AssetGroup = groupBox.Text;
            ViewModel.AssetTagsText = tagsBox.Text;
            ViewModel.AssetTransport = protocolBox.SelectedIndex switch
            {
                1 => ServerTransport.Telnet,
                2 => ServerTransport.RemoteDesktop,
                _ => ServerTransport.Ssh,
            };
            ViewModel.AssetStorageScope = storageScopeBox.SelectedIndex == 1
                ? AssetStorageScope.LocalOnly
                : AssetStorageScope.AccountSynced;
            ViewModel.IsJumpHostEnabled = ViewModel.AssetTransport == ServerTransport.Ssh && jumpEnabled.IsOn;
            ViewModel.JumpHost = jumpHostBox.Text;
            ViewModel.JumpPortText = jumpPortBox.Text;
            ViewModel.JumpUsername = jumpUserBox.Text;
            ViewModel.JumpAllowPasswordFallback = jumpFallback.IsChecked == true;
            ViewModel.JumpPassword = jumpPasswordBox.Password;
            ViewModel.JumpPrivateKey = jumpPrivateKeyBox.Text;
            ViewModel.JumpPrivateKeyPassphrase = jumpPassphraseBox.Password;
            ViewModel.AllowPasswordFallback = passwordFallbackCheck.IsChecked == true;
            if (passwordBox.Password.Length != 0)
            {
                ViewModel.Password = passwordBox.Password;
            }
            if (privateKeyBox.Text.Length != 0)
            {
                ViewModel.PrivateKey = privateKeyBox.Text;
                ViewModel.PrivateKeyPassphrase = privateKeyPassphraseBox.Password;
            }

            await ViewModel.SaveCurrentAssetAsync(CancellationToken.None);
            var savedAsset = ViewModel.SelectedAsset;
            if (savedAsset is not null && ViewModel.AssetTransport == ServerTransport.Ssh)
            {
                var selectedLibraryKey = (libraryKeyBox.SelectedItem as ComboBoxItem)?.Tag as SshKeyRecord;
                if (selectedLibraryKey is not null)
                {
                    await sshKeyLibrary.AssignToAssetAsync(selectedLibraryKey.Id, savedAsset.ToRecord(), CancellationToken.None);
                }
                else if (previouslyAssignedKey is not null)
                {
                    await sshKeyLibrary.RemoveFromAssetAsync(previouslyAssignedKey.Id, savedAsset.ToRecord(), CancellationToken.None);
                }
                await ViewModel.CheckCredentialHealthCommand.ExecuteAsync(null);
            }
            if (clearCredentialCheck?.IsChecked == true)
            {
                await ViewModel.ClearCurrentAssetCredentialAsync(CancellationToken.None);
            }
        }
        finally
        {
            isAssetDialogOpen = false;
        }
    }

    private async void EditSnippetClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedSnippet is { } selected)
        {
            await ShowSnippetEditorAsync(selected);
        }
    }

    private async void SnippetContextEditClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSnippet(sender) && ViewModel.SelectedSnippet is { } selected)
        {
            await ShowSnippetEditorAsync(selected);
        }
    }

    private async void SnippetContextInsertClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSnippet(sender))
        {
            await InsertSelectedSnippetIntoTerminalAsync();
        }
    }

    private void SnippetContextExecuteClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSnippet(sender))
        {
            ExecuteSnippetClick(sender, e);
        }
    }

    private void SnippetContextDeleteClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSnippet(sender))
        {
            DeleteSnippetClick(sender, e);
        }
    }

    private bool SelectContextSnippet(object sender)
    {
        if (sender is FrameworkElement { Tag: SnippetViewModel snippet })
        {
            ViewModel.SelectedSnippet = snippet;
            return true;
        }

        return false;
    }

    private async Task ShowSnippetEditorAsync(SnippetViewModel? selected)
    {
        if (isSnippetDialogOpen)
        {
            return;
        }

        isSnippetDialogOpen = true;
        try
        {
            var titleBox = new TextBox
            {
                Header = "标题",
                MaxLength = 120,
                Text = selected?.Title ?? string.Empty,
            };
            var categoryBox = new TextBox
            {
                Header = "分类",
                MaxLength = 80,
                Text = selected?.Category ?? "未分类",
            };
            var commandBox = new TextBox
            {
                Header = "命令",
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
                MaxLength = 8192,
                Text = selected?.Command ?? string.Empty,
            };
            var initialScope = selected?.EffectiveAssetScope ?? SnippetAssetScope.AllAssets;
            var restrictAssets = new CheckBox
            {
                Content = "仅允许指定资产使用",
                IsChecked = initialScope.IsRestricted,
            };
            var allowedAssetIds = initialScope.AssetIds.ToHashSet();
            var assetChoices = new StackPanel { Spacing = 4, Visibility = initialScope.IsRestricted ? Visibility.Visible : Visibility.Collapsed };
            foreach (var asset in ViewModel.Assets)
            {
                var choice = new CheckBox { Content = string.Concat(asset.Name, " · ", asset.Host), IsChecked = allowedAssetIds.Contains(asset.Id), Tag = asset.Id };
                choice.Checked += (sender, _) => allowedAssetIds.Add((Guid)((CheckBox)sender).Tag);
                choice.Unchecked += (sender, _) => allowedAssetIds.Remove((Guid)((CheckBox)sender).Tag);
                assetChoices.Children.Add(choice);
            }
            restrictAssets.Checked += (_, _) => assetChoices.Visibility = Visibility.Visible;
            restrictAssets.Unchecked += (_, _) => assetChoices.Visibility = Visibility.Collapsed;
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(titleBox);
            content.Children.Add(categoryBox);
            content.Children.Add(restrictAssets);
            content.Children.Add(assetChoices);
            content.Children.Add(commandBox);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = selected is null ? "新建快捷指令" : "编辑快捷指令",
                Content = content,
                PrimaryButtonText = "保存",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await ViewModel.SaveSnippetAsync(
                    selected?.Id,
                    titleBox.Text,
                    commandBox.Text,
                    categoryBox.Text,
                    restrictAssets.IsChecked == true
                        ? new SnippetAssetScope(SnippetAssetScope.SelectedAssetsMode, allowedAssetIds.ToArray())
                        : SnippetAssetScope.AllAssets,
                    CancellationToken.None);
            }
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private async void DeleteSnippetClick(object sender, RoutedEventArgs e)
    {
        if (isSnippetDialogOpen || ViewModel.SelectedSnippet is not { } selected)
        {
            return;
        }

        isSnippetDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "确认删除快捷指令？",
                Content = string.Concat("将从此设备删除“", selected.Title, "”。此操作不会影响远端服务器。"),
                PrimaryButtonText = "删除",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
                ViewModel.SelectedSnippet?.Id == selected.Id &&
                ViewModel.DeleteSnippetCommand.CanExecute(null))
            {
                ViewModel.DeleteSnippetCommand.Execute(null);
            }
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private async void InsertSnippetClick(object sender, RoutedEventArgs e)
    {
        await InsertSelectedSnippetIntoTerminalAsync();
    }

    private async Task InsertSelectedSnippetIntoTerminalAsync()
    {
        var command = await ResolveSelectedSnippetAsync();
        if (command is null)
        {
            return;
        }

        try
        {
            if (!ViewModel.TryPrepareResolvedSnippetForTerminalInput(command))
            {
                return;
            }

            await ActiveTerminalView.InsertTextAtPromptAsync(command);
            ActiveTerminalView.FocusTerminal();
        }
        catch (ArgumentException)
        {
            await ShowAccountMessageAsync("无法插入快捷指令", "该快捷指令包含不允许直接写入终端的内容。");
        }
    }

    private async void ExecuteSnippetClick(object sender, RoutedEventArgs e)
    {
        var command = await ResolveSelectedSnippetAsync();
        if (command is not null)
        {
            await ViewModel.ExecuteResolvedSnippetAsync(command, CancellationToken.None);
        }
    }

    private void OpenBatchCommandClick(object sender, RoutedEventArgs e)
    {
        if (batchCommandWindow is not null)
        {
            batchCommandWindow.Activate();
            return;
        }

        ViewModel.PrepareBatchCommandWorkspace();
        var window = new BatchCommandWindow(ViewModel, windowHandle, Root.ActualTheme);
        batchCommandWindow = window;
        window.Closed += (_, _) =>
        {
            if (ReferenceEquals(batchCommandWindow, window))
            {
                batchCommandWindow = null;
            }
        };
        window.ShowOwned();
    }

    private async Task<string?> ResolveSelectedSnippetAsync()
    {
        if (isSnippetDialogOpen || ViewModel.SelectedSnippet is not { } selected)
        {
            return null;
        }

        var variables = SnippetVariableResolver.Extract(selected.Command);
        if (variables.Count == 0)
        {
            return selected.Command;
        }

        isSnippetDialogOpen = true;
        try
        {
            var inputs = new Dictionary<string, TextBox>(StringComparer.Ordinal);
            var content = new StackPanel { Spacing = 12 };
            var validationText = new TextBlock
            {
                Text = "变量值最多 1024 个字符，且不能包含换行或控制字符。",
                TextWrapping = TextWrapping.Wrap,
            };
            foreach (var variable in variables)
            {
                var input = new TextBox
                {
                    Header = variable,
                    MaxLength = 1024,
                };
                inputs.Add(variable, input);
                content.Children.Add(input);
            }
            content.Children.Add(validationText);

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "填写快捷指令变量",
                Content = content,
                PrimaryButtonText = "应用",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
            };
            dialog.PrimaryButtonClick += (_, args) =>
            {
                try
                {
                    var candidateValues = inputs.ToDictionary(item => item.Key, item => item.Value.Text, StringComparer.Ordinal);
                    SnippetVariableResolver.Resolve(selected.Command, candidateValues);
                }
                catch (ArgumentException)
                {
                    args.Cancel = true;
                    validationText.Text = "变量值不能包含换行或控制字符，且长度不能超过 1024 个字符。";
                    validationText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 196, 43, 28));
                }
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return null;
            }

            var values = inputs.ToDictionary(item => item.Key, item => item.Value.Text, StringComparer.Ordinal);
            return SnippetVariableResolver.Resolve(selected.Command, values);
        }
        catch (ArgumentException)
        {
            return null;
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private void CopyDiagnosticsClick(object sender, RoutedEventArgs e)
    {
        var diagnostics = ViewModel.PrepareDiagnosticsBundleCopy();
        var package = new DataPackage();
        package.SetText(diagnostics);
        Clipboard.SetContent(package);
    }

    private void CheckCredentialHealthClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.CheckCredentialHealthCommand.CanExecute(null))
        {
            ViewModel.CheckCredentialHealthCommand.Execute(null);
        }
    }

    private async void ManageAccountClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsAccountSignedIn)
        {
            await ShowAccountSignInDialogAsync();
            return;
        }

        await ShowPersonalCenterDialogAsync();
    }

    private async Task ShowPersonalCenterDialogAsync()
    {
        string? requestedAction = null;
        ContentDialog? dialog = null;
        var content = new StackPanel { Spacing = 12, MinWidth = 460 };
        var accountCard = new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            Background = ResourceBrush("OrbitAccentSoftBrush"),
            BorderBrush = ResourceBrush("OrbitPanelStrokeBrush"),
            BorderThickness = new Thickness(1),
            Child = new StackPanel
            {
                Spacing = 4,
                Children =
                {
                    new TextBlock { Text = "当前账户", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ResourceBrush("OrbitPrimaryTextBrush") },
                    new TextBlock { Text = ViewModel.AccountUsername, FontSize = 15, Foreground = ResourceBrush("OrbitPrimaryTextBrush") },
                    new TextBlock
                    {
                        Text = ViewModel.AccountStatus,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
                    },
                },
            },
        };
        content.Children.Add(accountCard);

        Button ActionButton(string label, string action)
        {
            var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch };
            button.Click += (_, _) =>
            {
                requestedAction = action;
                dialog?.Hide();
            };
            return button;
        }

        content.Children.Add(ActionButton(ViewModel.IsAccountLocked ? "解锁工作站" : "锁定工作站", "lock"));
        content.Children.Add(ActionButton("修改登录密码", "password"));
        content.Children.Add(new TextBlock
        {
            Text = "主密码轮换会在本机重新加密全部云端资产、快捷指令和最近删除记录；服务器只接收密文。完成后其他设备必须使用新主密码重新解锁。",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
        });
        var rotateMaster = ActionButton("修改主密码", "master-password");
        rotateMaster.IsEnabled = ViewModel.IsAccountUnlocked;
        content.Children.Add(rotateMaster);
        content.Children.Add(ActionButton("导出脱敏诊断", "diagnostics"));
        content.Children.Add(ActionButton("退出或切换账户", "signout"));

        dialog = CreateThemedDialog(
            "个人中心",
            new ScrollViewer
            {
                MaxHeight = 560,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = content,
            });
        await dialog.ShowAsync();

        switch (requestedAction)
        {
            case "lock":
                if (ViewModel.IsAccountLocked)
                {
                    await ShowAccountUnlockDialogAsync();
                }
                else
                {
                    ViewModel.LockAccount();
                }
                break;
            case "password":
                await ShowChangeLoginPasswordDialogAsync();
                break;
            case "master-password":
                await ShowRotateMasterPasswordDialogAsync();
                break;
            case "diagnostics":
                CopyDiagnosticsClick(this, new RoutedEventArgs());
                await ShowAccountMessageAsync("已复制", "脱敏诊断信息已复制到剪贴板。");
                break;
            case "signout":
                if (await ConfirmCredentialMutationAsync(
                    "退出当前账户？",
                    "本机会话令牌将被清除；本机资产不会交给下一个账户。",
                    "退出登录"))
                {
                    await ViewModel.SignOutAccountAsync(CancellationToken.None);
                }
                break;
        }
    }

    private async Task ShowRotateMasterPasswordDialogAsync()
    {
        var currentMaster = new PasswordBox { Header = "当前主密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var nextMaster = new PasswordBox { Header = "新主密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var confirmation = new PasswordBox { Header = "确认新主密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var loginPassword = new PasswordBox { Header = "确认当前登录密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var content = new StackPanel { Spacing = 10, MinWidth = 460 };
        content.Children.Add(new TextBlock
        {
            Text = "此操作会读取完整云端密文快照并在本机重新加密，随后一次性原子提交。过程中密码不会发送到服务器。",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(currentMaster);
        content.Children.Add(nextMaster);
        content.Children.Add(confirmation);
        content.Children.Add(loginPassword);
        var dialog = CreateThemedDialog(
            "修改主密码",
            content,
            primaryButtonText: "继续安全轮换",
            closeButtonText: "取消");
        dialog.DefaultButton = ContentDialogButton.Close;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        var currentValue = currentMaster.Password;
        var nextValue = nextMaster.Password;
        var confirmationValue = confirmation.Password;
        var loginValue = loginPassword.Password;
        currentMaster.Password = nextMaster.Password = confirmation.Password = loginPassword.Password = string.Empty;
        if (!await ConfirmCredentialMutationAsync(
                "确认轮换主密码？",
                "全部云端资产、快捷指令和最近删除记录都会重新加密；其他设备随后必须使用新主密码解锁。",
                "确认轮换"))
        {
            return;
        }

        var changed = await ViewModel.RotateMasterPasswordAsync(
            currentValue,
            nextValue,
            confirmationValue,
            loginValue,
            CancellationToken.None);
        await ShowAccountMessageAsync(changed ? "主密码已更新" : "无法更新主密码", ViewModel.AccountStatus);
    }

    private async Task ShowChangeLoginPasswordDialogAsync()
    {
        var current = new PasswordBox { Header = "当前登录密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var next = new PasswordBox { Header = "新登录密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var confirmation = new PasswordBox { Header = "确认新登录密码", PasswordRevealMode = PasswordRevealMode.Hidden };
        var content = new StackPanel { Spacing = 10, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = "新密码至少 12 位，并应包含大写字母、小写字母、数字和特殊字符。修改后其他设备需要重新登录。",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(current);
        content.Children.Add(next);
        content.Children.Add(confirmation);
        var dialog = CreateThemedDialog(
            "修改登录密码",
            content,
            primaryButtonText: "更新密码",
            closeButtonText: "取消");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        var oldPassword = current.Password;
        var newPassword = next.Password;
        var confirmedPassword = confirmation.Password;
        current.Password = next.Password = confirmation.Password = string.Empty;
        var changed = await ViewModel.ChangeAccountPasswordAsync(
            oldPassword,
            newPassword,
            confirmedPassword,
            CancellationToken.None);
        await ShowAccountMessageAsync(changed ? "密码已更新" : "无法更新密码", ViewModel.AccountStatus);
    }

    private async void SynchronizeAccountClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsAccountUnlocked)
        {
            await ShowAccountUnlockDialogAsync();
            return;
        }

        // The footer is itself the synchronization status surface. Avoid a
        // second modal acknowledgement after a user-triggered reconciliation.
        await ViewModel.SynchronizeEncryptedConfigsAsync(
            string.Empty,
            CancellationToken.None,
            forceCompleteReconciliation: true);
    }

    private async void PublishLocalAssetsClick(object sender, RoutedEventArgs e)
    {
        await ShowPublishLocalAssetsDialogAsync();
    }

    private void LockAccountClick(object sender, RoutedEventArgs e)
    {
        ViewModel.LockAccount();
    }

    private async Task ShowAccountSignInDialogAsync()
    {
        var isLoginMode = true;
        var usernameBox = new TextBox
        {
            Header = "邮箱账号",
            PlaceholderText = "输入邮箱账号",
        };
        AutomationProperties.SetName(usernameBox, "OrbitTerm account username");
        var passwordBox = new PasswordBox
        {
            Header = "账户密码",
            PasswordRevealMode = PasswordRevealMode.Peek,
        };
        AutomationProperties.SetName(passwordBox, "OrbitTerm account password");
        var inviteCodeBox = new TextBox
        {
            Header = "邀请码",
            PlaceholderText = "管理员提供的邀请码",
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(inviteCodeBox, "OrbitTerm registration invite code");
        var passwordRequirement = new TextBlock
        {
            Text = "密码至少 12 位，且包含大小写字母、数字和特殊字符。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            Visibility = Visibility.Collapsed,
        };
        var validationText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 219, 74, 63)),
            Visibility = Visibility.Collapsed,
        };
        var termsAcceptedBox = new CheckBox
        {
            Content = "我已阅读并同意",
            IsChecked = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(termsAcceptedBox, "同意使用条款、免责声明与隐私说明");
        var termsLinkButton = new Button
        {
            Content = "《使用条款、免责声明与隐私说明》",
            Padding = new Thickness(4, 2, 4, 2),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            Foreground = ResourceBrush("OrbitAccentBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        termsLinkButton.Click += ShowTermsClick;
        var termsRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
        };
        termsRow.Children.Add(termsAcceptedBox);
        termsRow.Children.Add(termsLinkButton);
        var loginModeButton = new ToggleButton
        {
            Content = "登录",
            IsChecked = true,
            MinHeight = 36,
            Padding = new Thickness(12, 5, 12, 5),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        var registerModeButton = new ToggleButton
        {
            Content = "注册",
            MinHeight = 36,
            Padding = new Thickness(12, 5, 12, 5),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        var modeGrid = new Grid { ColumnSpacing = 2 };
        modeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        modeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(registerModeButton, 1);
        modeGrid.Children.Add(loginModeButton);
        modeGrid.Children.Add(registerModeButton);
        var modeSurface = new Border
        {
            Padding = new Thickness(2),
            CornerRadius = new CornerRadius(10),
            Background = ResourceBrush("OrbitMetricBrush"),
            BorderBrush = ResourceBrush("OrbitPanelStrokeBrush"),
            BorderThickness = new Thickness(1),
            Child = modeGrid,
        };

        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(modeSurface);
        content.Children.Add(usernameBox);
        content.Children.Add(passwordBox);
        content.Children.Add(inviteCodeBox);
        content.Children.Add(passwordRequirement);
        content.Children.Add(termsRow);
        content.Children.Add(validationText);
        var dialog = CreateThemedDialog(
            "登录 OrbitTerm 账户",
            content,
            primaryButtonText: "登录",
            closeButtonText: "取消");

        void ApplyMode(bool login)
        {
            isLoginMode = login;
            loginModeButton.IsChecked = login;
            registerModeButton.IsChecked = !login;
            inviteCodeBox.Visibility = login ? Visibility.Collapsed : Visibility.Visible;
            passwordRequirement.Visibility = login ? Visibility.Collapsed : Visibility.Visible;
            dialog.Title = login ? "登录 OrbitTerm 账户" : "注册 OrbitTerm 账户";
            dialog.PrimaryButtonText = login ? "登录" : "注册并登录";
            validationText.Visibility = Visibility.Collapsed;
        }

        loginModeButton.Click += (_, _) => ApplyMode(true);
        registerModeButton.Click += (_, _) => ApplyMode(false);
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (termsAcceptedBox.IsChecked != true)
            {
                validationText.Text = "请先勾选同意使用条款、免责声明与隐私说明。";
                validationText.Visibility = Visibility.Visible;
                args.Cancel = true;
                return;
            }
            if (isLoginMode)
            {
                if (!string.IsNullOrWhiteSpace(usernameBox.Text) && !string.IsNullOrWhiteSpace(passwordBox.Password))
                {
                    return;
                }
                validationText.Text = "请输入邮箱账号和账户密码。";
            }
            else if (!IsValidRegistrationInput(usernameBox.Text, passwordBox.Password, inviteCodeBox.Text, out var validationMessage))
            {
                validationText.Text = validationMessage;
            }
            else
            {
                return;
            }

            validationText.Visibility = Visibility.Visible;
            args.Cancel = true;
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        var username = usernameBox.Text;
        var password = passwordBox.Password;
        var inviteCode = inviteCodeBox.Text;
        passwordBox.Password = string.Empty;
        hasPromptedForAccountUnlockThisLaunch = true;
        var signedIn = isLoginMode
            ? await ViewModel.SignInAccountAsync(username, password, CancellationToken.None)
            : await ViewModel.RegisterAccountAsync(username, password, inviteCode, CancellationToken.None);
        if (signedIn)
        {
            if (isLoginMode)
            {
                await ShowAccountUnlockDialogAsync();
            }
            else
            {
                await ShowInitialMasterPasswordSetupDialogAsync();
            }
        }
        else
        {
            hasPromptedForAccountUnlockThisLaunch = false;
            await ShowAccountMessageAsync(isLoginMode ? "登录未完成" : "注册未完成", ViewModel.AccountStatus);
        }
    }

    private static bool IsValidRegistrationInput(
        string username,
        string password,
        string inviteCode,
        out string message)
    {
        var parts = username.Trim().Split('@', StringSplitOptions.None);
        if (parts.Length != 2 || parts[0].Length == 0 || parts[1].Length == 0)
        {
            message = "请输入有效的邮箱账号。";
            return false;
        }
        if (password.Length < 12 ||
            !password.Any(char.IsUpper) ||
            !password.Any(char.IsLower) ||
            !password.Any(char.IsDigit) ||
            !password.Any(character => !char.IsLetterOrDigit(character) && !char.IsWhiteSpace(character)))
        {
            message = "密码至少 12 位，且包含大小写字母、数字和特殊字符。";
            return false;
        }
        if (string.IsNullOrWhiteSpace(inviteCode))
        {
            message = "请输入管理员提供的邀请码。";
            return false;
        }

        message = string.Empty;
        return true;
    }

    private async Task ShowInitialMasterPasswordSetupDialogAsync()
    {
        var passwordBox = new PasswordBox
        {
            Header = "设置主密码",
            PasswordRevealMode = PasswordRevealMode.Peek,
        };
        var confirmationBox = new PasswordBox
        {
            Header = "确认主密码",
            PasswordRevealMode = PasswordRevealMode.Peek,
        };
        var validationText = new TextBlock
        {
            Text = "主密码至少 12 位；它用于端到端加密服务器资产。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(passwordBox);
        content.Children.Add(confirmationBox);
        content.Children.Add(validationText);
        var switchAccountButton = new Button
        {
            Content = "使用其他账号",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        content.Children.Add(switchAccountButton);
        var dialog = CreateThemedDialog(
            "设置主密码",
            content,
            primaryButtonText: "保存并解锁",
            closeButtonText: "稍后设置");
        var switchAccountRequested = false;
        switchAccountButton.Click += (_, _) =>
        {
            switchAccountRequested = true;
            dialog.Hide();
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (passwordBox.Password.Length >= 12 &&
                string.Equals(passwordBox.Password, confirmationBox.Password, StringComparison.Ordinal))
            {
                return;
            }

            validationText.Text = "主密码至少 12 位，且两次输入必须一致。";
            validationText.Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 219, 74, 63));
            args.Cancel = true;
        };
        var result = await dialog.ShowAsync();
        if (switchAccountRequested)
        {
            passwordBox.Password = string.Empty;
            confirmationBox.Password = string.Empty;
            if (!await ConfirmAndSwitchAccountAsync() && ViewModel.IsAccountLocked)
            {
                await ShowInitialMasterPasswordSetupDialogAsync();
            }
            return;
        }
        if (result != ContentDialogResult.Primary)
        {
            passwordBox.Password = string.Empty;
            confirmationBox.Password = string.Empty;
            return;
        }

        var masterPassword = passwordBox.Password;
        var confirmation = confirmationBox.Password;
        passwordBox.Password = string.Empty;
        confirmationBox.Password = string.Empty;
        var outcome = await ViewModel.InitializeNewAccountMasterPasswordAsync(
            masterPassword,
            confirmation,
            CancellationToken.None);
        if (outcome != AccountUnlockResult.Unlocked)
        {
            await ShowAccountMessageAsync("无法设置主密码", ViewModel.AccountStatus);
        }
    }

    private async Task ShowAccountUnlockDialogAsync()
    {
        var passwordBox = new PasswordBox
        {
            Header = "主密码",
            PasswordRevealMode = PasswordRevealMode.Hidden,
        };
        AutomationProperties.SetName(passwordBox, "OrbitTerm master password");
        var validationText = new TextBlock
        {
            Text = "请输入主密码以解锁本次运行的加密同步数据。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var progressRing = new ProgressRing
        {
            Width = 18,
            Height = 18,
            IsActive = false,
            Visibility = Visibility.Collapsed,
        };
        var progressText = new TextBlock
        {
            Text = "正在验证…",
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        var progressRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
        };
        progressRow.Children.Add(progressRing);
        progressRow.Children.Add(progressText);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = "主密码不会写入磁盘。验证成功后仅在本次应用运行期间保留于受控内存，用于自动加密同步；锁定、退出或关闭应用时立即清零。",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(passwordBox);
        content.Children.Add(validationText);
        content.Children.Add(progressRow);
        var switchAccountButton = new Button
        {
            Content = "使用其他账号",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        content.Children.Add(switchAccountButton);
        var dialog = CreateThemedDialog(
            "解锁加密同步数据",
            content,
            primaryButtonText: "解锁",
            closeButtonText: "取消");
        var switchAccountRequested = false;
        switchAccountButton.Click += (_, _) =>
        {
            switchAccountRequested = true;
            dialog.Hide();
        };
        AccountUnlockResult? outcome = null;
        var verificationInProgress = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (verificationInProgress)
            {
                args.Cancel = true;
                return;
            }

            if (string.IsNullOrEmpty(passwordBox.Password))
            {
                args.Cancel = true;
                validationText.Text = "请输入主密码后重试。";
                validationText.Foreground = ResourceBrush("OrbitDangerBrush");
                passwordBox.Focus(FocusState.Programmatic);
                return;
            }

            var deferral = args.GetDeferral();
            args.Cancel = true;
            verificationInProgress = true;
            dialog.IsPrimaryButtonEnabled = false;
            passwordBox.IsEnabled = false;
            validationText.Text = "正在安全验证主密码，请稍候。";
            validationText.Foreground = ResourceBrush("OrbitMutedTextBrush");
            progressRing.Visibility = Visibility.Visible;
            progressRing.IsActive = true;
            progressText.Visibility = Visibility.Visible;
            try
            {
                var password = passwordBox.Password;
                passwordBox.Password = string.Empty;
                outcome = await ViewModel.UnlockAccountAsync(password, CancellationToken.None);
                if (outcome is AccountUnlockResult.Unlocked or AccountUnlockResult.VerificationRequiresEncryptedConfig)
                {
                    args.Cancel = false;
                    return;
                }

                validationText.Text = ViewModel.AccountStatus;
                validationText.Foreground = ResourceBrush("OrbitDangerBrush");
            }
            finally
            {
                verificationInProgress = false;
                dialog.IsPrimaryButtonEnabled = true;
                passwordBox.IsEnabled = true;
                progressRing.IsActive = false;
                progressRing.Visibility = Visibility.Collapsed;
                progressText.Visibility = Visibility.Collapsed;
                if (args.Cancel)
                {
                    passwordBox.Focus(FocusState.Programmatic);
                }
                deferral.Complete();
            }
        };

        var result = await dialog.ShowAsync();
        passwordBox.Password = string.Empty;
        if (switchAccountRequested)
        {
            if (!await ConfirmAndSwitchAccountAsync() && ViewModel.IsAccountLocked)
            {
                await ShowAccountUnlockDialogAsync();
            }
            return;
        }
        if (result == ContentDialogResult.Primary &&
            outcome == AccountUnlockResult.VerificationRequiresEncryptedConfig)
        {
            await ShowInitialMasterPasswordSetupDialogAsync();
        }
    }

    private async Task<bool> ConfirmAndSwitchAccountAsync()
    {
        var accountLabel = MaskAccountIdentity(ViewModel.AccountUsername);
        if (!await ConfirmCredentialMutationAsync(
                "使用其他账号？",
                $"当前账号：{accountLabel}\n\n将断开当前账号的所有会话、传输、持续任务和端口映射，并清除本次运行中的主密码及令牌。随账号同步的数据和待同步操作继续隔离保存；标记为“仅本机”的资产属于当前 Windows 用户的本机工作区，切换账号后仍可见。",
                "切换账号"))
        {
            return false;
        }

        await ViewModel.SignOutAccountAsync(CancellationToken.None);
        hasPromptedForAccountUnlockThisLaunch = false;
        return true;
    }

    private static string MaskAccountIdentity(string value)
    {
        var normalized = value.Trim();
        if (normalized.Length == 0)
        {
            return "当前已登录账号";
        }

        var at = normalized.IndexOf('@');
        if (at > 0)
        {
            var local = normalized[..at];
            var maskedLocal = local.Length switch
            {
                1 => "*",
                2 => string.Concat(local[0], "*"),
                _ => string.Concat(local[0], new string('*', Math.Min(local.Length - 2, 4)), local[^1]),
            };
            return string.Concat(maskedLocal, normalized[at..]);
        }

        return normalized.Length <= 2
            ? new string('*', normalized.Length)
            : string.Concat(normalized[0], new string('*', Math.Min(normalized.Length - 2, 4)), normalized[^1]);
    }

    private async Task ShowEncryptedSyncDialogAsync()
    {
        if (!ViewModel.IsAccountUnlocked)
        {
            await ShowAccountUnlockDialogAsync();
            return;
        }
        await ViewModel.SynchronizeEncryptedConfigsAsync(
            string.Empty,
            CancellationToken.None,
            forceCompleteReconciliation: true);
        await ShowAccountMessageAsync("账户与同步", ViewModel.AccountStatus);
    }

    private async Task ShowPublishLocalAssetsDialogAsync()
    {
        if (!ViewModel.IsAccountUnlocked)
        {
            await ShowAccountUnlockDialogAsync();
            return;
        }
        if (!await ConfirmCredentialMutationAsync(
                "发布本机资产？",
                "将使用本次运行已解锁的密钥加密并上传本机资产；不会再次要求输入主密码。",
                "发布"))
        {
            return;
        }
        await ViewModel.PublishLocalAssetsAsync(string.Empty, CancellationToken.None);
        await ShowAccountMessageAsync("账户与同步", ViewModel.AccountStatus);
    }

    private async Task ShowAccountMessageAsync(string title, string message)
    {
        var dialog = CreateThemedDialog(
            title,
            new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            closeButtonText: "知道了");
        await dialog.ShowAsync();
    }

    private async Task<bool> ConfirmCredentialMutationAsync(string title, string description, string action)
    {
        var dialog = CreateThemedDialog(
            title,
            new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap },
            primaryButtonText: action,
            closeButtonText: "取消");
        dialog.DefaultButton = ContentDialogButton.Close;
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private void SelectWorkspaceTab1Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(0);
    }

    private void SelectWorkspaceTab2Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(1);
    }

    private void SelectWorkspaceTab3Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(2);
    }

    private void SelectWorkspaceTab4Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(3);
    }

    private void SelectWorkspaceTab5Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(4);
    }

    private void SelectWorkspaceTab6Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(5);
    }

    private void SelectWorkspaceTab7Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(6);
    }

    private void SelectWorkspaceTab8Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(7);
    }

    private void SelectWorkspaceTab9Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(8);
    }

    private void TerminalLinesCollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        RequestTerminalScrollToEnd();
    }

    private void TerminalScrollViewerViewChanged(object sender, ScrollViewerViewChangedEventArgs e)
    {
        if (!e.IsIntermediate)
        {
            ViewModel.SaveTerminalScrollOffset(TerminalScrollViewer.VerticalOffset);
        }
    }

    private void RestoreTerminalScrollPosition()
    {
        pendingTerminalScrollOffset = ViewModel.SelectedWorkspaceTab?.TerminalScrollOffset ?? 0;
        terminalScrollRestoreTimer.Stop();
        terminalScrollRestoreTimer.Start();
    }

    private void TerminalScrollRestoreTimerTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        var target = Math.Clamp(pendingTerminalScrollOffset, 0, TerminalScrollViewer.ScrollableHeight);
        TerminalScrollViewer.ChangeView(null, target, null, true);
    }

    private void RequestTerminalScrollToEnd()
    {
        if (!ViewModel.IsAutoScrollEnabled)
        {
            return;
        }

        terminalAutoScrollTimer.Stop();
        terminalAutoScrollTimer.Start();
    }

    private void TerminalAutoScrollTimerTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (ViewModel.IsAutoScrollEnabled)
        {
            NativeTerminalView.RequestAutoScrollToLatestOutput();
        }
    }

    private void UpdateTerminalEmptyState()
    {
        var becameOpen = ViewModel.IsTerminalOpen && !terminalWasOpen;
        terminalWasOpen = ViewModel.IsTerminalOpen;
        TerminalEmptyState.Visibility = ViewModel.IsTerminalOpen
            ? Visibility.Collapsed
            : Visibility.Visible;
        NativeTerminalView.IsInputEnabled = ViewModel.IsTerminalOpen;

        // Focus only for the closed -> open transition. Re-running a generic
        // workbench refresh must never steal focus from search, settings,
        // asset editing, or another application shortcut target.
        if (becameOpen)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (ViewModel.IsTerminalOpen)
                {
                    NativeTerminalView.FocusTerminal();
                }
            });
        }
    }

    private async void NativeTerminalViewPasteRequested(object? sender, EventArgs e)
    {
        var clipboardContent = Clipboard.GetContent();
        if (!clipboardContent.Contains(StandardDataFormats.Text))
        {
            return;
        }

        var pastedText = NormalizeTerminalPaste(await clipboardContent.GetTextAsync());
        if (pastedText.Length == 0)
        {
            return;
        }

        var byteCount = Encoding.UTF8.GetByteCount(pastedText);
        if (byteCount > 8 * 1024)
        {
            await ShowAccountMessageAsync("终端粘贴未执行", "粘贴内容超过 8 KB 限制。请拆分后再试。");
            return;
        }

        var executeAfterPaste = false;
        if (pastedText.Contains('\n'))
        {
            var lineCount = pastedText.Count(character => character == '\n') + 1;
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "确认粘贴多行终端内容",
                Content = new StackPanel
                {
                    Spacing = 8,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = $"检测到 {lineCount} 行内容。“合并为单行并执行”会用分号连接每一行后执行一次；“逐行粘贴并执行”会保留换行并按原顺序执行。请确认内容可信。",
                            TextWrapping = TextWrapping.Wrap,
                        },
                        new TextBox
                        {
                            Text = pastedText.Length > 1200 ? pastedText[..1200] + "\n…（预览已截断）" : pastedText,
                            IsReadOnly = true,
                            AcceptsReturn = true,
                            MaxHeight = 180,
                            TextWrapping = TextWrapping.Wrap,
                        },
                    },
                },
                PrimaryButtonText = "合并为单行并执行",
                SecondaryButtonText = "逐行粘贴并执行",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            var result = await dialog.ShowAsync();
            if (result == ContentDialogResult.None)
            {
                return;
            }
            executeAfterPaste = true;
            if (result == ContentDialogResult.Primary)
            {
                pastedText = string.Join(
                    "; ",
                    pastedText.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                if (pastedText.Length == 0)
                {
                    return;
                }
            }
        }

        if (executeAfterPaste && pastedText[^1] is not ('\r' or '\n'))
        {
            pastedText += "\r";
        }
        if (sender is NativeTerminalView terminalView &&
            terminalSplitSurfaces.Values.FirstOrDefault(surface => ReferenceEquals(surface.TerminalView, terminalView)) is { } splitSurface)
        {
            SetActiveTerminalSurface(terminalView, splitSurface.Pane.Id);
            await terminalView.SendApprovedPasteAsync(pastedText);
        }
        else
        {
            SetActiveTerminalSurface(NativeTerminalView, null);
            await NativeTerminalView.SendApprovedPasteAsync(pastedText);
        }
    }

    private static string NormalizeTerminalPaste(string value)
    {
        var normalized = value.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var builder = new StringBuilder(normalized.Length);
        foreach (var character in normalized)
        {
            if (!char.IsControl(character) || character is '\n' or '\t')
            {
                builder.Append(character);
            }
        }

        return builder.ToString();
    }

    private void UpdateAssetEmptyState()
    {
        AssetEmptyState.Visibility = ViewModel.HasAssetSearchResults
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void SftpPathTextBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && TryExecuteViewModelCommand("PrepareSftpBrowseCommand"))
        {
            e.Handled = true;
        }
    }

    private void SftpEntriesSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ListView listView)
        {
            ViewModel.SetSelectedSftpEntries(listView.SelectedItems.OfType<SftpDirectoryEntryViewModel>());
        }
    }

    private void SftpBreadcrumbClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string path } && !string.IsNullOrWhiteSpace(path))
        {
            ViewModel.SftpPathText = path;
            TryExecuteViewModelCommand("PrepareSftpBrowseCommand");
        }
    }

    private async void SftpEntriesDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ViewModel.SelectedSftpEntry is { IsDirectory: false })
        {
            await PreviewSelectedSftpEntryAsync();
            e.Handled = true;
        }
        else if (TryExecuteViewModelCommand("OpenSelectedSftpEntryCommand"))
        {
            e.Handled = true;
        }
    }

    private async void SftpEntriesKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                if (ViewModel.SelectedSftpEntry is { IsDirectory: false })
                {
                    await PreviewSelectedSftpEntryAsync();
                }
                else
                {
                    TryExecuteViewModelCommand("OpenSelectedSftpEntryCommand");
                }
                e.Handled = true;
                break;
            case VirtualKey.Back:
                TryExecuteViewModelCommand("GoParentSftpCommand");
                e.Handled = true;
                break;
            case VirtualKey.F2:
                RenameSelectedSftpEntryClick(sender, new RoutedEventArgs());
                e.Handled = true;
                break;
            case VirtualKey.Delete:
                RemoveSelectedSftpEntryClick(sender, new RoutedEventArgs());
                e.Handled = true;
                break;
        }
    }

    private void SftpEntryPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (e.OriginalSource is FrameworkElement element &&
            FindParentListViewItem(element) is { IsSelected: false } item &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitMetricBrush"] is Brush hoverBrush)
        {
            item.Background = hoverBrush;
        }
    }

    private void SftpEntryPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (e.OriginalSource is FrameworkElement element &&
            FindParentListViewItem(element) is { IsSelected: false } item &&
            Microsoft.UI.Xaml.Application.Current.Resources["OrbitPanelBrush"] is Brush normalBrush)
        {
            item.Background = normalBrush;
        }
    }

    private static ListViewItem? FindParentListViewItem(DependencyObject element)
    {
        DependencyObject? current = element;
        while (current is not null)
        {
            if (current is ListViewItem item)
            {
                return item;
            }

            current = VisualTreeHelper.GetParent(current);
        }

        return null;
    }

    private void SftpEntryContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: SftpDirectoryEntryViewModel entry } target)
        {
            return;
        }

        var flyout = CreateSftpOperationsFlyout(
            entry,
            SftpEntriesList.SelectedItems.OfType<SftpDirectoryEntryViewModel>());

        if (e.TryGetPosition(target, out var position))
        {
            flyout.ShowAt(target, position);
        }
        else
        {
            flyout.ShowAt(target);
        }

        e.Handled = true;
        QueueDefaultPointerCursorRestore();
    }

    private void SftpMoreClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement target)
        {
            return;
        }

        if (ViewModel.SelectedSftpEntry is not { } entry)
        {
            SftpRecentOperationsButton.Flyout?.ShowAt(target);
            QueueDefaultPointerCursorRestore();
            return;
        }

        var selection = ViewModel.SelectedSftpEntries.Count > 0
            ? ViewModel.SelectedSftpEntries
            : [entry];
        var flyout = CreateSftpOperationsFlyout(entry, selection);
        flyout.Items.Add(new MenuFlyoutSeparator());
        var recent = new MenuFlyoutItem
        {
            Text = "最近操作",
            IsEnabled = ViewModel.HasRecentSftpOperations,
        };
        recent.Click += (_, _) => Root.DispatcherQueue.TryEnqueue(() =>
            SftpRecentOperationsButton.Flyout?.ShowAt(target));
        flyout.Items.Add(recent);
        flyout.ShowAt(target);
        QueueDefaultPointerCursorRestore();
    }

    private MenuFlyout CreateSftpOperationsFlyout(
        SftpDirectoryEntryViewModel entry,
        IEnumerable<SftpDirectoryEntryViewModel> selectedEntries)
    {
        var policy = SftpContextMenuPolicy.Resolve(entry, selectedEntries);

        var canUseSftp = ViewModel.IsSftpOpen;
        var canMutateSingleEntry = canUseSftp && !ViewModel.IsSftpPreviewDirty;
        var canChangePermissions = canMutateSingleEntry &&
            (entry.PermissionsOctal & 0xF000U) is 0x4000U or 0x8000U;
        var flyout = new MenuFlyout();

        if (policy.ShowEnterDirectory)
        {
            flyout.Items.Add(CreateSftpContextItem(
                "进入文件夹",
                entry,
                canUseSftp,
                SftpContextOpenClick));
        }

        if (policy.ShowPreviewOrEdit)
        {
            flyout.Items.Add(CreateSftpContextItem(
                "预览 / 编辑文件",
                entry,
                canUseSftp,
                SftpContextPreviewClick));
        }

        flyout.Items.Add(CreateSftpContextItem(
            policy.DownloadText,
            entry,
            canUseSftp && !ViewModel.IsSftpBatchRunning,
            SftpContextDownloadClick));
        flyout.Items.Add(new MenuFlyoutSeparator());

        if (policy.ShowRename)
        {
            flyout.Items.Add(CreateSftpContextItem(
                policy.RenameText,
                entry,
                canMutateSingleEntry,
                SftpContextRenameClick));
        }

        if (policy.ShowPermissions)
        {
            flyout.Items.Add(CreateSftpContextItem(
                policy.PermissionsText,
                entry,
                canChangePermissions,
                SftpContextPermissionsClick));
        }

        flyout.Items.Add(CreateSftpContextItem(
            policy.DeleteText,
            entry,
            canUseSftp && !ViewModel.IsSftpBatchRunning && !ViewModel.IsSftpPreviewDirty,
            SftpContextDeleteClick));

        // Construct the final menu before it is shown. This avoids changing a
        // MenuFlyout's visual tree from its Opening callback, which can leave
        // WinUI's temporary busy cursor cached until the next pointer move.
        flyout.Opened += (_, _) => QueueDefaultPointerCursorRestore();
        flyout.Closed += (_, _) => QueueDefaultPointerCursorRestore();
        return flyout;
    }

    private static MenuFlyoutItem CreateSftpContextItem(
        string text,
        SftpDirectoryEntryViewModel entry,
        bool isEnabled,
        RoutedEventHandler clickHandler)
    {
        var item = new MenuFlyoutItem
        {
            Text = text,
            Tag = entry,
            IsEnabled = isEnabled,
        };
        item.Click += clickHandler;
        return item;
    }

    private void QueueDefaultPointerCursorRestore()
    {
        RestoreDefaultPointerCursor();
        Root.DispatcherQueue.TryEnqueue(RestoreDefaultPointerCursor);
    }

    private static void RestoreDefaultPointerCursor()
    {
        var arrowCursor = LoadCursor(IntPtr.Zero, new IntPtr(ArrowCursorResourceId));
        if (arrowCursor != IntPtr.Zero)
        {
            SetCursor(arrowCursor);
        }
    }

    private void SftpContextOpenClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender))
        {
            TryExecuteViewModelCommand("OpenSelectedSftpEntryCommand");
        }
    }

    private async void SftpContextPreviewClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender))
        {
            await PreviewSelectedSftpEntryAsync();
        }
    }

    private async void PreviewSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        await PreviewSelectedSftpEntryAsync();
    }

    private async Task PreviewSelectedSftpEntryAsync()
    {
        if (!ViewModel.CanPreviewSelectedSftpText)
        {
            return;
        }

        await ViewModel.PreviewSelectedSftpTextAsync(CancellationToken.None);
        if (ViewModel.HasSftpPreview)
        {
            await ShowSftpPreviewDialogAsync();
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "无法预览此文件",
            Content = new TextBlock
            {
                Text = "无法安全读取该远程文件。请确认它是可读取的文本文件，且大小在预览限制内。",
                TextWrapping = TextWrapping.Wrap,
            },
            CloseButtonText = "知道了",
        };
        await dialog.ShowAsync();
    }

    private void SftpContextDownloadClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender, preserveExistingMultiSelection: true))
        {
            DownloadSelectedSftpEntryClick(this, new RoutedEventArgs());
        }
    }

    private void SftpContextRenameClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender))
        {
            RenameSelectedSftpEntryClick(this, new RoutedEventArgs());
        }
    }

    private void SftpContextPermissionsClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender))
        {
            ChangeSelectedSftpPermissionsClick(this, new RoutedEventArgs());
        }
    }

    private void SftpContextDeleteClick(object sender, RoutedEventArgs e)
    {
        if (SelectContextSftpEntry(sender, preserveExistingMultiSelection: true))
        {
            RemoveSelectedSftpEntryClick(this, new RoutedEventArgs());
        }
    }

    private void ActiveSftpTransfersTabClick(object sender, RoutedEventArgs e)
    {
        ActiveSftpTransfersTab.IsChecked = true;
        CompletedSftpTransfersTab.IsChecked = false;
        ActiveSftpTransfersTab.Content = "进行中";
        CompletedSftpTransfersTab.Content = "完成";
        ActiveSftpTransfersTabColumn.Width = new GridLength(58);
        CompletedSftpTransfersTabColumn.Width = new GridLength(42);
        ActiveSftpTransfersContent.Visibility = Visibility.Visible;
        CompletedSftpTransfersContent.Visibility = Visibility.Collapsed;
    }

    private void CompletedSftpTransfersTabClick(object sender, RoutedEventArgs e)
    {
        ActiveSftpTransfersTab.IsChecked = false;
        CompletedSftpTransfersTab.IsChecked = true;
        ActiveSftpTransfersTab.Content = "进行";
        CompletedSftpTransfersTab.Content = "已完成";
        ActiveSftpTransfersTabColumn.Width = new GridLength(42);
        CompletedSftpTransfersTabColumn.Width = new GridLength(58);
        ActiveSftpTransfersContent.Visibility = Visibility.Collapsed;
        CompletedSftpTransfersContent.Visibility = Visibility.Visible;
    }

    private void PauseSftpTransferClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SftpTransferTaskViewModel task })
        {
            ViewModel.PauseSftpTransfer(task);
        }
    }

    private void ResumeSftpTransferClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SftpTransferTaskViewModel task })
        {
            ViewModel.ResumeSftpTransfer(task);
        }
    }

    private void CancelSftpTransferClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SftpTransferTaskViewModel task })
        {
            ViewModel.CancelSftpTransfer(task);
        }
    }

    private bool SelectContextSftpEntry(object sender, bool preserveExistingMultiSelection = false)
    {
        if (sender is FrameworkElement { Tag: SftpDirectoryEntryViewModel entry })
        {
            if (preserveExistingMultiSelection &&
                SftpEntriesList.SelectedItems.Count > 1 &&
                SftpEntriesList.SelectedItems.Contains(entry))
            {
                ViewModel.SetSelectedSftpEntries(
                    SftpEntriesList.SelectedItems.OfType<SftpDirectoryEntryViewModel>());
                return true;
            }

            SftpEntriesList.SelectedItems.Clear();
            SftpEntriesList.SelectedItems.Add(entry);
            ViewModel.SetSelectedSftpEntries([entry]);
            return true;
        }

        return false;
    }

    private bool TryExecuteViewModelCommand(string propertyName)
    {
        var property = typeof(MainWindowViewModel).GetProperty(
            propertyName,
            BindingFlags.Instance | BindingFlags.Public);
        if (property?.GetValue(ViewModel) is not ICommand command || !command.CanExecute(null))
        {
            return false;
        }

        command.Execute(null);
        return true;
    }

    private const uint WindowMessageGetMinMaxInfo = 0x0024;
    private const uint WindowMessageDpiChanged = 0x02E0;
    private const int ArrowCursorResourceId = 32512;

    private static double GetDpiScale(IntPtr hWnd)
    {
        var dpi = GetDpiForWindow(hWnd);
        return dpi == 0 ? 1d : dpi / 96d;
    }

    private delegate IntPtr WindowSubclassProc(
        IntPtr hWnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        IntPtr referenceData);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativePoint(int x, int y)
    {
        public readonly int X = x;
        public readonly int Y = y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public NativePoint Reserved;
        public NativePoint MaximumSize;
        public NativePoint MaximumPosition;
        public NativePoint MinimumTrackingSize;
        public NativePoint MaximumTrackingSize;
    }

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        IntPtr hWnd,
        WindowSubclassProc subclassProc,
        UIntPtr subclassId,
        IntPtr referenceData);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(
        IntPtr hWnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr LoadCursor(IntPtr instanceHandle, IntPtr cursorName);

    [DllImport("user32.dll")]
    private static extern IntPtr SetCursor(IntPtr cursorHandle);

    private sealed record TerminalAppearanceSettings(
        double FontSize,
        TerminalColorTheme Theme,
        string AppTheme = "跟随系统",
        string AppPalette = "翡翠流光",
        bool TelnetEnabled = false,
        bool? TerminalFollowsApplicationTheme = false);

    private sealed record KeyboardShortcutSettingsDocument(
        int Version,
        Dictionary<string, KeyboardShortcutGesture?> Bindings);

    private sealed record TerminalSplitSurface(
        TerminalSplitPaneViewModel Pane,
        Border Border,
        ScrollViewer ScrollViewer,
        NativeTerminalView TerminalView);

    private sealed record ApplicationPaletteOption(string Name);

    private sealed record ApplicationPaletteColors(
        Color Accent,
        Color Workbench,
        Color Chrome,
        Color Panel,
        Color Metric,
        Color Stroke,
        Color DialogSurface,
        Color FeatureWindow,
        Color FeatureTitleBar,
        Color FeatureStroke,
        Color FeatureInner,
        Color AccentSoft);
}
