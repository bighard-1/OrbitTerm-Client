using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public sealed partial class MainWindow
{
    private readonly Dictionary<ulong, LocalTunnelLease> activeLocalTunnels = [];
    private readonly PortForwardProfileLibrary portForwardProfileLibrary;
    private bool isPortForwardingDialogOpen;

    internal async void AssetContextPortForwardingClick(object sender, RoutedEventArgs e)
    {
        if (isPortForwardingDialogOpen || !SelectContextAsset(sender) || ViewModel.SelectedAsset is not { } asset)
            return;
        if (asset.Transport != ServerTransport.Ssh)
        {
            await ShowAccountMessageAsync("此资产不支持端口映射", "端口映射只复用已验证的 SSH 会话；请选择 SSH 资产。");
            return;
        }
        var workspace = ViewModel.WorkspaceTabs.FirstOrDefault(tab => tab.AssetId == asset.Id && tab.IsConnected);
        if (workspace is null)
        {
            await ShowAccountMessageAsync("需要已验证连接", "请先连接此 SSH 资产，再创建端口映射。OrbitTerm 不会为映射另起未经验证的连接。");
            return;
        }
        ViewModel.SelectedWorkspaceTab = workspace;
        isPortForwardingDialogOpen = true;
        try { await ShowLocalPortForwardingDialogAsync(asset, workspace); }
        finally { isPortForwardingDialogOpen = false; }
    }

    internal async void ShowSelectedAssetPortForwardingClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedAsset is not { } asset)
        {
            await ShowAccountMessageAsync("请选择 SSH 资产", "先从左侧资产库选择并连接一台 SSH 服务器，再创建端口映射。");
            return;
        }
        AssetContextPortForwardingClick(new Button { Tag = asset }, e);
    }

    private async Task ShowLocalPortForwardingDialogAsync(AssetViewModel asset, WorkspaceTabViewModel workspace)
    {
        var destinationHost = new TextBox { Header = "目标地址", PlaceholderText = "例如：127.0.0.1 或 db.internal", Text = "127.0.0.1" };
        var destinationPort = new NumberBox { Header = "目标端口", Minimum = 1, Maximum = 65535, Value = 3389, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var localPort = new NumberBox { Header = "本机端口", Minimum = 0, Maximum = 65535, Value = 0, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var createButton = new Button { Content = "启动映射", MinWidth = 112 };
        var saveButton = new Button { Content = "保存配置", MinWidth = 112 };
        var status = new TextBlock { Text = "本机端口填 0 时自动选择可用端口。监听地址固定为 127.0.0.1。", TextWrapping = TextWrapping.Wrap, Foreground = ResourceBrush("OrbitMutedTextBrush") };
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var activeList = new StackPanel { Spacing = 8 };
        var savedList = new StackPanel { Spacing = 8 };

        var form = new Grid { ColumnSpacing = 10 };
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        Grid.SetColumn(destinationHost, 0); Grid.SetColumn(destinationPort, 1); Grid.SetColumn(localPort, 2);
        form.Children.Add(destinationHost); form.Children.Add(destinationPort); form.Children.Add(localPort);

        void RefreshList()
        {
            activeList.Children.Clear();
            foreach (var tunnel in activeLocalTunnels.Values.Where(item => item.AssetId == asset.Id).OrderBy(item => item.BindPort))
            {
                var row = new Grid { Padding = new Thickness(10, 8, 10, 8), ColumnSpacing = 8, Background = ResourceBrush("OrbitMetricBrush") };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = $"127.0.0.1:{tunnel.BindPort} → {tunnel.DestinationHost}:{tunnel.DestinationPort}", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                        new TextBlock { Text = "运行中 · 复用当前已验证 SSH 会话", FontSize = 11, Foreground = ResourceBrush("OrbitMutedTextBrush") },
                    },
                });
                var stop = new Button { Content = "停止", Tag = tunnel, MinWidth = 76 };
                stop.Click += async (_, _) =>
                {
                    stop.IsEnabled = false;
                    try
                    {
                        await remoteAccessOrchestrator.StopLocalTunnelAsync(tunnel, CancellationToken.None);
                        activeLocalTunnels.Remove(tunnel.TunnelId);
                        status.Text = $"已停止本机端口 {tunnel.BindPort} 的映射。";
                        RefreshList();
                    }
                    catch { status.Text = "停止失败；SSH 会话可能已断开。该监听会随会话自动清理。"; stop.IsEnabled = true; }
                };
                Grid.SetColumn(stop, 1); row.Children.Add(stop); activeList.Children.Add(row);
            }
            if (activeList.Children.Count == 0)
                activeList.Children.Add(new TextBlock { Text = "此资产暂无运行中的本地映射。", Foreground = ResourceBrush("OrbitMutedTextBrush"), Margin = new Thickness(4, 12, 4, 12) });
        }

        createButton.Click += async (_, _) =>
        {
            var destination = destinationHost.Text.Trim();
            var destinationPortValue = double.IsNaN(destinationPort.Value) ? 0 : checked((int)destinationPort.Value);
            var localPortValue = double.IsNaN(localPort.Value) ? 0 : checked((int)localPort.Value);
            try
            {
                createButton.IsEnabled = false;
                var rule = PortForwardingPolicy.Validate(new PortForwardingRule(
                    Guid.NewGuid(), asset.Id, $"{destination}:{destinationPortValue}", PortForwardingMode.Local,
                    "127.0.0.1", localPortValue, destination, destinationPortValue));
                var lease = await remoteAccessOrchestrator.StartLocalTunnelAsync(
                    workspace.WorkspaceId, asset.Id, rule.DestinationHost, rule.DestinationPort,
                    rule.BindPort, CancellationToken.None);
                activeLocalTunnels[lease.TunnelId] = lease;
                status.Text = $"映射已启动：127.0.0.1:{lease.BindPort}。只允许本机程序访问。";
                RefreshList();
            }
            catch (Exception exception) { status.Text = exception.Message; }
            finally { createButton.IsEnabled = true; }
        };

        async Task RefreshSavedAsync()
        {
            savedList.Children.Clear();
            var scope = ViewModel.CurrentAccountScope;
            if (string.IsNullOrWhiteSpace(scope))
            {
                savedList.Children.Add(new TextBlock { Text = "登录并解锁后可保存端到端加密同步配置。", Foreground = ResourceBrush("OrbitMutedTextBrush") });
                saveButton.IsEnabled = false;
                return;
            }
            saveButton.IsEnabled = true;
            var profiles = await portForwardProfileLibrary.ListAsync(scope, asset.Id, CancellationToken.None);
            foreach (var profile in profiles)
            {
                var row = new Grid { Padding = new Thickness(10, 8, 10, 8), ColumnSpacing = 8, Background = ResourceBrush("OrbitMetricBrush") };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new StackPanel { Spacing = 2, Children =
                {
                    new TextBlock { Text = profile.Rule.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                    new TextBlock { Text = $"{profile.Rule.BindHost}:{profile.Rule.BindPort} → {profile.Rule.DestinationHost}:{profile.Rule.DestinationPort} · {(profile.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted ? "加密同步" : "仅本机")}", FontSize = 11, Foreground = ResourceBrush("OrbitMutedTextBrush") },
                }});
                var start = new Button { Content = "启动", Tag = profile, MinWidth = 72 };
                start.Click += async (_, _) =>
                {
                    try
                    {
                        var lease = await remoteAccessOrchestrator.StartLocalTunnelAsync(workspace.WorkspaceId, asset.Id,
                            profile.Rule.DestinationHost, profile.Rule.DestinationPort, profile.Rule.BindPort, CancellationToken.None);
                        activeLocalTunnels[lease.TunnelId] = lease; status.Text = $"已启动保存的映射：127.0.0.1:{lease.BindPort}。"; RefreshList();
                    }
                    catch (Exception exception) { status.Text = exception.Message; }
                };
                var remove = new Button { Content = "删除", Tag = profile, MinWidth = 72 };
                remove.Click += async (_, _) =>
                {
                    await portForwardProfileLibrary.DeleteAsync(scope, profile.Rule.Id, CancellationToken.None);
                    status.Text = "配置已删除；加密同步配置将生成删除墓碑。";
                    await RefreshSavedAsync();
                };
                Grid.SetColumn(start, 1); Grid.SetColumn(remove, 2); row.Children.Add(start); row.Children.Add(remove); savedList.Children.Add(row);
            }
            if (profiles.Count == 0) savedList.Children.Add(new TextBlock { Text = "此资产暂无保存的端口映射配置。", Foreground = ResourceBrush("OrbitMutedTextBrush") });
        }

        saveButton.Click += async (_, _) =>
        {
            var scope = ViewModel.CurrentAccountScope;
            if (string.IsNullOrWhiteSpace(scope)) return;
            try
            {
                var destination = destinationHost.Text.Trim();
                var destinationPortValue = double.IsNaN(destinationPort.Value) ? 0 : checked((int)destinationPort.Value);
                var localPortValue = double.IsNaN(localPort.Value) ? 0 : checked((int)localPort.Value);
                var now = DateTimeOffset.UtcNow;
                var rule = PortForwardingPolicy.Validate(new PortForwardingRule(Guid.NewGuid(), asset.Id,
                    $"{destination}:{destinationPortValue}", PortForwardingMode.Local, "127.0.0.1", localPortValue, destination, destinationPortValue));
                await portForwardProfileLibrary.SaveAsync(scope, new(rule, now, now,
                    PortForwardProfileSyncScope.EndToEndEncrypted, scope), CancellationToken.None);
                status.Text = "配置已保存到当前账户的 DPAPI 配置库；下次同步将端到端加密上传。";
                await RefreshSavedAsync();
            }
            catch (Exception exception) { status.Text = exception.Message; }
        };

        var content = new StackPanel { Width = 660, Spacing = 12 };
        content.Children.Add(new TextBlock { Text = $"{asset.Name} · {asset.Username}@{asset.Host}:{asset.Port}", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(new TextBlock { Text = "本地端口映射", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(createButton); actions.Children.Add(saveButton);
        content.Children.Add(form); content.Children.Add(actions); content.Children.Add(status);
        content.Children.Add(new TextBlock { Text = "保存的配置", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(savedList);
        content.Children.Add(new TextBlock { Text = "运行中的映射", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        content.Children.Add(activeList);
        RefreshList();
        await RefreshSavedAsync();
        await CreateThemedDialog("端口映射", content, closeButtonText: "完成").ShowAsync();
    }
}
