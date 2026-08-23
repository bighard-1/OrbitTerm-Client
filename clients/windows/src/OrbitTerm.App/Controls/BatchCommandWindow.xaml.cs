using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OrbitTerm.Presentation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace OrbitTerm.App.Controls;

// Hallmark · component: batch command workbench · genre: modern-minimal · theme: existing OrbitTerm tokens
// Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4
// states: default · hover · focus · active · disabled · loading · error · success · high-DPI
internal sealed partial class BatchCommandWindow : Window
{
    private const int GwlpHwndParent = -8;
    private const int LogicalWidth = 1040;
    private const int LogicalHeight = 680;
    private readonly MainWindowViewModel viewModel;
    private readonly nint ownerHandle;
    private bool allowClose;
    private bool closePromptOpen;

    public BatchCommandWindow(
        MainWindowViewModel viewModel,
        nint ownerHandle,
        ElementTheme requestedTheme)
    {
        this.viewModel = viewModel;
        this.ownerHandle = ownerHandle;
        InitializeComponent();
        Title = "OrbitTerm · 批量命令";
        WindowRoot.DataContext = viewModel;
        WindowRoot.RequestedTheme = requestedTheme;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        NativeWindowCornerService.Apply(this);
        ApplyTheme(requestedTheme);
        AppWindow.Closing += BatchAppWindowClosing;
        Closed += (_, _) => viewModel.RefreshBatchTargetSelection();
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
            AppWindow.Move(new PointInt32(
                ownerBounds.Left + Math.Max(0, (ownerBounds.Width - width) / 2),
                ownerBounds.Top + Math.Max(0, (ownerBounds.Height - height) / 2)));
        }
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMaximizable = true;
            presenter.IsMinimizable = true;
        }

        Activate();
        DispatcherQueue.TryEnqueue(
            Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () =>
            {
                ApplyTheme(WindowRoot.ActualTheme);
                CommandTextBox.Focus(FocusState.Programmatic);
            });
    }

    public void ApplyTheme(ElementTheme theme)
    {
        WindowRoot.RequestedTheme = theme;
        if (AppWindow?.TitleBar is not { } titleBar)
        {
            return;
        }

        var background = ResourceColor("OrbitFeatureTitleBarBrush");
        var foreground = ResourceColor("OrbitPrimaryTextBrush");
        var muted = ResourceColor("OrbitMutedTextBrush");
        var hover = ResourceColor("OrbitAccentSoftBrush");
        titleBar.BackgroundColor = background;
        titleBar.InactiveBackgroundColor = background;
        titleBar.ForegroundColor = foreground;
        titleBar.InactiveForegroundColor = muted;
        titleBar.ButtonBackgroundColor = background;
        titleBar.ButtonInactiveBackgroundColor = background;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = muted;
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedBackgroundColor = hover;
        titleBar.ButtonPressedForegroundColor = foreground;
        NativeWindowCornerService.ApplyVisibleFrameTheme(
            this,
            theme == ElementTheme.Dark || WindowRoot.ActualTheme == ElementTheme.Dark);
    }

    private void SelectFilteredTargetsClick(object sender, RoutedEventArgs e) =>
        viewModel.SelectFilteredBatchTargets(true);

    private void ClearSelectionClick(object sender, RoutedEventArgs e)
    {
        foreach (var target in viewModel.BatchAssetTargets)
        {
            target.IsSelected = false;
        }
        viewModel.RefreshBatchTargetSelection();
    }

    private void BatchTargetSelectionChanged(object sender, RoutedEventArgs e) =>
        viewModel.RefreshBatchTargetSelection();

    private void CollapseTargetPanelClick(object sender, RoutedEventArgs e)
    {
        TargetPanel.Visibility = Visibility.Collapsed;
        ExpandTargetPanelButton.Visibility = Visibility.Visible;
    }

    private void ExpandTargetPanelClick(object sender, RoutedEventArgs e)
    {
        TargetPanel.Visibility = Visibility.Visible;
        ExpandTargetPanelButton.Visibility = Visibility.Collapsed;
    }

    private void RemoveSelectedTargetClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: BatchAssetTargetViewModel target })
        {
            viewModel.UnselectBatchTarget(target.AssetId);
        }
    }

    private async void CopyResultsClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(viewModel.FilteredBatchOutputText))
        {
            CopyResultsButton.Content = "暂无结果";
            await Task.Delay(900);
            CopyResultsButton.Content = "复制结果";
            return;
        }

        var data = new DataPackage();
        data.SetText(viewModel.FilteredBatchOutputText);
        Clipboard.SetContent(data);
        Clipboard.Flush();
        CopyResultsButton.Content = "已复制";
        AutomationProperties.SetHelpText(CopyResultsButton, "批量命令结果已复制");
        await Task.Delay(1100);
        CopyResultsButton.Content = "复制结果";
    }

    private async void ExportTextResultsClick(object sender, RoutedEventArgs e) =>
        await ExportResultsAsync(csv: false);

    private async void ExportCsvResultsClick(object sender, RoutedEventArgs e) =>
        await ExportResultsAsync(csv: true);

    private async Task ExportResultsAsync(bool csv)
    {
        var content = viewModel.CreateBatchResultExport(csv);
        var button = csv ? ExportCsvButton : ExportTextButton;
        var original = csv ? "导出 CSV" : "导出 TXT";
        if (string.IsNullOrWhiteSpace(content))
        {
            button.Content = "暂无结果";
            await Task.Delay(900);
            button.Content = original;
            return;
        }

        var picker = new FileSavePicker
        {
            SuggestedFileName = string.Concat("OrbitTerm-批量命令-", DateTime.Now.ToString("yyyyMMdd-HHmmss")),
        };
        picker.FileTypeChoices.Add(csv ? "CSV 表格" : "文本文件", [csv ? ".csv" : ".txt"]);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is null)
        {
            return;
        }

        await FileIO.WriteTextAsync(file, content);
        button.Content = "已导出";
        await Task.Delay(1100);
        button.Content = original;
    }

    private async void CopyContinuousOutputClick(object sender, RoutedEventArgs e)
    {
        var output = viewModel.SelectedBatchContinuousSession?.OutputText ?? string.Empty;
        if (output.Length == 0)
        {
            CopyContinuousOutputButton.Content = "暂无输出";
            await Task.Delay(900);
            CopyContinuousOutputButton.Content = "复制当前输出";
            return;
        }

        var data = new DataPackage();
        data.SetText(output);
        Clipboard.SetContent(data);
        Clipboard.Flush();
        CopyContinuousOutputButton.Content = "已复制";
        await Task.Delay(1100);
        CopyContinuousOutputButton.Content = "复制当前输出";
    }

    private async void StopSelectedContinuousSessionClick(object sender, RoutedEventArgs e)
    {
        if (viewModel.SelectedBatchContinuousSession is { CanStop: true } session)
        {
            await viewModel.StopBatchContinuousSessionAsync(session.Id, CancellationToken.None);
        }
    }

    private async void BatchAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (allowClose || !viewModel.HasActiveBatchContinuousSessions)
        {
            return;
        }

        args.Cancel = true;
        if (closePromptOpen)
        {
            return;
        }

        closePromptOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = WindowRoot.XamlRoot,
                Title = "持续任务仍在运行",
                Content = new TextBlock
                {
                    Text = "关闭此窗口不会自动结束远端持续命令。你可以停止全部任务后关闭，也可以让任务在后台继续运行。",
                    TextWrapping = TextWrapping.Wrap,
                    MaxWidth = 460,
                },
                PrimaryButtonText = "停止任务并关闭",
                SecondaryButtonText = "后台继续并关闭",
                CloseButtonText = "返回任务",
                DefaultButton = ContentDialogButton.Close,
            };
            var result = await dialog.ShowAsync();
            switch (result)
            {
                case ContentDialogResult.Primary:
                    await viewModel.StopAllBatchContinuousSessionsForApplicationExitAsync();
                    allowClose = true;
                    Close();
                    break;
                case ContentDialogResult.Secondary:
                    allowClose = true;
                    Close();
                    break;
            }
        }
        finally
        {
            closePromptOpen = false;
        }
    }

    private void CloseClick(object sender, RoutedEventArgs e) => Close();

    private static Windows.UI.Color ResourceColor(string key)
    {
        if (Microsoft.UI.Xaml.Application.Current.Resources.TryGetValue(key, out var resource) &&
            resource is SolidColorBrush brush)
        {
            return brush.Color;
        }
        return Windows.UI.Color.FromArgb(255, 20, 25, 34);
    }

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetWindowLongPtr(nint windowHandle, int index, nint newValue);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint windowHandle, out NativeRect bounds);

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
