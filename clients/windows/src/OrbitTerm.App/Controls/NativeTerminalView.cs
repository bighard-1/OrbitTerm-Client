using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using OrbitTerm.Presentation;
using OrbitTerm.Terminal;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Native terminal surface. It renders the existing terminal screen model and
/// routes keyboard bytes straight to the active PTY; it never overlays a form
/// field over terminal output.
/// </summary>
public sealed class NativeTerminalView : Canvas
{
    private const double HorizontalPadding = 14;
    private const double VerticalPadding = 14;
    private const double DefaultCellWidth = 7.8;
    private const double DefaultCellHeight = 18;
    private const double SelectionScrollEdge = 36;
    private static readonly Color DefaultForeground = Color.FromArgb(255, 215, 222, 232);
    private static readonly Color DefaultBackground = Color.FromArgb(255, 16, 19, 24);
    private ObservableCollection<TerminalLineViewModel>? lines;
    private bool isLineSourceSubscribed;
    private bool isControlLoaded;
    private bool renderQueued;
    private TerminalCell? selectionAnchor;
    private TerminalCell? selectionEnd;
    private readonly MenuFlyout terminalContextFlyout;
    private readonly MenuFlyoutItem copySelectionItem;
    private readonly MenuFlyoutSeparator closeSplitPaneSeparator;
    private readonly MenuFlyoutItem closeSplitPaneItem;
    private readonly DispatcherQueueTimer renderTimer;
    private readonly DispatcherQueueTimer cursorBlinkTimer;
    private readonly DispatcherQueueTimer selectionAutoScrollTimer;
    private readonly DispatcherQueueTimer scrollToLatestTimer;
    private ScrollViewer? scrollHost;
    private double cellWidth = DefaultCellWidth;
    private double cellHeight = DefaultCellHeight;
    private double selectionScrollVelocity;
    private double lastPointerViewportX;
    private double lastPointerViewportY;
    private bool selectionStarted;
    private Windows.Foundation.Point selectionPressPosition;
    private bool isCursorVisible = true;
    private string searchQuery = string.Empty;
    private readonly List<TerminalMatch> searchMatches = [];
    private int activeSearchMatchIndex = -1;
    private double fontSize = 13;
    private TerminalColorTheme colorTheme = TerminalColorTheme.Dark;
    private bool followsApplicationTheme;
    private bool applicationThemeIsDark = true;
    private string applicationPalette = "翡翠流光";
    private int scrollToLatestAttempts;
    private double lastScrollOffset;
    private bool isFollowingLatestOutput = true;
    private bool isForcingLatestOutput;
    private readonly ConcurrentQueue<byte[]> pendingInput = new();
    private int inputPumpRunning;

    public NativeTerminalView()
    {
        Background = new SolidColorBrush(DefaultBackground);
        IsTabStop = true;
        AddHandler(PointerPressedEvent, new PointerEventHandler(TerminalPointerPressed), true);
        AddHandler(PointerMovedEvent, new PointerEventHandler(TerminalPointerMoved), true);
        AddHandler(PointerReleasedEvent, new PointerEventHandler(TerminalPointerReleased), true);
        KeyDown += TerminalKeyDown;
        CharacterReceived += TerminalCharacterReceived;
        GotFocus += (_, _) => Activated?.Invoke(this, EventArgs.Empty);
        RightTapped += TerminalRightTapped;
        SizeChanged += (_, _) => QueueRender();
        renderTimer = DispatcherQueue.CreateTimer();
        renderTimer.Interval = TimeSpan.FromMilliseconds(16);
        renderTimer.Tick += RenderTimerTick;
        cursorBlinkTimer = DispatcherQueue.CreateTimer();
        cursorBlinkTimer.Interval = TimeSpan.FromMilliseconds(530);
        cursorBlinkTimer.Tick += (_, _) =>
        {
            isCursorVisible = !isCursorVisible;
            QueueRender();
        };
        scrollToLatestTimer = DispatcherQueue.CreateTimer();
        scrollToLatestTimer.Interval = TimeSpan.FromMilliseconds(35);
        scrollToLatestTimer.Tick += ScrollToLatestTimerTick;
        selectionAutoScrollTimer = DispatcherQueue.CreateTimer();
        selectionAutoScrollTimer.Interval = TimeSpan.FromMilliseconds(16);
        selectionAutoScrollTimer.Tick += SelectionAutoScrollTimerTick;
        Loaded += (_, _) =>
        {
            isControlLoaded = true;
            SubscribeToLineSource();
            CalibrateCellMetrics();
            cursorBlinkTimer.Start();
            if (renderQueued)
            {
                renderTimer.Start();
            }
        };
        Unloaded += (_, _) =>
        {
            isControlLoaded = false;
            cursorBlinkTimer.Stop();
            renderTimer.Stop();
            scrollToLatestTimer.Stop();
            selectionAutoScrollTimer.Stop();
            Unsubscribe();
        };
        copySelectionItem = new MenuFlyoutItem { Text = "复制" };
        copySelectionItem.Click += (_, _) => CopySelectionToClipboard();
        var pasteItem = new MenuFlyoutItem { Text = "粘贴" };
        pasteItem.Click += (_, _) => PasteRequested?.Invoke(this, EventArgs.Empty);
        terminalContextFlyout = new MenuFlyout();
        terminalContextFlyout.Items.Add(copySelectionItem);
        terminalContextFlyout.Items.Add(pasteItem);
        terminalContextFlyout.Items.Add(new MenuFlyoutSeparator());
        var searchItem = new MenuFlyoutItem { Text = "搜索终端输出" };
        searchItem.Click += (_, _) => SearchRequested?.Invoke(this, EventArgs.Empty);
        var appearanceItem = new MenuFlyoutItem { Text = "终端主题与字体" };
        appearanceItem.Click += (_, _) => AppearanceRequested?.Invoke(this, EventArgs.Empty);
        var clearItem = new MenuFlyoutItem { Text = "清除终端输出" };
        clearItem.Click += (_, _) => ClearRequested?.Invoke(this, EventArgs.Empty);
        var copyTranscriptItem = new MenuFlyoutItem { Text = "复制全部终端输出" };
        copyTranscriptItem.Click += (_, _) => CopyTranscriptRequested?.Invoke(this, EventArgs.Empty);
        terminalContextFlyout.Items.Add(searchItem);
        terminalContextFlyout.Items.Add(appearanceItem);
        terminalContextFlyout.Items.Add(clearItem);
        terminalContextFlyout.Items.Add(copyTranscriptItem);
        closeSplitPaneSeparator = new MenuFlyoutSeparator { Visibility = Visibility.Collapsed };
        terminalContextFlyout.Items.Add(closeSplitPaneSeparator);
        closeSplitPaneItem = new MenuFlyoutItem
        {
            Text = "关闭此分屏",
            Visibility = Visibility.Collapsed,
        };
        closeSplitPaneItem.Click += (_, _) => CloseSplitPaneRequested?.Invoke(this, EventArgs.Empty);
        terminalContextFlyout.Items.Add(closeSplitPaneItem);
        terminalContextFlyout.Opening += (_, _) => copySelectionItem.IsEnabled = GetSelection() is not null;
    }

    /// <summary>Called by the host to write raw PTY bytes for interactive input.</summary>
    public Func<ReadOnlyMemory<byte>, Task>? SendInputAsync { get; set; }

    /// <summary>
    /// Gives the application first refusal only for an explicitly configured
    /// application shortcut. Returning false leaves the gesture entirely to
    /// the remote PTY. This prevents a focused terminal from swallowing app
    /// commands while preserving Ctrl+C and every unassigned control sequence.
    /// </summary>
    public Func<VirtualKey, bool, bool, bool, bool>? TryHandleApplicationShortcut { get; set; }

    /// <summary>The host supplies a user-confirmed paste payload.</summary>
    public event EventHandler? PasteRequested;

    /// <summary>Host-level actions exposed through the terminal's native right-click menu.</summary>
    public event EventHandler? SearchRequested;
    public event EventHandler? AppearanceRequested;
    public event EventHandler? ClearRequested;
    public event EventHandler? CopyTranscriptRequested;
    public event EventHandler? CloseSplitPaneRequested;

    /// <summary>
    /// Keeps split management out of the terminal canvas until this view is an
    /// auxiliary pane. The primary pane never exposes a close action.
    /// </summary>
    public bool CanCloseSplitPane
    {
        get => closeSplitPaneItem.Visibility == Visibility.Visible;
        set
        {
            var visibility = value ? Visibility.Visible : Visibility.Collapsed;
            closeSplitPaneSeparator.Visibility = visibility;
            closeSplitPaneItem.Visibility = visibility;
        }
    }

    /// <summary>Raised only when a drag becomes an actual text selection.</summary>
    public event EventHandler? SelectionStarted;

    /// <summary>
    /// Raised by the terminal surface itself because its handled pointer event
    /// does not reliably bubble to a surrounding split-pane border.
    /// </summary>
    public event EventHandler? Activated;

    public bool IsInputEnabled { get; set; }

    /// <summary>
    /// Places text at the active remote prompt without appending Enter. This is
    /// deliberately different from a paste operation: a shortcut can be reviewed
    /// and edited in the terminal before the user executes it.
    /// </summary>
    public Task InsertTextAtPromptAsync(string text)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(text);
        FocusTerminal();
        return DispatchInputAsync(Encoding.UTF8.GetBytes(text));
    }

    /// <summary>
    /// Enqueues a host-approved clipboard payload on the same ordered path as
    /// keyboard input. This preserves byte order and keeps native writes off the
    /// WinUI dispatcher even when the remote transport is busy.
    /// </summary>
    public Task SendApprovedPasteAsync(string text)
    {
        ArgumentException.ThrowIfNullOrEmpty(text);
        PrepareForInput();
        return DispatchInputAsync(Encoding.UTF8.GetBytes(text));
    }

    public void SetAppearance(
        double requestedFontSize,
        TerminalColorTheme requestedTheme,
        bool followApplicationTheme = false,
        bool appThemeIsDark = true,
        string appPalette = "翡翠流光")
    {
        var nextFontSize = Math.Clamp(requestedFontSize, 8, 24);
        var normalizedPalette = string.IsNullOrWhiteSpace(appPalette) ? "翡翠流光" : appPalette;
        if (Math.Abs(fontSize - nextFontSize) < 0.01 &&
            colorTheme == requestedTheme &&
            followsApplicationTheme == followApplicationTheme &&
            applicationThemeIsDark == appThemeIsDark &&
            string.Equals(applicationPalette, normalizedPalette, StringComparison.Ordinal))
        {
            return;
        }

        var fontSizeChanged = Math.Abs(fontSize - nextFontSize) >= 0.01;
        fontSize = nextFontSize;
        colorTheme = requestedTheme;
        followsApplicationTheme = followApplicationTheme;
        applicationThemeIsDark = appThemeIsDark;
        applicationPalette = normalizedPalette;
        Background = new SolidColorBrush(ThemeBackground);
        // RichTextBlock measurement must run after this control joins the live
        // XAML tree. Measuring it repeatedly during MainWindow construction can
        // block WinUI activation before the first HWND is created.
        if (fontSizeChanged && isControlLoaded)
        {
            CalibrateCellMetrics();
        }
        else if (fontSizeChanged)
        {
            cellWidth = DefaultCellWidth * (fontSize / 13d);
            cellHeight = Math.Ceiling(DefaultCellHeight * (fontSize / 13d));
        }
        QueueRender();
    }

    public void AttachScrollHost(ScrollViewer host)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (ReferenceEquals(scrollHost, host))
        {
            return;
        }

        if (scrollHost is not null)
        {
            scrollHost.SizeChanged -= ScrollHostSizeChanged;
            scrollHost.ViewChanged -= ScrollHostViewChanged;
        }

        scrollHost = host;
        scrollHost.SizeChanged += ScrollHostSizeChanged;
        scrollHost.ViewChanged += ScrollHostViewChanged;
        lastScrollOffset = scrollHost.VerticalOffset;
        UpdateViewportSize();
    }

    private void ScrollHostSizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateViewportSize();
        QueueRender();
    }

    private void ScrollHostViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        QueueRender();
        if (scrollHost is null)
        {
            return;
        }

        var currentOffset = scrollHost.VerticalOffset;
        // A forced jump can briefly be clamped to an older extent while the
        // terminal canvas completes layout. Do not mistake that correction for
        // another user-initiated upward scroll and cancel the first click.
        if (isForcingLatestOutput || scrollToLatestAttempts > 0)
        {
            lastScrollOffset = currentOffset;
            if (scrollHost.ScrollableHeight - currentOffset <= Math.Max(2, cellHeight))
            {
                isForcingLatestOutput = false;
                scrollToLatestAttempts = 0;
                scrollToLatestTimer.Stop();
                SetFollowingLatestOutput(true);
            }
            return;
        }

        // Layout/reflow can reduce the offset without user intent, especially
        // when a split pane is added or resized. Only an intermediate
        // ScrollViewer gesture is allowed to pause following; otherwise a
        // running ping/top pane could silently stop at an old row.
        if (e.IsIntermediate && currentOffset < lastScrollOffset - 0.5)
        {
            SetFollowingLatestOutput(false);
            lastScrollOffset = currentOffset;
            return;
        }

        if (scrollHost.ScrollableHeight - currentOffset <= Math.Max(2, cellHeight))
        {
            SetFollowingLatestOutput(true);
        }

        lastScrollOffset = currentOffset;
    }

    private void UpdateViewportSize()
    {
        if (scrollHost is null)
        {
            return;
        }

        // A Canvas inside ScrollViewer otherwise measures only its text
        // children, producing the small centered terminal seen in the client.
        // Keep the canvas at least as large as the viewport while still
        // allowing its height to grow for scrollback history.
        if (scrollHost.ViewportWidth > 0)
        {
            Width = Math.Max(Width, scrollHost.ViewportWidth);
        }

        if (scrollHost.ViewportHeight > 0)
        {
            Height = Math.Max(Height, scrollHost.ViewportHeight);
        }
    }

    public string UpdateSearchQuery(string query)
    {
        searchQuery = query.Trim();
        RebuildSearchMatches(lines ?? []);
        activeSearchMatchIndex = searchMatches.Count == 0 ? -1 : 0;
        ScrollToActiveSearchMatch();
        QueueRender();
        return BuildSearchSummary();
    }

    public string MoveSearchMatch(bool previous)
    {
        RebuildSearchMatches(lines ?? []);
        if (searchMatches.Count == 0)
        {
            return BuildSearchSummary();
        }

        // Search navigation is cyclic so every press has an observable result
        // (unless there is only one match), matching mature terminal search UX.
        activeSearchMatchIndex = previous
            ? (activeSearchMatchIndex - 1 + searchMatches.Count) % searchMatches.Count
            : (activeSearchMatchIndex + 1) % searchMatches.Count;
        ScrollToActiveSearchMatch();
        QueueRender();
        return BuildSearchSummary();
    }

    public void Bind(ObservableCollection<TerminalLineViewModel> source)
    {
        if (ReferenceEquals(lines, source))
        {
            SubscribeToLineSource();
            QueueRender();
            return;
        }

        Unsubscribe();
        lines = source;
        SubscribeToLineSource();

        QueueRender();
    }

    public bool FocusTerminal() => Focus(FocusState.Programmatic);

    public bool IsFollowingLatestOutput => isFollowingLatestOutput;

    public event EventHandler? FollowLatestChanged;

    /// <summary>
    /// Follows the newest terminal row after rendering and WinUI layout have
    /// both updated the scroll extent. Large output bursts can otherwise make
    /// a one-shot scroll run against the previous canvas height.
    /// </summary>
    public void ScrollToLatestOutput()
    {
        isForcingLatestOutput = true;
        QueueRender();
        UpdateViewportSize();
        StartScrollToLatestOutput();
    }

    public void RequestAutoScrollToLatestOutput()
    {
        if (isFollowingLatestOutput)
        {
            StartScrollToLatestOutput();
        }
    }

    public void PauseFollowingLatestOutput() => SetFollowingLatestOutput(false);

    private void StartScrollToLatestOutput()
    {
        // Large terminal histories can require several render/layout passes
        // before ScrollableHeight reflects the newest canvas height. Keep
        // retrying long enough for that layout to settle.
        scrollToLatestAttempts = 60;
        scrollToLatestTimer.Stop();
        scrollToLatestTimer.Start();
    }

    private void SetFollowingLatestOutput(bool value)
    {
        if (isFollowingLatestOutput == value)
        {
            return;
        }

        isFollowingLatestOutput = value;
        if (!value && !isForcingLatestOutput)
        {
            scrollToLatestAttempts = 0;
            scrollToLatestTimer.Stop();
        }
        FollowLatestChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ScrollToLatestTimerTick(DispatcherQueueTimer sender, object args)
    {
        if (scrollHost is null || scrollToLatestAttempts <= 0)
        {
            sender.Stop();
            return;
        }

        // double.MaxValue is deliberately used here. ScrollViewer clamps it to
        // its current extent, which remains correct while a virtualized terminal
        // canvas is still completing one or more layout passes.
        scrollHost.ChangeView(null, double.MaxValue, null, true);
        lastScrollOffset = scrollHost.VerticalOffset;
        scrollToLatestAttempts--;
        if (scrollHost.ScrollableHeight - scrollHost.VerticalOffset <= Math.Max(2, cellHeight))
        {
            isForcingLatestOutput = false;
            scrollToLatestAttempts = 0;
            SetFollowingLatestOutput(true);
            sender.Stop();
        }
        else if (scrollToLatestAttempts == 0)
        {
            isForcingLatestOutput = false;
            sender.Stop();
        }
    }

    private void LinesCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.OldItems is not null)
        {
            foreach (TerminalLineViewModel line in e.OldItems)
            {
                line.PropertyChanged -= LinePropertyChanged;
            }
        }

        if (e.NewItems is not null)
        {
            foreach (TerminalLineViewModel line in e.NewItems)
            {
                line.PropertyChanged += LinePropertyChanged;
            }
        }

        QueueRender();
        RequestAutoScrollToLatestOutput();
    }

    private void LinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        QueueRender();
        RequestAutoScrollToLatestOutput();
    }

    private void QueueRender()
    {
        renderQueued = true;
        if (isControlLoaded)
        {
            renderTimer.Start();
        }
    }

    private void RenderTimerTick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (!renderQueued)
        {
            return;
        }

        renderQueued = false;
        RenderScreen();
    }

    private void RenderScreen()
    {
        Children.Clear();
        var currentLines = lines;
        if (currentLines is null)
        {
            return;
        }

        TerminalLineViewModel? cursorLine = null;
        var cursorRow = 0;
        var firstVisibleRow = scrollHost is null
            ? 0
            : Math.Max(0, (int)Math.Floor((scrollHost.VerticalOffset - VerticalPadding) / cellHeight) - 2);
        var visibleRows = scrollHost is null || scrollHost.ViewportHeight <= 0
            ? currentLines.Count
            : (int)Math.Ceiling(scrollHost.ViewportHeight / cellHeight) + 5;
        var lastVisibleRowExclusive = Math.Min(currentLines.Count, firstVisibleRow + visibleRows);
        RebuildSearchMatches(currentLines);
        AddSearchHighlights(currentLines, firstVisibleRow, lastVisibleRowExclusive);
        AddSelectionHighlights(currentLines, firstVisibleRow, lastVisibleRowExclusive);
        for (var row = 0; row < currentLines.Count; row++)
        {
            var line = currentLines[row];
            if (line.IsCursorRow && line.CursorColumn >= 0)
            {
                cursorLine = line;
                cursorRow = row;
            }

            if (row < firstVisibleRow || row >= lastVisibleRowExclusive)
            {
                continue;
            }

            var text = BuildLine(line);
            SetLeft(text, HorizontalPadding);
            SetTop(text, VerticalPadding + (row * cellHeight));
            Children.Add(text);
        }

        if (cursorLine is not null && isCursorVisible &&
            cursorRow >= firstVisibleRow && cursorRow < lastVisibleRowExclusive)
        {
            var cursor = new Border
            {
                Width = cellWidth,
                Height = cellHeight - 2,
                Background = new SolidColorBrush(Color.FromArgb(135, 230, 237, 243)),
                IsHitTestVisible = false,
            };
            SetLeft(cursor, HorizontalPadding + (cursorLine.CursorColumn * cellWidth));
            SetTop(cursor, VerticalPadding + (cursorRow * cellHeight));
            Children.Add(cursor);
        }

        var contentHeight = VerticalPadding * 2 + (Math.Max(1, currentLines.Count) * cellHeight);
        var viewportWidth = scrollHost?.ViewportWidth > 0 ? scrollHost.ViewportWidth : ActualWidth;
        var viewportHeight = scrollHost?.ViewportHeight > 0 ? scrollHost.ViewportHeight : ActualHeight;
        // The PTY is resized to the viewport column count. Do not preserve the
        // historical longest row as a wider XAML surface: doing so creates a
        // horizontal scrollbar and leaves stale blank space after the inspector
        // is resized. Rows outside the current PTY width are clipped until the
        // screen model completes its bounded reflow.
        Width = Math.Max(1, viewportWidth);
        Height = Math.Max(viewportHeight, contentHeight);
    }

    private RichTextBlock BuildLine(TerminalLineViewModel line)
    {
        var text = new RichTextBlock
        {
            // Selection is owned by the terminal canvas so a right-click never asks
            // RichTextBlock to replace the user's cell-range before Copy executes.
            IsTextSelectionEnabled = false,
            TextWrapping = TextWrapping.NoWrap,
            MaxWidth = Math.Max(1, (scrollHost?.ViewportWidth ?? ActualWidth) - (HorizontalPadding * 2)),
            FontFamily = new FontFamily("Cascadia Mono"),
            FontSize = fontSize,
        };
        var paragraph = new Paragraph { Margin = new Thickness(0) };
        var runs = GetRenderableRuns(line);
        var textOffset = 0;
        foreach (var terminalRun in runs)
        {
            var (foreground, background) = ResolveColors(terminalRun.Style);
            paragraph.Inlines.Add(new Run
            {
                Text = terminalRun.Text,
                Foreground = new SolidColorBrush(foreground),
                FontWeight = terminalRun.Style.IsBold || terminalRun.Style.IsInverse ? FontWeights.SemiBold : FontWeights.Normal,
            });
            if (terminalRun.Text.Length > 0 &&
                (terminalRun.Style.Background.Kind != TerminalColorKind.Default || terminalRun.Style.IsInverse))
            {
                var highlighter = new TextHighlighter
                {
                    Background = new SolidColorBrush(background),
                    Foreground = new SolidColorBrush(foreground),
                };
                highlighter.Ranges.Add(new TextRange
                {
                    StartIndex = textOffset,
                    Length = terminalRun.Text.Length,
                });
                text.TextHighlighters.Add(highlighter);
            }
            textOffset += terminalRun.Text.Length;
        }

        text.Blocks.Add(paragraph);
        return text;
    }

    private static IReadOnlyList<TerminalTextRun> GetRenderableRuns(TerminalLineViewModel line)
    {
        if (line.Runs.Count == 0)
        {
            return [new TerminalTextRun(line.Text, TerminalStyle.Default)];
        }

        return line.Runs;
    }

    private void TerminalPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (point.Properties.IsRightButtonPressed ||
            point.Properties.PointerUpdateKind is Microsoft.UI.Input.PointerUpdateKind.RightButtonPressed or Microsoft.UI.Input.PointerUpdateKind.MiddleButtonPressed)
        {
            // Context-menu invocation must never move either edge of the
            // existing selection. Copy uses this immutable cell range.
            return;
        }

        selectionAnchor = CellAt(point.Position);
        selectionEnd = selectionAnchor;
        selectionStarted = false;
        selectionPressPosition = point.Position;
        CapturePointer(e.Pointer);
        if (IsInputEnabled)
        {
            Activated?.Invoke(this, EventArgs.Empty);
            FocusTerminal();
        }

        e.Handled = true;
    }

    private void TerminalPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (selectionAnchor is null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            return;
        }

        var position = e.GetCurrentPoint(this).Position;
        if (!selectionStarted &&
            Math.Abs(position.X - selectionPressPosition.X) < 3 &&
            Math.Abs(position.Y - selectionPressPosition.Y) < 3)
        {
            return;
        }

        var nextEnd = CellAt(position);
        if (!selectionStarted)
        {
            selectionStarted = true;
            PauseFollowingLatestOutput();
            SelectionStarted?.Invoke(this, EventArgs.Empty);
        }

        if (nextEnd == selectionEnd)
        {
            return;
        }

        selectionEnd = nextEnd;

        UpdateSelectionAutoScroll(position);
        QueueRender();
        e.Handled = true;
    }

    private void TerminalPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (point.Properties.PointerUpdateKind is Microsoft.UI.Input.PointerUpdateKind.RightButtonReleased or Microsoft.UI.Input.PointerUpdateKind.MiddleButtonReleased)
        {
            // The completed left-drag selection remains authoritative. A
            // context-menu release must not replace its end cell.
            return;
        }

        if (selectionAnchor is null)
        {
            return;
        }

        if (selectionStarted)
        {
            selectionEnd = CellAt(point.Position);
        }
        else
        {
            selectionAnchor = null;
            selectionEnd = null;
        }
        ReleasePointerCapture(e.Pointer);
        StopSelectionAutoScroll();
        QueueRender();
        e.Handled = true;
    }

    private void TerminalRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        terminalContextFlyout.ShowAt(this, new FlyoutShowOptions
        {
            Position = e.GetPosition(this),
        });
        e.Handled = true;
    }

    private void TerminalCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (!IsInputEnabled || e.Character == 0)
        {
            return;
        }

        PrepareForInput();
        _ = DispatchInputAsync(Encoding.UTF8.GetBytes(char.ConvertFromUtf32((int)e.Character)));
        e.Handled = true;
    }

    private void TerminalKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!IsInputEnabled)
        {
            return;
        }

        var control = IsControlDown();
        var shift = IsShiftDown();
        var alt = IsAltDown();
        if (TryHandleApplicationShortcut?.Invoke(e.Key, control, shift, alt) == true)
        {
            e.Handled = true;
            return;
        }

        if (control && e.Key == VirtualKey.V)
        {
            PasteRequested?.Invoke(this, EventArgs.Empty);
            e.Handled = true;
            return;
        }

        if (control && shift && e.Key == VirtualKey.C)
        {
            CopySelectionToClipboard();
            e.Handled = true;
            return;
        }

        var bytes = e.Key switch
        {
            VirtualKey.Enter => new byte[] { 0x0D },
            VirtualKey.Back => new byte[] { 0x7F },
            VirtualKey.Tab => new byte[] { 0x09 },
            VirtualKey.Escape => new byte[] { 0x1B },
            VirtualKey.Left => new byte[] { 0x1B, (byte)'[', (byte)'D' },
            VirtualKey.Up => new byte[] { 0x1B, (byte)'[', (byte)'A' },
            VirtualKey.Right => new byte[] { 0x1B, (byte)'[', (byte)'C' },
            VirtualKey.Down => new byte[] { 0x1B, (byte)'[', (byte)'B' },
            VirtualKey.Home => new byte[] { 0x1B, (byte)'[', (byte)'H' },
            VirtualKey.End => new byte[] { 0x1B, (byte)'[', (byte)'F' },
            VirtualKey.Insert => new byte[] { 0x1B, (byte)'[', (byte)'2', (byte)'~' },
            VirtualKey.Delete => new byte[] { 0x1B, (byte)'[', (byte)'3', (byte)'~' },
            VirtualKey.PageUp => new byte[] { 0x1B, (byte)'[', (byte)'5', (byte)'~' },
            VirtualKey.PageDown => new byte[] { 0x1B, (byte)'[', (byte)'6', (byte)'~' },
            _ => GetControlBytes(e.Key),
        };
        if (bytes is null)
        {
            return;
        }

        PrepareForInput();
        _ = DispatchInputAsync(bytes);
        e.Handled = true;
    }

    private static byte[]? GetControlBytes(VirtualKey key)
    {
        if (!IsControlDown() || key is < VirtualKey.A or > VirtualKey.Z)
        {
            return null;
        }

        return [(byte)(key - VirtualKey.A + 1)];
    }

    private static bool IsControlDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0;

    private static bool IsShiftDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;

    private static bool IsAltDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu) & CoreVirtualKeyStates.Down) != 0;

    private Task DispatchInputAsync(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.IsEmpty || SendInputAsync is null)
        {
            return Task.CompletedTask;
        }

        pendingInput.Enqueue(bytes.ToArray());
        StartInputPump();
        return Task.CompletedTask;
    }

    private void StartInputPump()
    {
        if (Interlocked.CompareExchange(ref inputPumpRunning, 1, 0) != 0)
        {
            return;
        }

        _ = Task.Run(PumpInputAsync);
    }

    private async Task PumpInputAsync()
    {
        try
        {
            while (pendingInput.TryDequeue(out var first))
            {
                using var batch = new MemoryStream(capacity: Math.Min(8192, Math.Max(64, first.Length)));
                batch.Write(first);
                // Coalesce already queued printable keystrokes without waiting.
                // Control bytes retain their position and the entire batch is
                // delivered by one ordered native call.
                while (batch.Length < 8192 && pendingInput.TryDequeue(out var next))
                {
                    batch.Write(next);
                }

                var sender = SendInputAsync;
                if (sender is not null)
                {
                    await sender(batch.ToArray()).ConfigureAwait(false);
                }
            }
        }
        catch (Exception)
        {
            // Transport failures are surfaced by the view model's connection
            // state. The input pump itself must never terminate the UI process.
        }
        finally
        {
            Volatile.Write(ref inputPumpRunning, 0);
            if (!pendingInput.IsEmpty)
            {
                StartInputPump();
            }
        }
    }

    private void PrepareForInput()
    {
        ClearSelection();
        ResetCursorBlink();
        ScrollToLatestOutput();
    }

    public void ClearSelection()
    {
        selectionAnchor = null;
        selectionEnd = null;
        selectionStarted = false;
        StopSelectionAutoScroll();
        QueueRender();
    }

    private void ResetCursorBlink()
    {
        isCursorVisible = true;
        cursorBlinkTimer.Stop();
        cursorBlinkTimer.Start();
        QueueRender();
    }

    private void Unsubscribe()
    {
        if (lines is null || !isLineSourceSubscribed)
        {
            return;
        }

        lines.CollectionChanged -= LinesCollectionChanged;
        foreach (var line in lines)
        {
            line.PropertyChanged -= LinePropertyChanged;
        }
        isLineSourceSubscribed = false;
    }

    private void SubscribeToLineSource()
    {
        if (!isControlLoaded || lines is null || isLineSourceSubscribed)
        {
            return;
        }

        lines.CollectionChanged += LinesCollectionChanged;
        foreach (var line in lines)
        {
            line.PropertyChanged += LinePropertyChanged;
        }
        isLineSourceSubscribed = true;
    }

    private void CalibrateCellMetrics()
    {
        const int probeLength = 80;
        var probe = new RichTextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono"),
            FontSize = fontSize,
            TextWrapping = TextWrapping.NoWrap,
        };
        var paragraph = new Paragraph { Margin = new Thickness(0) };
        paragraph.Inlines.Add(new Run { Text = new string('0', probeLength) });
        probe.Blocks.Add(paragraph);
        probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var measuredWidth = probe.DesiredSize.Width / probeLength;
        if (measuredWidth <= 0 || probe.DesiredSize.Height <= 0)
        {
            return;
        }

        cellWidth = measuredWidth;
        cellHeight = Math.Ceiling(probe.DesiredSize.Height);
        QueueRender();
    }

    private void UpdateSelectionAutoScroll(Windows.Foundation.Point position)
    {
        if (scrollHost is null)
        {
            return;
        }

        lastPointerViewportX = position.X - scrollHost.HorizontalOffset;
        lastPointerViewportY = position.Y - scrollHost.VerticalOffset;
        var distanceFromTop = lastPointerViewportY;
        var distanceFromBottom = scrollHost.ViewportHeight - lastPointerViewportY;
        selectionScrollVelocity = distanceFromTop < SelectionScrollEdge
            ? -Math.Max(2, (SelectionScrollEdge - distanceFromTop) / 4)
            : distanceFromBottom < SelectionScrollEdge
                ? Math.Max(2, (SelectionScrollEdge - distanceFromBottom) / 4)
                : 0;

        if (selectionScrollVelocity == 0)
        {
            StopSelectionAutoScroll();
        }
        else
        {
            selectionAutoScrollTimer.Start();
        }
    }

    private void SelectionAutoScrollTimerTick(DispatcherQueueTimer sender, object args)
    {
        var host = scrollHost;
        if (selectionAnchor is null || host is null || selectionScrollVelocity == 0)
        {
            StopSelectionAutoScroll();
            return;
        }

        var targetOffset = Math.Clamp(
            host.VerticalOffset + selectionScrollVelocity,
            0,
            host.ScrollableHeight);
        if (Math.Abs(targetOffset - host.VerticalOffset) < 0.1)
        {
            StopSelectionAutoScroll();
            return;
        }

        host.ChangeView(null, targetOffset, null, true);
        selectionEnd = CellAt(new Windows.Foundation.Point(
            lastPointerViewportX + host.HorizontalOffset,
            lastPointerViewportY + targetOffset));
        QueueRender();
    }

    private void StopSelectionAutoScroll()
    {
        selectionScrollVelocity = 0;
        selectionAutoScrollTimer.Stop();
    }

    private TerminalCell CellAt(Windows.Foundation.Point point)
    {
        var rowCount = lines?.Count ?? 0;
        var row = Math.Clamp(
            (int)Math.Floor((point.Y - VerticalPadding) / cellHeight),
            0,
            Math.Max(0, rowCount - 1));
        // Selection endpoints are caret boundaries, not inclusive character
        // indexes. Snapping to the nearest edge makes drag selection match a
        // native editor and avoids growing both ends of a selection on copy.
        var lineWidth = row >= 0 && row < rowCount && lines is not null
            ? GetDisplayCellWidth(lines[row].Text)
            : 0;
        var column = TerminalSelectionMath.ToCaretColumn(
            point.X,
            HorizontalPadding,
            cellWidth,
            lineWidth);
        return new TerminalCell(row, column);
    }

    private TerminalSelection? GetSelection()
    {
        if (selectionAnchor is null || selectionEnd is null || selectionAnchor == selectionEnd)
        {
            return null;
        }

        return selectionAnchor.Value.CompareTo(selectionEnd.Value) <= 0
            ? new TerminalSelection(selectionAnchor.Value, selectionEnd.Value)
            : new TerminalSelection(selectionEnd.Value, selectionAnchor.Value);
    }

    private void AddSelectionHighlights(
        IReadOnlyList<TerminalLineViewModel> currentLines,
        int firstVisibleRow,
        int lastVisibleRowExclusive)
    {
        if (GetSelection() is not { } selection)
        {
            return;
        }

        var startRow = Math.Max(selection.Start.Row, firstVisibleRow);
        var endRow = Math.Min(selection.End.Row, lastVisibleRowExclusive - 1);
        for (var row = startRow; row <= endRow && row < currentLines.Count; row++)
        {
            var lineLength = Math.Max(GetDisplayCellWidth(currentLines[row].Text), 1);
            var start = row == selection.Start.Row ? selection.Start.Column : 0;
            var endExclusive = row == selection.End.Row
                ? selection.End.Column
                : lineLength;
            start = Math.Clamp(start, 0, lineLength);
            endExclusive = Math.Clamp(endExclusive, start, lineLength);
            if (endExclusive == start)
            {
                continue;
            }

            var highlight = new Border
            {
                Width = (endExclusive - start) * cellWidth,
                Height = cellHeight,
                Background = new SolidColorBrush(Color.FromArgb(115, 56, 139, 253)),
                IsHitTestVisible = false,
            };
            SetLeft(highlight, HorizontalPadding + (start * cellWidth));
            SetTop(highlight, VerticalPadding + (row * cellHeight));
            Children.Add(highlight);
        }
    }

    private void CopySelectionToClipboard()
    {
        var currentLines = lines;
        if (GetSelection() is not { } selection || currentLines is null)
        {
            return;
        }

        var selectedLines = new List<string>();
        for (var row = selection.Start.Row; row <= selection.End.Row && row < currentLines.Count; row++)
        {
            var text = currentLines[row].Text;
            var start = row == selection.Start.Row ? selection.Start.Column : 0;
            var endExclusive = row == selection.End.Row
                ? selection.End.Column
                : GetDisplayCellWidth(text);
            start = Math.Clamp(start, 0, GetDisplayCellWidth(text));
            endExclusive = Math.Clamp(endExclusive, start, GetDisplayCellWidth(text));
            var startIndex = GetTextIndexAtDisplayColumn(text, start, includePartialWideCell: false);
            var endIndex = GetTextIndexAtDisplayColumn(text, endExclusive, includePartialWideCell: true);
            selectedLines.Add(text[startIndex..endIndex]);
        }

        var selectedText = string.Join("\n", selectedLines);
        if (selectedText.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(selectedText);
        Clipboard.SetContent(package);
    }

    private void RebuildSearchMatches(IReadOnlyList<TerminalLineViewModel> currentLines)
    {
        var previousMatch = activeSearchMatchIndex >= 0 && activeSearchMatchIndex < searchMatches.Count
            ? searchMatches[activeSearchMatchIndex]
            : (TerminalMatch?)null;
        searchMatches.Clear();
        if (searchQuery.Length == 0)
        {
            activeSearchMatchIndex = -1;
            return;
        }

        for (var row = 0; row < currentLines.Count; row++)
        {
            var text = currentLines[row].Text;
            var startIndex = 0;
            while (startIndex < text.Length)
            {
                var matchIndex = text.IndexOf(searchQuery, startIndex, StringComparison.OrdinalIgnoreCase);
                if (matchIndex < 0)
                {
                    break;
                }

                var matchColumn = GetDisplayColumnAtTextIndex(text, matchIndex);
                var matchEndColumn = GetDisplayColumnAtTextIndex(text, matchIndex + searchQuery.Length);
                searchMatches.Add(new TerminalMatch(row, matchColumn, matchEndColumn - matchColumn));
                startIndex = matchIndex + Math.Max(1, searchQuery.Length);
            }
        }

        if (searchMatches.Count == 0)
        {
            activeSearchMatchIndex = -1;
            return;
        }

        if (previousMatch is { } prior)
        {
            var restoredIndex = searchMatches.FindIndex(candidate => candidate == prior);
            activeSearchMatchIndex = restoredIndex >= 0 ? restoredIndex : Math.Clamp(activeSearchMatchIndex, 0, searchMatches.Count - 1);
        }
        else
        {
            activeSearchMatchIndex = Math.Clamp(activeSearchMatchIndex, 0, searchMatches.Count - 1);
        }
    }

    private void AddSearchHighlights(
        IReadOnlyList<TerminalLineViewModel> currentLines,
        int firstVisibleRow,
        int lastVisibleRowExclusive)
    {
        for (var index = 0; index < searchMatches.Count; index++)
        {
            var match = searchMatches[index];
            if (match.Row >= currentLines.Count ||
                match.Row < firstVisibleRow ||
                match.Row >= lastVisibleRowExclusive)
            {
                continue;
            }

            var highlight = new Border
            {
                Width = match.Length * cellWidth,
                Height = cellHeight,
                Background = new SolidColorBrush(index == activeSearchMatchIndex
                    ? Color.FromArgb(225, 255, 153, 0)
                    : Color.FromArgb(72, 255, 205, 64)),
                BorderBrush = index == activeSearchMatchIndex
                    ? new SolidColorBrush(Color.FromArgb(255, 255, 238, 170))
                    : null,
                BorderThickness = index == activeSearchMatchIndex ? new Thickness(1) : new Thickness(0),
                IsHitTestVisible = false,
            };
            SetLeft(highlight, HorizontalPadding + (match.Column * cellWidth));
            SetTop(highlight, VerticalPadding + (match.Row * cellHeight));
            Children.Add(highlight);
        }
    }

    private void ScrollToActiveSearchMatch()
    {
        if (scrollHost is null || activeSearchMatchIndex < 0 || activeSearchMatchIndex >= searchMatches.Count)
        {
            return;
        }

        var match = searchMatches[activeSearchMatchIndex];
        DispatcherQueue.TryEnqueue(() =>
        {
            if (scrollHost is null)
            {
                return;
            }

            var offset = Math.Clamp(
                (match.Row * cellHeight) - (scrollHost.ViewportHeight * 0.4),
                0,
                scrollHost.ScrollableHeight);
            scrollHost.ChangeView(null, offset, null, true);
        });
    }

    private string BuildSearchSummary() => searchQuery.Length == 0
        ? ""
        : searchMatches.Count == 0
            ? "未找到"
            : $"{activeSearchMatchIndex + 1} / {searchMatches.Count}";

    private static int GetDisplayCellWidth(string text)
    {
        var width = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            width += TerminalTextMetrics.CellWidth(rune);
        }

        return width;
    }

    private static int GetDisplayColumnAtTextIndex(string text, int textIndex)
    {
        var column = 0;
        var index = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (index >= textIndex)
            {
                break;
            }

            column += TerminalTextMetrics.CellWidth(rune);
            index += rune.Utf16SequenceLength;
        }

        return column;
    }

    private static int GetTextIndexAtDisplayColumn(string text, int column, bool includePartialWideCell)
    {
        var currentColumn = 0;
        var index = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            var width = TerminalTextMetrics.CellWidth(rune);
            var nextColumn = currentColumn + width;
            if (column <= currentColumn)
            {
                return index;
            }

            if (column < nextColumn)
            {
                return includePartialWideCell ? index + rune.Utf16SequenceLength : index;
            }

            if (column == nextColumn)
            {
                return index + rune.Utf16SequenceLength;
            }

            currentColumn = nextColumn;
            index += rune.Utf16SequenceLength;
        }

        return text.Length;
    }

    private (Color Foreground, Color Background) ResolveColors(TerminalStyle style)
    {
        var foreground = ResolveColor(style.Foreground, ThemeForeground);
        var background = ResolveColor(style.Background, ThemeBackground);
        return style.IsInverse ? (background, foreground) : (foreground, background);
    }

    private Color ResolveColor(TerminalColor color, Color fallback) => color.Kind switch
    {
        TerminalColorKind.Default => fallback,
        TerminalColorKind.Standard => ActiveStandardPalette[Math.Clamp(color.Value, 0, 7)],
        TerminalColorKind.Bright => ActiveBrightPalette[Math.Clamp(color.Value, 0, 7)],
        TerminalColorKind.Indexed => ResolveIndexedColor(color.Value),
        TerminalColorKind.TrueColor => Color.FromArgb(
            255,
            (byte)((color.Value >> 16) & 0xFF),
            (byte)((color.Value >> 8) & 0xFF),
            (byte)(color.Value & 0xFF)),
        _ => fallback,
    };

    /// <summary>Maps the ANSI/xterm 256-colour palette without depending on a web renderer.</summary>
    private Color ResolveIndexedColor(int value)
    {
        value = Math.Clamp(value, 0, 255);
        if (value < 8)
        {
            return ActiveStandardPalette[value];
        }

        if (value < 16)
        {
            return ActiveBrightPalette[value - 8];
        }

        if (value < 232)
        {
            var paletteIndex = value - 16;
            var red = paletteIndex / 36;
            var green = (paletteIndex / 6) % 6;
            var blue = paletteIndex % 6;
            return Color.FromArgb(255, XtermComponent(red), XtermComponent(green), XtermComponent(blue));
        }

        var gray = (byte)(8 + ((value - 232) * 10));
        return Color.FromArgb(255, gray, gray, gray);
    }

    private static byte XtermComponent(int value) => value == 0 ? (byte)0 : (byte)(55 + (40 * value));

    private static readonly Color[] ApplicationDarkStandardPalette =
    [
        Color.FromArgb(255, 72, 79, 88), Color.FromArgb(255, 255, 123, 114),
        Color.FromArgb(255, 86, 211, 100), Color.FromArgb(255, 230, 237, 143),
        Color.FromArgb(255, 121, 192, 255), Color.FromArgb(255, 210, 168, 255),
        Color.FromArgb(255, 57, 197, 207), Color.FromArgb(255, 215, 222, 232),
    ];

    private static readonly Color[] ApplicationDarkBrightPalette =
    [
        Color.FromArgb(255, 139, 148, 158), Color.FromArgb(255, 255, 166, 158),
        Color.FromArgb(255, 126, 231, 135), Color.FromArgb(255, 255, 223, 93),
        Color.FromArgb(255, 166, 216, 255), Color.FromArgb(255, 238, 189, 255),
        Color.FromArgb(255, 125, 225, 228), Color.FromArgb(255, 255, 255, 255),
    ];

    private static readonly Color[] ApplicationLightStandardPalette =
    [
        Color.FromArgb(255, 31, 41, 55), Color.FromArgb(255, 181, 44, 44),
        Color.FromArgb(255, 15, 118, 68), Color.FromArgb(255, 137, 94, 0),
        Color.FromArgb(255, 0, 91, 181), Color.FromArgb(255, 126, 48, 151),
        Color.FromArgb(255, 0, 112, 120), Color.FromArgb(255, 209, 215, 224),
    ];

    private static readonly Color[] ApplicationLightBrightPalette =
    [
        Color.FromArgb(255, 75, 85, 99), Color.FromArgb(255, 210, 45, 45),
        Color.FromArgb(255, 17, 138, 76), Color.FromArgb(255, 166, 112, 0),
        Color.FromArgb(255, 0, 112, 215), Color.FromArgb(255, 151, 62, 181),
        Color.FromArgb(255, 0, 132, 143), Color.FromArgb(255, 255, 255, 255),
    ];

    private static readonly Color[] DraculaStandardPalette =
    [
        Rgb(40, 42, 54), Rgb(255, 85, 85), Rgb(80, 250, 123), Rgb(241, 250, 140),
        Rgb(98, 114, 164), Rgb(255, 121, 198), Rgb(139, 233, 253), Rgb(248, 248, 242),
    ];

    private static readonly Color[] DraculaBrightPalette =
    [
        Rgb(68, 71, 90), Rgb(255, 110, 110), Rgb(105, 255, 160), Rgb(255, 255, 170),
        Rgb(189, 147, 249), Rgb(255, 146, 213), Rgb(170, 255, 255), Rgb(255, 255, 255),
    ];

    private static readonly Color[] SolarizedStandardPalette =
    [
        Rgb(7, 54, 66), Rgb(220, 50, 47), Rgb(133, 153, 0), Rgb(181, 137, 0),
        Rgb(38, 139, 210), Rgb(211, 54, 130), Rgb(42, 161, 152), Rgb(238, 232, 213),
    ];

    private static readonly Color[] SolarizedBrightPalette =
    [
        Rgb(0, 43, 54), Rgb(203, 75, 22), Rgb(88, 110, 117), Rgb(101, 123, 131),
        Rgb(131, 148, 150), Rgb(108, 113, 196), Rgb(147, 161, 161), Rgb(253, 246, 227),
    ];

    private static readonly Color[] NordStandardPalette =
    [
        Rgb(59, 66, 82), Rgb(191, 97, 106), Rgb(163, 190, 140), Rgb(235, 203, 139),
        Rgb(129, 161, 193), Rgb(180, 142, 173), Rgb(136, 192, 208), Rgb(229, 233, 240),
    ];

    private static readonly Color[] NordBrightPalette =
    [
        Rgb(76, 86, 106), Rgb(191, 97, 106), Rgb(163, 190, 140), Rgb(235, 203, 139),
        Rgb(129, 161, 193), Rgb(180, 142, 173), Rgb(143, 188, 187), Rgb(236, 239, 244),
    ];

    private static readonly Color[] HomebrewStandardPalette =
    [
        Rgb(0, 0, 0), Rgb(0, 221, 0), Rgb(0, 255, 85), Rgb(85, 255, 85),
        Rgb(0, 170, 0), Rgb(0, 204, 0), Rgb(102, 255, 153), Rgb(170, 255, 187),
    ];

    private static readonly Color[] HomebrewBrightPalette =
    [
        Rgb(0, 68, 0), Rgb(51, 255, 51), Rgb(102, 255, 102), Rgb(153, 255, 153),
        Rgb(0, 136, 0), Rgb(51, 204, 51), Rgb(187, 255, 204), Rgb(221, 255, 221),
    ];

    private Color[] ActiveStandardPalette => followsApplicationTheme
        ? applicationThemeIsDark ? ApplicationDarkStandardPalette : ApplicationLightStandardPalette
        : colorTheme switch
        {
            TerminalColorTheme.SolarizedDark => SolarizedStandardPalette,
            TerminalColorTheme.Nord => NordStandardPalette,
            TerminalColorTheme.Homebrew => HomebrewStandardPalette,
            _ => DraculaStandardPalette,
        };

    private Color[] ActiveBrightPalette => followsApplicationTheme
        ? applicationThemeIsDark ? ApplicationDarkBrightPalette : ApplicationLightBrightPalette
        : colorTheme switch
        {
            TerminalColorTheme.SolarizedDark => SolarizedBrightPalette,
            TerminalColorTheme.Nord => NordBrightPalette,
            TerminalColorTheme.Homebrew => HomebrewBrightPalette,
            _ => DraculaBrightPalette,
        };

    private static Color Rgb(byte red, byte green, byte blue) =>
        Color.FromArgb(255, red, green, blue);

    private readonly record struct TerminalCell(int Row, int Column) : IComparable<TerminalCell>
    {
        public int CompareTo(TerminalCell other) => Row != other.Row
            ? Row.CompareTo(other.Row)
            : Column.CompareTo(other.Column);
    }

    private readonly record struct TerminalSelection(TerminalCell Start, TerminalCell End);

    private readonly record struct TerminalMatch(int Row, int Column, int Length);

    private Color ThemeForeground => followsApplicationTheme
        ? applicationThemeIsDark
            ? Color.FromArgb(255, 239, 246, 244)
            : Color.FromArgb(255, 24, 36, 48)
        : colorTheme switch
    {
        TerminalColorTheme.SolarizedDark => Color.FromArgb(255, 131, 148, 150),
        TerminalColorTheme.Nord => Color.FromArgb(255, 216, 222, 233),
        TerminalColorTheme.Homebrew => Color.FromArgb(255, 0, 255, 102),
        _ => Color.FromArgb(255, 248, 248, 242),
    };

    private Color ThemeBackground => followsApplicationTheme
        ? ResolveApplicationTerminalBackground()
        : colorTheme switch
    {
        TerminalColorTheme.SolarizedDark => Color.FromArgb(255, 0, 43, 54),
        TerminalColorTheme.Nord => Color.FromArgb(255, 46, 52, 64),
        TerminalColorTheme.Homebrew => Color.FromArgb(255, 0, 0, 0),
        _ => Color.FromArgb(255, 40, 42, 54),
    };

    private Color ResolveApplicationTerminalBackground() => (applicationPalette, applicationThemeIsDark) switch
    {
        ("天空糖果", true) => Color.FromArgb(255, 9, 24, 34),
        ("蜜桃晨光", true) => Color.FromArgb(255, 29, 20, 17),
        ("薰衣草雾", true) => Color.FromArgb(255, 24, 19, 33),
        ("冰川薄荷", true) => Color.FromArgb(255, 9, 25, 28),
        ("翡翠流光", true) => Color.FromArgb(255, 10, 25, 18),
        ("天空糖果", false) => Color.FromArgb(255, 247, 251, 255),
        ("蜜桃晨光", false) => Color.FromArgb(255, 255, 250, 247),
        ("薰衣草雾", false) => Color.FromArgb(255, 252, 249, 255),
        ("冰川薄荷", false) => Color.FromArgb(255, 247, 252, 253),
        _ => Color.FromArgb(255, 247, 252, 249),
    };
}

public enum TerminalColorTheme
{
    Dark,
    SolarizedDark,
    Nord,
    Homebrew,
}
