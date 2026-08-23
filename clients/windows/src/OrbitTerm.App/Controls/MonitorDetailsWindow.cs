using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Presentation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using WinRT.Interop;
using FontWeight = Windows.UI.Text.FontWeight;

namespace OrbitTerm.App.Controls;

// Hallmark · component: monitoring detail window · genre: modern-minimal · theme: existing OrbitTerm tokens
// Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4
// states: default · hover · focus · active · disabled · loading · error · success · high-DPI
internal sealed class MonitorDetailsWindow : Window
{
    private const int GwlpHwndParent = -8;
    private const int LogicalWidth = 660;
    private const int LogicalHeight = 650;

    private readonly MainWindowViewModel viewModel;
    private readonly nint ownerHandle;
    private readonly ElementTheme requestedTheme;
    private readonly StackPanel metricsHost = new() { Spacing = 7 };
    private readonly TextBlock footerStatus = new()
    {
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button refreshButton = new()
    {
        Content = "刷新",
        MinWidth = 82,
        HorizontalAlignment = HorizontalAlignment.Right,
    };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer processRefreshTimer;
    private readonly CancellationTokenSource processRefreshCancellation = new();
    private readonly ObservableCollection<RemoteProcessViewModel> visibleRemoteProcesses = [];
    private string processSearchText = string.Empty;
    private int processSortIndex;
    private TextBox? processSearchBox;
    private ListView? processList;
    private Border? processSelectionPanel;
    private TextBlock? selectedProcessCommand;
    private TextBlock? selectedProcessSummary;
    private TextBlock? selectedProcessCommandLine;
    private TextBlock? processCpuHistoryValue;
    private TextBlock? processMemoryHistoryValue;
    private TextBlock? processHistoryStatus;
    private MonitorTrendLine? processCpuHistoryLine;
    private MonitorTrendLine? processMemoryHistoryLine;
    private Button? parentProcessButton;
    private Button? childProcessesButton;
    private TextBlock? processEmptyState;
    private TextBlock? processActionStatus;
    private ProgressRing? processActionProgress;
    private Button? terminateProcessButton;
    private Button? forceKillProcessButton;
    private bool processActionRunning;
    private bool ownerDisabled;
    private readonly List<ProcessHistorySample> selectedProcessHistory = [];
    private (uint ProcessId, long StartIdentity)? selectedProcessHistoryIdentity;
    private DateTimeOffset? lastProcessHistorySampleAt;

    public MonitorDetailsWindow(
        MainWindowViewModel viewModel,
        nint ownerHandle,
        ElementTheme requestedTheme)
    {
        this.viewModel = viewModel;
        this.ownerHandle = ownerHandle;
        this.requestedTheme = requestedTheme;
        Title = "OrbitTerm · 监控详情";
        processRefreshTimer = DispatcherQueue.CreateTimer();
        processRefreshTimer.Interval = TimeSpan.FromSeconds(2);
        processRefreshTimer.Tick += ProcessRefreshTimerTick;

        var titleBar = CreateTitleBar();

        var scrollViewer = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = metricsHost,
        };
        var closeButton = new Button
        {
            Content = "关闭",
            MinWidth = 82,
        };
        closeButton.Click += (_, _) => Close();
        refreshButton.Click += RefreshClick;

        var footer = new Grid
        {
            ColumnSpacing = 8,
            Padding = new Thickness(0, 10, 0, 0),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        Grid.SetColumn(refreshButton, 1);
        Grid.SetColumn(closeButton, 2);
        footer.Children.Add(footerStatus);
        footer.Children.Add(refreshButton);
        footer.Children.Add(closeButton);

        var body = new Grid
        {
            Background = ResourceBrush("OrbitFeatureWindowBrush"),
            Padding = new Thickness(16),
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = new GridLength(1, GridUnitType.Star) },
                new RowDefinition { Height = GridLength.Auto },
            },
        };
        var heading = new StackPanel { Spacing = 2, Margin = new Thickness(0, 0, 0, 12) };
        heading.Children.Add(new TextBlock
        {
            Text = "监控详情",
            FontSize = 20,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        });
        heading.Children.Add(new TextBlock
        {
            Text = "当前终端会话的有限历史快照",
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        Grid.SetRow(scrollViewer, 1);
        Grid.SetRow(footer, 2);
        body.Children.Add(heading);
        body.Children.Add(scrollViewer);
        body.Children.Add(footer);

        var root = new Grid
        {
            RequestedTheme = requestedTheme,
            Background = ResourceBrush("OrbitFeatureWindowBrush"),
            RowDefinitions =
            {
                new RowDefinition { Height = new GridLength(38) },
                new RowDefinition { Height = new GridLength(1, GridUnitType.Star) },
            },
        };
        Grid.SetRow(body, 1);
        root.Children.Add(titleBar);
        root.Children.Add(body);
        var windowFrame = new Border
        {
            Margin = new Thickness(1),
            BorderBrush = ResourceBrush("OrbitFeatureWindowStrokeBrush"),
            // The title bar owns the top edge so native caption controls never
            // cover the semantic feature-window frame.
            BorderThickness = new Thickness(2, 0, 2, 2),
            CornerRadius = new CornerRadius(12),
            IsHitTestVisible = false,
        };
        Grid.SetRowSpan(windowFrame, 2);
        root.Children.Add(windowFrame);
        Content = root;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(titleBar);
        ConfigureWindowChrome();
        NativeWindowCornerService.Apply(this);

        Closed += (_, _) =>
        {
            processRefreshTimer.Stop();
            processRefreshCancellation.Cancel();
            processRefreshCancellation.Dispose();
            RestoreOwner();
        };
        RebuildMetrics();
    }

    public void ShowOwned()
    {
        var childHandle = WindowNative.GetWindowHandle(this);
        SetWindowLongPtr(childHandle, GwlpHwndParent, ownerHandle);

        var dpiScale = Math.Max(1d, GetDpiForWindow(ownerHandle) / 96d);
        var width = (int)Math.Round(LogicalWidth * dpiScale);
        var height = (int)Math.Round(LogicalHeight * dpiScale);
        AppWindow.Resize(new SizeInt32(width, height));
        if (GetWindowRect(ownerHandle, out var ownerBounds))
        {
            var x = ownerBounds.Left + Math.Max(0, (ownerBounds.Width - width) / 2);
            var y = ownerBounds.Top + Math.Max(0, (ownerBounds.Height - height) / 2);
            AppWindow.Move(new PointInt32(x, y));
        }
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsResizable = true;
        }

        Activate();
        DispatcherQueue.TryEnqueue(() =>
            NativeWindowCornerService.ApplyVisibleFrameTheme(
                this,
                requestedTheme == ElementTheme.Dark));
        processRefreshTimer.Start();
        _ = RefreshProcessesAsync();
        EnableWindow(ownerHandle, false);
        // EnableWindow returns the owner's previous disabled state, not whether
        // disabling succeeded. Once this owned window is shown, always restore
        // the owner on close.
        ownerDisabled = true;
    }

    private async void RefreshClick(object sender, RoutedEventArgs e)
    {
        if (!viewModel.IsConnected || viewModel.IsTelnetSession)
        {
            footerStatus.Text = "当前会话不支持 SSH 系统监控。";
            return;
        }

        refreshButton.IsEnabled = false;
        footerStatus.Text = "正在刷新监控快照…";
        try
        {
            await viewModel.RefreshMonitorDetailsAsync(CancellationToken.None);
            await viewModel.RefreshRemoteProcessesAsync(CancellationToken.None);
            RebuildMetrics();
        }
        finally
        {
            refreshButton.IsEnabled = viewModel.IsConnected && !viewModel.IsTelnetSession;
        }
    }

    private void RebuildMetrics()
    {
        metricsHost.Children.Clear();
        metricsHost.Children.Add(CreateOverviewCard());
        foreach (var metric in viewModel.MonitorTrendMetrics)
        {
            metricsHost.Children.Add(CreateMetricCard(metric));
        }
        metricsHost.Children.Add(CreateProcessCard());
        footerStatus.Text = string.Concat(viewModel.MonitorTrendStatus, " · ", viewModel.MonitorTrendRange);
        footerStatus.Foreground = ResourceBrush("OrbitMutedTextBrush");
        refreshButton.IsEnabled = viewModel.IsConnected && !viewModel.IsTelnetSession;
    }

    private async void ProcessRefreshTimerTick(
        Microsoft.UI.Dispatching.DispatcherQueueTimer sender,
        object args)
    {
        await RefreshProcessesAsync();
    }

    private async Task RefreshProcessesAsync()
    {
        if (!viewModel.IsConnected ||
            viewModel.IsTelnetSession ||
            viewModel.RefreshMonitorSnapshotCommand.IsRunning ||
            viewModel.RunBatchCommand.IsRunning ||
            processRefreshCancellation.IsCancellationRequested)
        {
            return;
        }

        try
        {
            await viewModel.RefreshRemoteProcessesAsync(processRefreshCancellation.Token);
            SynchronizeVisibleProcesses();
            if (processList?.SelectedItem is RemoteProcessViewModel selected)
            {
                RecordSelectedProcessSample(selected);
                UpdateProcessSelection(selected, preserveFeedback: true);
            }
        }
        catch (OperationCanceledException) when (processRefreshCancellation.IsCancellationRequested)
        {
            // The details window is closing.
        }
    }

    private Border CreateProcessCard()
    {
        var content = new StackPanel { Spacing = 8 };
        var heading = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        heading.Children.Add(new TextBlock
        {
            Text = "实时进程",
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var sampleLabel = new TextBlock
        {
            Text = "完整快照 · 支持搜索排序",
            FontSize = 11,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(sampleLabel, 1);
        heading.Children.Add(sampleLabel);
        content.Children.Add(heading);

        var status = new TextBlock
        {
            FontSize = 11,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            TextWrapping = TextWrapping.Wrap,
        };
        status.SetBinding(TextBlock.TextProperty, new Binding
        {
            Source = viewModel,
            Path = new PropertyPath(nameof(MainWindowViewModel.RemoteProcessStatus)),
            Mode = BindingMode.OneWay,
        });
        content.Children.Add(status);

        var tools = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(150) },
            },
        };
        processSearchBox = new TextBox
        {
            PlaceholderText = "搜索 PID、用户或进程",
            Text = processSearchText,
            MaxLength = 128,
        };
        var search = processSearchBox;
        AutomationProperties.SetName(search, "搜索远端进程");
        search.TextChanged += (_, _) =>
        {
            processSearchText = search.Text.Trim();
            SynchronizeVisibleProcesses();
        };
        var sort = new ComboBox
        {
            ItemsSource = new[] { "CPU 从高到低", "内存从高到低", "PID 从小到大", "名称 A–Z" },
            SelectedIndex = processSortIndex,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(sort, "进程排序方式");
        sort.SelectionChanged += (_, _) =>
        {
            processSortIndex = Math.Max(0, sort.SelectedIndex);
            SynchronizeVisibleProcesses();
        };
        Grid.SetColumn(sort, 1);
        tools.Children.Add(search);
        tools.Children.Add(sort);
        content.Children.Add(tools);

        var header = new Grid
        {
            Padding = new Thickness(5, 0, 5, 2),
        };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(54) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(82) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(58) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(58) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(74) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AddProcessCell(header, "PID", 0, FontWeights.SemiBold);
        AddProcessCell(header, "用户", 1, FontWeights.SemiBold);
        AddProcessCell(header, "CPU", 2, FontWeights.SemiBold);
        AddProcessCell(header, "内存", 3, FontWeights.SemiBold);
        AddProcessCell(header, "状态", 4, FontWeights.SemiBold);
        AddProcessCell(header, "进程", 5, FontWeights.SemiBold);
        content.Children.Add(header);

        processList = new ListView
        {
            ItemsSource = visibleRemoteProcesses,
            Height = 240,
            SelectionMode = ListViewSelectionMode.Single,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            ItemTemplate = (DataTemplate)XamlReader.Load(
                """
                <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                  <Grid Height="36" Padding="5,0" ColumnDefinitions="54,82,58,58,74,*"
                        AutomationProperties.Name="{Binding AccessibilityDescription}">
                    <TextBlock Text="{Binding ProcessIdText}" VerticalAlignment="Center" FontFamily="{StaticResource OrbitTerminalFont}" FontSize="11" />
                    <TextBlock Grid.Column="1" Text="{Binding User}" VerticalAlignment="Center" FontSize="11" TextTrimming="CharacterEllipsis" />
                    <TextBlock Grid.Column="2" Text="{Binding CpuPercentText}" VerticalAlignment="Center" FontSize="11" />
                    <TextBlock Grid.Column="3" Text="{Binding MemoryPercentText}" VerticalAlignment="Center" FontSize="11" />
                    <TextBlock Grid.Column="4" Text="{Binding StateLabel}" VerticalAlignment="Center" FontSize="11" TextTrimming="CharacterEllipsis" />
                    <TextBlock Grid.Column="5" Text="{Binding Command}" VerticalAlignment="Center" FontFamily="{StaticResource OrbitTerminalFont}" FontSize="11" TextTrimming="CharacterEllipsis" />
                  </Grid>
                </DataTemplate>
                """),
        };
        AutomationProperties.SetName(processList, "远端实时进程列表");
        processList.SelectionChanged += ProcessListSelectionChanged;
        processList.ContainerContentChanging += ProcessListContainerContentChanging;
        processEmptyState = new TextBlock
        {
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(18),
            IsHitTestVisible = false,
        };
        var listHost = new Grid { Height = 240 };
        processList.Height = double.NaN;
        listHost.Children.Add(processList);
        listHost.Children.Add(processEmptyState);
        content.Children.Add(listHost);

        processSelectionPanel = CreateProcessSelectionPanel();
        content.Children.Add(processSelectionPanel);
        SynchronizeVisibleProcesses();
        var restoredSelection = selectedProcessHistoryIdentity is { } identity
            ? visibleRemoteProcesses.FirstOrDefault(process =>
                process.ProcessId == identity.ProcessId &&
                process.StartIdentity == identity.StartIdentity)
            : null;
        processList.SelectedItem = restoredSelection;
        UpdateProcessSelection(restoredSelection);
        return CreateCard(content, "当前会话实时进程监控");
    }

    private Border CreateProcessSelectionPanel()
    {
        var root = new Grid
        {
            Padding = new Thickness(0, 8, 0, 0),
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = GridLength.Auto },
            },
        };
        var identity = new StackPanel { Spacing = 2 };
        selectedProcessCommand = new TextBlock
        {
            FontFamily = (FontFamily)Microsoft.UI.Xaml.Application.Current.Resources["OrbitTerminalFont"],
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        selectedProcessSummary = new TextBlock
        {
            FontSize = 11,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        identity.Children.Add(selectedProcessCommand);
        identity.Children.Add(selectedProcessSummary);
        root.Children.Add(identity);

        terminateProcessButton = new Button { Content = "结束进程", MinWidth = 92 };
        forceKillProcessButton = new Button
        {
            Content = "强制终止",
            MinWidth = 92,
            Foreground = ResourceBrush("OrbitDangerBrush"),
            Background = ResourceBrush("OrbitDangerSoftBrush"),
        };
        terminateProcessButton.Click += async (_, _) =>
            await ConfirmAndRunProcessActionAsync(RemoteProcessAction.Terminate);
        forceKillProcessButton.Click += async (_, _) =>
            await ConfirmAndRunProcessActionAsync(RemoteProcessAction.ForceKill);
        Grid.SetColumn(terminateProcessButton, 1);
        Grid.SetColumn(forceKillProcessButton, 2);
        root.Children.Add(terminateProcessButton);
        root.Children.Add(forceKillProcessButton);

        var relationships = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 7, 0, 0),
        };
        parentProcessButton = new Button { MinWidth = 112 };
        childProcessesButton = new Button { MinWidth = 112 };
        parentProcessButton.Click += (_, _) =>
        {
            if (processList?.SelectedItem is RemoteProcessViewModel selected)
            {
                NavigateToProcess(selected.ParentProcessId);
            }
        };
        relationships.Children.Add(parentProcessButton);
        relationships.Children.Add(childProcessesButton);
        Grid.SetRow(relationships, 1);
        Grid.SetColumnSpan(relationships, 3);
        root.Children.Add(relationships);

        var commandDetails = new StackPanel
        {
            Spacing = 2,
            Margin = new Thickness(0, 7, 0, 0),
        };
        commandDetails.Children.Add(new TextBlock
        {
            Text = "完整命令",
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        selectedProcessCommandLine = new TextBlock
        {
            FontFamily = (FontFamily)Microsoft.UI.Xaml.Application.Current.Resources["OrbitTerminalFont"],
            FontSize = 11,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
        };
        commandDetails.Children.Add(selectedProcessCommandLine);
        Grid.SetRow(commandDetails, 2);
        Grid.SetColumnSpan(commandDetails, 3);
        root.Children.Add(commandDetails);

        var history = CreateProcessHistoryPanel();
        Grid.SetRow(history, 3);
        Grid.SetColumnSpan(history, 3);
        root.Children.Add(history);

        var feedback = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 7,
            Margin = new Thickness(0, 6, 0, 0),
        };
        processActionProgress = new ProgressRing
        {
            Width = 14,
            Height = 14,
            IsActive = false,
            Visibility = Visibility.Collapsed,
        };
        processActionStatus = new TextBlock
        {
            Text = "选择进程后可查看详情或执行受控操作。",
            FontSize = 11,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        };
        feedback.Children.Add(processActionProgress);
        feedback.Children.Add(processActionStatus);
        Grid.SetRow(feedback, 4);
        Grid.SetColumnSpan(feedback, 3);
        root.Children.Add(feedback);

        return new Border
        {
            BorderBrush = ResourceBrush("OrbitPanelStrokeBrush"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = root,
        };
    }

    private FrameworkElement CreateProcessHistoryPanel()
    {
        var content = new StackPanel
        {
            Spacing = 5,
            Margin = new Thickness(0, 8, 0, 0),
        };
        var heading = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        heading.Children.Add(new TextBlock
        {
            Text = "资源变化历史",
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        });
        processHistoryStatus = new TextBlock
        {
            Text = "选择后开始记录 · 仅保留 10 分钟",
            FontSize = 10,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        Grid.SetColumn(processHistoryStatus, 1);
        heading.Children.Add(processHistoryStatus);
        content.Children.Add(heading);

        var charts = new Grid
        {
            ColumnSpacing = 10,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        var cpu = CreateProcessHistoryChart("CPU", out processCpuHistoryValue, out processCpuHistoryLine);
        var memory = CreateProcessHistoryChart("内存", out processMemoryHistoryValue, out processMemoryHistoryLine);
        Grid.SetColumn(memory, 1);
        charts.Children.Add(cpu);
        charts.Children.Add(memory);
        content.Children.Add(charts);
        return content;
    }

    private static FrameworkElement CreateProcessHistoryChart(
        string label,
        out TextBlock value,
        out MonitorTrendLine line)
    {
        var root = new Grid
        {
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = new GridLength(38) },
            },
        };
        var header = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        header.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 10,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        value = new TextBlock
        {
            Text = "暂无数据",
            FontSize = 10,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        };
        Grid.SetColumn(value, 1);
        header.Children.Add(value);
        root.Children.Add(header);
        line = new MonitorTrendLine
        {
            Sparkline = "—",
            Height = 34,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Grid.SetRow(line, 1);
        root.Children.Add(line);
        return root;
    }

    private void SynchronizeVisibleProcesses()
    {
        var query = processSearchText.Trim();
        IEnumerable<RemoteProcessViewModel> filtered = viewModel.RemoteProcesses;
        if (query.Length > 0)
        {
            filtered = filtered.Where(process =>
                process.ProcessIdText.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                process.User.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                process.Command.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                process.StateLabel.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        filtered = processSortIndex switch
        {
            1 => filtered.OrderByDescending(static process => process.MemoryPercent)
                .ThenByDescending(static process => process.CpuPercent),
            2 => filtered.OrderBy(static process => process.ProcessId),
            3 => filtered.OrderBy(static process => process.Command, StringComparer.OrdinalIgnoreCase)
                .ThenBy(static process => process.ProcessId),
            _ => filtered.OrderByDescending(static process => process.CpuPercent)
                .ThenByDescending(static process => process.MemoryPercent),
        };

        var desired = filtered.ToArray();
        var desiredIdentities = desired
            .Select(static process => (process.ProcessId, process.StartIdentity))
            .ToHashSet();
        for (var desiredIndex = 0; desiredIndex < desired.Length; desiredIndex++)
        {
            var process = desired[desiredIndex];
            var currentIndex = visibleRemoteProcesses.IndexOf(process);
            if (currentIndex < 0)
            {
                visibleRemoteProcesses.Insert(Math.Min(desiredIndex, visibleRemoteProcesses.Count), process);
            }
            else if (currentIndex != desiredIndex)
            {
                visibleRemoteProcesses.Move(currentIndex, desiredIndex);
            }
        }
        for (var index = visibleRemoteProcesses.Count - 1; index >= 0; index--)
        {
            var process = visibleRemoteProcesses[index];
            if (!desiredIdentities.Contains((process.ProcessId, process.StartIdentity)))
            {
                visibleRemoteProcesses.RemoveAt(index);
            }
        }

        if (processEmptyState is not null)
        {
            processEmptyState.Visibility = visibleRemoteProcesses.Count == 0
                ? Visibility.Visible
                : Visibility.Collapsed;
            processEmptyState.Text = viewModel.RemoteProcesses.Count == 0
                ? "暂时没有可显示的进程。等待下一次采样。"
                : "未找到匹配的进程。请清除搜索或更改关键词。";
        }
        if (processList?.SelectedItem is RemoteProcessViewModel selected &&
            !visibleRemoteProcesses.Contains(selected))
        {
            processList.SelectedItem = null;
        }
    }

    private void ProcessListSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var process = processList?.SelectedItem as RemoteProcessViewModel;
        ResetProcessHistoryWhenIdentityChanges(process);
        if (process is not null)
        {
            RecordSelectedProcessSample(process);
        }
        UpdateProcessSelection(process);
    }

    private void ProcessListContainerContentChanging(
        ListViewBase sender,
        ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue ||
            args.ItemContainer is not ListViewItem item ||
            args.Item is not RemoteProcessViewModel process)
        {
            return;
        }
        item.ContextFlyout = CreateProcessContextMenu(process);
    }

    private MenuFlyout CreateProcessContextMenu(RemoteProcessViewModel process)
    {
        var menu = new MenuFlyout();
        var details = new MenuFlyoutItem { Text = "查看详情" };
        details.Click += (_, _) =>
        {
            if (processList is not null)
            {
                processList.SelectedItem = process;
                processList.ScrollIntoView(process);
            }
        };
        var parent = new MenuFlyoutItem
        {
            Text = string.Concat("查看父进程 · ", process.ParentProcessIdText),
            IsEnabled = FindProcess(process.ParentProcessId) is not null,
        };
        parent.Click += (_, _) => NavigateToProcess(process.ParentProcessId);
        var children = FindChildProcesses(process.ProcessId);
        var childMenu = new MenuFlyoutSubItem
        {
            Text = string.Concat("查看子进程 · ", children.Count),
            IsEnabled = children.Count > 0,
        };
        AddChildProcessMenuItems(childMenu.Items, children);
        var copyPid = new MenuFlyoutItem { Text = "复制 PID" };
        copyPid.Click += (_, _) =>
        {
            SelectProcess(process);
            CopyProcessText(process.ProcessIdText, "PID 已复制");
        };
        var copyDetails = new MenuFlyoutItem { Text = "复制进程信息" };
        copyDetails.Click += (_, _) =>
        {
            SelectProcess(process);
            CopyProcessText(
                string.Concat(process.Command, " · ", process.DetailSummary),
                "进程信息已复制");
        };
        var terminate = new MenuFlyoutItem
        {
            Text = "结束进程",
            IsEnabled = !process.IsProtectedProcess,
        };
        terminate.Click += async (_, _) =>
        {
            SelectProcess(process);
            await ConfirmAndRunProcessActionAsync(RemoteProcessAction.Terminate);
        };
        var forceKill = new MenuFlyoutItem
        {
            Text = "强制终止",
            IsEnabled = !process.IsProtectedProcess,
        };
        forceKill.Click += async (_, _) =>
        {
            SelectProcess(process);
            await ConfirmAndRunProcessActionAsync(RemoteProcessAction.ForceKill);
        };
        menu.Items.Add(details);
        menu.Items.Add(parent);
        menu.Items.Add(childMenu);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(copyPid);
        menu.Items.Add(copyDetails);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(terminate);
        menu.Items.Add(forceKill);
        return menu;
    }

    private void SelectProcess(RemoteProcessViewModel process)
    {
        if (processList is not null)
        {
            processList.SelectedItem = process;
        }
        UpdateProcessSelection(process);
    }

    private void UpdateProcessSelection(
        RemoteProcessViewModel? process,
        bool preserveFeedback = false)
    {
        if (processSelectionPanel is null ||
            selectedProcessCommand is null ||
            selectedProcessSummary is null ||
            selectedProcessCommandLine is null ||
            parentProcessButton is null ||
            childProcessesButton is null ||
            terminateProcessButton is null ||
            forceKillProcessButton is null)
        {
            return;
        }

        processSelectionPanel.Visibility = process is null ? Visibility.Collapsed : Visibility.Visible;
        if (process is null)
        {
            return;
        }
        selectedProcessCommand.Text = process.ProcessName;
        selectedProcessSummary.Text = process.DetailSummary;
        selectedProcessCommandLine.Text = process.Command;
        var parent = FindProcess(process.ParentProcessId);
        parentProcessButton.Content = parent is null
            ? string.Concat("父进程 ", process.ParentProcessIdText)
            : string.Concat("父进程 · ", parent.ProcessName);
        parentProcessButton.IsEnabled = parent is not null;
        AutomationProperties.SetName(
            parentProcessButton,
            parent is null
                ? string.Concat("父进程 ", process.ParentProcessIdText, " 不在当前快照中")
                : string.Concat("转到父进程 ", parent.ProcessName, "，PID ", parent.ProcessIdText));
        var children = FindChildProcesses(process.ProcessId);
        childProcessesButton.Content = string.Concat("子进程 · ", children.Count);
        childProcessesButton.IsEnabled = children.Count > 0;
        childProcessesButton.Flyout = CreateChildProcessFlyout(children);
        AutomationProperties.SetName(childProcessesButton, string.Concat("查看 ", children.Count, " 个子进程"));
        terminateProcessButton.IsEnabled = !processActionRunning && !process.IsProtectedProcess;
        forceKillProcessButton.IsEnabled = !processActionRunning && !process.IsProtectedProcess;
        AutomationProperties.SetName(terminateProcessButton, $"结束进程 {process.ProcessId}");
        AutomationProperties.SetName(forceKillProcessButton, $"强制终止进程 {process.ProcessId}");
        if (preserveFeedback)
        {
            return;
        }
        if (process.IsProtectedProcess && processActionStatus is not null)
        {
            processActionStatus.Text = "系统 1 号进程受保护，OrbitTerm 不允许结束它。";
            processActionStatus.Foreground = ResourceBrush("OrbitWarningBrush");
        }
        else if (!processActionRunning && processActionStatus is not null)
        {
            processActionStatus.Text = process.IsPotentiallyCritical
                ? "此进程可能承载系统、SSH 或容器服务；操作前请确认影响。"
                : "“结束进程”允许清理资源；仅在无响应时使用“强制终止”。";
            processActionStatus.Foreground = ResourceBrush(
                process.IsPotentiallyCritical ? "OrbitWarningBrush" : "OrbitMutedTextBrush");
        }
    }

    private RemoteProcessViewModel? FindProcess(uint processId) =>
        viewModel.RemoteProcesses.FirstOrDefault(process => process.ProcessId == processId);

    private IReadOnlyList<RemoteProcessViewModel> FindChildProcesses(uint parentProcessId) =>
        viewModel.RemoteProcesses
            .Where(process => process.ParentProcessId == parentProcessId)
            .OrderByDescending(process => process.CpuPercent)
            .ThenBy(process => process.ProcessId)
            .ToArray();

    private void NavigateToProcess(uint processId)
    {
        var target = FindProcess(processId);
        if (target is null || processList is null)
        {
            SetProcessActionFeedback("目标进程已结束或不在当前快照中。", "OrbitMutedTextBrush");
            return;
        }
        processSearchText = string.Empty;
        if (processSearchBox is not null)
        {
            processSearchBox.Text = string.Empty;
        }
        SynchronizeVisibleProcesses();
        processList.SelectedItem = target;
        processList.ScrollIntoView(target, ScrollIntoViewAlignment.Leading);
    }

    private MenuFlyout CreateChildProcessFlyout(IReadOnlyList<RemoteProcessViewModel> children)
    {
        var flyout = new MenuFlyout();
        AddChildProcessMenuItems(flyout.Items, children);
        return flyout;
    }

    private void AddChildProcessMenuItems(
        IList<MenuFlyoutItemBase> items,
        IReadOnlyList<RemoteProcessViewModel> children)
    {
        foreach (var child in children.Take(24))
        {
            var item = new MenuFlyoutItem
            {
                Text = string.Concat(child.ProcessName, " · PID ", child.ProcessIdText),
            };
            item.Click += (_, _) => NavigateToProcess(child.ProcessId);
            items.Add(item);
        }
        if (children.Count > 24)
        {
            items.Add(new MenuFlyoutItem
            {
                Text = string.Concat("另有 ", children.Count - 24, " 个子进程"),
                IsEnabled = false,
            });
        }
    }

    private void ResetProcessHistoryWhenIdentityChanges(RemoteProcessViewModel? process)
    {
        (uint ProcessId, long StartIdentity)? identity = process is null
            ? null
            : (process.ProcessId, process.StartIdentity);
        if (selectedProcessHistoryIdentity == identity)
        {
            return;
        }
        selectedProcessHistoryIdentity = identity;
        selectedProcessHistory.Clear();
        lastProcessHistorySampleAt = null;
        UpdateProcessHistoryVisuals(process);
    }

    private void RecordSelectedProcessSample(RemoteProcessViewModel process)
    {
        var identity = (process.ProcessId, process.StartIdentity);
        if (selectedProcessHistoryIdentity != identity)
        {
            ResetProcessHistoryWhenIdentityChanges(process);
        }
        var now = DateTimeOffset.UtcNow;
        if (lastProcessHistorySampleAt is { } previous && now - previous < TimeSpan.FromSeconds(1))
        {
            UpdateProcessHistoryVisuals(process);
            return;
        }
        selectedProcessHistory.Add(new ProcessHistorySample(now, process.CpuPercent, process.MemoryPercent));
        lastProcessHistorySampleAt = now;
        var cutoff = now - TimeSpan.FromMinutes(10);
        selectedProcessHistory.RemoveAll(sample => sample.SampledAt < cutoff);
        if (selectedProcessHistory.Count > 300)
        {
            selectedProcessHistory.RemoveRange(0, selectedProcessHistory.Count - 300);
        }
        UpdateProcessHistoryVisuals(process);
    }

    private void UpdateProcessHistoryVisuals(RemoteProcessViewModel? process)
    {
        if (processCpuHistoryLine is null ||
            processMemoryHistoryLine is null ||
            processCpuHistoryValue is null ||
            processMemoryHistoryValue is null ||
            processHistoryStatus is null)
        {
            return;
        }
        processCpuHistoryLine.Sparkline = BuildProcessSparkline(
            selectedProcessHistory.Select(sample => sample.CpuPercent));
        processMemoryHistoryLine.Sparkline = BuildProcessSparkline(
            selectedProcessHistory.Select(sample => sample.MemoryPercent));
        processCpuHistoryValue.Text = process is null ? "暂无数据" : process.CpuPercentText;
        processMemoryHistoryValue.Text = process is null ? "暂无数据" : process.MemoryPercentText;
        processHistoryStatus.Text = process is null
            ? "选择后开始记录 · 仅保留 10 分钟"
            : string.Concat("本次查看已采样 ", selectedProcessHistory.Count, " 次 · 不写入磁盘");
    }

    private static string BuildProcessSparkline(IEnumerable<double> source)
    {
        const string levels = "▁▂▃▄▅▆▇█";
        var values = source.ToArray();
        if (values.Length < 2)
        {
            return "—";
        }
        var minimum = values.Min();
        var maximum = values.Max();
        var span = Math.Max(maximum - minimum, 0.0001d);
        return new string(values.Select(value =>
        {
            var level = (int)Math.Round(((value - minimum) / span) * (levels.Length - 1));
            return levels[Math.Clamp(level, 0, levels.Length - 1)];
        }).ToArray());
    }

    private async Task ConfirmAndRunProcessActionAsync(RemoteProcessAction action)
    {
        if (processActionRunning || processList?.SelectedItem is not RemoteProcessViewModel process)
        {
            return;
        }
        if (process.IsProtectedProcess)
        {
            SetProcessActionFeedback("系统 1 号进程受保护，无法执行此操作。", "OrbitWarningBrush");
            return;
        }

        var force = action == RemoteProcessAction.ForceKill;
        var impact = force
            ? "强制终止不会让进程保存状态或清理资源，可能造成未完成写入。"
            : "系统会先发送正常结束信号，让进程有机会保存状态并清理资源。";
        if (process.IsPotentiallyCritical)
        {
            impact = string.Concat(
                impact,
                " 此进程可能承载系统、SSH 或容器服务，操作后当前连接或远端服务可能中断。");
        }
        var details = new StackPanel { Spacing = 7 };
        details.Children.Add(new TextBlock
        {
            Text = process.Command,
            FontFamily = (FontFamily)Microsoft.UI.Xaml.Application.Current.Resources["OrbitTerminalFont"],
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        details.Children.Add(new TextBlock
        {
            Text = process.DetailSummary,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        details.Children.Add(new TextBlock
        {
            Text = impact,
            Foreground = ResourceBrush(force || process.IsPotentiallyCritical
                ? "OrbitWarningBrush"
                : "OrbitPrimaryTextBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        var dialog = new ContentDialog
        {
            XamlRoot = ((FrameworkElement)Content).XamlRoot,
            Title = force ? "强制终止此进程？" : "结束此进程？",
            Content = details,
            PrimaryButtonText = force ? "强制终止" : "结束进程",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            RequestedTheme = ((FrameworkElement)Content).RequestedTheme,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        processActionRunning = true;
        processActionProgress!.IsActive = true;
        processActionProgress.Visibility = Visibility.Visible;
        terminateProcessButton!.IsEnabled = false;
        forceKillProcessButton!.IsEnabled = false;
        SetProcessActionFeedback(
            force ? "正在强制终止进程…" : "正在发送结束信号…",
            "OrbitMutedTextBrush");
        try
        {
            var result = await viewModel.RunRemoteProcessActionAsync(
                process,
                action,
                processRefreshCancellation.Token);
            var feedback = result switch
            {
                RemoteProcessActionResult.Completed => force
                    ? ("强制终止信号已发送，进程列表已刷新。", "OrbitSuccessBrush")
                    : ("结束信号已发送，进程列表已刷新。", "OrbitSuccessBrush"),
                RemoteProcessActionResult.NotFound =>
                    ("该进程已结束，无需再次操作。", "OrbitMutedTextBrush"),
                RemoteProcessActionResult.IdentityChanged =>
                    ("PID 已被其他进程复用，本次操作已安全拦截。", "OrbitWarningBrush"),
                RemoteProcessActionResult.Protected =>
                    ("系统关键进程受保护，无法执行此操作。", "OrbitWarningBrush"),
                RemoteProcessActionResult.PermissionDenied =>
                    ("当前远端用户无权结束此进程。请使用具备相应权限的账户。", "OrbitDangerBrush"),
                RemoteProcessActionResult.Busy =>
                    ("已有进程操作正在执行，请稍后重试。", "OrbitWarningBrush"),
                _ => ("进程操作未完成。请确认连接状态后重试。", "OrbitDangerBrush"),
            };
            SetProcessActionFeedback(feedback.Item1, feedback.Item2);
            SynchronizeVisibleProcesses();
        }
        catch (OperationCanceledException) when (processRefreshCancellation.IsCancellationRequested)
        {
            return;
        }
        finally
        {
            processActionRunning = false;
            processActionProgress.IsActive = false;
            processActionProgress.Visibility = Visibility.Collapsed;
            if (processList?.SelectedItem is RemoteProcessViewModel selected)
            {
                UpdateProcessSelection(selected, preserveFeedback: true);
            }
        }
    }

    private void CopyProcessText(string value, string successMessage)
    {
        var package = new DataPackage();
        package.SetText(value);
        Clipboard.SetContent(package);
        SetProcessActionFeedback(successMessage, "OrbitSuccessBrush");
    }

    private void SetProcessActionFeedback(string text, string brushKey)
    {
        if (processActionStatus is null)
        {
            return;
        }
        processActionStatus.Text = text;
        processActionStatus.Foreground = ResourceBrush(brushKey);
    }

    private static void AddProcessCell(
        Grid grid,
        string text,
        int column,
        FontWeight fontWeight)
    {
        var label = new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = fontWeight,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        Grid.SetColumn(label, column);
        grid.Children.Add(label);
    }

    private Border CreateOverviewCard()
    {
        var content = new StackPanel { Spacing = 3 };
        content.Children.Add(new TextBlock
        {
            Text = "系统概览",
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        });
        content.Children.Add(new TextBlock
        {
            Text = viewModel.SystemOverviewSummary,
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        });
        return CreateCard(content, "当前会话系统概览");
    }

    private Border CreateMetricCard(MonitorTrendMetricViewModel metric)
    {
        var chart = new Grid
        {
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = new GridLength(58) },
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = GridLength.Auto },
            },
        };
        var header = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        header.Children.Add(new TextBlock
        {
            Text = metric.Label,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        });
        var value = new TextBlock
        {
            Text = metric.CurrentValue,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
        };
        Grid.SetColumn(value, 1);
        header.Children.Add(value);
        chart.Children.Add(header);

        var line = new MonitorTrendLine
        {
            Sparkline = metric.Sparkline,
            Height = 52,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 3, 0, 0),
        };
        Grid.SetRow(line, 1);
        chart.Children.Add(line);

        var scale = CreateTimeScale();
        Grid.SetRow(scale, 2);
        chart.Children.Add(scale);
        var statistics = new TextBlock
        {
            Text = metric.StatisticsSummary,
            FontSize = 11,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 2, 0, 0),
        };
        Grid.SetRow(statistics, 3);
        chart.Children.Add(statistics);
        return CreateCard(chart, string.Concat(metric.AccessibilityLabel, "，趋势详情"));
    }

    private Grid CreateTimeScale()
    {
        var range = viewModel.MonitorTrendRange switch
        {
            "实时（30 秒）" => ("−30 秒", "−15 秒", "现在"),
            "5 分钟" => ("−5 分钟", "−2.5 分钟", "现在"),
            _ => ("−10 分钟", "−5 分钟", "现在"),
        };
        var scale = new Grid
        {
            Margin = new Thickness(0, 2, 0, 0),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
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

    private static Border CreateCard(UIElement content, string accessibleName)
    {
        var card = new Border
        {
            Padding = new Thickness(10, 7, 10, 7),
            CornerRadius = new CornerRadius(8),
            Background = ResourceBrush("OrbitMetricBrush"),
            BorderBrush = ResourceBrush("OrbitPanelStrokeBrush"),
            BorderThickness = new Thickness(1),
            Child = content,
        };
        AutomationProperties.SetName(card, accessibleName);
        return card;
    }

    private void RestoreOwner()
    {
        if (ownerHandle == 0)
        {
            return;
        }

        // Re-enabling is idempotent and protects the main window even if the
        // details window closes while it is still activating.
        EnableWindow(ownerHandle, true);
        if (ownerDisabled)
        {
            SetForegroundWindow(ownerHandle);
        }
        ownerDisabled = false;
    }

    private static Border CreateTitleBar()
    {
        var titleBarContent = new Grid
        {
            Padding = new Thickness(12, 0, 148, 0),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        var logo = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(7),
            Background = ResourceBrush("OrbitPanelBrush"),
            Child = new Image
            {
                Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(
                    new Uri("ms-appx:///Assets/Square44x44Logo.png")),
                Stretch = Stretch.Uniform,
            },
            VerticalAlignment = VerticalAlignment.Center,
        };
        var title = new TextBlock
        {
            Text = "监控详情",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = ResourceBrush("OrbitPrimaryTextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };
        Grid.SetColumn(title, 1);
        titleBarContent.Children.Add(logo);
        titleBarContent.Children.Add(title);

        var titleBar = new Border
        {
            Height = 38,
            Background = ResourceBrush("OrbitFeatureTitleBarBrush"),
            BorderBrush = ResourceBrush("OrbitFeatureWindowStrokeBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = titleBarContent,
        };
        AutomationProperties.SetName(titleBar, "监控详情窗口标题栏");
        return titleBar;
    }

    private void ConfigureWindowChrome()
    {
        if (AppWindow?.TitleBar is not { } titleBar)
        {
            return;
        }

        var background = ((SolidColorBrush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitFeatureTitleBarBrush"]).Color;
        var foreground = ((SolidColorBrush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitPrimaryTextBrush"]).Color;
        var inactive = ((SolidColorBrush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"]).Color;
        var hover = ((SolidColorBrush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitAccentSoftBrush"]).Color;
        var pressed = ((SolidColorBrush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitPanelStrokeBrush"]).Color;
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
    }

    private static Brush ResourceBrush(string key) =>
        (Brush)Microsoft.UI.Xaml.Application.Current.Resources[key];

    private readonly record struct ProcessHistorySample(
        DateTimeOffset SampledAt,
        double CpuPercent,
        double MemoryPercent);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetWindowLongPtr(nint windowHandle, int index, nint newValue);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint windowHandle, out NativeRect bounds);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnableWindow(nint windowHandle, [MarshalAs(UnmanagedType.Bool)] bool enabled);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint windowHandle);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint windowHandle);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }
}
