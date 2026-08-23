using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation.Peers;
using System.Diagnostics;
using System.Security.Cryptography;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;
using OrbitTerm.Application.Accounts;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.App;

public sealed partial class MainWindow
{
    internal async void ShowSshKeyLibraryClick(object sender, RoutedEventArgs e)
    {
        if (isSshKeyLibraryOpen || Root.XamlRoot is null)
        {
            return;
        }

        isSshKeyLibraryOpen = true;
        try
        {
            await ShowSshKeyLibraryAsync();
        }
        catch (Exception)
        {
            // A key-management construction error must never look like an ignored
            // toolbar click. Keep the failure visible and recoverable.
            if (Root.XamlRoot is not null)
            {
                var failure = CreateThemedDialog(
                    "密钥管理暂不可用",
                    new TextBlock
                    {
                        Text = "无法打开密钥管理界面，请重新启动应用后重试。现有密钥和资产凭据未被修改。",
                        TextWrapping = TextWrapping.Wrap,
                    },
                    closeButtonText: "知道了");
                await failure.ShowAsync();
            }
        }
        finally
        {
            isSshKeyLibraryOpen = false;
        }
    }

    private async Task ShowSshKeyLibraryAsync()
    {
        var keyList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Height = 190,
        };
        AutomationProperties.SetName(keyList, "本机 SSH 密钥列表");

        var importButton = new Button { Content = "导入", MinWidth = 86 };
        var generateButton = new Button { Content = "生成 Ed25519", MinWidth = 120 };
        var deleteButton = new Button { Content = "删除", MinWidth = 88, IsEnabled = false };
        var leftToolbar = new Grid { ColumnSpacing = 8 };
        leftToolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        leftToolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        leftToolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(importButton, 0);
        Grid.SetColumn(generateButton, 1);
        Grid.SetColumn(deleteButton, 2);
        leftToolbar.Children.Add(importButton);
        leftToolbar.Children.Add(generateButton);
        leftToolbar.Children.Add(deleteButton);

        var librarySummary = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            FontSize = 12,
        };
        var leftPanel = new StackPanel { Spacing = 10 };
        leftPanel.Children.Add(new TextBlock { Text = "本机密钥库", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        leftPanel.Children.Add(librarySummary);
        leftPanel.Children.Add(leftToolbar);
        leftPanel.Children.Add(keyList);

        var emptyState = new StackPanel
        {
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        emptyState.Children.Add(new FontIcon { Glyph = "\uE8D7", FontSize = 28 });
        emptyState.Children.Add(new TextBlock { Text = "选择一把密钥查看详情", FontSize = 17 });
        emptyState.Children.Add(new TextBlock
        {
            Text = "私钥不会在界面中回显，也不会写入普通资产文件。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });

        var nameBox = new TextBox { Header = "密钥名称", MaxLength = SshKeyMaterialPolicy.MaximumNameLength };
        var saveNameButton = new Button { Content = "保存名称", MinWidth = 112 };
        var copyPublicKeyButton = new Button { Content = "复制公钥", MinWidth = 112 };
        var exportPublicKeyButton = new Button { Content = "导出 .pub", MinWidth = 112 };
        var deployPublicKeyButton = new Button { Content = "部署到资产", MinWidth = 112 };
        var keyActions = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        keyActions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyActions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyActions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        keyActions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(copyPublicKeyButton, 1);
        Grid.SetRow(exportPublicKeyButton, 1);
        Grid.SetRow(deployPublicKeyButton, 1);
        Grid.SetColumn(deployPublicKeyButton, 1);
        foreach (var button in new[] { saveNameButton, copyPublicKeyButton, exportPublicKeyButton, deployPublicKeyButton })
        {
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            keyActions.Children.Add(button);
        }
        var formatText = new TextBlock();
        var fingerprintText = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var createdText = new TextBlock();
        var keySyncToggle = new ToggleSwitch
        {
            Header = "端到端加密同步",
            OffContent = "仅保存在此 Windows 用户",
            OnContent = "随当前账户自动同步",
        };
        var keySyncExplanation = new TextBlock
        {
            Text = "启用后，私钥、口令、名称和资产分配会先用主密码派生的密钥加密，再上传；云端和诊断中不会出现明文。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var detailMetadata = new StackPanel { Spacing = 7 };
        detailMetadata.Children.Add(formatText);
        detailMetadata.Children.Add(fingerprintText);
        detailMetadata.Children.Add(createdText);

        var assetAssignments = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            MaxHeight = 250,
        };
        AutomationProperties.SetName(assetAssignments, "使用此密钥的 SSH 资产");
        var applyAssignmentsButton = new Button { Content = "应用资产分配", MinWidth = 132 };
        var detailPanel = new StackPanel { Spacing = 12, Visibility = Visibility.Collapsed };
        detailPanel.Children.Add(new TextBlock { Text = "密钥详情", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        detailPanel.Children.Add(nameBox);
        detailPanel.Children.Add(keyActions);
        detailPanel.Children.Add(detailMetadata);
        detailPanel.Children.Add(keySyncToggle);
        detailPanel.Children.Add(keySyncExplanation);
        detailPanel.Children.Add(new TextBlock { Text = "分配给资产", FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        detailPanel.Children.Add(new TextBlock
        {
            Text = "勾选后会替换该资产当前保存的私钥，但保留密码回退凭据。仅列出 SSH 资产。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            FontSize = 12,
        });
        detailPanel.Children.Add(assetAssignments);
        detailPanel.Children.Add(applyAssignmentsButton);

        var importNameBox = new TextBox { Header = "密钥名称", PlaceholderText = "例如：生产环境 Ed25519" };
        var importPassphraseBox = new PasswordBox { Header = "私钥口令（可选）" };
        var chooseKeyButton = new Button { Content = "选择私钥文件", MinWidth = 132 };
        var selectedFileText = new TextBlock
        {
            Text = "尚未选择文件",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        var confirmImportButton = new Button { Content = "安全导入", MinWidth = 112, IsEnabled = false };
        var cancelImportButton = new Button { Content = "取消", MinWidth = 88 };
        var importActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        importActions.Children.Add(confirmImportButton);
        importActions.Children.Add(cancelImportButton);
        var importPanel = new StackPanel { Spacing = 12, Visibility = Visibility.Collapsed };
        importPanel.Children.Add(new TextBlock { Text = "导入私钥", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        importPanel.Children.Add(new TextBlock
        {
            Text = "支持 OpenSSH、PEM 与 PKCS#8 私钥。密钥和名称会作为一个整体由当前 Windows 用户的 DPAPI 加密。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        importPanel.Children.Add(importNameBox);
        importPanel.Children.Add(importPassphraseBox);
        importPanel.Children.Add(chooseKeyButton);
        importPanel.Children.Add(selectedFileText);
        importPanel.Children.Add(importActions);

        var generatedNameBox = new TextBox
        {
            Header = "密钥名称",
            Text = $"OrbitTerm Ed25519 {DateTime.Now:yyyy-MM-dd}",
            MaxLength = SshKeyMaterialPolicy.MaximumNameLength,
        };
        var confirmGenerateButton = new Button { Content = "安全生成", MinWidth = 112 };
        var cancelGenerateButton = new Button { Content = "取消", MinWidth = 88 };
        var generateActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        generateActions.Children.Add(confirmGenerateButton);
        generateActions.Children.Add(cancelGenerateButton);
        var generatePanel = new StackPanel { Spacing = 12, Visibility = Visibility.Collapsed };
        generatePanel.Children.Add(new TextBlock
        {
            Text = "生成 Ed25519 密钥",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        generatePanel.Children.Add(new TextBlock
        {
            Text = "密钥对将在本机生成。私钥立即写入当前 Windows 用户的 DPAPI 密钥库；临时文件会覆写并删除，私钥不会在界面中回显。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        generatePanel.Children.Add(generatedNameBox);
        generatePanel.Children.Add(generateActions);

        var deploymentAssets = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Height = 205,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(deploymentAssets, ScrollBarVisibility.Visible);
        AutomationProperties.SetName(deploymentAssets, "公钥部署目标资产");
        var selectAllDeploymentButton = new Button { Content = "全选", MinWidth = 88 };
        var clearDeploymentButton = new Button { Content = "清空", MinWidth = 88 };
        var deploymentSelectionActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        deploymentSelectionActions.Children.Add(selectAllDeploymentButton);
        deploymentSelectionActions.Children.Add(clearDeploymentButton);
        var startDeploymentButton = new Button { Content = "开始安全部署", MinWidth = 132 };
        var cancelDeploymentButton = new Button { Content = "取消部署", MinWidth = 100, IsEnabled = false };
        var backFromDeploymentButton = new Button { Content = "返回详情", MinWidth = 100 };
        var deploymentActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        deploymentActions.Children.Add(startDeploymentButton);
        deploymentActions.Children.Add(cancelDeploymentButton);
        deploymentActions.Children.Add(backFromDeploymentButton);
        var deploymentProgress = new ProgressBar { Minimum = 0, Maximum = 1, Value = 0, Height = 4 };
        var deploymentSummary = new TextBlock
        {
            Text = "选择一个或多个 SSH 资产。部署成功后会用新密钥回连验证，再安全替换资产私钥。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        AutomationProperties.SetLiveSetting(deploymentSummary, AutomationLiveSetting.Polite);
        var challengeDetails = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var trustChallengeButton = new Button { Content = "信任并继续", MinWidth = 112 };
        var skipChallengeButton = new Button { Content = "跳过此资产", MinWidth = 112 };
        var challengeActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        challengeActions.Children.Add(trustChallengeButton);
        challengeActions.Children.Add(skipChallengeButton);
        var challengePanel = new StackPanel
        {
            Spacing = 8,
            Visibility = Visibility.Collapsed,
            Background = ResourceBrush("OrbitAccentSoftBrush"),
            Padding = new Thickness(12),
        };
        challengePanel.Children.Add(new TextBlock { Text = "首次连接需要确认主机密钥", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        challengePanel.Children.Add(challengeDetails);
        challengePanel.Children.Add(challengeActions);
        var deploymentTitle = new TextBlock
        {
            Text = "一键部署公钥",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        var deploymentEligibility = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
            FontSize = 12,
        };
        var deploymentPanel = new StackPanel { Spacing = 10, Visibility = Visibility.Collapsed };
        deploymentPanel.Children.Add(deploymentTitle);
        deploymentPanel.Children.Add(new TextBlock
        {
            Text = "OrbitTerm 会使用资产现有凭据登录，将公钥幂等写入 authorized_keys；随后只使用新私钥回连。验证失败时不会覆盖原凭据。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        });
        deploymentPanel.Children.Add(deploymentEligibility);
        deploymentPanel.Children.Add(deploymentSelectionActions);
        deploymentPanel.Children.Add(deploymentAssets);
        deploymentPanel.Children.Add(challengePanel);
        deploymentPanel.Children.Add(deploymentProgress);
        deploymentPanel.Children.Add(deploymentSummary);
        deploymentPanel.Children.Add(deploymentActions);

        var statusText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 20,
            Foreground = ResourceBrush("OrbitMutedTextBrush"),
        };
        AutomationProperties.SetLiveSetting(statusText, AutomationLiveSetting.Polite);
        var rightHost = new Grid { MinHeight = 190 };
        rightHost.Children.Add(emptyState);
        rightHost.Children.Add(detailPanel);
        rightHost.Children.Add(importPanel);
        rightHost.Children.Add(generatePanel);
        rightHost.Children.Add(deploymentPanel);
        var detailScroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = rightHost,
        };
        AutomationProperties.SetName(detailScroll, "密钥详情");

        var body = new Grid
        {
            Width = 500,
            MaxWidth = 500,
            Height = 530,
            MaxHeight = 530,
            RowSpacing = 10,
        };
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(leftPanel, 0);
        Grid.SetRow(detailScroll, 1);
        Grid.SetRow(statusText, 2);
        body.Children.Add(leftPanel);
        body.Children.Add(detailScroll);
        body.Children.Add(statusText);

        SshKeyRecord? selectedRecord = null;
        string? selectedPrivateKey = null;
        CancellationTokenSource? deploymentCancellation = null;
        TaskCompletionSource<bool>? pendingTrustDecision = null;
        var deleteArmedKeyId = Guid.Empty;
        var updatingSyncToggle = false;
        var accessibleAssets = ViewModel.Assets
            .Where(ViewModel.CanAccessAsset)
            .Select(asset => asset.ToRecord())
            .OrderBy(asset => asset.Group, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(asset => asset.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
        var sshAssets = accessibleAssets
            .Where(asset => asset.Transport == ServerTransport.Ssh)
            .ToArray();
        var excludedRdpCount = accessibleAssets.Count(asset => asset.Transport == ServerTransport.RemoteDesktop);
        var excludedTelnetCount = accessibleAssets.Count(asset => asset.Transport == ServerTransport.Telnet);

        void ShowEmpty()
        {
            leftPanel.Visibility = Visibility.Visible;
            emptyState.Visibility = Visibility.Visible;
            detailPanel.Visibility = Visibility.Collapsed;
            importPanel.Visibility = Visibility.Collapsed;
            generatePanel.Visibility = Visibility.Collapsed;
            deploymentPanel.Visibility = Visibility.Collapsed;
            selectedRecord = null;
            deleteButton.IsEnabled = false;
            deleteButton.Content = "删除";
            deleteArmedKeyId = Guid.Empty;
        }

        void ShowImport()
        {
            leftPanel.Visibility = Visibility.Visible;
            emptyState.Visibility = Visibility.Collapsed;
            detailPanel.Visibility = Visibility.Collapsed;
            importPanel.Visibility = Visibility.Visible;
            generatePanel.Visibility = Visibility.Collapsed;
            deploymentPanel.Visibility = Visibility.Collapsed;
            keyList.SelectedItem = null;
            deleteButton.IsEnabled = false;
        }

        void ShowGenerate()
        {
            leftPanel.Visibility = Visibility.Visible;
            emptyState.Visibility = Visibility.Collapsed;
            detailPanel.Visibility = Visibility.Collapsed;
            importPanel.Visibility = Visibility.Collapsed;
            generatePanel.Visibility = Visibility.Visible;
            deploymentPanel.Visibility = Visibility.Collapsed;
            generatedNameBox.Text = $"OrbitTerm Ed25519 {DateTime.Now:yyyy-MM-dd}";
            keyList.SelectedItem = null;
            deleteButton.IsEnabled = false;
            statusText.Text = "确认名称后即可在本机安全生成。";
            generatedNameBox.Focus(FocusState.Programmatic);
        }

        void ShowDetail(SshKeyRecord record)
        {
            leftPanel.Visibility = Visibility.Visible;
            selectedRecord = record;
            emptyState.Visibility = Visibility.Collapsed;
            importPanel.Visibility = Visibility.Collapsed;
            generatePanel.Visibility = Visibility.Collapsed;
            deploymentPanel.Visibility = Visibility.Collapsed;
            detailPanel.Visibility = Visibility.Visible;
            nameBox.Text = record.Name;
            formatText.Text = $"密钥格式：{record.Format}";
            fingerprintText.Text = $"本机材料标识：{record.MaterialFingerprint}";
            createdText.Text = $"导入时间：{record.CreatedAt.ToLocalTime():yyyy-MM-dd HH:mm} · 已分配 {record.AssignedAssetIds.Count} 个资产";
            updatingSyncToggle = true;
            keySyncToggle.IsOn = record.SyncScope == SshKeySyncScope.EndToEndEncrypted;
            updatingSyncToggle = false;
            deleteButton.IsEnabled = true;
            deleteButton.Content = "删除";
            deleteArmedKeyId = Guid.Empty;
            assetAssignments.Items.Clear();
            foreach (var asset in sshAssets)
            {
                var checkBox = new CheckBox
                {
                    Tag = asset,
                    IsChecked = record.AssignedAssetIds.Contains(asset.Id),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Content = new StackPanel
                    {
                        Spacing = 2,
                        Children =
                        {
                            new TextBlock { Text = asset.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                            new TextBlock
                            {
                                Text = $"{asset.Group} · {asset.Username}@{asset.Host}:{asset.Port}",
                                FontSize = 11,
                                Foreground = ResourceBrush("OrbitMutedTextBrush"),
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                        },
                    },
                };
                assetAssignments.Items.Add(checkBox);
            }
        }

        void ShowDeployment()
        {
            if (selectedRecord is null)
                return;
            emptyState.Visibility = Visibility.Collapsed;
            importPanel.Visibility = Visibility.Collapsed;
            generatePanel.Visibility = Visibility.Collapsed;
            detailPanel.Visibility = Visibility.Collapsed;
            deploymentPanel.Visibility = Visibility.Visible;
            // Deployment is a focused workflow. Hiding the library chooser frees
            // the full dialog height for targets and keeps all actions visible.
            leftPanel.Visibility = Visibility.Collapsed;
            deploymentAssets.Items.Clear();
            foreach (var asset in sshAssets)
            {
                var checkBox = new CheckBox
                {
                    Tag = asset,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Content = new StackPanel
                    {
                        Spacing = 2,
                        Children =
                        {
                            new TextBlock { Text = asset.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                            new TextBlock
                            {
                                Text = $"{asset.Group} · {asset.Username}@{asset.Host}:{asset.Port}",
                                FontSize = 11,
                                Foreground = ResourceBrush("OrbitMutedTextBrush"),
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                        },
                    },
                };
                deploymentAssets.Items.Add(checkBox);
            }
            deploymentProgress.Maximum = Math.Max(1, sshAssets.Length);
            deploymentProgress.Value = 0;
            deploymentTitle.Text = $"一键部署公钥 · {sshAssets.Length} 台可部署";
            var excludedParts = new List<string>();
            if (excludedRdpCount > 0) excludedParts.Add($"RDP {excludedRdpCount} 台");
            if (excludedTelnetCount > 0) excludedParts.Add($"Telnet {excludedTelnetCount} 台");
            deploymentEligibility.Text = excludedParts.Count == 0
                ? $"当前可访问资产共 {accessibleAssets.Length} 台，全部为 SSH 资产。"
                : $"当前可访问资产共 {accessibleAssets.Length} 台；已自动排除 {string.Join("、", excludedParts)}，因为这些协议不使用 SSH authorized_keys。";
            deploymentSummary.Text = sshAssets.Length == 0
                ? "当前没有可访问的 SSH 资产。"
                : "请选择目标。支持一次部署到多台资产；每台都会独立连接、验证和提交。";
            challengePanel.Visibility = Visibility.Collapsed;
            startDeploymentButton.IsEnabled = sshAssets.Length > 0;
            cancelDeploymentButton.IsEnabled = false;
            backFromDeploymentButton.IsEnabled = true;
            detailScroll.UpdateLayout();
            detailScroll.ChangeView(null, 0, null, disableAnimation: true);
        }

        async Task RefreshAsync(Guid selectId = default)
        {
            var records = await sshKeyLibrary.ListAccessibleAsync(
                ViewModel.CurrentAccountScope,
                ViewModel.IsAccountUnlocked,
                CancellationToken.None);
            keyList.Items.Clear();
            var synchronizedCount = records.Count(item => item.SyncScope == SshKeySyncScope.EndToEndEncrypted);
            librarySummary.Text = records.Count == 0
                ? "尚无密钥。导入后可复用于多个 SSH 资产。"
                : $"{records.Count} 把密钥 · 已加密同步 {synchronizedCount} 把 · 私钥内容始终隐藏";
            ListViewItem? itemToSelect = null;
            foreach (var record in records)
            {
                var item = new ListViewItem
                {
                    Tag = record,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Content = new StackPanel
                    {
                        Spacing = 3,
                        Children =
                        {
                            new TextBlock { Text = record.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                            new TextBlock
                            {
                                Text = $"{record.Format} · {record.AssignedAssetIds.Count} 个资产 · {(record.SyncScope == SshKeySyncScope.EndToEndEncrypted ? "加密同步" : "仅本机")}",
                                FontSize = 11,
                                Foreground = ResourceBrush("OrbitMutedTextBrush"),
                            },
                        },
                    },
                };
                keyList.Items.Add(item);
                if (record.Id == selectId) itemToSelect = item;
            }

            if (itemToSelect is not null)
            {
                keyList.SelectedItem = itemToSelect;
                ShowDetail((SshKeyRecord)itemToSelect.Tag);
            }
            else if (records.Count == 0)
            {
                ShowEmpty();
            }
        }

        keyList.SelectionChanged += (_, _) =>
        {
            if (keyList.SelectedItem is ListViewItem { Tag: SshKeyRecord record }) ShowDetail(record);
        };
        keySyncToggle.Toggled += async (_, _) =>
        {
            if (updatingSyncToggle || selectedRecord is null)
            {
                return;
            }

            keySyncToggle.IsEnabled = false;
            try
            {
                var scope = keySyncToggle.IsOn
                    ? SshKeySyncScope.EndToEndEncrypted
                    : SshKeySyncScope.LocalOnly;
                var updated = await sshKeyLibrary.SetSyncScopeAsync(
                    selectedRecord.Id,
                    scope,
                    ViewModel.CurrentAccountScope,
                    CancellationToken.None);
                selectedRecord = updated;
                if (ViewModel.IsAccountUnlocked)
                {
                    statusText.Text = keySyncToggle.IsOn
                        ? "正在端到端加密并同步此密钥…"
                        : "正在提交停止同步与远端删除墓碑…";
                    var result = await ViewModel.SynchronizeEncryptedConfigsAsync(string.Empty, CancellationToken.None);
                    statusText.Text = result?.Status == EncryptedConfigSynchronizationStatus.Completed
                        ? (keySyncToggle.IsOn ? "此密钥已启用自动端到端加密同步。" : "此密钥已改为仅本机，远端删除状态已提交。")
                        : "密钥范围已保存在本机；自动同步将在下次账户解锁或网络恢复时重试。";
                }
                else
                {
                    statusText.Text = keySyncToggle.IsOn
                        ? "已标记为加密同步；登录并解锁账户后会自动上传。"
                        : "已改为仅本机；登录并解锁后会同步删除云端副本。";
                }
                await RefreshAsync(updated.Id);
            }
            catch (Exception exception)
            {
                statusText.Text = exception.Message;
                updatingSyncToggle = true;
                keySyncToggle.IsOn = selectedRecord.SyncScope == SshKeySyncScope.EndToEndEncrypted;
                updatingSyncToggle = false;
            }
            finally
            {
                keySyncToggle.IsEnabled = true;
            }
        };
        importButton.Click += (_, _) => ShowImport();
        generateButton.Click += (_, _) => ShowGenerate();
        cancelGenerateButton.Click += (_, _) => ShowEmpty();
        confirmGenerateButton.Click += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(generatedNameBox.Text))
            {
                statusText.Text = "请填写密钥名称。";
                generatedNameBox.Focus(FocusState.Programmatic);
                return;
            }

            generateButton.IsEnabled = false;
            confirmGenerateButton.IsEnabled = false;
            cancelGenerateButton.IsEnabled = false;
            statusText.Text = "正在本机生成 Ed25519 密钥，请稍候…";
            string? privateKey = null;
            try
            {
                privateKey = await GenerateEd25519PrivateKeyAsync(CancellationToken.None);
                var generated = await sshKeyLibrary.ImportAsync(
                    generatedNameBox.Text,
                    privateKey,
                    string.Empty,
                    CancellationToken.None,
                    SshKeyOrigin.Generated);
                statusText.Text = "Ed25519 密钥已在本机生成并安全写入 DPAPI 密钥库。";
                await RefreshAsync(generated.Id);
            }
            catch (Exception exception) { statusText.Text = exception.Message; }
            finally
            {
                privateKey = null;
                generateButton.IsEnabled = true;
                confirmGenerateButton.IsEnabled = true;
                cancelGenerateButton.IsEnabled = true;
            }
        };
        cancelImportButton.Click += (_, _) => ShowEmpty();
        chooseKeyButton.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            picker.FileTypeFilter.Add(".pem");
            picker.FileTypeFilter.Add(".key");
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, windowHandle);
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            try
            {
                var properties = await file.GetBasicPropertiesAsync();
                if (properties.Size is 0 or > SshKeyMaterialPolicy.MaximumPrivateKeyBytes)
                {
                    throw new InvalidDataException("私钥必须是非空文本，且不能超过 1 MB。");
                }
                selectedPrivateKey = await FileIO.ReadTextAsync(file);
                _ = SshKeyMaterialPolicy.NormalizePrivateKey(selectedPrivateKey);
                if (string.IsNullOrWhiteSpace(importNameBox.Text)) importNameBox.Text = Path.GetFileNameWithoutExtension(file.Name);
                selectedFileText.Text = $"已选择：{file.Name} · {properties.Size / 1024.0:F1} KiB";
                confirmImportButton.IsEnabled = true;
                statusText.Text = "文件容器检查通过；导入后私钥不会回显。";
            }
            catch (Exception exception)
            {
                selectedPrivateKey = null;
                confirmImportButton.IsEnabled = false;
                selectedFileText.Text = "尚未选择有效的私钥文件";
                statusText.Text = exception.Message;
            }
        };
        confirmImportButton.Click += async (_, _) =>
        {
            if (selectedPrivateKey is null) return;
            try
            {
                confirmImportButton.IsEnabled = false;
                var imported = await sshKeyLibrary.ImportAsync(importNameBox.Text, selectedPrivateKey, importPassphraseBox.Password, CancellationToken.None);
                selectedPrivateKey = null;
                importPassphraseBox.Password = string.Empty;
                statusText.Text = "密钥已安全导入本机密钥库。";
                await RefreshAsync(imported.Id);
            }
            catch (Exception exception)
            {
                statusText.Text = exception.Message;
                confirmImportButton.IsEnabled = true;
            }
        };
        saveNameButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            try
            {
                var renamed = await sshKeyLibrary.RenameAsync(selectedRecord.Id, nameBox.Text, CancellationToken.None);
                if (renamed.SyncScope == SshKeySyncScope.EndToEndEncrypted && ViewModel.IsAccountUnlocked)
                {
                    await ViewModel.SynchronizeEncryptedConfigsAsync(string.Empty, CancellationToken.None);
                }
                statusText.Text = renamed.SyncScope == SshKeySyncScope.EndToEndEncrypted
                    ? "密钥名称已更新并加入自动同步。"
                    : "密钥名称已更新。";
                await RefreshAsync(renamed.Id);
            }
            catch (Exception exception) { statusText.Text = exception.Message; }
        };
        copyPublicKeyButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            try
            {
                copyPublicKeyButton.IsEnabled = false;
                var publicKey = await DeriveStoredPublicKeyAsync(selectedRecord, CancellationToken.None);
                var package = new DataPackage();
                package.SetText(publicKey);
                Clipboard.SetContent(package);
                statusText.Text = "OpenSSH 公钥已复制，可粘贴到远端 ~/.ssh/authorized_keys。";
            }
            catch (Exception exception) { statusText.Text = exception.Message; }
            finally { copyPublicKeyButton.IsEnabled = true; }
        };
        exportPublicKeyButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            try
            {
                exportPublicKeyButton.IsEnabled = false;
                var publicKey = await DeriveStoredPublicKeyAsync(selectedRecord, CancellationToken.None);
                var picker = new FileSavePicker
                {
                    SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                    SuggestedFileName = SanitizePublicKeyFileName(selectedRecord.Name),
                };
                picker.FileTypeChoices.Add("OpenSSH 公钥", [".pub"]);
                InitializeWithWindow.Initialize(picker, windowHandle);
                var file = await picker.PickSaveFileAsync();
                if (file is null)
                {
                    statusText.Text = "已取消导出公钥。";
                    return;
                }
                await FileIO.WriteTextAsync(file, string.Concat(publicKey, Environment.NewLine));
                statusText.Text = $"公钥已导出：{file.Name}";
            }
            catch (Exception exception) { statusText.Text = exception.Message; }
            finally { exportPublicKeyButton.IsEnabled = true; }
        };
        deployPublicKeyButton.Click += (_, _) => ShowDeployment();
        selectAllDeploymentButton.Click += (_, _) =>
        {
            foreach (var item in deploymentAssets.Items.OfType<CheckBox>()) item.IsChecked = true;
        };
        clearDeploymentButton.Click += (_, _) =>
        {
            foreach (var item in deploymentAssets.Items.OfType<CheckBox>()) item.IsChecked = false;
        };
        backFromDeploymentButton.Click += (_, _) =>
        {
            if (selectedRecord is not null) ShowDetail(selectedRecord);
        };
        trustChallengeButton.Click += (_, _) => pendingTrustDecision?.TrySetResult(true);
        skipChallengeButton.Click += (_, _) => pendingTrustDecision?.TrySetResult(false);
        cancelDeploymentButton.Click += (_, _) =>
        {
            pendingTrustDecision?.TrySetResult(false);
            deploymentCancellation?.Cancel();
        };
        startDeploymentButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            var targets = deploymentAssets.Items
                .OfType<CheckBox>()
                .Where(item => item.IsChecked == true)
                .ToArray();
            if (targets.Length == 0)
            {
                deploymentSummary.Text = "请至少选择一个 SSH 资产。";
                return;
            }

            deploymentCancellation?.Dispose();
            deploymentCancellation = new CancellationTokenSource();
            var cancellationToken = deploymentCancellation.Token;
            startDeploymentButton.IsEnabled = false;
            cancelDeploymentButton.IsEnabled = true;
            backFromDeploymentButton.IsEnabled = false;
            selectAllDeploymentButton.IsEnabled = false;
            clearDeploymentButton.IsEnabled = false;
            keyList.IsEnabled = false;
            importButton.IsEnabled = false;
            generateButton.IsEnabled = false;
            deploymentProgress.Maximum = targets.Length;
            deploymentProgress.Value = 0;
            var succeeded = 0;
            var failed = 0;
            var skipped = 0;
            string? publicKey = null;
            try
            {
                publicKey = await DeriveStoredPublicKeyAsync(selectedRecord, cancellationToken);
                for (var index = 0; index < targets.Length; index++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var item = targets[index];
                    var asset = (ServerAssetRecord)item.Tag;
                    deploymentSummary.Text = $"正在处理 {index + 1} / {targets.Length}：{asset.Name} · 正在安全连接";
                    item.IsEnabled = false;

                    SshPublicKeyDeploymentResult result;
                    while (true)
                    {
                        result = await Task.Run(
                            async () => await sshPublicKeyDeployment.DeployAsync(
                                selectedRecord.Id,
                                asset,
                                publicKey,
                                cancellationToken).ConfigureAwait(false),
                            cancellationToken);
                        if (result is not SshPublicKeyDeploymentResult.RequiresHostKeyTrust required)
                            break;

                        challengeDetails.Text = $"{asset.Name}\n{required.Challenge.NormalizedHost}:{required.Challenge.Port}\n{required.Challenge.KeyAlgorithm} · {required.Challenge.FingerprintSha256}\n请与服务器管理员提供的指纹核对。";
                        challengePanel.Visibility = Visibility.Visible;
                        pendingTrustDecision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        deploymentSummary.Text = $"{asset.Name} 首次连接，等待确认主机密钥。";
                        var trust = await pendingTrustDecision.Task;
                        pendingTrustDecision = null;
                        challengePanel.Visibility = Visibility.Collapsed;
                        if (!trust)
                        {
                            skipped++;
                            result = new SshPublicKeyDeploymentResult.Failed("host_key_skipped", "已跳过：未确认主机密钥。", false);
                            break;
                        }

                        var trustResult = await Task.Run(
                            async () => await remoteAccessOrchestrator.TrustHostKeyAsync(
                                required.Challenge,
                                "OrbitTerm Windows key deployment",
                                cancellationToken).ConfigureAwait(false),
                            cancellationToken);
                        if (trustResult is HostKeyTrustResult.Persisted)
                            continue;
                        result = new SshPublicKeyDeploymentResult.Failed("host_key_persist_failed", "无法保存主机密钥，未执行部署。", false);
                        break;
                    }

                    var targetPanel = item.Content as StackPanel;
                    switch (result)
                    {
                        case SshPublicKeyDeploymentResult.Succeeded success:
                            succeeded++;
                            targetPanel?.Children.Add(new TextBlock
                            {
                                Text = success.AlreadyPresent ? "已验证 · 远端原已存在" : "部署并回连验证成功",
                                Foreground = ResourceBrush("OrbitSuccessBrush"),
                                FontSize = 11,
                            });
                            break;
                        case SshPublicKeyDeploymentResult.Failed failure:
                            if (!string.Equals(failure.Code, "host_key_skipped", StringComparison.Ordinal)) failed++;
                            targetPanel?.Children.Add(new TextBlock
                            {
                                Text = failure.Message,
                                Foreground = ResourceBrush("OrbitDangerBrush"),
                                FontSize = 11,
                                TextWrapping = TextWrapping.Wrap,
                            });
                            break;
                    }
                    deploymentProgress.Value = index + 1;
                    deploymentSummary.Text = $"已处理 {index + 1} / {targets.Length} · 成功 {succeeded} · 失败 {failed} · 跳过 {skipped}";
                }
                deploymentSummary.Text = $"部署完成：成功 {succeeded} / {targets.Length}，失败 {failed}，跳过 {skipped}。只有回连验证成功的资产才更新了本机私钥。";
            }
            catch (OperationCanceledException)
            {
                deploymentSummary.Text = $"部署已取消：已完成 {succeeded}，失败 {failed}，其余目标未处理。";
            }
            catch (Exception exception)
            {
                deploymentSummary.Text = exception.Message;
            }
            finally
            {
                publicKey = null;
                pendingTrustDecision = null;
                challengePanel.Visibility = Visibility.Collapsed;
                cancelDeploymentButton.IsEnabled = false;
                backFromDeploymentButton.IsEnabled = true;
                selectAllDeploymentButton.IsEnabled = true;
                clearDeploymentButton.IsEnabled = true;
                keyList.IsEnabled = true;
                importButton.IsEnabled = true;
                generateButton.IsEnabled = true;
                startDeploymentButton.IsEnabled = true;
                deploymentCancellation.Dispose();
                deploymentCancellation = null;
            }
        };
        applyAssignmentsButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            try
            {
                applyAssignmentsButton.IsEnabled = false;
                var requested = assetAssignments.Items
                    .OfType<CheckBox>()
                    .Where(item => item.IsChecked == true)
                    .Select(item => ((ServerAssetRecord)item.Tag).Id)
                    .ToHashSet();
                foreach (var asset in sshAssets.Where(asset => requested.Contains(asset.Id) && !selectedRecord.AssignedAssetIds.Contains(asset.Id)))
                    await sshKeyLibrary.AssignToAssetAsync(selectedRecord.Id, asset, CancellationToken.None);
                foreach (var asset in sshAssets.Where(asset => !requested.Contains(asset.Id) && selectedRecord.AssignedAssetIds.Contains(asset.Id)))
                    await sshKeyLibrary.RemoveFromAssetAsync(selectedRecord.Id, asset, CancellationToken.None);
                statusText.Text = "资产分配已更新；密码回退凭据未被更改。";
                if (selectedRecord.SyncScope == SshKeySyncScope.EndToEndEncrypted && ViewModel.IsAccountUnlocked)
                {
                    await ViewModel.SynchronizeEncryptedConfigsAsync(string.Empty, CancellationToken.None);
                    statusText.Text = "资产分配已更新并加密同步；密码回退凭据未被更改。";
                }
                await RefreshAsync(selectedRecord.Id);
            }
            catch (Exception exception) { statusText.Text = exception.Message; }
            finally { applyAssignmentsButton.IsEnabled = true; }
        };
        deleteButton.Click += async (_, _) =>
        {
            if (selectedRecord is null) return;
            if (deleteArmedKeyId != selectedRecord.Id)
            {
                deleteArmedKeyId = selectedRecord.Id;
                deleteButton.Content = "确认删除";
                statusText.Text = "再次点击“确认删除”才会删除。已分配给资产的密钥不能删除。";
                return;
            }
            try
            {
                var wasSynchronized = selectedRecord.SyncScope == SshKeySyncScope.EndToEndEncrypted;
                await sshKeyLibrary.DeleteAsync(selectedRecord.Id, CancellationToken.None);
                if (wasSynchronized && ViewModel.IsAccountUnlocked)
                {
                    await ViewModel.SynchronizeEncryptedConfigsAsync(string.Empty, CancellationToken.None);
                }
                statusText.Text = wasSynchronized
                    ? "密钥已删除；加密同步删除状态已提交或安全排队。"
                    : "密钥已从本机密钥库删除。";
                await RefreshAsync();
            }
            catch (Exception exception)
            {
                deleteButton.Content = "删除";
                deleteArmedKeyId = Guid.Empty;
                statusText.Text = exception.Message;
            }
        };

        await RefreshAsync();
        var dialog = CreateThemedDialog("SSH 密钥管理", body, closeButtonText: "完成");
        dialog.Closing += (_, args) =>
        {
            if (deploymentCancellation is null)
                return;
            args.Cancel = true;
            deploymentSummary.Text = "部署仍在进行。请先点击“取消部署”，等待当前安全步骤结束后再关闭。";
        };
        await dialog.ShowAsync();
        selectedPrivateKey = null;
        importPassphraseBox.Password = string.Empty;
    }

    private static async Task<string> GenerateEd25519PrivateKeyAsync(CancellationToken cancellationToken)
    {
        var sshKeygen = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "OpenSSH", "ssh-keygen.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh-keygen.exe"),
        }.FirstOrDefault(File.Exists) ?? throw new FileNotFoundException("未找到 Windows OpenSSH ssh-keygen 组件。请先安装 OpenSSH Client。");
        var directory = Path.Combine(Path.GetTempPath(), $"OrbitTerm-Key-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var keyPath = Path.Combine(directory, "id_ed25519");
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = sshKeygen,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            startInfo.ArgumentList.Add("-q");
            startInfo.ArgumentList.Add("-t");
            startInfo.ArgumentList.Add("ed25519");
            startInfo.ArgumentList.Add("-a");
            startInfo.ArgumentList.Add("64");
            startInfo.ArgumentList.Add("-C");
            startInfo.ArgumentList.Add("OrbitTerm Windows");
            startInfo.ArgumentList.Add("-N");
            startInfo.ArgumentList.Add(string.Empty);
            startInfo.ArgumentList.Add("-f");
            startInfo.ArgumentList.Add(keyPath);
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) throw new InvalidOperationException("无法启动 Windows OpenSSH 密钥生成器。");
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var error = await errorTask;
            if (process.ExitCode != 0 || !File.Exists(keyPath))
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "Ed25519 密钥生成失败。" : error.Trim());
            return await File.ReadAllTextAsync(keyPath, cancellationToken);
        }
        finally
        {
            foreach (var file in new[] { keyPath, keyPath + ".pub" })
            {
                try
                {
                    if (!File.Exists(file)) continue;
                    var length = new FileInfo(file).Length;
                    if (length is > 0 and <= SshKeyMaterialPolicy.MaximumPrivateKeyBytes)
                    {
                        await using var stream = new FileStream(file, FileMode.Open, FileAccess.Write, FileShare.None);
                        var zeros = new byte[checked((int)length)];
                        await stream.WriteAsync(zeros, CancellationToken.None);
                        CryptographicOperations.ZeroMemory(zeros);
                    }
                    File.Delete(file);
                }
                catch { }
            }
            try { Directory.Delete(directory, recursive: false); } catch { }
        }
    }

    private async Task<string> DeriveStoredPublicKeyAsync(SshKeyRecord record, CancellationToken cancellationToken)
    {
        var secret = await sshKeyLibrary.ReadSecretAsync(record.Id, cancellationToken);
        var publicKey = await DeriveOpenSshPublicKeyAsync(secret.PrivateKey, secret.Passphrase, cancellationToken);
        var comment = new string(record.Name.Where(character => !char.IsControl(character)).ToArray()).Trim();
        return string.IsNullOrWhiteSpace(comment) ? publicKey : string.Concat(publicKey, " ", comment);
    }

    private static async Task<string> DeriveOpenSshPublicKeyAsync(
        string privateKey,
        string passphrase,
        CancellationToken cancellationToken)
    {
        var sshKeygen = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "OpenSSH", "ssh-keygen.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh-keygen.exe"),
        }.FirstOrDefault(File.Exists) ?? throw new FileNotFoundException("未找到 Windows OpenSSH ssh-keygen 组件。请先安装 OpenSSH Client。");
        var directory = Path.Combine(Path.GetTempPath(), $"OrbitTerm-PublicKey-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var keyPath = Path.Combine(directory, "private_key");
        try
        {
            await File.WriteAllTextAsync(keyPath, privateKey, cancellationToken);
            var startInfo = new ProcessStartInfo
            {
                FileName = sshKeygen,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            startInfo.ArgumentList.Add("-y");
            startInfo.ArgumentList.Add("-f");
            startInfo.ArgumentList.Add(keyPath);
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) throw new InvalidOperationException("无法启动 Windows OpenSSH 公钥派生器。");
            await process.StandardInput.WriteLineAsync(passphrase.AsMemory(), cancellationToken);
            process.StandardInput.Close();
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var output = (await outputTask).Trim();
            var error = (await errorTask).Trim();
            if (process.ExitCode != 0 || !output.StartsWith("ssh-", StringComparison.Ordinal))
            {
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error)
                    ? "无法从该私钥派生 OpenSSH 公钥。"
                    : "私钥口令不正确，或密钥格式不受当前 OpenSSH 支持。");
            }
            return output;
        }
        finally
        {
            SecureDeleteTemporaryDirectory(directory);
        }
    }

    private static string SanitizePublicKeyFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var normalized = new string(name.Where(character => !invalid.Contains(character) && !char.IsControl(character)).ToArray()).Trim();
        return string.IsNullOrWhiteSpace(normalized) ? "orbitterm_ed25519" : normalized;
    }

    private static void SecureDeleteTemporaryDirectory(string directory)
    {
        if (!Directory.Exists(directory)) return;
        foreach (var file in Directory.EnumerateFiles(directory))
        {
            try
            {
                var length = new FileInfo(file).Length;
                if (length > 0)
                {
                    using var stream = new FileStream(file, FileMode.Open, FileAccess.Write, FileShare.None);
                    var zeros = new byte[checked((int)Math.Min(length, 1024 * 1024))];
                    long remaining = length;
                    while (remaining > 0)
                    {
                        var count = (int)Math.Min(remaining, zeros.Length);
                        stream.Write(zeros, 0, count);
                        remaining -= count;
                    }
                    stream.Flush(true);
                    CryptographicOperations.ZeroMemory(zeros);
                }
                File.Delete(file);
            }
            catch { }
        }
        try { Directory.Delete(directory, recursive: false); } catch { }
    }
}
