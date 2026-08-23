using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.UI;
using OrbitTerm.Presentation;

namespace OrbitTerm.App.Controls;

public sealed class DockerLogWindow : Window, IAsyncDisposable
{
    private readonly DockerLogSessionController controller;
    private readonly DispatcherQueueTimer searchTimer;
    private readonly Grid windowRoot;
    private readonly Grid appTitleBar;
    private readonly Border windowFrame;
    private readonly TextBlock titleBarText;
    private readonly Grid root;
    private readonly TextBox logTextBox;
    private readonly TextBox searchBox;
    private readonly TextBlock statusText;
    private readonly TextBlock searchStatusText;
    private readonly ToggleButton pauseButton;
    private readonly ToggleButton followButton;
    private readonly Button previousMatchButton;
    private readonly Button nextMatchButton;
    private IReadOnlyList<int> searchMatches = [];
    private int selectedMatchIndex = -1;
    private bool isDisposed;
    private bool isClosed;

    public DockerLogWindow(
        AppWindow ownerWindow,
        DockerLogSessionController controller,
        ElementTheme requestedTheme)
    {
        this.controller = controller;
        Title = string.Concat("容器日志 · ", controller.Context.ContainerName);
        NativeWindowCornerService.Apply(this);

        windowRoot = new Grid { RequestedTheme = requestedTheme };
        windowRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        windowRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        appTitleBar = new Grid
        {
            Height = 36,
            Padding = new Thickness(12, 0, 156, 0),
            ColumnSpacing = 8,
        };
        appTitleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        appTitleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var logoBorder = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(7),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new Image
            {
                Source = new BitmapImage(new Uri("ms-appx:///Assets/Square44x44Logo.png")),
                Stretch = Stretch.Uniform,
            },
        };
        titleBarText = new TextBlock
        {
            Text = Title,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(titleBarText, 1);
        appTitleBar.Children.Add(logoBorder);
        appTitleBar.Children.Add(titleBarText);
        windowRoot.Children.Add(appTitleBar);

        root = new Grid
        {
            Padding = new Thickness(16),
            RowSpacing = 10,
            RequestedTheme = requestedTheme,
        };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var heading = new TextBlock
        {
            Text = string.Concat(
                "容器：", controller.Context.ContainerName,
                "  ·  镜像：", controller.Context.Image),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        root.Children.Add(heading);

        statusText = new TextBlock
        {
            Text = "正在建立日志跟随会话…",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetRow(statusText, 1);
        root.Children.Add(statusText);

        pauseButton = CreateToggleButton("暂停", "暂停或恢复容器日志刷新");
        pauseButton.Click += (_, _) =>
        {
            if (pauseButton.IsChecked == true)
            {
                controller.Pause();
            }
            else
            {
                controller.Resume();
            }
        };
        followButton = CreateToggleButton("跟随最新", "自动跟随最新容器日志");
        followButton.IsChecked = true;
        followButton.Click += (_, _) =>
        {
            if (followButton.IsChecked == true)
            {
                ScrollToLatest();
            }
        };

        var refreshButton = CreateActionButton("立即刷新", "立即刷新容器日志");
        refreshButton.Click += async (_, _) =>
        {
            refreshButton.IsEnabled = false;
            try
            {
                statusText.Text = "正在刷新容器日志…";
                await controller.RefreshNowAsync();
            }
            finally
            {
                refreshButton.IsEnabled = true;
            }
        };
        var latestButton = CreateActionButton("最新日志", "返回最新容器日志");
        latestButton.Click += (_, _) =>
        {
            followButton.IsChecked = true;
            ScrollToLatest();
        };
        var copyButton = CreateActionButton("复制", "复制选中或全部容器日志");
        copyButton.Click += (_, _) => CopyVisibleLogs();

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(pauseButton);
        actions.Children.Add(followButton);
        actions.Children.Add(refreshButton);
        actions.Children.Add(latestButton);
        actions.Children.Add(copyButton);
        Grid.SetRow(actions, 2);
        root.Children.Add(actions);

        searchStatusText = new TextBlock
        {
            Text = "输入关键词可定位日志",
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        };
        searchBox = new TextBox
        {
            PlaceholderText = "搜索日志",
            MinWidth = 280,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(searchBox, "搜索容器日志");
        previousMatchButton = CreateCompactButton("上一处", "定位到上一个日志匹配项");
        nextMatchButton = CreateCompactButton("下一处", "定位到下一个日志匹配项");
        previousMatchButton.Click += (_, _) => SelectRelativeMatch(-1);
        nextMatchButton.Click += (_, _) => SelectRelativeMatch(1);

        var searchRow = new Grid { ColumnSpacing = 8 };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.Children.Add(searchBox);
        Grid.SetColumn(previousMatchButton, 1);
        Grid.SetColumn(nextMatchButton, 2);
        Grid.SetColumn(searchStatusText, 3);
        searchRow.Children.Add(previousMatchButton);
        searchRow.Children.Add(nextMatchButton);
        searchRow.Children.Add(searchStatusText);
        Grid.SetRow(searchRow, 3);
        root.Children.Add(searchRow);

        logTextBox = new TextBox
        {
            Text = "正在读取容器日志…",
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono"),
            FontSize = 12,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            MinHeight = 320,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(logTextBox, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(logTextBox, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(logTextBox, "容器日志内容");
        logTextBox.PointerPressed += (_, _) => followButton.IsChecked = false;
        logTextBox.PointerWheelChanged += (_, e) =>
        {
            if (e.GetCurrentPoint(logTextBox).Properties.MouseWheelDelta > 0)
            {
                followButton.IsChecked = false;
            }
        };
        Grid.SetRow(logTextBox, 4);
        root.Children.Add(logTextBox);
        Grid.SetRow(root, 1);
        windowRoot.Children.Add(root);
        windowFrame = new Border
        {
            Margin = new Thickness(1),
            // The native caption buttons own the top edge. Drawing the custom
            // frame underneath them makes that area look clipped.
            BorderThickness = new Thickness(2, 0, 2, 2),
            CornerRadius = new CornerRadius(12),
            IsHitTestVisible = false,
        };
        Grid.SetRowSpan(windowFrame, 2);
        windowRoot.Children.Add(windowFrame);
        Content = windowRoot;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(appTitleBar);

        searchTimer = DispatcherQueue.CreateTimer();
        searchTimer.Interval = TimeSpan.FromMilliseconds(160);
        searchTimer.IsRepeating = false;
        searchTimer.Tick += (_, _) => RebuildSearchMatches(selectFirst: true);
        searchBox.TextChanged += (_, _) =>
        {
            searchTimer.Stop();
            searchTimer.Start();
        };

        controller.FrameReceived += ControllerFrameReceived;
        controller.PauseChanged += ControllerPauseChanged;
        Closed += DockerLogWindowClosed;

        ApplyTheme(requestedTheme);
        PositionRelativeToOwner(ownerWindow);
    }

    public void Show()
    {
        ObjectDisposedException.ThrowIf(isDisposed, this);
        controller.Start();
        Activate();
    }

    public void ApplyTheme(ElementTheme theme)
    {
        if (isDisposed)
        {
            return;
        }

        windowRoot.RequestedTheme = theme;
        root.RequestedTheme = theme;
        var dark = theme == ElementTheme.Dark || windowRoot.ActualTheme == ElementTheme.Dark;
        var windowBackground = ResourceColor("OrbitFeatureWindowBrush");
        var titleBackground = ResourceColor("OrbitFeatureTitleBarBrush");
        var panelBackground = ResourceColor("OrbitFeatureInnerBrush");
        var primary = ResourceColor("OrbitPrimaryTextBrush");
        var muted = ResourceColor("OrbitMutedTextBrush");
        var border = ResourceColor("OrbitFeatureWindowStrokeBrush");
        var hover = ResourceColor("OrbitAccentSoftBrush");
        var pressed = ResourceColor("OrbitPanelStrokeBrush");

        windowRoot.Background = new SolidColorBrush(windowBackground);
        appTitleBar.Background = new SolidColorBrush(titleBackground);
        titleBarText.Foreground = new SolidColorBrush(primary);
        root.Background = new SolidColorBrush(windowBackground);
        logTextBox.Background = new SolidColorBrush(panelBackground);
        logTextBox.Foreground = new SolidColorBrush(primary);
        logTextBox.BorderBrush = new SolidColorBrush(border);
        windowFrame.BorderBrush = new SolidColorBrush(border);
        statusText.Foreground = new SolidColorBrush(muted);
        searchStatusText.Foreground = new SolidColorBrush(muted);

        if (AppWindow?.TitleBar is { } titleBar)
        {
            titleBar.BackgroundColor = titleBackground;
            titleBar.InactiveBackgroundColor = titleBackground;
            titleBar.ForegroundColor = primary;
            titleBar.InactiveForegroundColor = muted;
            titleBar.ButtonBackgroundColor = titleBackground;
            titleBar.ButtonInactiveBackgroundColor = titleBackground;
            titleBar.ButtonForegroundColor = primary;
            titleBar.ButtonInactiveForegroundColor = muted;
            titleBar.ButtonHoverBackgroundColor = hover;
            titleBar.ButtonHoverForegroundColor = primary;
            titleBar.ButtonPressedBackgroundColor = pressed;
            titleBar.ButtonPressedForegroundColor = primary;
        }
        NativeWindowCornerService.ApplyVisibleFrameTheme(this, dark);
    }

    public void StopAndClose()
    {
        if (!isClosed)
        {
            Close();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (isDisposed)
        {
            return;
        }

        isDisposed = true;
        searchTimer.Stop();
        controller.FrameReceived -= ControllerFrameReceived;
        controller.PauseChanged -= ControllerPauseChanged;
        await controller.DisposeAsync();
    }

    private void ControllerFrameReceived(DockerLogFrame frame)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (isDisposed)
            {
                return;
            }

            statusText.Text = frame.Status;
            if (!frame.IsError || !string.IsNullOrEmpty(frame.Text))
            {
                var changed = !string.Equals(logTextBox.Text, frame.Text, StringComparison.Ordinal);
                if (changed)
                {
                    logTextBox.Text = frame.Text;
                    if (!string.IsNullOrWhiteSpace(searchBox.Text))
                    {
                        searchTimer.Stop();
                        searchTimer.Start();
                    }
                    if (followButton.IsChecked == true && string.IsNullOrWhiteSpace(searchBox.Text))
                    {
                        ScrollToLatest();
                    }
                }
            }

            if (frame.IsError && frame.Status.Contains("会话已切换或断开", StringComparison.Ordinal))
            {
                pauseButton.IsChecked = true;
                pauseButton.Content = "已停止";
                pauseButton.IsEnabled = false;
                followButton.IsEnabled = false;
                controller.Pause();
            }
        });
    }

    private void ControllerPauseChanged(bool paused)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (isDisposed)
            {
                return;
            }
            pauseButton.IsChecked = paused;
            pauseButton.Content = paused ? "继续" : "暂停";
            statusText.Text = paused
                ? "日志刷新已暂停；当前内容保持可搜索和复制。"
                : controller.LatestFrame?.Status ?? "日志刷新已恢复。";
        });
    }

    private void RebuildSearchMatches(bool selectFirst)
    {
        searchMatches = DockerLogSessionController.FindMatches(logTextBox.Text, searchBox.Text);
        previousMatchButton.IsEnabled = searchMatches.Count > 0;
        nextMatchButton.IsEnabled = searchMatches.Count > 0;
        if (string.IsNullOrWhiteSpace(searchBox.Text))
        {
            selectedMatchIndex = -1;
            searchStatusText.Text = "输入关键词可定位日志";
            return;
        }
        if (searchMatches.Count == 0)
        {
            selectedMatchIndex = -1;
            searchStatusText.Text = "无匹配结果";
            return;
        }
        if (selectFirst || selectedMatchIndex < 0 || selectedMatchIndex >= searchMatches.Count)
        {
            selectedMatchIndex = 0;
        }
        SelectCurrentMatch();
    }

    private void SelectRelativeMatch(int offset)
    {
        if (searchMatches.Count == 0)
        {
            return;
        }
        selectedMatchIndex = (selectedMatchIndex + offset + searchMatches.Count) % searchMatches.Count;
        SelectCurrentMatch();
    }

    private void SelectCurrentMatch()
    {
        if (selectedMatchIndex < 0 || selectedMatchIndex >= searchMatches.Count)
        {
            return;
        }
        followButton.IsChecked = false;
        logTextBox.Select(searchMatches[selectedMatchIndex], searchBox.Text.Length);
        logTextBox.Focus(FocusState.Programmatic);
        searchStatusText.Text = $"{selectedMatchIndex + 1} / {searchMatches.Count}";
    }

    private void CopyVisibleLogs()
    {
        var text = string.IsNullOrEmpty(logTextBox.SelectedText)
            ? logTextBox.Text
            : logTextBox.SelectedText;
        if (string.IsNullOrEmpty(text))
        {
            statusText.Text = "当前没有可复制的日志。";
            return;
        }
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        statusText.Text = string.IsNullOrEmpty(logTextBox.SelectedText)
            ? "全部日志已复制。"
            : "所选日志已复制。";
    }

    private void ScrollToLatest()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (isDisposed)
            {
                return;
            }
            logTextBox.Select(logTextBox.Text.Length, 0);
            logTextBox.Focus(FocusState.Programmatic);
        });
    }

    private async void DockerLogWindowClosed(object sender, WindowEventArgs args)
    {
        if (isClosed)
        {
            return;
        }
        isClosed = true;
        await controller.StopAsync();
    }

    private void PositionRelativeToOwner(AppWindow ownerWindow)
    {
        var width = Math.Clamp((int)Math.Round(ownerWindow.Size.Width * 0.78), 900, 1280);
        var height = Math.Clamp((int)Math.Round(ownerWindow.Size.Height * 0.8), 620, 900);
        AppWindow.Resize(new SizeInt32(width, height));
        AppWindow.Move(new PointInt32(
            ownerWindow.Position.X + Math.Max(24, (ownerWindow.Size.Width - width) / 2),
            ownerWindow.Position.Y + Math.Max(24, (ownerWindow.Size.Height - height) / 2)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMaximizable = true;
            presenter.IsMinimizable = true;
        }
    }

    private static ToggleButton CreateToggleButton(string content, string accessibleName)
    {
        var button = new ToggleButton
        {
            Content = content,
            MinWidth = 112,
            MinHeight = 34,
            Padding = new Thickness(12, 5, 12, 5),
        };
        AutomationProperties.SetName(button, accessibleName);
        return button;
    }

    private static Button CreateActionButton(string content, string accessibleName)
    {
        var button = new Button
        {
            Content = content,
            MinWidth = 112,
            MinHeight = 34,
            Padding = new Thickness(12, 5, 12, 5),
        };
        AutomationProperties.SetName(button, accessibleName);
        return button;
    }

    private static Button CreateCompactButton(string content, string accessibleName)
    {
        var button = new Button
        {
            Content = content,
            MinWidth = 64,
            Padding = new Thickness(8, 4, 8, 4),
        };
        AutomationProperties.SetName(button, accessibleName);
        return button;
    }

    private static Color ResourceColor(string key)
    {
        if (Microsoft.UI.Xaml.Application.Current.Resources.TryGetValue(key, out var value) &&
            value is SolidColorBrush brush)
        {
            return brush.Color;
        }
        return Color.FromArgb(255, 20, 25, 34);
    }
}
