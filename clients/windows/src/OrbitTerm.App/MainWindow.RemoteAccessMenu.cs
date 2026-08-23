using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public sealed partial class MainWindow
{
    private void InstallWindowsRemoteAccessCommands()
    {
        if (AppTitleBar.Children.FirstOrDefault() is not Grid titleGrid ||
            titleGrid.Children.FirstOrDefault() is not StackPanel commandBar)
            return;

        var buttonStyle = (Style)Microsoft.UI.Xaml.Application.Current.Resources["OrbitTitleBarButtonStyle"];
        var keyButton = new Button
        {
            Content = "密钥管理",
            Style = buttonStyle,
        };
        keyButton.Click += ShowSshKeyLibraryClick;
        var remoteButton = new Button
        {
            Content = "远程访问",
            Style = buttonStyle,
        };
        remoteButton.Click += ShowSelectedAssetRemoteAccessClick;

        var insertIndex = Math.Min(3, commandBar.Children.Count);
        commandBar.Children.Insert(insertIndex, keyButton);
        commandBar.Children.Insert(insertIndex + 1, remoteButton);
    }

    private async void ShowSelectedAssetRemoteAccessClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedAsset is not { } asset)
        {
            await ShowAccountMessageAsync("请选择服务器资产", "先在左侧选择一台服务器，再打开端口映射或远程桌面。");
            return;
        }
        var source = new Button { Tag = asset };
        await ShowAssetRemoteAccessMenuAsync(source, e);
    }

    internal async Task ShowAssetRemoteAccessMenuAsync(object sender, RoutedEventArgs e)
    {
        if (!SelectContextAsset(sender) || ViewModel.SelectedAsset is not { } asset) return;
        var actionBox = new ComboBox
        {
            Header = "选择操作",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            SelectedIndex = 0,
            Items =
            {
                new ComboBoxItem { Content = "本地端口映射", Tag = "forward" },
                new ComboBoxItem { Content = "打开 Windows 远程桌面", Tag = "rdp" },
            },
        };
        var content = new StackPanel { Width = 440, Spacing = 10 };
        content.Children.Add(new TextBlock
        {
            Text = $"{asset.Name} · {asset.Username}@{asset.Host}:{asset.Port}",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        content.Children.Add(actionBox);
        content.Children.Add(new TextBlock
        {
            Text = "端口映射只复用已经通过主机密钥验证的 SSH 会话；远程桌面强制启用 NLA。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["OrbitMutedTextBrush"],
            FontSize = 12,
        });
        var dialog = CreateThemedDialog("资产操作", content, "继续", "取消");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        switch ((actionBox.SelectedItem as ComboBoxItem)?.Tag as string)
        {
            case "forward": AssetContextPortForwardingClick(sender, e); break;
            case "rdp": AssetContextRemoteDesktopClick(sender, e); break;
            default: break;
        }
    }
}
