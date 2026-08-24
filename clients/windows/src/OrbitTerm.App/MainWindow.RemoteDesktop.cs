using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OrbitTerm.App.Services;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public sealed partial class MainWindow
{
    private readonly Dictionary<RemoteDesktopHostSession, LocalTunnelLease?> remoteDesktopHosts = [];
    private readonly HashSet<RemoteDesktopHostSession> remoteDesktopFailurePresented = [];
    private readonly object remoteDesktopHostsGate = new();
    private readonly RemoteDesktopHostLauncher remoteDesktopHostLauncher = new();
    private bool isRemoteDesktopDialogOpen;

    private async Task LaunchSavedRemoteDesktopAssetAsync(AssetViewModel asset)
    {
        if (isRemoteDesktopDialogOpen)
            return;

        isRemoteDesktopDialogOpen = true;
        try
        {
            var credential = await credentialVault.ReadAsync(asset.CredentialId, CancellationToken.None);
            if (string.IsNullOrWhiteSpace(credential.Password))
            {
                await ShowAccountMessageAsync(
                    "缺少远程桌面凭据",
                    "此 Windows 资产没有可用的本机密码。请右键资产选择“编辑资产”，补充密码后再连接。");
                return;
            }

            var request = RemoteDesktopPolicy.Validate(new RemoteDesktopLaunchRequest(
                asset.Id,
                asset.Host,
                asset.Port,
                RemoteDesktopGatewayMode.Direct,
                ClipboardEnabled: true,
                DriveRedirectionEnabled: false,
                PrinterRedirectionEnabled: false,
                UseNetworkLevelAuthentication: true));
            await LaunchRemoteDesktopAsync(asset, request, asset.Username, credential.Password);
        }
        catch (Exception exception)
        {
            await ShowAccountMessageAsync("远程桌面未启动", exception.Message);
        }
        finally
        {
            isRemoteDesktopDialogOpen = false;
        }
    }

    internal async void AssetContextRemoteDesktopClick(object sender, RoutedEventArgs e)
    {
        if (isRemoteDesktopDialogOpen || !SelectContextAsset(sender) || ViewModel.SelectedAsset is not { } asset)
            return;
        if (asset.Transport == ServerTransport.RemoteDesktop)
        {
            await LaunchSavedRemoteDesktopAssetAsync(asset);
            return;
        }
        if (asset.Transport != ServerTransport.Ssh)
        {
            await ShowAccountMessageAsync("无法打开远程桌面", "远程桌面只支持 SSH 资产；Telnet 资产不能建立受验证的隧道。");
            return;
        }

        isRemoteDesktopDialogOpen = true;
        try { await ShowRemoteDesktopLaunchDialogAsync(asset); }
        finally { isRemoteDesktopDialogOpen = false; }
    }

    private async Task ShowRemoteDesktopLaunchDialogAsync(AssetViewModel asset)
    {
        var hostBox = new TextBox
        {
            Header = "Windows 主机",
            Text = asset.Host,
            PlaceholderText = "IP 地址或主机名",
            MaxLength = 253,
        };
        var portBox = new NumberBox
        {
            Header = "RDP 端口",
            Value = 3389,
            Minimum = 1,
            Maximum = 65535,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        };
        var usernameBox = new TextBox
        {
            Header = "Windows 用户名",
            PlaceholderText = "例如：Administrator 或 DOMAIN\\user",
            MaxLength = 256,
        };
        var passwordBox = new PasswordBox
        {
            Header = "Windows 密码",
            PlaceholderText = "留空时由 Windows 远程桌面安全询问",
            MaxLength = 1024,
        };
        var modeBox = new ComboBox
        {
            Header = "连接方式",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Items =
            {
                new ComboBoxItem { Content = "直接连接 RDP", Tag = RemoteDesktopGatewayMode.Direct },
                new ComboBoxItem { Content = "通过当前已验证 SSH 会话", Tag = RemoteDesktopGatewayMode.ThroughVerifiedSshTunnel },
            },
            SelectedIndex = 0,
        };
        var clipboardCheck = new CheckBox { Content = "允许共享剪贴板", IsChecked = true };
        var driveCheck = new CheckBox { Content = "允许访问本机磁盘（高风险）", IsChecked = false };
        var printerCheck = new CheckBox { Content = "允许使用本机打印机", IsChecked = false };
        var nlaStatus = new Border
        {
            Padding = new Thickness(10, 8, 10, 8),
            Background = ResourceBrush("OrbitAccentSoftBrush"),
            CornerRadius = new CornerRadius(8),
            Child = new TextBlock
            {
                Text = "✓ 强制启用网络级别身份验证（NLA）与服务器身份验证；不能在此关闭。",
                TextWrapping = TextWrapping.Wrap,
            },
        };
        var tunnelStatus = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        AutomationProperties.SetLiveSetting(tunnelStatus, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);

        void UpdateTunnelStatus()
        {
            var tunnelSelected = modeBox.SelectedIndex == 1;
            hostBox.IsEnabled = !tunnelSelected;
            if (!tunnelSelected)
            {
                tunnelStatus.Text = "直接连接不会复用 SSH 会话；Windows RDP 会独立验证目标服务器。";
                return;
            }
            var workspace = FindConnectedWorkspace(asset.Id);
            tunnelStatus.Text = workspace is null
                ? "此资产当前没有已验证 SSH 会话。请先连接资产，随后再选择隧道模式。"
                : "RDP 将仅监听本机 127.0.0.1，并复用当前已验证 SSH 会话转发到远端 127.0.0.1:3389。";
        }
        modeBox.SelectionChanged += (_, _) => UpdateTunnelStatus();
        UpdateTunnelStatus();

        var endpointGrid = new Grid { ColumnSpacing = 10 };
        endpointGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        endpointGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        endpointGrid.Children.Add(hostBox);
        Grid.SetColumn(portBox, 1);
        endpointGrid.Children.Add(portBox);

        var redirectionPanel = new StackPanel { Spacing = 4 };
        redirectionPanel.Children.Add(new TextBlock { Text = "本机资源重定向", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        redirectionPanel.Children.Add(clipboardCheck);
        redirectionPanel.Children.Add(driveCheck);
        redirectionPanel.Children.Add(printerCheck);

        var content = new StackPanel { Width = 560, Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = $"资产：{asset.Name} · SSH {asset.Username}@{asset.Host}:{asset.Port}",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        content.Children.Add(endpointGrid);
        content.Children.Add(usernameBox);
        content.Children.Add(passwordBox);
        content.Children.Add(modeBox);
        content.Children.Add(tunnelStatus);
        content.Children.Add(nlaStatus);
        content.Children.Add(redirectionPanel);
        content.Children.Add(new TextBlock
        {
            Text = "密码只交给 Windows 自带远程桌面控件，本次会话结束即释放；不会写入命令行、.rdp 文件、日志或同步数据。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            FontSize = 12,
        });

        var dialog = CreateThemedDialog("打开远程桌面", content, "安全连接", "取消");
        dialog.DefaultButton = ContentDialogButton.Primary;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var mode = modeBox.SelectedItem is ComboBoxItem { Tag: RemoteDesktopGatewayMode selectedMode }
            ? selectedMode
            : RemoteDesktopGatewayMode.Direct;
        var request = new RemoteDesktopLaunchRequest(
            asset.Id,
            mode == RemoteDesktopGatewayMode.ThroughVerifiedSshTunnel ? "127.0.0.1" : hostBox.Text,
            double.IsNaN(portBox.Value) ? 0 : checked((int)portBox.Value),
            mode,
            clipboardCheck.IsChecked == true,
            driveCheck.IsChecked == true,
            printerCheck.IsChecked == true,
            UseNetworkLevelAuthentication: true);
        try { request = RemoteDesktopPolicy.Validate(request); }
        catch (Exception exception)
        {
            passwordBox.Password = string.Empty;
            await ShowAccountMessageAsync("远程桌面配置无效", exception.Message);
            return;
        }

        if ((request.DriveRedirectionEnabled || request.PrinterRedirectionEnabled) &&
            !await ConfirmRemoteDesktopRedirectionAsync(request))
        {
            passwordBox.Password = string.Empty;
            return;
        }

        var password = passwordBox.Password;
        passwordBox.Password = string.Empty;
        await LaunchRemoteDesktopAsync(asset, request, usernameBox.Text.Trim(), password);
    }

    private async Task<bool> ConfirmRemoteDesktopRedirectionAsync(RemoteDesktopLaunchRequest request)
    {
        var enabled = new List<string>();
        if (request.DriveRedirectionEnabled) enabled.Add("本机磁盘");
        if (request.PrinterRedirectionEnabled) enabled.Add("本机打印机");
        var dialog = CreateThemedDialog(
            "确认本机资源重定向",
            new TextBlock
            {
                Text = $"远端 Windows 会话将可访问：{string.Join("、", enabled)}。仅应对受信任的主机启用；剪贴板状态已在连接页单独显示。",
                TextWrapping = TextWrapping.Wrap,
            },
            "确认并连接",
            "返回");
        dialog.DefaultButton = ContentDialogButton.Close;
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task LaunchRemoteDesktopAsync(
        AssetViewModel asset,
        RemoteDesktopLaunchRequest request,
        string username,
        string password)
    {
        LocalTunnelLease? tunnel = null;
        try
        {
            var targetHost = request.Host;
            var targetPort = request.Port;
            if (request.GatewayMode == RemoteDesktopGatewayMode.ThroughVerifiedSshTunnel)
            {
                var workspace = FindConnectedWorkspace(asset.Id);
                if (workspace is null)
                    throw new InvalidOperationException("当前没有此资产的已验证 SSH 会话，未创建 RDP 隧道。");
                tunnel = await remoteAccessOrchestrator.StartLocalTunnelAsync(
                    workspace.WorkspaceId,
                    asset.Id,
                    "127.0.0.1",
                    request.Port,
                    0,
                    CancellationToken.None);
                activeLocalTunnels[tunnel.TunnelId] = tunnel;
                targetHost = "127.0.0.1";
                targetPort = tunnel.BindPort;
            }

            var host = await remoteDesktopHostLauncher.LaunchAsync(new RemoteDesktopHostRequest(
                asset.Id, asset.Name, targetHost, targetPort, username, password,
                request.ClipboardEnabled, request.DriveRedirectionEnabled,
                request.PrinterRedirectionEnabled,
                Root.ActualTheme == ElementTheme.Dark || terminalAppearance.AppTheme == "深色"));
            lock (remoteDesktopHostsGate) remoteDesktopHosts[host] = tunnel;
            host.Exited += RemoteDesktopHostExited;
            host.StateChanged += RemoteDesktopHostStateChanged;
            if (host.Current.Phase == RemoteDesktopSessionPhase.Failed)
                PresentRemoteDesktopFailure(host, host.Current);
        }
        catch (Exception exception)
        {
            if (tunnel is not null)
            {
                activeLocalTunnels.Remove(tunnel.TunnelId);
                try { await remoteAccessOrchestrator.StopLocalTunnelAsync(tunnel, CancellationToken.None); } catch { }
            }
            await ShowAccountMessageAsync("远程桌面未启动", exception.Message);
        }
    }

    private WorkspaceTabViewModel? FindConnectedWorkspace(Guid assetId) =>
        ViewModel.WorkspaceTabs.FirstOrDefault(tab => tab.AssetId == assetId && tab.IsConnected);

    private void RemoteDesktopHostStateChanged(object? sender, RemoteDesktopSessionUpdate update)
    {
        if (sender is not RemoteDesktopHostSession session) return;
        if (update.Phase is RemoteDesktopSessionPhase.Reconnecting or RemoteDesktopSessionPhase.Connected)
        {
            lock (remoteDesktopHostsGate) remoteDesktopFailurePresented.Remove(session);
            return;
        }
        if (update.Phase == RemoteDesktopSessionPhase.Failed)
            PresentRemoteDesktopFailure(session, update);
    }

    private void PresentRemoteDesktopFailure(
        RemoteDesktopHostSession session,
        RemoteDesktopSessionUpdate update)
    {
        lock (remoteDesktopHostsGate)
        {
            if (!remoteDesktopFailurePresented.Add(session)) return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            await ShowAccountMessageAsync(
                "远程桌面连接未完成",
                RemoteDesktopFailurePresentation.UserMessage(update));
        });
    }

    private async void RemoteDesktopHostExited(object? sender, EventArgs e)
    {
        if (sender is not RemoteDesktopHostSession session) return;
        LocalTunnelLease? tunnel;
        lock (remoteDesktopHostsGate)
        {
            if (!remoteDesktopHosts.Remove(session, out tunnel)) return;
            remoteDesktopFailurePresented.Remove(session);
        }
        session.StateChanged -= RemoteDesktopHostStateChanged;
        session.Dispose();
        if (tunnel is null) return;
        activeLocalTunnels.Remove(tunnel.TunnelId);
        try { await remoteAccessOrchestrator.StopLocalTunnelAsync(tunnel, CancellationToken.None); } catch { }
    }

    private void CloseRemoteDesktopWindows()
    {
        RemoteDesktopHostSession[] sessions;
        lock (remoteDesktopHostsGate)
        {
            sessions = remoteDesktopHosts.Keys.ToArray();
            remoteDesktopHosts.Clear();
            remoteDesktopFailurePresented.Clear();
        }
        foreach (var session in sessions)
        {
            session.Exited -= RemoteDesktopHostExited;
            session.StateChanged -= RemoteDesktopHostStateChanged;
            session.Close();
            session.Dispose();
        }
    }
}
