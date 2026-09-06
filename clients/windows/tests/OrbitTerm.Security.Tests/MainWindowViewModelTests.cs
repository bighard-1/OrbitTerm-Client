using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using OrbitTerm.Presentation;
using OrbitTerm.Terminal;
using System.Text.Json;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class MainWindowViewModelTests
{
    [Fact]
    public void EmptyWorkspaceCopyAndDraftTabMatchDesktopContract()
    {
        var viewModel = CreateViewModel(seedDefaultAsset: false);

        Assert.Equal("还没有服务器", viewModel.AssetEmptyStateTitle);
        Assert.Equal("添加服务器后，即可从这里安全地发起连接。", viewModel.AssetEmptyStateDescription);
        Assert.Equal("暂无会话", viewModel.TerminalEmptyStateLabel);
        Assert.Equal("从左侧选择服务器，然后建立连接。", viewModel.TerminalEmptyStateDescription);

        var draft = Assert.IsType<WorkspaceTabViewModel>(viewModel.SelectedWorkspaceTab);
        Assert.False(draft.IsSessionTabVisible);
        draft.MarkSessionStarted();
        Assert.True(draft.IsSessionTabVisible);
    }

    [Fact]
    public void LegacyAssetDocumentsReceiveSafeGroupAndTagDefaults()
    {
        const string legacyAssetJson = """
            {"id":"11111111-1111-1111-1111-111111111111","credentialId":"22222222-2222-2222-2222-222222222222","name":"Legacy","host":"legacy.example","port":22,"username":"ops","transport":"ssh","allowPasswordFallback":false}
            """;

        var asset = JsonSerializer.Deserialize<ServerAssetRecord>(legacyAssetJson);

        Assert.NotNull(asset);
        Assert.Equal("未分组", asset.Group);
        Assert.Null(asset.Tags);
        var viewModel = AssetViewModel.FromRecord(asset);
        Assert.Equal("未分组", viewModel.Group);
        Assert.Empty(viewModel.Tags);
    }

    [Fact]
    public void AssetEditorValidatesGroupAndTagInput()
    {
        var viewModel = CreateViewModel();

        Assert.Null(viewModel.ValidateAssetEditorInput("生产", "prod.example", "22", "ops", "生产环境", "Linux，数据库"));
        Assert.Equal("标签不能重复。", viewModel.ValidateAssetEditorInput("生产", "prod.example", "22", "ops", "生产环境", "Linux，linux"));
        Assert.Equal("端口必须是 1 到 65535 之间的数字。", viewModel.ValidateAssetEditorInput("生产", "prod.example", "70000", "ops", "生产环境", string.Empty));
    }

    [Fact]
    public async Task AssetGroupsCanBeQuickFilteredAndExposeAnEmptyState()
    {
        var store = new MemoryServerAssetStore();
        store.Seed(
            new ServerAssetRecord(Guid.NewGuid(), Guid.NewGuid(), "生产数据库", "prod-db.example", 22, "ops", ServerTransport.Ssh, false, "生产环境", ["数据库"]),
            new ServerAssetRecord(Guid.NewGuid(), Guid.NewGuid(), "开发主机", "dev.example", 22, "dev", ServerTransport.Ssh, false, "开发环境", ["Linux"]));
        var viewModel = CreateViewModel(assetStore: store, seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 2);

        Assert.Contains("生产环境", viewModel.AssetGroupFilters);
        viewModel.AssetGroupFilter = "生产环境";
        Assert.Single(viewModel.FilteredAssets);
        Assert.Equal("生产数据库", viewModel.FilteredAssets[0].Name);

        viewModel.AssetSearchQuery = "不存在";
        Assert.False(viewModel.HasAssetSearchResults);
        Assert.Equal("未找到匹配的服务器", viewModel.AssetEmptyStateTitle);
    }

    [Fact]
    public async Task ImportAssetsValidatesDeduplicatesAndPersistsCredentialOutsideAssetJson()
    {
        var store = new MemoryServerAssetStore();
        var credentialVault = new MemoryCredentialVault();
        var viewModel = CreateViewModel(credentialVault: credentialVault, assetStore: store, seedDefaultAsset: false);
        var items = new[]
        {
            new BulkAssetImportItem("生产一", "生产", "one.example", 22, "ops", "secret", string.Empty, string.Empty, ["Linux"]),
            new BulkAssetImportItem("重复端点", "生产", "one.example", 22, "ops", "another", string.Empty, string.Empty, []),
            new BulkAssetImportItem(
                "生产二", "生产", "two.example", 2222, "deploy", string.Empty,
                "-----BEGIN OPENSSH PRIVATE KEY-----\r\nbulk-import\r\n-----END OPENSSH PRIVATE KEY-----",
                "phrase", []),
        };

        var imported = await viewModel.ImportAssetsAsync(items, CancellationToken.None);

        Assert.Equal(2, imported);
        Assert.Equal(2, store.SavedAssets.Count);
        Assert.All(store.SavedAssets, asset => Assert.DoesNotContain("secret", JsonSerializer.Serialize(asset), StringComparison.Ordinal));
        Assert.Equal("two.example", viewModel.SelectedAsset?.Host);
    }

    [Fact]
    public void SelectingJumpAssetRestoresJumpDraftWithoutExposingCredential()
    {
        var viewModel = CreateViewModel(seedDefaultAsset: false);
        var asset = new AssetViewModel(
            Guid.NewGuid(), Guid.NewGuid(), "Jumped", "target.example", 22, "ops",
            ServerTransport.Ssh, false, "生产", [],
            new JumpHostRecord(Guid.NewGuid(), "jump.example", 2222, "bastion", true));

        viewModel.SelectedAsset = asset;

        Assert.True(viewModel.IsJumpHostEnabled);
        Assert.Equal("jump.example", viewModel.JumpHost);
        Assert.Equal("2222", viewModel.JumpPortText);
        Assert.Equal("bastion", viewModel.JumpUsername);
        Assert.Empty(viewModel.JumpPassword);
        Assert.Empty(viewModel.JumpPrivateKey);
    }

    [Fact]
    public async Task MainSshPrivateKeyIsStoredOnlyInCredentialVault()
    {
        var store = new MemoryServerAssetStore();
        var credentialVault = new MemoryCredentialVault();
        var viewModel = CreateViewModel(credentialVault: credentialVault, assetStore: store, seedDefaultAsset: false);
        viewModel.AssetName = "密钥资产";
        viewModel.Host = "key.example.com";
        viewModel.PortText = "22";
        viewModel.Username = "ops";
        viewModel.PrivateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----";
        viewModel.PrivateKeyPassphrase = "key-passphrase";
        viewModel.Password = "fallback-secret";
        viewModel.AllowPasswordFallback = true;

        await viewModel.SaveCurrentAssetAsync(CancellationToken.None);

        var saved = Assert.Single(store.SavedAssets);
        Assert.True(saved.AllowPasswordFallback);
        Assert.Equal("fallback-secret", credentialVault.LastSavedCredential.Password);
        Assert.Contains("OPENSSH PRIVATE KEY", credentialVault.LastSavedCredential.PrivateKey, StringComparison.Ordinal);
        Assert.Equal("key-passphrase", credentialVault.LastSavedCredential.PrivateKeyPassphrase);
        var metadata = JsonSerializer.Serialize(saved);
        Assert.DoesNotContain("fallback-secret", metadata, StringComparison.Ordinal);
        Assert.DoesNotContain("OPENSSH PRIVATE KEY", metadata, StringComparison.Ordinal);
        Assert.Empty(viewModel.Password);
        Assert.Empty(viewModel.PrivateKey);
        Assert.Empty(viewModel.PrivateKeyPassphrase);
    }

    [Fact]
    public void ConnectCommandRequiresValidEndpointAndPassword()
    {
        var viewModel = CreateViewModel();

        Assert.False(viewModel.ConnectCommand.CanExecute(null));

        viewModel.Password = "secret";
        Assert.True(viewModel.ConnectCommand.CanExecute(null));

        viewModel.PortText = string.Empty;
        Assert.False(viewModel.ConnectCommand.CanExecute(null));

        viewModel.PortText = "70000";
        Assert.False(viewModel.ConnectCommand.CanExecute(null));
    }

    [Fact]
    public async Task TelnetConnectionFailsClosedWithoutExplicitTargetAuthorization()
    {
        var viewModel = CreateViewModel();
        viewModel.AssetTransport = ServerTransport.Telnet;
        viewModel.PortText = "23";
        viewModel.Password = "secret";

        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Status.Contains("Telnet", StringComparison.Ordinal));

        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);
        Assert.Contains("确认明文传输风险", viewModel.Status, StringComparison.Ordinal);
    }

    [Fact]
    public async Task VerifiedConnectionOpensTerminalWithoutASecondUserAction()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";

        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.True(viewModel.IsConnected);
        Assert.NotEqual(0UL, coreClient.LastOpenedTerminalChannelId);
        Assert.False(viewModel.OpenTerminalCommand.CanExecute(null));
    }

    [Fact]
    public async Task EmptyPreInputSendsARealCarriageReturn()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = string.Empty;
        Assert.True(viewModel.SendCommand.CanExecute(null));
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.SendCommand.IsRunning && coreClient.WriteTerminalCallCount == 1);

        Assert.Equal(new byte[] { 0x0D }, coreClient.LastTerminalWrite);
        Assert.Equal("暂无命令历史", viewModel.CommandHistorySummary);
    }

    [Fact]
    public async Task VerifiedSessionSupportsIndependentBoundedTerminalSplits()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.AddTerminalSplitCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.TerminalSplitPanes.Count == 1);
        var firstSplit = viewModel.TerminalSplitPanes[0];
        Assert.Equal(2, viewModel.TerminalPaneCount);
        Assert.NotEqual(77UL, firstSplit.Lease.TerminalChannelId);

        coreClient.EmitTerminalData(firstSplit.Lease.TerminalChannelId, "split-output\n");
        await WaitUntilAsync(() => firstSplit.Lines.Any(line => line.Text.Contains("split-output", StringComparison.Ordinal)));
        Assert.DoesNotContain(viewModel.TerminalLines, line => line.Text.Contains("split-output", StringComparison.Ordinal));

        var wrote = await viewModel.WriteTerminalSplitInputAsync(
            firstSplit.Id,
            System.Text.Encoding.UTF8.GetBytes("pwd\r"),
            CancellationToken.None);
        Assert.True(wrote);
        Assert.Equal(firstSplit.Lease.TerminalChannelId, coreClient.LastWrittenTerminalChannelId);

        viewModel.SetActiveTerminalPane(firstSplit.Id);
        viewModel.CommandText = "whoami";
        var primaryLinesBeforeSplitCommand = viewModel.TerminalLines.Select(line => line.Text).ToArray();
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);
        Assert.Equal(firstSplit.Lease.TerminalChannelId, coreClient.LastWrittenTerminalChannelId);
        Assert.Equal(primaryLinesBeforeSplitCommand, viewModel.TerminalLines.Select(line => line.Text));
        Assert.DoesNotContain(viewModel.TerminalLines, line => line.Text.Contains("whoami", StringComparison.Ordinal));

        viewModel.SetActiveTerminalPane(null);
        viewModel.CommandText = "hostname";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);
        Assert.Equal(77UL, coreClient.LastWrittenTerminalChannelId);
        Assert.DoesNotContain(viewModel.TerminalLines, line =>
            string.Equals(line.Text, "$ hostname", StringComparison.Ordinal));

        viewModel.AddTerminalSplitCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.TerminalSplitPanes.Count == 2);
        viewModel.AddTerminalSplitCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.TerminalSplitPanes.Count == 3);
        Assert.Equal(4, viewModel.TerminalPaneCount);
        Assert.False(viewModel.AddTerminalSplitCommand.CanExecute(null));

        Assert.True(await viewModel.CloseTerminalSplitPaneAsync(firstSplit.Id, CancellationToken.None));
        Assert.Equal(2, viewModel.TerminalSplitPanes.Count);
        Assert.Equal([2, 3], viewModel.TerminalSplitPanes.Select(pane => pane.PaneNumber).ToArray());
    }

    [Fact]
    public async Task BackgroundSplitOutputDoesNotInvalidateTheVisibleSplitLayout()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        viewModel.AddTerminalSplitCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.TerminalSplitPanes.Count == 1);
        var backgroundPane = viewModel.TerminalSplitPanes[0];

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        viewModel.NewAssetCommand.Execute(null);
        viewModel.AssetName = "Second";
        viewModel.Host = "second.example";
        viewModel.Username = "ops";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen && viewModel.Host == "second.example");
        var visibleVersion = viewModel.TerminalSplitOutputVersion;

        coreClient.EmitTerminalData(backgroundPane.Lease.TerminalChannelId, "background-ping\r\n");
        await WaitUntilAsync(() => backgroundPane.Lines.Any(line => line.Text.Contains("background-ping", StringComparison.Ordinal)));

        Assert.Equal(visibleVersion, viewModel.TerminalSplitOutputVersion);
    }

    [Fact]
    public void SelectingAssetUpdatesConnectionFields()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "old-secret";
        var asset = new AssetViewModel(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "Staging",
            "staging.example",
            2022,
            "deploy",
            ServerTransport.Ssh,
            false);
        viewModel.Assets.Add(asset);

        viewModel.SelectedAsset = asset;

        Assert.Equal("staging.example", viewModel.Host);
        Assert.Equal("2022", viewModel.PortText);
        Assert.Equal("deploy", viewModel.Username);
        Assert.Equal("Staging", viewModel.WorkspaceTitle);
        Assert.Equal("deploy@staging.example:2022", viewModel.WorkspaceSubtitle);
        Assert.Equal(string.Empty, viewModel.Password);
        Assert.False(viewModel.ConnectCommand.CanExecute(null));
    }

    [Fact]
    public async Task CurrentConnectedHostFollowsActiveTerminalInsteadOfAssetSelection()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        Assert.Equal("example.com", viewModel.CurrentConnectedHost);

        var other = new AssetViewModel(
            Guid.NewGuid(), Guid.NewGuid(), "Other", "other.example", 22, "ops",
            ServerTransport.Ssh, false);
        viewModel.Assets.Add(other);
        viewModel.SelectedAsset = other;

        Assert.Equal("other.example", viewModel.Host);
        Assert.Equal("example.com", viewModel.CurrentConnectedHost);
    }

    [Fact]
    public async Task StoredCredentialEnablesConnectionWithoutExposingItsValue()
    {
        var credentialId = Guid.NewGuid();
        var store = new MemoryServerAssetStore();
        store.Seed(new ServerAssetRecord(
            Guid.NewGuid(),
            credentialId,
            "已保存凭据的服务器",
            "saved.example",
            22,
            "ops",
            ServerTransport.Ssh,
            false));
        var credentialVault = new MemoryCredentialVault();
        await credentialVault.SaveAsync(
            credentialId,
            new CredentialMaterial("not-exposed", string.Empty, string.Empty),
            CancellationToken.None);
        var viewModel = CreateViewModel(credentialVault: credentialVault, assetStore: store, seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 1);
        viewModel.SelectedAsset = viewModel.Assets[0];

        Assert.Equal(string.Empty, viewModel.Password);
        Assert.True(viewModel.ConnectCommand.CanExecute(null));
        Assert.Equal("已安全保存凭据；可直接连接。", viewModel.SelectedCredentialAvailabilitySummary);
        Assert.DoesNotContain("not-exposed", viewModel.SelectedCredentialAvailabilitySummary, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CredentialHealthCheckReportsOnlyCountsAndAvailability()
    {
        var credentialId = Guid.NewGuid();
        var store = new MemoryServerAssetStore();
        store.Seed(new ServerAssetRecord(
            Guid.NewGuid(), credentialId, "受保护资产", "secure.example", 22, "ops", ServerTransport.Ssh, false));
        var credentialVault = new MemoryCredentialVault();
        await credentialVault.SaveAsync(
            credentialId,
            new CredentialMaterial("not-exported", string.Empty, string.Empty),
            CancellationToken.None);
        var viewModel = CreateViewModel(credentialVault: credentialVault, assetStore: store, seedDefaultAsset: false);
        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 1);

        viewModel.CheckCredentialHealthCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CredentialHealthStatus.StartsWith("本机凭据健康检查完成：", StringComparison.Ordinal));

        Assert.Contains("已保护 1", viewModel.CredentialHealthStatus, StringComparison.Ordinal);
        Assert.DoesNotContain("not-exported", viewModel.CredentialHealthStatus, StringComparison.Ordinal);
    }

    [Fact]
    public async Task LocalAssetsCanBeLoadedSavedAndDeletedWithoutStoringPasswords()
    {
        var store = new MemoryServerAssetStore();
        var asset = new ServerAssetRecord(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "Lab",
            "lab.local",
            2222,
            "tester",
            ServerTransport.Ssh,
            false);
        store.Seed(asset);
        var credentialVault = new MemoryCredentialVault();
        var viewModel = CreateViewModel(credentialVault: credentialVault, assetStore: store, seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 1);
        viewModel.SelectedAsset = viewModel.Assets[0];

        Assert.Equal("Lab", viewModel.AssetName);
        Assert.Equal("lab.local", viewModel.Host);
        Assert.Equal("tester", viewModel.Username);

        viewModel.AssetName = "Lab Updated";
        viewModel.Host = "lab-updated.local";
        viewModel.PortText = "2200";
        viewModel.Username = "ops";
        viewModel.Password = "secret";
        viewModel.SaveAssetCommand.Execute(null);
        await WaitUntilAsync(() => store.SavedAssets.Count == 1 && store.SavedAssets[0].Host == "lab-updated.local");

        Assert.Equal("Lab Updated", store.SavedAssets[0].Name);
        Assert.DoesNotContain("secret", store.SavedAssets[0].ToString(), StringComparison.Ordinal);

        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);
        Assert.Equal(asset.CredentialId, credentialVault.LastSavedCredentialId);

        viewModel.DeleteAssetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 0);

        Assert.Equal(asset.CredentialId, credentialVault.LastDeletedCredentialId);
        Assert.Equal("已从本地资产库删除 1 个资产。", viewModel.AssetEditorStatus);
    }

    [Fact]
    public async Task LoadingAssetsKeepsInitialWorkspaceEmptyUntilUserSelectsAnAsset()
    {
        var store = new MemoryServerAssetStore();
        store.Seed(
            new ServerAssetRecord(
                Guid.NewGuid(), Guid.NewGuid(), "生产主机", "prod.example", 22, "ops",
                ServerTransport.Ssh, false, "生产", ["Linux"]),
            new ServerAssetRecord(
                Guid.NewGuid(), Guid.NewGuid(), "测试主机", "test.example", 2222, "tester",
                ServerTransport.Ssh, false, "测试", []));
        var viewModel = CreateViewModel(assetStore: store, seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 2);

        Assert.Null(viewModel.SelectedAsset);
        Assert.Equal("未选择服务器", viewModel.WorkspaceTitle);
        Assert.Equal("请选择或新建服务器资产", viewModel.WorkspaceSubtitle);
        Assert.Empty(viewModel.Host);
        Assert.Empty(viewModel.Username);
        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);
        Assert.False(viewModel.ConnectCommand.CanExecute(null));
        Assert.DoesNotContain(viewModel.WorkspaceTabs, tab =>
            tab.Host == "prod.example" || tab.Host == "test.example");
    }

    [Fact]
    public async Task AssetsCanBeBatchDeletedWithOnePersistedUpdate()
    {
        var store = new MemoryServerAssetStore();
        var first = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "生产一", "one.example", 22, "ops",
            ServerTransport.Ssh, false, "生产", ["Linux"]);
        var second = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "生产二", "two.example", 22, "ops",
            ServerTransport.Ssh, false, "生产", ["Linux"]);
        var retained = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "开发", "dev.example", 22, "dev",
            ServerTransport.Ssh, false, "开发", []);
        store.Seed(first, second, retained);
        var viewModel = CreateViewModel(assetStore: store, seedDefaultAsset: false);
        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 3);

        var result = await viewModel.DeleteAssetsAsync([first.Id, second.Id], CancellationToken.None);

        Assert.Equal(2, result.DeletedCount);
        Assert.Equal(0, result.FailedCount);
        Assert.Single(viewModel.Assets);
        Assert.Equal(retained.Id, viewModel.Assets[0].Id);
        Assert.Single(store.SavedAssets);
        Assert.Equal(retained.Id, store.SavedAssets[0].Id);
        Assert.Equal("已从本地资产库删除 2 个资产。", viewModel.AssetEditorStatus);
    }

    [Fact]
    public async Task AssetsCanBeBatchMovedAndHaveTagsAddedAndRemoved()
    {
        var store = new MemoryServerAssetStore();
        var first = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "生产一", "one.example", 22, "ops",
            ServerTransport.Ssh, false, "生产", ["旧标签", "Linux"]);
        var second = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "生产二", "two.example", 22, "ops",
            ServerTransport.Ssh, false, "生产", ["旧标签"]);
        var retained = new ServerAssetRecord(
            Guid.NewGuid(), Guid.NewGuid(), "开发", "dev.example", 22, "dev",
            ServerTransport.Ssh, false, "开发", ["保持"]);
        store.Seed(first, second, retained);
        var viewModel = CreateViewModel(assetStore: store, seedDefaultAsset: false);
        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 3);

        var result = await viewModel.UpdateAssetsMetadataAsync(
            [first.Id, second.Id],
            "归档",
            "关键，linux",
            "旧标签",
            CancellationToken.None);

        Assert.Equal(2, result.UpdatedCount);
        Assert.Equal(0, result.QueueFailures);
        Assert.All(viewModel.Assets.Where(asset => asset.Id == first.Id || asset.Id == second.Id), asset =>
        {
            Assert.Equal("归档", asset.Group);
            Assert.Contains("关键", asset.Tags);
            Assert.Contains(asset.Tags, tag => string.Equals(tag, "Linux", StringComparison.OrdinalIgnoreCase));
            Assert.DoesNotContain(asset.Tags, tag => string.Equals(tag, "旧标签", StringComparison.OrdinalIgnoreCase));
        });
        Assert.Equal("开发", viewModel.Assets.Single(asset => asset.Id == retained.Id).Group);
        Assert.Equal(3, store.SavedAssets.Count);
        Assert.Equal("已批量更新 2 个资产的分组或标签。", viewModel.AssetEditorStatus);
    }

    [Fact]
    public void WorkspaceTabsPreserveConnectionDraftsWhenSwitching()
    {
        var viewModel = CreateViewModel();
        var firstTab = viewModel.SelectedWorkspaceTab;

        Assert.NotNull(firstTab);
        Assert.Equal("1 个会话标签", viewModel.WorkspaceTabSummary);

        viewModel.OpenWorkspaceTabCommand.Execute(null);

        Assert.Equal(2, viewModel.WorkspaceTabs.Count);
        Assert.Equal("2 个会话标签", viewModel.WorkspaceTabSummary);
        Assert.NotSame(firstTab, viewModel.SelectedWorkspaceTab);

        viewModel.AssetName = "Staging";
        viewModel.Host = "staging.example";
        viewModel.PortText = "2022";
        viewModel.Username = "deploy";

        var secondTab = viewModel.SelectedWorkspaceTab;
        Assert.NotNull(secondTab);
        Assert.Equal("Staging", secondTab.Title);
        Assert.Equal("deploy@staging.example:2022", secondTab.Endpoint);

        viewModel.SelectedWorkspaceTab = firstTab;

        Assert.Equal("Production", viewModel.AssetName);
        Assert.Equal("example.com", viewModel.Host);
        Assert.Equal("admin", viewModel.Username);

        viewModel.SelectedWorkspaceTab = secondTab;

        Assert.Equal("Staging", viewModel.AssetName);
        Assert.Equal("staging.example", viewModel.Host);
        Assert.Equal("deploy", viewModel.Username);
        Assert.Equal(string.Empty, viewModel.Password);
    }

    [Fact]
    public void WorkspaceTabsCanBeSelectedByMenuIndex()
    {
        var viewModel = CreateViewModel();
        viewModel.OpenWorkspaceTabCommand.Execute(null);
        viewModel.AssetName = "Second";
        viewModel.Host = "second.example";
        viewModel.Username = "ops";

        Assert.True(viewModel.SelectWorkspaceTabAt(0));
        Assert.Equal("Production", viewModel.AssetName);

        Assert.True(viewModel.SelectWorkspaceTabAt(1));
        Assert.Equal("Second", viewModel.AssetName);
        Assert.Equal("ops@second.example:22", viewModel.WorkspaceSubtitle);

        Assert.False(viewModel.SelectWorkspaceTabAt(9));
        Assert.Equal("Second", viewModel.AssetName);
    }

    [Fact]
    public async Task WorkspaceTabsPreserveIndependentLiveSessionState()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        var firstTab = viewModel.SelectedWorkspaceTab;
        viewModel.OpenWorkspaceTabCommand.Execute(null);
        var secondTab = viewModel.SelectedWorkspaceTab;
        viewModel.SelectedWorkspaceTab = firstTab;
        viewModel.Password = "secret";

        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() =>
            viewModel.IsConnected &&
            viewModel.IsTerminalOpen &&
            !viewModel.IsConnecting);
        var firstTerminalChannelId = coreClient.LastOpenedTerminalChannelId;

        Assert.True(viewModel.OpenWorkspaceTabCommand.CanExecute(null));
        Assert.False(viewModel.CloseWorkspaceTabCommand.CanExecute(null));

        viewModel.SelectedWorkspaceTab = secondTab;

        Assert.Same(secondTab, viewModel.SelectedWorkspaceTab);
        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);

        viewModel.NewAssetCommand.Execute(null);
        viewModel.AssetName = "Second";
        viewModel.Host = "second.example";
        viewModel.Username = "ops";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        coreClient.EmitTerminalData(firstTerminalChannelId, "background-first-tab");
        await Task.Delay(20);

        Assert.DoesNotContain(viewModel.TerminalLines, line => line.Text == "background-first-tab");

        viewModel.SelectedWorkspaceTab = firstTab;

        Assert.True(viewModel.IsConnected);
        Assert.True(viewModel.IsTerminalOpen);
        Assert.Equal("example.com:22", viewModel.TerminalTitle);
        Assert.Contains(viewModel.TerminalLines, line => line.Text == "background-first-tab");
    }

    [Fact]
    public async Task ActiveWorkspaceTabCanBeDisconnectedAndClosedExplicitly()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.OpenWorkspaceTabCommand.Execute(null);
        var secondTab = viewModel.SelectedWorkspaceTab;
        viewModel.SelectedWorkspaceTab = viewModel.WorkspaceTabs[0];
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.False(viewModel.CloseWorkspaceTabCommand.CanExecute(null));
        Assert.True(viewModel.DisconnectAndCloseWorkspaceTabCommand.CanExecute(null));

        viewModel.DisconnectAndCloseWorkspaceTabCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.WorkspaceTabs.Count == 1);

        Assert.Equal(1, coreClient.CloseTerminalCallCount);
        Assert.Same(secondTab, viewModel.SelectedWorkspaceTab);
        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);
        Assert.Equal("Workspace tab closed", viewModel.Status);
    }

    [Fact]
    public async Task DisconnectAndCloseLastWorkspaceTabResetsToCleanDraft()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        viewModel.DisconnectAndCloseWorkspaceTabCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.WorkspaceTabs.Count == 1 && !viewModel.IsConnected);

        Assert.Equal("新建服务器草稿", viewModel.AssetName);
        Assert.Equal(string.Empty, viewModel.Host);
        Assert.Equal("22", viewModel.PortText);
        Assert.Equal("Workspace tab reset", viewModel.Status);
        Assert.Equal("1 个会话标签", viewModel.WorkspaceTabSummary);
    }

    [Fact]
    public async Task WorkspaceTabsRestoreTerminalHistoryAndSftpDraftState()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        var firstTab = viewModel.SelectedWorkspaceTab;
        viewModel.SftpPathText = "/var/log";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = "uptime";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);
        coreClient.EmitTerminalData(77, "root@example:~# uptime\r\n");
        await WaitUntilAsync(() => viewModel.HasTerminalOutput);
        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected && !viewModel.IsTerminalOpen);

        Assert.True(viewModel.HasTerminalOutput);
        Assert.Equal("命令历史：1 条", viewModel.CommandHistorySummary);

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        var secondTab = viewModel.SelectedWorkspaceTab;
        viewModel.AssetName = "Scratch";
        viewModel.Host = "scratch.example";
        viewModel.Username = "dev";
        viewModel.SftpPathText = "/opt/app";
        viewModel.ClearTerminalCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.HasTerminalOutput);

        viewModel.SelectedWorkspaceTab = firstTab;

        Assert.True(viewModel.HasTerminalOutput);
        Assert.Equal("命令历史：1 条", viewModel.CommandHistorySummary);
        Assert.Equal("/", viewModel.SftpPathText);

        viewModel.SelectedWorkspaceTab = secondTab;

        Assert.False(viewModel.HasTerminalOutput);
        Assert.Equal("/opt/app", viewModel.SftpPathText);
        Assert.Equal("Scratch", viewModel.AssetName);
    }

    [Fact]
    public async Task TerminalViewportResizeUpdatesTheVerifiedPtyLease()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        await viewModel.ResizeTerminalAsync(new TerminalSize(100, 40), CancellationToken.None);

        Assert.Equal(1, coreClient.ResizeTerminalCallCount);
        Assert.Equal(100U, coreClient.LastTerminalColumns);
        Assert.Equal(40U, coreClient.LastTerminalRows);
        Assert.Contains("100 × 40", viewModel.TerminalSubtitle, StringComparison.Ordinal);
    }

    [Fact]
    public async Task WorkbenchStateTracksVerifiedSessionAndTerminal()
    {
        var viewModel = CreateViewModel();

        Assert.Equal("未连接", viewModel.ConnectionStateLabel);
        Assert.Equal("等待连接", viewModel.SecurityBadgeText);
        Assert.Equal("尚未连接", viewModel.TerminalStateLabel);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.Equal("SSH 已验证", viewModel.ConnectionStateLabel);
        Assert.Equal("主机密钥已验证", viewModel.SecurityBadgeText);
        Assert.Equal("ssh-ed25519  SHA256:abc", viewModel.SecurityStatus);

        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.Equal("example.com:22", viewModel.TerminalTitle);
        Assert.Equal("PTY 120x32", viewModel.TerminalStateLabel);
        Assert.Equal("1 条终端事件", viewModel.ActivitySummary);
    }

    [Fact]
    public async Task TerminalCommandsSupportHistoryNavigationAndClear()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = "uptime";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);

        viewModel.CommandText = "uptime";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() =>
            viewModel.CommandText.Length == 0 &&
            !viewModel.SendCommand.IsRunning &&
            viewModel.CommandHistorySummary == "命令历史：1 条");

        Assert.Equal("命令历史：1 条", viewModel.CommandHistorySummary);

        viewModel.PreviousCommandHistoryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText == "uptime");
        viewModel.NextCommandHistoryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0);

        viewModel.ClearTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Status == "终端输出已清除");
        Assert.Equal("终端输出已清除", viewModel.Status);
        Assert.DoesNotContain(viewModel.TerminalLines, line => line.Text.Contains("uptime", StringComparison.Ordinal));
    }

    [Fact]
    public void TerminalCommandPreviewUsesTheExistingRemotePromptWithoutSyntheticShellMarker()
    {
        var line = new TerminalLineViewModel(
            "root@example:~# ",
            false,
            [new TerminalTextRun("root@example:~# ", TerminalStyle.Default)],
            true,
            16);

        Assert.True(line.TryPreviewInputAtCursor("ping 1.1.1.1"));
        Assert.Equal("root@example:~# ping 1.1.1.1", line.Text);
        Assert.Equal(28, line.CursorColumn);
        Assert.DoesNotContain("$ ping", line.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task LatestTerminalCommandCanBeSavedAsAnAllAssetsSnippet()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        viewModel.CommandText = "journalctl -u sshd";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);

        viewModel.SaveLatestCommandAsSnippetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SnippetStatus == "已从终端历史保存快捷指令");

        var saved = Assert.Single(viewModel.Snippets);
        Assert.Equal("journalctl -u sshd", saved.Command);
        Assert.Equal("历史", saved.Category);
        Assert.False(saved.EffectiveAssetScope.IsRestricted);
    }

    [Fact]
    public void CommandPasteSanitizesUnsafeTextAndPreservesSelectionIntent()
    {
        var viewModel = CreateViewModel();
        viewModel.CommandText = "ssh old-host";

        var edit = viewModel.ApplyCommandPaste("prod\u0000\nwhoami\t--all", 4, 8);

        Assert.Equal("ssh prod whoami --all", viewModel.CommandText);
        Assert.Equal(21, edit.CaretIndex);
        Assert.True(edit.RemovedControlCharacters);
        Assert.True(edit.ConvertedMultiline);
        Assert.Equal("Paste sanitized: controls removed, lines joined", viewModel.PasteSafetyStatus);
        Assert.Equal("Paste sanitized: controls removed, lines joined", viewModel.Status);
    }

    [Fact]
    public void CommandPasteClampsInvalidSelectionAndIgnoresNonCommandText()
    {
        var viewModel = CreateViewModel();
        viewModel.CommandText = "echo";

        var edit = viewModel.ApplyCommandPaste("\u0000\u0001", 900, 900);

        Assert.Equal("echo", viewModel.CommandText);
        Assert.Equal(4, edit.CaretIndex);
        Assert.True(edit.RemovedControlCharacters);
        Assert.False(edit.ConvertedMultiline);
        Assert.Equal("Paste ignored: no command text", viewModel.PasteSafetyStatus);
    }

    [Fact]
    public async Task TerminalInterruptSendsControlCAndClearsOnlyTheLocalComposer()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = "unfinished command";
        viewModel.ClearCommandInput();
        Assert.Equal(string.Empty, viewModel.CommandText);

        Assert.True(await viewModel.InterruptTerminalAsync(CancellationToken.None));
        Assert.Equal(new byte[] { 0x03 }, coreClient.LastTerminalWrite);
        Assert.Equal("已发送终端中断信号", viewModel.Status);
    }

    [Fact]
    public async Task TerminalOutputRetainsExtendedScrollbackAndVisibleTranscriptCanBeCopied()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.True(viewModel.IsAutoScrollEnabled);
        viewModel.IsAutoScrollEnabled = false;
        Assert.False(viewModel.IsAutoScrollEnabled);

        for (var index = 0; index < 505; index++)
        {
            coreClient.EmitTerminalData(77, $"line-{index:000}\r\n");
        }

        await WaitUntilAsync(() => viewModel.TerminalLines.Count == 506);
        Assert.Equal("已显示 506 行输出", viewModel.TerminalOutputSummary);
        Assert.Equal(506, viewModel.TerminalLines.Count);
        Assert.Equal("line-000", viewModel.TerminalLines[0].Text);
        Assert.Equal(string.Empty, viewModel.TerminalLines[^1].Text);

        var transcript = viewModel.PrepareTerminalTranscriptCopy();

        Assert.StartsWith("line-000", transcript, StringComparison.Ordinal);
        Assert.Contains("line-504", transcript, StringComparison.Ordinal);
        Assert.DoesNotContain("Connected to example.com", transcript, StringComparison.Ordinal);
        Assert.Equal("Copied 506 visible lines", viewModel.Status);
    }

    [Fact]
    public async Task TerminalOutputCoalescesToLatestScreenBeforeUiDispatcherRuns()
    {
        var coreClient = new FakeCheckedCoreClient();
        var pendingUiActions = new List<Action>();
        var viewModel = CreateViewModel(coreClient, dispatch: pendingUiActions.Add);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        coreClient.EmitTerminalData(77, "first\r\n");
        coreClient.EmitTerminalData(77, "second\r\n");

        Assert.Single(pendingUiActions);
        pendingUiActions[0]();
        Assert.Contains(viewModel.TerminalLines, line => line.Text == "first");
        Assert.Contains(viewModel.TerminalLines, line => line.Text == "second");
    }

    [Fact]
    public async Task TerminalOutputUsesABoundedUiFrameCadence()
    {
        var coreClient = new FakeCheckedCoreClient();
        var pendingUiActions = new System.Collections.Concurrent.ConcurrentQueue<Action>();
        var viewModel = CreateViewModel(
            coreClient,
            dispatch: pendingUiActions.Enqueue,
            terminalUiFrameInterval: TimeSpan.FromMilliseconds(25));
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        coreClient.EmitTerminalData(77, "first\r\n");
        coreClient.EmitTerminalData(77, "second\r\n");

        Assert.Empty(pendingUiActions);
        await WaitUntilAsync(() => pendingUiActions.Count == 1);
        Assert.True(pendingUiActions.TryDequeue(out var update));
        update();
        Assert.Contains(viewModel.TerminalLines, line => line.Text == "second");
    }

    [Fact]
    public void IdenticalTerminalRowsDoNotRaiseRedundantRichTextChanges()
    {
        var runs = new[] { new TerminalTextRun("ready", TerminalStyle.Default) };
        var line = new TerminalLineViewModel("ready", false, runs, true, 5);
        var changes = 0;
        line.PropertyChanged += (_, _) => changes++;

        line.Apply(new TerminalScreenRow("ready", [.. runs]), true, 5);

        Assert.Equal(0, changes);
    }

    [Fact]
    public async Task TerminalOutputDoesNotRebuildUnrelatedWorkspaceCollections()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        var process = new RemoteProcessViewModel(
            42,
            1,
            "root",
            1.5,
            0.5,
            "S",
            DateTimeOffset.UtcNow.AddMinutes(-1).ToUnixTimeSeconds(),
            "sleep 300");
        viewModel.RemoteProcesses.Add(process);
        viewModel.SelectedWorkspaceTab!.RemoteProcesses.Add(process);

        coreClient.EmitTerminalData(77, "terminal-only-update\r\n");

        Assert.Same(process, Assert.Single(viewModel.SelectedWorkspaceTab.RemoteProcesses));
    }

    [Fact]
    public async Task EndSessionClosesTerminalAndClearsVerifiedState()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = "top";
        Assert.True(viewModel.EndSessionCommand.CanExecute(null));

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected && !viewModel.IsTerminalOpen);

        Assert.Equal(1, coreClient.CloseTerminalCallCount);
        Assert.Equal("未连接", viewModel.ConnectionStateLabel);
        Assert.Equal("等待连接", viewModel.SecurityBadgeText);
        Assert.Equal("No verified session", viewModel.SecurityStatus);
        Assert.Equal("打开终端后可输入命令", viewModel.TerminalInputHint);
        Assert.Equal(string.Empty, viewModel.CommandText);
        Assert.Equal("Session ended", viewModel.SessionActionSummary);
        Assert.False(viewModel.EndSessionCommand.CanExecute(null));

        var lineCount = viewModel.TerminalLines.Count;
        coreClient.EmitTerminalData(77, "late-output");

        Assert.Equal(lineCount, viewModel.TerminalLines.Count);
    }

    [Fact]
    public async Task SftpOpenRequiresVerifiedSessionAndEndsWithSession()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.OpenSftpCommand.CanExecute(null));
        Assert.False(viewModel.PrepareSftpBrowseCommand.CanExecute(null));
        Assert.False(viewModel.RefreshSftpBrowseCommand.CanExecute(null));
        Assert.False(viewModel.GoParentSftpCommand.CanExecute(null));
        Assert.False(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        Assert.Equal(1, coreClient.OpenSftpCallCount);
        Assert.Equal("SFTP 会话 55", viewModel.SftpStateLabel);
        Assert.Equal("SFTP channel open", viewModel.SftpStatus);
        Assert.True(viewModel.PrepareSftpBrowseCommand.CanExecute(null));
        Assert.True(viewModel.RefreshSftpBrowseCommand.CanExecute(null));
        Assert.True(viewModel.GoParentSftpCommand.CanExecute(null));
        Assert.False(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));
        Assert.False(viewModel.OpenSftpCommand.CanExecute(null));

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected && !viewModel.IsSftpOpen);

        Assert.Equal("SFTP 未打开", viewModel.SftpStateLabel);
        Assert.Equal("/", viewModel.SftpPathText);
        Assert.Equal("Open SFTP to prepare browsing", viewModel.SftpBrowserStatus);
        Assert.Equal("尚未打开 SFTP", viewModel.SftpListingSummary);
        Assert.True(viewModel.OpenSftpCommand.CanExecute(null) == false);
    }

    [Fact]
    public async Task SftpBrowserPathPreparationIsBoundedAndHonest()
    {
        var viewModel = CreateViewModel();

        viewModel.SftpPathText = "/var/log";
        Assert.False(viewModel.PrepareSftpBrowseCommand.CanExecute(null));

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.SftpPathText = "  //var//./log/  ";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "已列出 /var/log");

        Assert.Equal("/var/log", viewModel.SftpPathText);
        Assert.Equal("1 个项目", viewModel.SftpListingSummary);
        Assert.Equal("目录已刷新：文件夹优先，再按名称排序。", viewModel.SftpOperationStatus);
        Assert.Single(viewModel.SftpEntries);
        Assert.Equal("syslog", viewModel.SftpEntries[0].Name);
        Assert.Equal("/var/log/syslog", viewModel.SftpEntries[0].Path);
        Assert.Equal("文件", viewModel.SftpEntries[0].KindText);
        Assert.False(viewModel.SftpEntries[0].IsDirectory);
        Assert.Equal("42 B", viewModel.SftpEntries[0].SizeText);

        viewModel.SftpPathText = "/var/log/syslog";
        viewModel.PreviewSftpTextCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpPreviewStatus == "Previewed 12 B from /var/log/syslog");

        Assert.Equal("hello\nworld\n", viewModel.SftpPreviewText);
        Assert.Equal("Text preview is read-only", viewModel.SftpOperationStatus);

        viewModel.SftpPathText = "/var/../etc";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "SFTP path rejected");
        Assert.Equal("Use an absolute path without control characters, backslashes, or parent traversal", viewModel.SftpOperationStatus);

        viewModel.SftpPathText = "C:\\Users";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "SFTP path rejected");

        viewModel.SftpPathText = string.Concat("/", new string('a', 512));
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "SFTP path rejected");
    }

    [Fact]
    public async Task SftpDirectorySelectionNavigatesAndPreviewsSafely()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.SftpPathText = "/var";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "已列出 /var");

        Assert.Single(viewModel.SftpEntries);
        Assert.Equal("log", viewModel.SftpEntries[0].Name);
        Assert.Equal("/var/log", viewModel.SftpEntries[0].Path);
        Assert.Equal("文件夹", viewModel.SftpEntries[0].KindText);
        Assert.True(viewModel.SftpEntries[0].IsDirectory);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        Assert.True(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));
        viewModel.OpenSelectedSftpEntryCommand.Execute(null);
        await WaitUntilAsync(() =>
            viewModel.SftpBrowserStatus == "已列出 /var/log" &&
            !viewModel.OpenSelectedSftpEntryCommand.IsRunning);

        Assert.Equal("/var/log", viewModel.SftpPathText);
        Assert.Single(viewModel.SftpEntries);
        Assert.Equal("syslog", viewModel.SftpEntries[0].Name);
        Assert.False(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        viewModel.OpenSelectedSftpEntryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpPreviewStatus == "Previewed 12 B from /var/log/syslog");

        Assert.Equal("/var/log/syslog", viewModel.SftpPathText);
        Assert.Equal("hello\nworld\n", viewModel.SftpPreviewText);
        Assert.True(viewModel.CanEditSftpPreview);
        Assert.False(viewModel.CanSaveSftpPreview);

        viewModel.SftpPreviewText = "updated\n";
        Assert.True(viewModel.IsSftpPreviewDirty);
        Assert.True(viewModel.CanSaveSftpPreview);
        Assert.False(viewModel.GoParentSftpCommand.CanExecute(null));
        Assert.False(viewModel.CanMutateSelectedSftpEntry);
        Assert.False(viewModel.CanChangeSelectedSftpPermissions);

        viewModel.RevertSftpPreviewChanges();
        Assert.False(viewModel.IsSftpPreviewDirty);
        Assert.True(viewModel.CanMutateSelectedSftpEntry);
        Assert.True(viewModel.CanChangeSelectedSftpPermissions);

        viewModel.SftpPreviewText = "updated\n";
        await viewModel.SaveSftpPreviewAsync(CancellationToken.None);
        Assert.Equal("/var/log/syslog", coreClient.LastWrittenSftpTextPath);
        Assert.Equal("updated\n", coreClient.LastWrittenSftpTextContent);
        Assert.False(viewModel.IsSftpPreviewDirty);
        Assert.False(viewModel.CanEditSftpPreview);
        Assert.True(viewModel.GoParentSftpCommand.CanExecute(null));

        viewModel.GoParentSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "已列出 /var/log");

        Assert.Equal("/var/log", viewModel.SftpPathText);
        Assert.Single(viewModel.SftpEntries);
    }

    [Fact]
    public async Task SftpUploadUsesCurrentDirectoryAndRefreshesListing()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        var localPath = Path.Combine(Path.GetTempPath(), $"orbitterm-upload-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(localPath, "checked upload");

        try
        {
            viewModel.Password = "secret";
            viewModel.ConnectCommand.Execute(null);
            await WaitUntilAsync(() => viewModel.IsConnected);
            await WaitUntilAsync(() => viewModel.IsSftpOpen);
            viewModel.SftpPathText = "/var/log";

            await viewModel.UploadSftpFileAsync(localPath, "report.txt", CancellationToken.None);

            Assert.Equal(1, coreClient.UploadSftpFileCallCount);
            Assert.Equal(55UL, coreClient.LastSftpUploadSessionId);
            Assert.Equal(localPath, coreClient.LastSftpUploadLocalPath);
            Assert.Equal("/var/log/report.txt", coreClient.LastSftpUploadRemotePath);
            Assert.Equal("已列出 /var/log", viewModel.SftpBrowserStatus);
            Assert.Equal("Uploaded 42 B to /var/log/report.txt", viewModel.SftpOperationStatus);
            Assert.True(viewModel.IsSftpFeedbackSuccess);
            Assert.Equal("上传完成", viewModel.SftpFeedbackTitle);
            Assert.True(viewModel.HasRecentSftpOperations);
            Assert.Equal("上传完成", viewModel.RecentSftpOperations[0].Title);
            Assert.Equal("成功", viewModel.RecentSftpOperations[0].KindText);
        }
        finally
        {
            File.Delete(localPath);
        }
    }

    [Fact]
    public async Task SftpMutationsUseSelectedSnapshotAndRejectSelectionDrift()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/var/log";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "已列出 /var/log");

        await viewModel.CreateSftpDirectoryAsync("archive", CancellationToken.None);
        Assert.Equal("/var/log/archive", coreClient.LastCreatedSftpDirectoryPath);
        Assert.Equal("Created folder /var/log/archive", viewModel.SftpOperationStatus);

        await viewModel.CreateSftpFileAsync("empty.txt", CancellationToken.None);
        Assert.Equal("/var/log/empty.txt", coreClient.LastCreatedSftpFilePath);
        Assert.Equal("Created file /var/log/empty.txt", viewModel.SftpOperationStatus);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        await viewModel.RenameSelectedSftpEntryAsync("syslog.old", CancellationToken.None);
        Assert.Equal("/var/log/syslog", coreClient.LastRenamedSftpSourcePath);
        Assert.Equal("/var/log/syslog.old", coreClient.LastRenamedSftpDestinationPath);
        Assert.Equal(42UL, coreClient.LastSftpMutationSnapshot?.Size);
        Assert.Equal(33188U, coreClient.LastSftpMutationSnapshot?.PermissionsOctal);
        Assert.Equal("重命名成功：/var/log/syslog.old", viewModel.SftpOperationStatus);
        Assert.True(viewModel.IsSftpFeedbackSuccess);
        Assert.Equal("重命名完成", viewModel.SftpFeedbackTitle);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        var chmodEntry = viewModel.SelectedSftpEntry;
        Assert.NotNull(chmodEntry);
        await viewModel.ChangeSelectedSftpPermissionsConfirmedAsync(
            chmodEntry!,
            "640",
            CancellationToken.None);
        Assert.Equal(0x1A0U, coreClient.LastSftpPermissionsMode);
        Assert.Equal("权限已修改为：640", viewModel.SftpOperationStatus);
        Assert.True(viewModel.IsSftpFeedbackSuccess);
        Assert.Equal("权限修改完成", viewModel.SftpFeedbackTitle);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        var confirmed = viewModel.SelectedSftpEntry;
        Assert.NotNull(confirmed);
        viewModel.SelectedSftpEntry = null;
        await viewModel.RemoveSelectedSftpEntryConfirmedAsync(confirmed!, CancellationToken.None);
        Assert.Equal(0, coreClient.RemoveSftpEntryCallCount);
        Assert.Equal("SFTP 所选项目已变化，请重新确认目标", viewModel.SftpOperationStatus);
        Assert.True(viewModel.IsSftpFeedbackError);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        confirmed = viewModel.SelectedSftpEntry;
        Assert.NotNull(confirmed);
        await viewModel.RemoveSelectedSftpEntryConfirmedAsync(confirmed!, CancellationToken.None);
        Assert.Equal(1, coreClient.RemoveSftpEntryCallCount);
        Assert.Equal("/var/log/syslog", coreClient.LastRemovedSftpPath);
        Assert.Equal("删除成功：/var/log/syslog", viewModel.SftpOperationStatus);
        Assert.True(viewModel.IsSftpFeedbackSuccess);
        Assert.Equal("删除完成", viewModel.SftpFeedbackTitle);
        Assert.True(viewModel.HasRecentSftpOperations);
        Assert.Equal("删除完成", viewModel.RecentSftpOperations[0].Title);
        Assert.Contains(viewModel.RecentSftpOperations, operation => operation.KindText == "失败");
    }

    [Fact]
    public async Task SftpMultiSelectionSupportsBatchDownloadRetryAndBatchDelete()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);
        await WaitUntilAsync(() => viewModel.PrepareSftpBrowseCommand.CanExecute(null));
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);

        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries);

        Assert.Equal(3, viewModel.SelectedSftpEntryCount);
        Assert.True(viewModel.CanDownloadSelectedSftpEntries);
        Assert.True(viewModel.CanDeleteSelectedSftpEntries);
        Assert.False(viewModel.CanPreviewSelectedSftpText);
        Assert.False(viewModel.CanMutateSelectedSftpEntry);
        Assert.Contains("已选择 3 项", viewModel.SftpSelectionSummary, StringComparison.Ordinal);

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-batch-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        var collisionPath = Path.Combine(downloadDirectory, "one.txt");
        try
        {
            File.WriteAllText(collisionPath, "existing");
            await viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);

            Assert.Equal(2, coreClient.DownloadSftpFileCallCount);
            Assert.True(Directory.Exists(Path.Combine(downloadDirectory, "folder")));
            Assert.Contains("失败 1", viewModel.SftpTransferStatus, StringComparison.Ordinal);
            Assert.True(viewModel.CanRetryLastSftpTransfer);

            File.Delete(collisionPath);
            viewModel.RetryLastSftpTransferCommand.Execute(null);
            await WaitUntilAsync(() => coreClient.DownloadSftpFileCallCount == 3);
            await WaitUntilAsync(() => viewModel.SftpTransferStatus.Contains("成功 1/1", StringComparison.Ordinal));
            Assert.Contains("成功 1/1", viewModel.SftpTransferStatus, StringComparison.Ordinal);
            Assert.False(viewModel.CanRetryLastSftpTransfer);
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }

        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries);
        var confirmed = viewModel.SelectedSftpEntries.ToList();
        await viewModel.RemoveSelectedSftpEntriesConfirmedAsync(confirmed, CancellationToken.None);

        Assert.Equal(3, coreClient.RemoveSftpEntryCallCount);
        Assert.Equal(new[] { "/batch/folder", "/batch/one.txt", "/batch/two.log" }, coreClient.RemovedSftpPaths.Order(StringComparer.Ordinal));
        Assert.Contains("批量删除完成：成功 3/3", viewModel.SftpTransferStatus, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SftpBatchDownloadCancellationStopsBeforeTheNextFile()
    {
        var coreClient = new FakeCheckedCoreClient { SftpDownloadDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);
        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries.Where(static entry => !entry.IsDirectory));

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-cancel-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        try
        {
            var operation = viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);
            await WaitUntilAsync(() => coreClient.DownloadSftpFileCallCount == 1 && viewModel.IsSftpBatchRunning);
            viewModel.CancelSftpBatchCommand.Execute(null);
            await operation;

            Assert.Equal(1, coreClient.DownloadSftpFileCallCount);
            Assert.Equal(1, coreClient.CancelSftpTransferCallCount);
            Assert.Contains("已取消", viewModel.SftpTransferStatus, StringComparison.Ordinal);
            Assert.True(viewModel.CanRetryLastSftpTransfer);
            Assert.Contains(
                viewModel.RecentSftpOperations,
                operation => operation.Title == "批量下载已取消" && operation.KindText == "注意");
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task PausedSftpTransferCancelsOnTheFirstRequest()
    {
        var coreClient = new FakeCheckedCoreClient { SftpDownloadDelayMilliseconds = 750 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);
        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries.Where(static entry => !entry.IsDirectory));

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-paused-cancel-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        try
        {
            var operation = viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);
            await WaitUntilAsync(() => viewModel.ActiveSftpTransferTasks.Count == 1);
            var task = Assert.Single(viewModel.ActiveSftpTransferTasks);

            viewModel.PauseSftpTransfer(task);
            Assert.Equal(SftpTransferTaskState.Paused, task.State);

            viewModel.CancelSftpTransfer(task);

            Assert.True(task.IsCancellationRequested);
            Assert.False(task.CanCancel);
            Assert.False(task.CanResume);
            Assert.Equal("正在取消：" + task.FileName, task.StatusText);
            Assert.Equal(1, coreClient.CancelSftpTransferCallCount);

            await operation;
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task SftpQueuesRunConcurrentlyAndRemainIsolatedPerWorkspace()
    {
        using var uploadReleaseGate = new ManualResetEventSlim(false);
        var coreClient = new FakeCheckedCoreClient { SftpUploadReleaseGate = uploadReleaseGate };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        var firstTab = viewModel.SelectedWorkspaceTab!;

        var firstPath = Path.Combine(Path.GetTempPath(), $"orbitterm-parallel-a-{Guid.NewGuid():N}.bin");
        var secondPath = Path.Combine(Path.GetTempPath(), $"orbitterm-parallel-b-{Guid.NewGuid():N}.bin");
        var queuedSecondPath = Path.Combine(Path.GetTempPath(), $"orbitterm-parallel-c-{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(firstPath, new byte[32]);
        await File.WriteAllBytesAsync(secondPath, new byte[32]);
        await File.WriteAllBytesAsync(queuedSecondPath, new byte[32]);
        try
        {
            var firstOperation = viewModel.UploadSftpFilesAsync(
                [new SftpUploadSource(firstPath, Path.GetFileName(firstPath), 32)],
                SftpUploadConflictPolicy.KeepBoth,
                CancellationToken.None);
            await WaitUntilAsync(() => coreClient.SftpUploadInFlight == 1);

            viewModel.OpenWorkspaceTabCommand.Execute(null);
            viewModel.NewAssetCommand.Execute(null);
            viewModel.AssetName = "Second";
            viewModel.Host = "second.example";
            viewModel.Username = "ops";
            viewModel.Password = "secret";
            viewModel.ConnectCommand.Execute(null);
            await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
            var secondTab = viewModel.SelectedWorkspaceTab!;

            var secondOperation = viewModel.UploadSftpFilesAsync(
                [
                    new SftpUploadSource(secondPath, Path.GetFileName(secondPath), 32),
                    new SftpUploadSource(queuedSecondPath, Path.GetFileName(queuedSecondPath), 32),
                ],
                SftpUploadConflictPolicy.KeepBoth,
                CancellationToken.None);
            await WaitUntilAsync(() => coreClient.MaxConcurrentSftpUploads == 2);

            Assert.True(viewModel.IsSftpBatchRunning);
            Assert.Equal(2, viewModel.SftpTransferTasks.Count);
            Assert.Contains(viewModel.SftpTransferTasks, task => task.FileName == Path.GetFileName(secondPath));
            viewModel.CancelSftpBatchCommand.Execute(null);
            viewModel.SelectedWorkspaceTab = firstTab;
            Assert.True(viewModel.IsSftpBatchRunning);
            Assert.Equal(Path.GetFileName(firstPath), Assert.Single(viewModel.SftpTransferTasks).FileName);

            uploadReleaseGate.Set();
            await Task.WhenAll(firstOperation, secondOperation);
            Assert.Equal(2, coreClient.MaxConcurrentSftpUploads);
            Assert.Single(viewModel.CompletedSftpTransferTasks);
            Assert.False(viewModel.IsSftpBatchRunning);

            viewModel.SelectedWorkspaceTab = secondTab;
            Assert.False(viewModel.IsSftpBatchRunning);
            Assert.Contains("取消", viewModel.SftpTransferStatus, StringComparison.Ordinal);
        }
        finally
        {
            uploadReleaseGate.Set();
            File.Delete(firstPath);
            File.Delete(secondPath);
            File.Delete(queuedSecondPath);
        }
    }

    [Fact]
    public async Task SftpBatchKeepsItsOriginalLeaseWhenVisibleWorkspaceChanges()
    {
        var coreClient = new FakeCheckedCoreClient { SftpDownloadDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);
        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries.Where(static entry => !entry.IsDirectory));

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-owner-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        try
        {
            var operation = viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);
            await WaitUntilAsync(() => coreClient.DownloadSftpFileCallCount == 1);
            var field = typeof(MainWindowViewModel).GetField(
                "sftpLease",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
            Assert.NotNull(field);
            field!.SetValue(viewModel, new SftpSessionLease(
                Guid.NewGuid(),
                Guid.NewGuid(),
                999,
                999,
                "other.example",
                22,
                "ssh-ed25519",
                "SHA256:other"));

            await operation;

            Assert.Equal(2, coreClient.DownloadSftpFileCallCount);
            Assert.All(coreClient.SftpDownloadSessionIds, sessionId => Assert.Equal(55UL, sessionId));
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task ActiveSftpTransferBlocksUnsafeExitAndStopsCleanlyWhenConfirmed()
    {
        var coreClient = new FakeCheckedCoreClient { SftpDownloadDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);
        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries.Where(static entry => !entry.IsDirectory));

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-exit-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        try
        {
            var operation = viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);
            await WaitUntilAsync(() => viewModel.HasActiveSftpTransfers);
            await WaitUntilAsync(() => coreClient.DownloadSftpFileCallCount > 0);

            Assert.True(viewModel.ActiveSftpTransferCount > 0);
            Assert.Contains("退出", viewModel.SftpExitProtectionMessage, StringComparison.Ordinal);

            await viewModel.StopSftpTransfersForApplicationExitAsync(CancellationToken.None);
            await operation;

            Assert.False(viewModel.HasActiveSftpTransfers);
            Assert.Contains(viewModel.SftpTransferTasks, task => task.State == SftpTransferTaskState.Cancelled);
            Assert.True(coreClient.CancelSftpTransferCallCount > 0);
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task DisconnectPreservesInterruptedQueueUntilOriginalAssetReconnects()
    {
        var coreClient = new FakeCheckedCoreClient { SftpDownloadDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/batch";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Count == 3);
        viewModel.SetSelectedSftpEntries(viewModel.SftpEntries.Where(static entry => !entry.IsDirectory));

        var downloadDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-reconnect-{Guid.NewGuid():N}");
        Directory.CreateDirectory(downloadDirectory);
        try
        {
            var transfer = viewModel.DownloadSelectedSftpEntriesAsync(downloadDirectory, CancellationToken.None);
            await WaitUntilAsync(() => viewModel.HasActiveSftpTransfers);
            await viewModel.DisconnectSelectedWorkspaceAsync(CancellationToken.None);
            await transfer;

            Assert.False(viewModel.IsConnected);
            Assert.NotEmpty(viewModel.SftpTransferTasks);
            Assert.Contains("重新连接原资产", viewModel.SftpTransferStatus, StringComparison.Ordinal);
            Assert.False(viewModel.CanRetryLastSftpTransfer);

            viewModel.ConnectCommand.Execute(null);
            await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);

            Assert.True(viewModel.CanRetryLastSftpTransfer);
            Assert.Contains("连接已恢复", viewModel.SftpTransferStatus, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(downloadDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task SftpBatchUploadAppliesSkipKeepBothAndSafeReplacePolicies()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/replace";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpEntries.Any(entry => entry.Name == "same.txt"));

        var localDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-upload-{Guid.NewGuid():N}");
        Directory.CreateDirectory(localDirectory);
        var localPath = Path.Combine(localDirectory, "same.txt");
        File.WriteAllText(localPath, "new value");
        var source = new SftpUploadSource(localPath, "same.txt", 9);
        try
        {
            Assert.Equal(new[] { "same.txt" }, viewModel.GetSftpUploadConflictNames([source]));

            await viewModel.UploadSftpFilesAsync([source], SftpUploadConflictPolicy.Skip, CancellationToken.None);
            Assert.Equal(0, coreClient.UploadSftpFileCallCount);
            Assert.Contains(viewModel.SftpTransferTasks, task => task.State == SftpTransferTaskState.Skipped);
            Assert.Contains(viewModel.CompletedSftpTransferTasks, task => task.State == SftpTransferTaskState.Skipped);
            Assert.DoesNotContain(viewModel.ActiveSftpTransferTasks, task => task.State == SftpTransferTaskState.Skipped);

            await viewModel.UploadSftpFilesAsync([source], SftpUploadConflictPolicy.KeepBoth, CancellationToken.None);
            Assert.Equal(1, coreClient.UploadSftpFileCallCount);
            Assert.Equal("/replace/same (1).txt", coreClient.LastSftpUploadRemotePath);

            await viewModel.UploadSftpFilesAsync([source], SftpUploadConflictPolicy.Replace, CancellationToken.None);
            Assert.Equal(2, coreClient.UploadSftpFileCallCount);
            Assert.StartsWith("/replace/.same.txt.orbitterm-", coreClient.LastSftpUploadRemotePath, StringComparison.Ordinal);
            Assert.EndsWith(".upload", coreClient.LastSftpUploadRemotePath, StringComparison.Ordinal);
            Assert.Equal("/replace/same.txt", coreClient.LastRemovedSftpPath);
            Assert.Equal(coreClient.LastSftpUploadRemotePath, coreClient.LastRenamedSftpSourcePath);
            Assert.Equal("/replace/same.txt", coreClient.LastRenamedSftpDestinationPath);
            Assert.Contains(viewModel.SftpTransferTasks, task =>
                task.Direction == SftpTransferDirection.Upload &&
                task.State == SftpTransferTaskState.Completed &&
                task.StatusText == "安全替换完成");
        }
        finally
        {
            Directory.Delete(localDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task SftpBatchUploadFailureRemainsInQueueAndRetriesOnlyFailedItems()
    {
        var coreClient = new FakeCheckedCoreClient { SftpUploadFailuresRemaining = 1 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsSftpOpen);

        var localDirectory = Path.Combine(Path.GetTempPath(), $"orbitterm-sftp-upload-retry-{Guid.NewGuid():N}");
        Directory.CreateDirectory(localDirectory);
        var localPath = Path.Combine(localDirectory, "retry.txt");
        File.WriteAllText(localPath, "retry");
        try
        {
            await viewModel.UploadSftpFilesAsync(
                [new SftpUploadSource(localPath, "retry.txt", 5)],
                SftpUploadConflictPolicy.Skip,
                CancellationToken.None);

            Assert.Equal(1, coreClient.UploadSftpFileCallCount);
            Assert.True(viewModel.CanRetryLastSftpTransfer);
            Assert.Equal(SftpTransferTaskState.Failed, Assert.Single(viewModel.SftpTransferTasks).State);
            Assert.Empty(viewModel.CompletedSftpTransferTasks);
            Assert.Equal(SftpTransferTaskState.Failed, Assert.Single(viewModel.ActiveSftpTransferTasks).State);

            viewModel.RetryLastSftpTransferCommand.Execute(null);
            await WaitUntilAsync(() => coreClient.UploadSftpFileCallCount == 2 && !viewModel.IsSftpBatchRunning);

            Assert.False(viewModel.CanRetryLastSftpTransfer);
            Assert.Equal(SftpTransferTaskState.Completed, Assert.Single(viewModel.SftpTransferTasks).State);
            Assert.Empty(viewModel.ActiveSftpTransferTasks);
            Assert.Equal(SftpTransferTaskState.Completed, Assert.Single(viewModel.CompletedSftpTransferTasks).State);
            Assert.Contains("成功 1/1", viewModel.SftpTransferStatus, StringComparison.Ordinal);

            viewModel.ClearCompletedSftpTransfersCommand.Execute(null);
            await WaitUntilAsync(() => viewModel.SftpTransferTasks.Count == 0);
            Assert.Equal("传输记录已清理", viewModel.RecentSftpOperations[0].Title);
            Assert.Contains("1 项", viewModel.RecentSftpOperations[0].Message, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(localDirectory, recursive: true);
        }
    }

    [Fact]
    public void SftpTransferTaskCalculatesRealSpeedAndEstimatedRemainingTime()
    {
        var task = new SftpTransferTaskViewModel(
            Guid.NewGuid(),
            "archive.tar",
            "/uploads/archive.tar",
            SftpTransferDirection.Upload,
            "等待处理");
        var startedAt = new DateTimeOffset(2026, 8, 9, 12, 0, 0, TimeSpan.Zero);

        task.MarkRunning("正在上传");
        task.UpdateProgress(0, 8UL * 1024 * 1024, startedAt);
        task.UpdateProgress(4UL * 1024 * 1024, 8UL * 1024 * 1024, startedAt.AddSeconds(2));

        Assert.Equal(0.5, task.Progress, precision: 3);
        Assert.Equal(2d * 1024 * 1024, task.BytesPerSecond, precision: 0);
        Assert.Contains("4 MB / 8 MB", task.TransferDetailText, StringComparison.Ordinal);
        Assert.Contains("2 MB/s", task.TransferDetailText, StringComparison.Ordinal);
        Assert.Contains("剩余 2 秒", task.TransferDetailText, StringComparison.Ordinal);
    }

    [Fact]
    public void SftpTransferTaskPauseAndResumePreserveProgressAndExposeCorrectActions()
    {
        var task = new SftpTransferTaskViewModel(
            Guid.NewGuid(),
            "backup.tar",
            "/backup.tar",
            SftpTransferDirection.Download,
            "等待处理");

        task.MarkRunning("正在下载");
        task.UpdateProgress(2UL * 1024 * 1024, 8UL * 1024 * 1024);
        task.Pause();

        Assert.Equal(SftpTransferTaskState.Paused, task.State);
        Assert.True(task.CanResume);
        Assert.True(task.CanCancel);
        Assert.False(task.CanPause);
        Assert.Equal(0.25, task.Progress, precision: 3);

        task.Resume();

        Assert.Equal(SftpTransferTaskState.Running, task.State);
        Assert.True(task.CanPause);
        Assert.False(task.CanResume);
        Assert.Equal(0.25, task.Progress, precision: 3);
    }

    [Fact]
    public void LargeLongRunningTransferProgressRemainsFiniteAndBounded()
    {
        const ulong totalBytes = 8UL * 1024 * 1024 * 1024;
        const int sampleCount = 12_000;
        var task = new SftpTransferTaskViewModel(
            Guid.NewGuid(),
            "backup-8gb.img",
            "/backups/backup-8gb.img",
            SftpTransferDirection.Upload,
            "等待处理");
        var startedAt = new DateTimeOffset(2026, 8, 9, 12, 0, 0, TimeSpan.Zero);

        task.MarkRunning("正在上传");
        for (var sample = 0; sample <= sampleCount; sample++)
        {
            var transferred = (ulong)((decimal)totalBytes * sample / sampleCount);
            task.UpdateProgress(transferred, totalBytes, startedAt.AddMilliseconds(sample * 250L));
        }

        Assert.Equal(1, task.Progress, precision: 6);
        Assert.True(double.IsFinite(task.BytesPerSecond));
        Assert.True(task.BytesPerSecond > 0);
        Assert.DoesNotContain("NaN", task.TransferDetailText, StringComparison.Ordinal);
        Assert.DoesNotContain("Infinity", task.TransferDetailText, StringComparison.Ordinal);
        Assert.Contains("8 GB / 8 GB", task.TransferDetailText, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BatchCommandRequiresTargetAndKeepsGlobalWindowResult()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        viewModel.BatchCommandText = "uname -a";
        Assert.False(viewModel.RunBatchCommand.CanExecute(null));

        viewModel.Host = "batch.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.True(viewModel.RunBatchCommand.CanExecute(null));
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchStatus.StartsWith("批量命令已完成", StringComparison.Ordinal));

        Assert.Equal("uname -a", coreClient.LastExecCommand);
        Assert.Contains("batch output", viewModel.BatchOutputText);

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        Assert.Contains("批量命令已完成", viewModel.BatchStatus, StringComparison.Ordinal);
        Assert.Contains("batch output", viewModel.BatchOutputText);

        viewModel.BatchCommandText = "bad\ncommand";
        Assert.False(viewModel.RunBatchCommand.CanExecute(null));
    }

    [Fact]
    public void BatchReceiptsSupportSearchFailureFilterAndTextOrCsvExport()
    {
        var viewModel = CreateViewModel();
        viewModel.BatchCommandReceipts.Add(new BatchCommandReceiptViewModel(
            Guid.NewGuid(), "alpha", "root@alpha.example:22", true, "Linux alpha"));
        viewModel.BatchCommandReceipts.Add(new BatchCommandReceiptViewModel(
            Guid.NewGuid(), "beta", "root@beta.example:22", false, "连接失败"));

        viewModel.BatchResultQuery = "beta";
        Assert.Single(viewModel.FilteredBatchCommandReceipts);
        Assert.Contains("beta", viewModel.FilteredBatchOutputText, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("alpha", viewModel.FilteredBatchOutputText, StringComparison.OrdinalIgnoreCase);

        viewModel.BatchResultQuery = string.Empty;
        viewModel.ShowOnlyFailedBatchResults = true;
        var failed = Assert.Single(viewModel.FilteredBatchCommandReceipts);
        Assert.False(failed.IsSuccess);
        Assert.Contains("连接失败", viewModel.CreateBatchResultExport(csv: false), StringComparison.Ordinal);

        var csv = viewModel.CreateBatchResultExport(csv: true);
        Assert.StartsWith("asset,endpoint,status,output", csv, StringComparison.Ordinal);
        Assert.Contains("\"beta\"", csv, StringComparison.Ordinal);
        Assert.DoesNotContain("\"alpha\"", csv, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BatchCommandPublishesDeterminateProgressAndSelectedTargetReview()
    {
        var coreClient = new FakeCheckedCoreClient { ExecDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Host = "progress.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        viewModel.PrepareBatchCommandWorkspace();
        foreach (var target in viewModel.BatchAssetTargets)
        {
            target.IsSelected = true;
        }
        viewModel.RefreshBatchTargetSelection();
        var selected = Assert.Single(viewModel.SelectedBatchAssetTargets);
        Assert.True(selected.IsSelected);
        Assert.Contains(selected, viewModel.BatchAssetTargets);

        viewModel.BatchCommandText = "uptime";
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.ExecCallCount == 1);

        Assert.Equal(1, viewModel.BatchTotalCount);
        Assert.Equal(0, viewModel.BatchCompletedCount);
        Assert.Contains("命令已发送", viewModel.BatchCurrentTarget, StringComparison.Ordinal);

        await WaitUntilAsync(() => !viewModel.RunBatchCommand.IsRunning);
        Assert.Equal(1, viewModel.BatchCompletedCount);
        Assert.Equal(1, viewModel.BatchSucceededCount);
        Assert.Contains("已完成", viewModel.BatchProgressText, StringComparison.Ordinal);

        viewModel.UnselectBatchTarget(selected.AssetId);
        Assert.Empty(viewModel.SelectedBatchAssetTargets);
        Assert.False(viewModel.RunBatchCommand.CanExecute(null));
    }

    [Theory]
    [InlineData("ping 1.1.1.1", "持续或交互式命令")]
    [InlineData("top", "持续或交互式命令")]
    [InlineData("tail -f /var/log/syslog", "持续或交互式命令")]
    [InlineData("ping -c 20 1.1.1.1", "一次性命令")]
    [InlineData("top -b -n 1", "一次性命令")]
    public void BatchCommandExplainsContinuousOutputBoundary(string command, string expectedGuidance)
    {
        var viewModel = CreateViewModel();

        viewModel.BatchCommandText = command;

        Assert.Contains(expectedGuidance, viewModel.BatchCommandGuidance, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ContinuousBatchUsesIsolatedPtysStreamsPerAssetAndStopsIndependently()
    {
        var coreClient = new FakeCheckedCoreClient();
        var credentialVault = new MemoryCredentialVault();
        var store = new MemoryServerAssetStore();
        var firstAssetId = Guid.NewGuid();
        var secondAssetId = Guid.NewGuid();
        var firstCredentialId = Guid.NewGuid();
        var secondCredentialId = Guid.NewGuid();
        store.Seed(
            new ServerAssetRecord(firstAssetId, firstCredentialId, "Alpha", "alpha.example", 22, "root", ServerTransport.Ssh, false, "Production"),
            new ServerAssetRecord(secondAssetId, secondCredentialId, "Beta", "beta.example", 22, "root", ServerTransport.Ssh, false, "Production"));
        await credentialVault.SaveAsync(firstCredentialId, new CredentialMaterial("secret", string.Empty, string.Empty), CancellationToken.None);
        await credentialVault.SaveAsync(secondCredentialId, new CredentialMaterial("secret", string.Empty, string.Empty), CancellationToken.None);
        var viewModel = CreateViewModel(coreClient, credentialVault, store, seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchAssetTargets.Count == 2);
        foreach (var target in viewModel.BatchAssetTargets)
        {
            target.IsSelected = true;
        }
        viewModel.RefreshBatchTargetSelection();
        viewModel.IsBatchContinuousMode = true;
        viewModel.BatchContinuousTimeoutMinutes = 1;
        viewModel.BatchCommandText = "top";
        viewModel.RunBatchCommand.Execute(null);

        await WaitUntilAsync(() => viewModel.BatchContinuousSessions.Count == 2 &&
            viewModel.BatchContinuousSessions.All(session => session.IsRunning));
        Assert.True(viewModel.HasActiveBatchContinuousSessions);
        Assert.Equal(2, coreClient.OpenedTerminalChannelIds.Count);
        Assert.Equal(2, coreClient.OpenedTerminalChannelIds.Distinct().Count());
        Assert.Equal(2, coreClient.ConnectCallCount);
        Assert.Equal(2, coreClient.WriteTerminalCallCount);
        Assert.All(coreClient.TerminalWrites, write => Assert.Equal("top\n", System.Text.Encoding.UTF8.GetString(write.Data)));
        Assert.Equal(2, coreClient.TerminalWrites.Select(write => write.ChannelId).Distinct().Count());

        var alpha = viewModel.BatchContinuousSessions.Single(session => session.AssetId == firstAssetId);
        var beta = viewModel.BatchContinuousSessions.Single(session => session.AssetId == secondAssetId);
        coreClient.EmitTerminalData(coreClient.OpenedTerminalChannelIds[0], "alpha-only\r\n");
        coreClient.EmitTerminalData(coreClient.OpenedTerminalChannelIds[1], "beta-only\r\n");
        await WaitUntilAsync(() => alpha.OutputText.Contains("alpha-only", StringComparison.Ordinal) &&
            beta.OutputText.Contains("beta-only", StringComparison.Ordinal));

        Assert.DoesNotContain("beta-only", alpha.OutputText, StringComparison.Ordinal);
        Assert.DoesNotContain("alpha-only", beta.OutputText, StringComparison.Ordinal);

        var topFrameRows = string.Join("\r\n", Enumerable.Range(1, 40).Select(index => $"old-{index}"));
        coreClient.EmitTerminalData(coreClient.OpenedTerminalChannelIds[0], topFrameRows);
        coreClient.EmitTerminalData(coreClient.OpenedTerminalChannelIds[0], "\u001b[H\u001b[2Jnew-top-frame");
        await WaitUntilAsync(() => alpha.OutputText.Contains("new-top-frame", StringComparison.Ordinal));
        Assert.DoesNotContain("old-1", alpha.OutputText, StringComparison.Ordinal);

        await viewModel.StopBatchContinuousSessionAsync(alpha.Id, CancellationToken.None);
        Assert.False(alpha.IsRunning);
        Assert.True(beta.IsRunning);
        Assert.True(viewModel.HasActiveBatchContinuousSessions);

        await viewModel.StopBatchContinuousSessionAsync(beta.Id, CancellationToken.None);
        Assert.False(viewModel.HasActiveBatchContinuousSessions);
        Assert.Equal(2, coreClient.CloseTerminalCallCount);
        Assert.Equal(new byte[] { 0x03 }, coreClient.LastTerminalWrite);
    }

    [Fact]
    public async Task BatchCommandBoundsLargeOutputBeforePublishingItToTheWorkspace()
    {
        var coreClient = new FakeCheckedCoreClient { ExecStdout = new string('x', 70 * 1024) };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Host = "batch.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.BatchCommandText = "uptime";

        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchStatus.StartsWith("批量命令已完成", StringComparison.Ordinal));

        Assert.Contains("结果已截断", viewModel.BatchOutputText);
        Assert.True(viewModel.BatchOutputText.Length < 66 * 1024);
    }

    [Fact]
    public async Task BatchCommandCanSelectSavedDisconnectedAssetAndUsesTemporaryVerifiedSession()
    {
        var coreClient = new FakeCheckedCoreClient();
        var credentialVault = new MemoryCredentialVault();
        var store = new MemoryServerAssetStore();
        var assetId = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        store.Seed(new ServerAssetRecord(
            assetId,
            credentialId,
            "Disconnected batch target",
            "batch-saved.example",
            22,
            "tester",
            ServerTransport.Ssh,
            false,
            "Production"));
        await credentialVault.SaveAsync(
            credentialId,
            new CredentialMaterial("secret", string.Empty, string.Empty),
            CancellationToken.None);
        var viewModel = CreateViewModel(
            coreClient,
            credentialVault,
            store,
            seedDefaultAsset: false);

        viewModel.LoadAssetsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchAssetTargets.Count == 1);
        var target = Assert.Single(viewModel.BatchAssetTargets);
        Assert.False(target.IsConnected);
        Assert.Equal("可自动连接", target.StateText);

        viewModel.PrepareBatchCommandWorkspace();
        target.IsSelected = true;
        viewModel.RefreshBatchTargetSelection();
        viewModel.BatchCommandText = "hostname";
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchStatus == "批量命令已完成：成功 1 / 1");

        Assert.Equal(1, coreClient.ConnectCallCount);
        Assert.Equal(1, coreClient.ExecCallCount);
        Assert.Contains("临时连接已释放", target.StateText, StringComparison.Ordinal);

        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.ConnectCallCount == 2 && !viewModel.RunBatchCommand.IsRunning);
        Assert.Equal(2, coreClient.ConnectCallCount);
        Assert.Equal(2, coreClient.ExecCallCount);
    }

    [Fact]
    public async Task BatchCommandExecutesOnceForEachExplicitlySelectedVerifiedWorkspace()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Host = "batch.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.WorkspaceTabs.Count == 2);
        viewModel.NewAssetCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.NewAssetCommand.IsRunning);
        viewModel.AssetName = "Batch second";
        viewModel.Host = "batch-second.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        Assert.All(viewModel.WorkspaceTabs, tab => Assert.True(tab.IsBatchTargetSelected));
        viewModel.BatchCommandText = "hostname";
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.BatchStatus == "批量命令已完成：成功 2 / 2");

        Assert.Equal(2, coreClient.ExecCallCount);
        Assert.Contains("[", viewModel.BatchOutputText);
        Assert.Contains("batch output", viewModel.BatchOutputText);
    }

    [Fact]
    public async Task BatchCommandSnapshotsCommandAndKeepsResultAcrossWorkspaceSwitch()
    {
        var coreClient = new FakeCheckedCoreClient { ExecDelayMilliseconds = 250 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.BatchCommandText = "hostname --fqdn";
        viewModel.RunBatchCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.ExecCallCount >= 1);

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.WorkspaceTabs.Count == 2);
        var visibleTab = viewModel.SelectedWorkspaceTab!;
        viewModel.BatchCommandText = "whoami";

        await WaitUntilAsync(() => !viewModel.RunBatchCommand.IsRunning);

        Assert.Single(coreClient.ExecutedCommands);
        Assert.All(coreClient.ExecutedCommands, command => Assert.Equal("hostname --fqdn", command));
        Assert.Same(visibleTab, viewModel.SelectedWorkspaceTab);
        Assert.Equal("whoami", viewModel.BatchCommandText);
        Assert.Contains("批量命令已完成", viewModel.BatchStatus, StringComparison.Ordinal);
        Assert.Contains("batch output", viewModel.BatchOutputText, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SnippetsPersistAndReuseExistingTerminalInputs()
    {
        var store = new MemorySnippetStore();
        var viewModel = CreateViewModel(snippetStore: store);

        await viewModel.SaveSnippetAsync(
            null,
            "System load",
            "uptime",
            "System",
            CancellationToken.None);

        Assert.Single(viewModel.Snippets);
        Assert.Equal("快捷指令已创建", viewModel.SnippetStatus);
        Assert.False(viewModel.InsertSnippetCommand.CanExecute(null));

        viewModel.Host = "snippets.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.True(viewModel.InsertSnippetCommand.CanExecute(null));
        viewModel.InsertSnippetCommand.Execute(null);
        Assert.Equal("uptime", viewModel.CommandText);

        viewModel.ExecuteSnippetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SnippetStatus == "快捷指令已发送到终端");

        viewModel.DeleteSnippetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Snippets.Count == 0);
        Assert.Empty(store.SavedSnippets);

        await viewModel.SaveSnippetAsync(null, "Bad", "bad\ncommand", "System", CancellationToken.None);
        Assert.Empty(viewModel.Snippets);
        Assert.StartsWith("快捷指令不符合要求", viewModel.SnippetStatus);
    }

    [Fact]
    public async Task SnippetExecutionCompletionDoesNotOverwriteAnotherWorkspaceStatus()
    {
        var coreClient = new FakeCheckedCoreClient { TerminalWriteDelayMilliseconds = 250 };
        var store = new MemorySnippetStore();
        var viewModel = CreateViewModel(coreClient, snippetStore: store);
        await viewModel.SaveSnippetAsync(
            null,
            "Hostname",
            "hostname",
            "System",
            CancellationToken.None);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected && viewModel.IsTerminalOpen);
        var originTab = viewModel.SelectedWorkspaceTab!;

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        viewModel.NewAssetCommand.Execute(null);
        viewModel.AssetName = "Second terminal host";
        viewModel.Host = "terminal-second.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected && viewModel.IsTerminalOpen);
        var secondTab = viewModel.SelectedWorkspaceTab!;

        viewModel.SelectedWorkspaceTab = originTab;
        viewModel.SelectedSnippet = Assert.Single(viewModel.Snippets);
        viewModel.ExecuteSnippetCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.WriteTerminalCallCount == 1);

        viewModel.SelectedWorkspaceTab = secondTab;
        var secondStatus = viewModel.Status;
        await WaitUntilAsync(() => !viewModel.ExecuteSnippetCommand.IsRunning);

        Assert.Same(secondTab, viewModel.SelectedWorkspaceTab);
        Assert.Equal(secondStatus, viewModel.Status);
        Assert.Equal("命令已发送", originTab.Status);
        Assert.Equal("hostname\r", System.Text.Encoding.UTF8.GetString(coreClient.LastTerminalWrite));
    }

    [Fact]
    public async Task SnippetVariablesAndGroupedSearchRemainGuarded()
    {
        var viewModel = CreateViewModel();
        await viewModel.SaveSnippetAsync(null, "Logs", "journalctl -u {{service}}", "System", CancellationToken.None);
        await viewModel.SaveSnippetAsync(null, "Containers", "docker ps", "Docker", CancellationToken.None);

        Assert.Equal(2, viewModel.SnippetGroups.Count);
        viewModel.SnippetQuery = "journal";
        Assert.Single(viewModel.SnippetGroups);
        Assert.Equal("System", viewModel.SnippetGroups[0].Category);
        Assert.Single(viewModel.SnippetGroups[0].Items);

        viewModel.SelectedSnippet = viewModel.Snippets.Single(item => item.Title == "Logs");

        var variables = SnippetVariableResolver.Extract(viewModel.SelectedSnippet.Command);
        Assert.Equal(new[] { "service" }, variables);
        var resolved = SnippetVariableResolver.Resolve(
            viewModel.SelectedSnippet.Command,
            new Dictionary<string, string> { ["service"] = "sshd" });
        Assert.Equal("journalctl -u sshd", resolved);

        Assert.Throws<ArgumentException>(() => SnippetVariableResolver.Resolve(
            "echo {{value}}",
            new Dictionary<string, string> { ["value"] = "bad\nvalue" }));
    }

    [Fact]
    public async Task BatchWorkspaceEntryStartsEmptyAndGroupSelectionOnlyFiltersTargets()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        var verified = viewModel.SelectedWorkspaceTab!;
        verified.IsBatchTargetSelected = false;

        viewModel.PrepareBatchCommandWorkspace();

        Assert.False(verified.IsBatchTargetSelected);
        Assert.All(viewModel.BatchAssetTargets, target => Assert.False(target.IsSelected));
        Assert.Empty(viewModel.SelectedBatchAssetTargets);

        var group = viewModel.BatchAssetTargets[0].Group;
        viewModel.SelectedBatchTargetGroup = group;
        Assert.NotEmpty(viewModel.FilteredBatchAssetTargets);
        Assert.All(viewModel.FilteredBatchAssetTargets, target => Assert.Equal(group, target.Group));
        Assert.All(viewModel.BatchAssetTargets, target => Assert.False(target.IsSelected));

        var chosen = viewModel.FilteredBatchAssetTargets[0];
        chosen.IsSelected = true;
        viewModel.RefreshBatchTargetSelection();
        Assert.Single(viewModel.SelectedBatchAssetTargets);
        Assert.Equal(chosen.AssetId, viewModel.SelectedBatchAssetTargets[0].AssetId);
        Assert.Contains("输入命令", viewModel.BatchStatus, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DiagnosticsCopyExportsSanitizedRuntimeState()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.CommandText = "cat /var/log/auth.log";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0 && !viewModel.SendCommand.IsRunning);
        viewModel.SftpPathText = "/var/log/auth.log";
        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);
        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];
        viewModel.PreviewDockerLogsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerLogText.Length > 0);

        var json = viewModel.PrepareDiagnosticsBundleCopy();

        Assert.Contains("\"product\": \"OrbitTerm\"", json);
        Assert.Contains("\"has_verified_session\": true", json);
        Assert.Contains("\"has_terminal\": true", json);
        Assert.Contains("\"has_sftp\": true", json);
        Assert.Contains("\"visible_terminal_line_count\":", json);
        Assert.Contains("\"username\": \"[REDACTED]\"", json);
        Assert.Contains("\"last_remote_path\": \"[REDACTED]\"", json);
        Assert.Contains("\"last_command\": \"[REDACTED]\"", json);
        Assert.Contains("\"docker_container_count\": 2", json);
        Assert.Contains("\"docker_stats_count\": 2", json);
        Assert.Contains("\"has_docker_log_preview\": true", json);
        using (var document = JsonDocument.Parse(json))
        {
            Assert.True(document.RootElement.GetProperty("session").GetProperty("sftp_entry_count").GetInt32() >= 0);
        }
        Assert.DoesNotContain("secret", json, StringComparison.Ordinal);
        Assert.DoesNotContain("admin", json, StringComparison.Ordinal);
        Assert.DoesNotContain("/var/log/auth.log", json, StringComparison.Ordinal);
        Assert.DoesNotContain("cat /var", json, StringComparison.Ordinal);
        Assert.DoesNotContain("line one", json, StringComparison.Ordinal);
        Assert.DoesNotContain("abcdef1234567890", json, StringComparison.Ordinal);
        Assert.StartsWith("Diagnostics copied: ", viewModel.DiagnosticsStatus, StringComparison.Ordinal);
        Assert.Equal("Diagnostics copied", viewModel.Status);
    }

    [Fact]
    public async Task MonitorSnapshotRefreshRequiresVerifiedSessionAndShowsBoundedSummary()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));
        Assert.Equal("监控待命", viewModel.MonitorStatus);
        Assert.Equal("尚无监控快照", viewModel.MonitorSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.True(viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));

        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() =>
            viewModel.MonitorStatus.StartsWith("采样于 ", StringComparison.Ordinal) &&
            viewModel.MonitorTrendPointCount == 1 &&
            viewModel.MonitorTrendMetrics.Single(metric => metric.Key == "cpu").CurrentValue == "12.5%");

        Assert.Equal(1, coreClient.MonitorSnapshotCallCount);
        Assert.Equal(1, viewModel.MonitorTrendPointCount);
        Assert.Equal("12.5%", viewModel.MonitorTrendMetrics.Single(metric => metric.Key == "cpu").CurrentValue);
        Assert.Equal("cpu", viewModel.CpuMonitorTrend.Key);
        Assert.Equal("memory", viewModel.MemoryMonitorTrend.Key);
        Assert.Equal("disk", viewModel.DiskMonitorTrend.Key);
        Assert.Equal("download", viewModel.DownloadMonitorTrend.Key);
        Assert.Equal("upload", viewModel.UploadMonitorTrend.Key);
        Assert.Equal("latency", viewModel.LatencyMonitorTrend.Key);
        Assert.Contains("CPU 12.5%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("内存 48%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("磁盘 61%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("TCP 延迟 18.4 ms", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.DoesNotContain("ping_unavailable", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("Debian GNU/Linux", viewModel.SystemOverviewSummary, StringComparison.Ordinal);
        Assert.Contains("CPU 4 核 / 8 线程", viewModel.SystemOverviewSummary, StringComparison.Ordinal);
        Assert.Contains("内存 8 GB", viewModel.SystemOverviewSummary, StringComparison.Ordinal);
        Assert.Contains("磁盘总容量 100 GB", viewModel.SystemOverviewSummary, StringComparison.Ordinal);
        Assert.Contains("Swap 2 GB", viewModel.SystemOverviewSummary, StringComparison.Ordinal);
        // Docker and SFTP inspectors may finish their automatic verified-session
        // refresh after the monitor request; the dedicated monitor state is the
        // stable contract, while SessionActionSummary intentionally reports the
        // most recently completed tool action.
        Assert.StartsWith("采样于 ", viewModel.MonitorStatus, StringComparison.Ordinal);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("监控待命", viewModel.MonitorStatus);
        Assert.Equal("尚无监控快照", viewModel.MonitorSummary);
        Assert.False(viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));
    }

    [Theory]
    [InlineData(850, "850 Kbps")]
    [InlineData(4_400, "4.4 Mbps")]
    [InlineData(2_500_000, "2.5 Gbps")]
    public void MonitorNetworkCardsSelectReadableUnits(double kilobitsPerSecond, string expected)
    {
        var metric = new MonitorTrendMetricViewModel(
            "upload",
            "上传",
            snapshot => snapshot.TransmitRateKilobitsPerSecond);
        metric.Update([
            new MonitorSnapshot(
                1,
                0,
                0,
                0,
                0,
                null,
                0,
                kilobitsPerSecond,
                [])
        ]);

        Assert.Equal(expected, metric.CurrentValue);
        Assert.Contains(expected, metric.StatisticsSummary, StringComparison.Ordinal);
    }

    [Fact]
    public void TcpLatencyCardIncludesRollingProbeFailureAndPercentiles()
    {
        var metric = new MonitorTrendMetricViewModel(
            "latency",
            "TCP 延迟",
            snapshot => snapshot.PingLatencyMilliseconds,
            MonitorSampleMetrics.Latency);
        metric.Update([
            new MonitorSnapshot(1, 0, 0, 0, 0, 20, 0, 0, [], AvailableMetrics: MonitorSampleMetrics.Latency),
            new MonitorSnapshot(2, 0, 0, 0, 0, null, 0, 0, [], AvailableMetrics: MonitorSampleMetrics.None),
            new MonitorSnapshot(3, 0, 0, 0, 0, 24, 0, 0, [], AvailableMetrics: MonitorSampleMetrics.Latency),
        ]);

        Assert.Equal("24 ms · 失败 33.3%", metric.CurrentValue);
        Assert.Contains("探测失败 33.3%", metric.StatisticsSummary, StringComparison.Ordinal);
        Assert.Contains("P50 20 ms", metric.StatisticsSummary, StringComparison.Ordinal);
        Assert.Contains("P95 24 ms", metric.StatisticsSummary, StringComparison.Ordinal);

        metric.Update([
            new MonitorSnapshot(4, 0, 0, 0, 0, 24, 0, 0, [], AvailableMetrics: MonitorSampleMetrics.Latency),
            new MonitorSnapshot(5, 0, 0, 0, 0, null, 0, 0, [], AvailableMetrics: MonitorSampleMetrics.None),
        ]);
        Assert.Equal("-- ms · 失败 50%", metric.CurrentValue);
    }

    [Fact]
    public async Task ActiveSftpRateAddsTimeSamplesAndCanFallAfterInitialBurst()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var viewModel = CreateViewModel(utcNow: () => now);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.MonitorTrendPointCount == 1);

        var task = new SftpTransferTaskViewModel(
            Guid.NewGuid(),
            "large.iso",
            "/large.iso",
            SftpTransferDirection.Upload,
            "等待上传");
        task.MarkRunning("正在上传");
        task.UpdateProgress(0, 100UL * 1024 * 1024, now);
        task.UpdateProgress(2UL * 1024 * 1024, 100UL * 1024 * 1024, now.AddSeconds(1));
        viewModel.ActiveSftpTransferTasks.Add(task);

        var updateOverlay = typeof(MainWindowViewModel).GetMethod(
            "UpdateMonitorFromSftpTransferProgress",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        Assert.NotNull(updateOverlay);

        now = now.AddSeconds(2);
        updateOverlay!.Invoke(viewModel, null);
        var burstRate = viewModel.UploadMonitorTrend.CurrentValue;
        Assert.Equal(2, viewModel.MonitorTrendPointCount);

        task.UpdateProgress(
            2UL * 1024 * 1024 + 128UL * 1024,
            100UL * 1024 * 1024,
            now.AddSeconds(1));
        now = now.AddSeconds(2);
        updateOverlay.Invoke(viewModel, null);

        Assert.Equal(3, viewModel.MonitorTrendPointCount);
        Assert.NotEqual(burstRate, viewModel.UploadMonitorTrend.CurrentValue);
        Assert.Equal("11.9 Mbps", viewModel.UploadMonitorTrend.CurrentValue);
        Assert.Contains("保留 1 个采样点", viewModel.CpuMonitorTrend.AccessibilityLabel, StringComparison.Ordinal);
        Assert.Contains('·', viewModel.CpuMonitorTrend.Sparkline);
        Assert.Contains("保留 3 个采样点", viewModel.UploadMonitorTrend.AccessibilityLabel, StringComparison.Ordinal);
        Assert.Equal("系统指标持续采样 · 传输速率实时", viewModel.MonitorStatus);

        now = now.AddSeconds(10);
        task.UpdateProgress(
            3UL * 1024 * 1024,
            100UL * 1024 * 1024,
            now);
        updateOverlay.Invoke(viewModel, null);

        Assert.Equal("系统指标采样延迟 · 传输速率实时", viewModel.MonitorStatus);
        Assert.Contains("保留 1 个采样点", viewModel.CpuMonitorTrend.AccessibilityLabel, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MonitorHistoryIsWorkspaceScopedAndClearedWhenTheSessionEnds()
    {
        var now = DateTimeOffset.Parse("2026-08-05T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        var viewModel = CreateViewModel(utcNow: () => now);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.MonitorTrendPointCount == 1);
        // Monitor sampling is intentionally off the UI thread so the terminal
        // stays responsive; wait for the command's async lifetime to finish
        // before issuing the cooldown assertion.
        await WaitUntilAsync(() => viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));
        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.MonitorStatus == "请在 1 秒后刷新监控");
        Assert.Equal(1, viewModel.MonitorTrendPointCount);
        var connectedTab = viewModel.SelectedWorkspaceTab;

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.WorkspaceTabs.Count == 2);
        Assert.Equal(0, viewModel.MonitorTrendPointCount);

        viewModel.SelectedWorkspaceTab = connectedTab;
        Assert.Equal(1, viewModel.MonitorTrendPointCount);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);
        Assert.Equal(0, viewModel.MonitorTrendPointCount);
        Assert.Equal("暂无趋势采样", viewModel.MonitorTrendStatus);
    }

    [Fact]
    public async Task MonitorFailureIsActionableWithoutShowingProtocolCodes()
    {
        var coreClient = new FakeCheckedCoreClient { MonitorFailureCode = "monitor_snapshot_mismatch" };
        var viewModel = CreateViewModel(coreClient);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.MonitorStatus == "监控刷新失败");

        Assert.Equal("收到的监控数据无法安全验证，请重试；若持续出现，请导出脱敏诊断。", viewModel.MonitorSummary);
        Assert.Equal("监控刷新失败", viewModel.SessionActionSummary);
        Assert.DoesNotContain("monitor_snapshot_mismatch", viewModel.MonitorSummary, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RepeatedMonitorFailuresClearStaleConnectedAndMetricState()
    {
        var now = DateTimeOffset.Parse("2026-08-15T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        var coreClient = new FakeCheckedCoreClient { MonitorFailureCode = "remote_unavailable" };
        var viewModel = CreateViewModel(coreClient, utcNow: () => now);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        var initialMonitorCalls = coreClient.MonitorSnapshotCallCount;

        for (var attempt = 0; attempt < 3; attempt++)
        {
            now = now.AddSeconds(2);
            viewModel.RefreshMonitorSnapshotCommand.Execute(null);
            await WaitUntilAsync(() => coreClient.MonitorSnapshotCallCount >= initialMonitorCalls + attempt + 1 &&
                !viewModel.RefreshMonitorSnapshotCommand.IsRunning);
        }

        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);
        Assert.Equal("监控待命", viewModel.MonitorStatus);
        Assert.Equal("尚无监控快照", viewModel.MonitorSummary);
        Assert.Equal(0, viewModel.MonitorTrendPointCount);
        Assert.Contains("失去响应", viewModel.Status, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DockerContainerListRequiresVerifiedSessionAndShowsContainers()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.RefreshDockerContainersCommand.CanExecute(null));
        Assert.Equal("Docker 待命", viewModel.DockerStatus);
        Assert.Equal("尚无 Docker 容器数据", viewModel.DockerSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        Assert.True(viewModel.RefreshDockerContainersCommand.CanExecute(null));

        var automaticListCalls = coreClient.DockerListCallCount;
        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerListCallCount == automaticListCalls + 1);
        await WaitUntilAsync(() => !viewModel.RefreshDockerContainersCommand.IsRunning);

        Assert.Equal(automaticListCalls + 1, coreClient.DockerListCallCount);
        Assert.Equal("已读取 2 个 Docker 容器", viewModel.DockerSummary);
        Assert.Equal(2, viewModel.DockerContainers.Count);
        Assert.Equal("web", viewModel.DockerContainers[0].Name);
        Assert.Equal("nginx:stable", viewModel.DockerContainers[0].Image);
        Assert.Equal("running", viewModel.DockerContainers[0].State);
        Assert.Equal("abcdef123456", viewModel.DockerContainers[0].ShortId);
        Assert.True(viewModel.IsDockerFeedbackSuccess);
        Assert.Equal("容器列表已刷新", viewModel.DockerFeedbackTitle);
        Assert.Equal("容器列表已刷新", viewModel.RecentDockerOperations[0].Title);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("Docker 待命", viewModel.DockerStatus);
        Assert.Equal("尚无 Docker 容器数据", viewModel.DockerSummary);
        Assert.Empty(viewModel.DockerContainers);
        Assert.False(viewModel.RefreshDockerContainersCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerStatsRequiresVerifiedSessionAndShowsReadOnlySnapshot()
    {
        var coreClient = new FakeCheckedCoreClient();
        var now = new DateTimeOffset(2026, 8, 11, 12, 0, 0, TimeSpan.Zero);
        var viewModel = CreateViewModel(coreClient, utcNow: () => now);

        Assert.False(viewModel.RefreshDockerStatsCommand.CanExecute(null));
        Assert.Equal("Docker 待命", viewModel.DockerStatus);
        Assert.Equal("尚无 Docker 资源数据", viewModel.DockerStatsSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => viewModel.DockerStats.Count == 2);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        Assert.True(viewModel.RefreshDockerStatsCommand.CanExecute(null));

        var recentOperationsBeforeAutoRefresh = viewModel.RecentDockerOperations.Count;
        var listCallsBeforeAutoRefresh = coreClient.DockerListCallCount;
        var statsCallsBeforeAutoRefresh = coreClient.DockerStatsCallCount;
        var firstContainerBeforeAutoRefresh = viewModel.DockerContainers[0];
        var collectionChanges = 0;
        var containerPropertyChanges = 0;
        viewModel.DockerContainers.CollectionChanged += (_, _) => collectionChanges++;
        firstContainerBeforeAutoRefresh.PropertyChanged += (_, _) => containerPropertyChanges++;
        await viewModel.RefreshDockerInspectorForAutoRefreshAsync(CancellationToken.None);
        Assert.Equal(listCallsBeforeAutoRefresh, coreClient.DockerListCallCount);
        Assert.Equal(statsCallsBeforeAutoRefresh + 1, coreClient.DockerStatsCallCount);
        Assert.Equal(recentOperationsBeforeAutoRefresh, viewModel.RecentDockerOperations.Count);
        Assert.Same(firstContainerBeforeAutoRefresh, viewModel.DockerContainers[0]);
        Assert.Equal(0, collectionChanges);
        Assert.Equal(0, containerPropertyChanges);

        now += TimeSpan.FromSeconds(11);
        await viewModel.RefreshDockerInspectorForAutoRefreshAsync(CancellationToken.None);
        Assert.Equal(listCallsBeforeAutoRefresh + 1, coreClient.DockerListCallCount);
        Assert.Equal(statsCallsBeforeAutoRefresh + 2, coreClient.DockerStatsCallCount);
        Assert.Same(firstContainerBeforeAutoRefresh, viewModel.DockerContainers[0]);

        var automaticStatsCalls = coreClient.DockerStatsCallCount;
        viewModel.RefreshDockerStatsCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerStatsCallCount == automaticStatsCalls + 1);
        await WaitUntilAsync(() => !viewModel.RefreshDockerStatsCommand.IsRunning);

        Assert.Equal(automaticStatsCalls + 1, coreClient.DockerStatsCallCount);
        Assert.Equal("已读取 2 项 Docker 资源数据", viewModel.DockerStatsSummary);
        Assert.Equal(2, viewModel.DockerStats.Count);
        Assert.Equal("web", viewModel.DockerStats[0].Name);
        Assert.Equal("12.5%", viewModel.DockerStats[0].CpuPercent);
        Assert.Equal("48%", viewModel.DockerStats[0].MemoryPercent);
        Assert.Equal("128MiB / 256MiB", viewModel.DockerStats[0].MemoryUsage);
        Assert.Equal("1.2kB / 2.3kB", viewModel.DockerStats[0].NetworkIo);
        Assert.Equal("4.5kB / 6.7kB", viewModel.DockerStats[0].BlockIo);
        Assert.Equal("7", viewModel.DockerStats[0].Pids);
        Assert.Equal("12.5%", viewModel.DockerContainers[0].CpuPercent);
        Assert.Equal("48%", viewModel.DockerContainers[0].MemoryPercent);
        Assert.Equal("128MiB / 256MiB", viewModel.DockerContainers[0].MemoryUsage);
        Assert.Contains("CPU 12.5%", viewModel.DockerContainers[0].ResourceUsageSummary, StringComparison.Ordinal);
        Assert.Contains("网络 1.2kB / 2.3kB", viewModel.DockerContainers[0].ResourceIoSummary, StringComparison.Ordinal);
        Assert.Equal("Docker 资源数据已更新", viewModel.SessionActionSummary);
        Assert.True(viewModel.IsDockerFeedbackSuccess);
        Assert.Equal("资源数据已刷新", viewModel.RecentDockerOperations[0].Title);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("Docker 待命", viewModel.DockerStatus);
        Assert.Equal("尚无 Docker 资源数据", viewModel.DockerStatsSummary);
        Assert.Empty(viewModel.DockerStats);
        Assert.False(viewModel.RefreshDockerStatsCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerAutoRefreshRejectsOverlappingTimerTicks()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected && !viewModel.ConnectCommand.IsRunning);

        coreClient.DockerStatsDelayMilliseconds = 150;
        var callsBefore = coreClient.DockerStatsCallCount;
        var first = viewModel.RefreshDockerInspectorForAutoRefreshAsync(CancellationToken.None);
        await WaitUntilAsync(() => coreClient.DockerStatsCallCount == callsBefore + 1);
        var overlapping = viewModel.RefreshDockerInspectorForAutoRefreshAsync(CancellationToken.None);

        await Task.WhenAll(first, overlapping);

        Assert.Equal(callsBefore + 1, coreClient.DockerStatsCallCount);
    }

    [Fact]
    public async Task DockerLogsRequireSelectedContainerAndShowBoundedPreview()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));
        Assert.Equal("尚无 Docker 日志预览", viewModel.DockerLogStatus);
        Assert.Equal(string.Empty, viewModel.DockerLogText);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);

        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));

        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);
        await WaitUntilAsync(() => !viewModel.RefreshDockerContainersCommand.IsRunning);

        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];
        Assert.True(viewModel.PreviewDockerLogsCommand.CanExecute(null));
        var logContext = Assert.IsType<DockerLogSessionContext>(viewModel.CreateSelectedDockerLogSessionContext());
        Assert.True(viewModel.IsDockerLogSessionContextAvailable(logContext));

        viewModel.PreviewDockerLogsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerLogStatus == "Docker 日志预览：abcdef123456");

        Assert.Equal(1, coreClient.DockerLogsCallCount);
        Assert.Equal("abcdef1234567890", coreClient.LastDockerLogsContainerId);
        Assert.Equal(100U, coreClient.LastDockerLogsTailLines);
        Assert.Equal("line one\nline two\n", viewModel.DockerLogText);
        Assert.Equal("Docker 日志已更新", viewModel.SessionActionSummary);
        Assert.True(viewModel.IsDockerFeedbackSuccess);
        Assert.Equal("容器日志已读取", viewModel.RecentDockerOperations[0].Title);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("尚无 Docker 日志预览", viewModel.DockerLogStatus);
        Assert.Equal(string.Empty, viewModel.DockerLogText);
        Assert.Null(viewModel.SelectedDockerContainer);
        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));
        Assert.False(viewModel.IsDockerLogSessionContextAvailable(logContext));
        var staleFrame = await viewModel.CaptureDockerLogFrameAsync(logContext, 500, CancellationToken.None);
        Assert.True(staleFrame.IsError);
        Assert.Contains("会话已切换或断开", staleFrame.Status, StringComparison.Ordinal);
        Assert.Equal(1, coreClient.DockerLogsCallCount);
    }

    [Fact]
    public async Task DockerActionsRequireSelectedContainerAndUseAllowedActionTokens()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.PauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.UnpauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.KillDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RemoveDockerContainerCommand.CanExecute(null));

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));

        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning);
        var listCallsBeforeAction = coreClient.DockerListCallCount;
        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.RestartDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.PauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.UnpauseDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.KillDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.RemoveDockerContainerCommand.CanExecute(null));

        viewModel.RestartDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerStatus == "Docker 容器已重启，容器列表已刷新");
        await WaitUntilAsync(() => !viewModel.RestartDockerContainerCommand.IsRunning);

        Assert.Equal(1, coreClient.DockerActionCallCount);
        Assert.Equal(listCallsBeforeAction + 1, coreClient.DockerListCallCount);
        Assert.Equal("abcdef1234567890", coreClient.LastDockerActionContainerId);
        Assert.Equal("restart", coreClient.LastDockerAction);
        Assert.NotNull(viewModel.SelectedDockerContainer);
        Assert.Equal("abcdef1234567890", viewModel.SelectedDockerContainer.Id);
        Assert.Equal("Docker 容器重启完成", viewModel.SessionActionSummary);
        Assert.True(viewModel.IsDockerFeedbackSuccess);
        Assert.Equal("容器重启完成", viewModel.DockerFeedbackTitle);
        Assert.Equal("容器重启完成", viewModel.RecentDockerOperations[0].Title);
        Assert.Equal("成功", viewModel.RecentDockerOperations[0].KindText);

        viewModel.PauseDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 2);
        await WaitUntilAsync(() => !viewModel.PauseDockerContainerCommand.IsRunning);
        Assert.Equal("pause", coreClient.LastDockerAction);

        viewModel.SelectedDockerContainer = new DockerContainerViewModel(
            "abcdef123456",
            "web",
            "nginx:stable",
            "paused",
            "Up 3 minutes (Paused)",
            "3 minutes",
            "abcdef1234567890");
        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.PauseDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.UnpauseDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.KillDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.RemoveDockerContainerCommand.CanExecute(null));

        viewModel.UnpauseDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 3);
        await WaitUntilAsync(() => !viewModel.UnpauseDockerContainerCommand.IsRunning);
        Assert.Equal("unpause", coreClient.LastDockerAction);

        viewModel.SelectedDockerContainer = viewModel.DockerContainers[1];
        Assert.True(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.PauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.UnpauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.KillDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.RemoveDockerContainerCommand.CanExecute(null));

        viewModel.StartDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 4);
        await WaitUntilAsync(() => !viewModel.StartDockerContainerCommand.IsRunning);
        Assert.Equal("start", coreClient.LastDockerAction);

        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];
        viewModel.StopDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 5);
        await WaitUntilAsync(() => !viewModel.StopDockerContainerCommand.IsRunning);
        Assert.Equal("stop", coreClient.LastDockerAction);

        viewModel.KillDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 6);
        await WaitUntilAsync(() => !viewModel.KillDockerContainerCommand.IsRunning);
        Assert.Equal("kill", coreClient.LastDockerAction);

        viewModel.RemoveDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 7);
        await WaitUntilAsync(() => !viewModel.RemoveDockerContainerCommand.IsRunning);
        Assert.Equal("remove", coreClient.LastDockerAction);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.PauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.UnpauseDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.KillDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RemoveDockerContainerCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerActionRemainsBoundToItsOriginWorkspaceWhenTheVisibleTabChanges()
    {
        var coreClient = new FakeCheckedCoreClient { DockerActionDelayMilliseconds = 300 };
        var viewModel = CreateViewModel(coreClient);
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected && viewModel.DockerContainers.Count == 2);
        var originTab = viewModel.SelectedWorkspaceTab!;

        viewModel.OpenWorkspaceTabCommand.Execute(null);
        viewModel.NewAssetCommand.Execute(null);
        viewModel.AssetName = "Second Docker host";
        viewModel.Host = "docker-second.example";
        viewModel.Username = "tester";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected && viewModel.DockerContainers.Count == 2);
        var secondTab = viewModel.SelectedWorkspaceTab!;

        viewModel.SelectedWorkspaceTab = originTab;
        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];
        viewModel.RestartDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => coreClient.DockerActionCallCount == 1);

        viewModel.SelectedWorkspaceTab = secondTab;
        var secondStatus = viewModel.DockerStatus;
        var secondSummary = viewModel.SessionActionSummary;
        await WaitUntilAsync(() => !viewModel.RestartDockerContainerCommand.IsRunning);

        Assert.Same(secondTab, viewModel.SelectedWorkspaceTab);
        Assert.Equal(secondStatus, viewModel.DockerStatus);
        Assert.Equal(secondSummary, viewModel.SessionActionSummary);
        Assert.Contains("已重启", originTab.DockerStatus, StringComparison.Ordinal);
        Assert.Equal("Docker 容器重启完成", originTab.SessionActionSummary);
        Assert.Equal("Second Docker host", viewModel.SelectedWorkspaceTab.Title);
    }

    [Fact]
    public async Task RemoteProcessMonitorUsesVerifiedSessionAndParsesBoundedSnapshot()
    {
        var coreClient = new FakeCheckedCoreClient
        {
            ExecStdout =
                "101 1 root 22.5 4.2 R 1786424400 nginx\n" +
                "202 1 postgres 7.0 12.8 S 1786424300 postgres\n" +
                "invalid remote output\n",
        };
        var viewModel = CreateViewModel(coreClient);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsConnected);

        await viewModel.RefreshRemoteProcessesAsync(CancellationToken.None);

        Assert.Equal(1, coreClient.ExecCallCount);
        Assert.Contains("ps -eo pid=,ppid=,user=,pcpu=,pmem=,stat=,etimes=,args=", coreClient.LastExecCommand, StringComparison.Ordinal);
        Assert.Contains("head -n 2048", coreClient.LastExecCommand, StringComparison.Ordinal);
        Assert.DoesNotContain("head -n 20 ", coreClient.LastExecCommand, StringComparison.Ordinal);
        Assert.Equal(2, viewModel.RemoteProcesses.Count);
        Assert.Equal(101U, viewModel.RemoteProcesses[0].ProcessId);
        Assert.Equal("root", viewModel.RemoteProcesses[0].User);
        Assert.Equal("22.5%", viewModel.RemoteProcesses[0].CpuPercentText);
        Assert.Equal("4.2%", viewModel.RemoteProcesses[0].MemoryPercentText);
        Assert.Equal(1786424400, viewModel.RemoteProcesses[0].StartIdentity);
        Assert.Equal("运行中", viewModel.RemoteProcesses[0].StateLabel);
        Assert.Equal("nginx", viewModel.RemoteProcesses[0].Command);
        Assert.Contains("实时更新", viewModel.RemoteProcessStatus, StringComparison.Ordinal);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);
        Assert.Empty(viewModel.RemoteProcesses);
        Assert.Equal("等待进程采样", viewModel.RemoteProcessStatus);
    }

    [Fact]
    public async Task RemoteProcessMonitorDoesNotDropIdleProcessesOutsideFormerTopTwentyLimit()
    {
        var rows = Enumerable.Range(1, 24)
            .Select(index => $"{100 + index} 1 root {25 - index}.0 0.1 S 1786424{index:000} worker-{index}")
            .Append("999 1 root 0.0 0.0 S 1786424999 sleep");
        var coreClient = new FakeCheckedCoreClient
        {
            ExecStdout = string.Join('\n', rows) + "\n",
        };
        var viewModel = CreateViewModel(coreClient);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsConnected);

        await viewModel.RefreshRemoteProcessesAsync(CancellationToken.None);

        Assert.Equal(25, viewModel.RemoteProcesses.Count);
        Assert.Contains(viewModel.RemoteProcesses, process =>
            process.ProcessId == 999U && process.Command == "sleep");
        Assert.Contains("已采集 25 个进程", viewModel.RemoteProcessStatus, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RemoteProcessMonitorKeepsFullCommandAndRelationshipDetails()
    {
        var coreClient = new FakeCheckedCoreClient
        {
            ExecStdout = "999 321 deploy 0.0 0.2 S 1786424999 /usr/bin/sleep 300\n",
        };
        var viewModel = CreateViewModel(coreClient);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.ConnectCommand.IsRunning && viewModel.IsConnected);

        await viewModel.RefreshRemoteProcessesAsync(CancellationToken.None);

        var process = Assert.Single(viewModel.RemoteProcesses);
        Assert.Equal(321U, process.ParentProcessId);
        Assert.Equal("321", process.ParentProcessIdText);
        Assert.Equal("/usr/bin/sleep 300", process.Command);
        Assert.Equal("sleep", process.ProcessName);
        Assert.Contains("父进程 321", process.DetailSummary, StringComparison.Ordinal);
        Assert.Contains("已运行", process.DetailSummary, StringComparison.Ordinal);
    }

    private static MainWindowViewModel CreateViewModel(
        FakeCheckedCoreClient? coreClient = null,
        MemoryCredentialVault? credentialVault = null,
        IServerAssetStore? assetStore = null,
        ISnippetStore? snippetStore = null,
        bool seedDefaultAsset = true,
        Func<DateTimeOffset>? utcNow = null,
        Action<Action>? dispatch = null,
        TimeSpan? terminalUiFrameInterval = null)
    {
        credentialVault ??= new MemoryCredentialVault();
        var orchestrator = new SessionOrchestrator(
            coreClient ?? new FakeCheckedCoreClient(),
            credentialVault,
            new FakeKnownHostsPathProvider(),
            new VerifiedSessionRegistry(),
            new TerminalSessionRegistry());

        var viewModel = new MainWindowViewModel(
            orchestrator,
            credentialVault,
            assetStore,
            snippetStore,
            dispatch: dispatch,
            utcNow: utcNow,
            terminalUiFrameInterval: terminalUiFrameInterval ?? TimeSpan.Zero,
            tcpLatencyProbe: static (_, _, _) =>
                Task.FromResult(new TcpLatencyProbeResult(true, 18.4)));
        if (seedDefaultAsset)
        {
            var asset = new AssetViewModel(
                Guid.NewGuid(),
                Guid.NewGuid(),
                "Production",
                "example.com",
                22,
                "admin",
                ServerTransport.Ssh,
                false);
            viewModel.Assets.Add(asset);
            viewModel.SelectedAsset = asset;
        }

        return viewModel;
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!condition())
        {
            timeout.Token.ThrowIfCancellationRequested();
            await Task.Delay(10, timeout.Token);
        }
    }

    private sealed class FakeCheckedCoreClient : ICheckedOrbitCoreClient
    {
        public event EventHandler<TerminalDataReceivedEventArgs>? TerminalDataReceived;

        public event EventHandler<SftpTransferProgressEventArgs>? SftpTransferProgress
        {
            add { }
            remove { }
        }

        public int CloseTerminalCallCount { get; private set; }
        public int WriteTerminalCallCount { get; private set; }
        public int TerminalWriteDelayMilliseconds { get; init; }
        public int ResizeTerminalCallCount { get; private set; }
        public int OpenSftpCallCount { get; private set; }
        public int UploadSftpFileCallCount { get; private set; }
        public int DownloadSftpFileCallCount { get; private set; }
        public List<ulong> SftpDownloadSessionIds { get; } = [];
        public int CancelSftpTransferCallCount { get; private set; }
        public int SftpDownloadDelayMilliseconds { get; init; }
        public int SftpUploadDelayMilliseconds { get; init; }
        public ManualResetEventSlim? SftpUploadReleaseGate { get; init; }
        private int sftpUploadInFlight;
        private int maxConcurrentSftpUploads;
        public int SftpUploadInFlight => Volatile.Read(ref sftpUploadInFlight);
        public int MaxConcurrentSftpUploads => Volatile.Read(ref maxConcurrentSftpUploads);
        public int SftpUploadFailuresRemaining { get; set; }
        public int RemoveSftpEntryCallCount { get; private set; }
        public List<string> RemovedSftpPaths { get; } = [];
        public int ChangeSftpPermissionsCallCount { get; private set; }
        public int MonitorSnapshotCallCount { get; private set; }
        public string? MonitorFailureCode { get; init; }
        public string ExecStdout { get; init; } = "batch output\n";
        public int ExecDelayMilliseconds { get; init; }
        public int ExecCallCount { get; private set; }
        public int ConnectCallCount { get; private set; }
        public List<string> ExecutedCommands { get; } = [];
        public int DockerListCallCount { get; private set; }
        public int DockerStatsCallCount { get; private set; }
        public int DockerStatsDelayMilliseconds { get; set; }
        public int DockerLogsCallCount { get; private set; }
        public int DockerActionCallCount { get; private set; }
        public int DockerActionDelayMilliseconds { get; init; }
        public string LastDockerLogsContainerId { get; private set; } = string.Empty;
        public uint LastDockerLogsTailLines { get; private set; }
        public string LastDockerActionContainerId { get; private set; } = string.Empty;
        public string LastDockerAction { get; private set; } = string.Empty;
        public ulong LastOpenedTerminalChannelId { get; private set; }
        public List<ulong> OpenedTerminalChannelIds { get; } = [];
        public List<(ulong ChannelId, byte[] Data)> TerminalWrites { get; } = [];
        public ulong LastWrittenTerminalChannelId { get; private set; }
        public byte[] LastTerminalWrite { get; private set; } = [];
        public uint LastTerminalColumns { get; private set; }
        public uint LastTerminalRows { get; private set; }
        public ulong LastSftpUploadSessionId { get; private set; }
        public string? LastSftpUploadLocalPath { get; private set; }
        public string? LastSftpUploadRemotePath { get; private set; }
        public string? LastCreatedSftpDirectoryPath { get; private set; }
        public string? LastCreatedSftpFilePath { get; private set; }
        public string? LastRenamedSftpSourcePath { get; private set; }
        public string? LastRenamedSftpDestinationPath { get; private set; }
        public string? LastRemovedSftpPath { get; private set; }
        public uint LastSftpPermissionsMode { get; private set; }
        public string? LastWrittenSftpTextPath { get; private set; }
        public string? LastWrittenSftpTextContent { get; private set; }
        public SftpEntrySnapshot? LastSftpMutationSnapshot { get; private set; }
        private ulong nextTerminalChannelId = 77;

        public CheckedConnectOutcome Connect(CheckedConnectionRequest request, HostKeyRequestId requestId)
        {
            ConnectCallCount++;
            return new CheckedConnectOutcome.Connected(new ConnectedPayload(
                9UL,
                request.Host,
                request.Host,
                checked((ushort)request.Port),
                $"{request.Host}:{request.Port}",
                "ssh-ed25519",
                "SHA256:abc",
                CheckedSecurityGeneration.HostKeyVerified));
        }

        public CheckedHostKeyTrustOutcome AcceptAndPersistHostKey(
            string challengeId,
            string knownHostsPath,
            string comment,
            HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedTerminalOpenOutcome OpenTerminal(
            ulong baseSessionId,
            uint columns,
            uint rows,
            HostKeyRequestId requestId)
        {
            LastOpenedTerminalChannelId = nextTerminalChannelId++;
            OpenedTerminalChannelIds.Add(LastOpenedTerminalChannelId);
            return new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
                baseSessionId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                LastOpenedTerminalChannelId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                CheckedSecurityGeneration.HostKeyVerified,
                columns,
                rows));
        }

        public TerminalControlResult WriteTerminal(ulong terminalChannelId, ReadOnlyMemory<byte> data)
        {
            WriteTerminalCallCount++;
            LastWrittenTerminalChannelId = terminalChannelId;
            LastTerminalWrite = data.ToArray();
            TerminalWrites.Add((terminalChannelId, data.ToArray()));
            if (TerminalWriteDelayMilliseconds > 0)
            {
                Thread.Sleep(TerminalWriteDelayMilliseconds);
            }
            return new TerminalControlResult.Succeeded("written");
        }

        public void EmitTerminalData(ulong terminalChannelId, string text)
        {
            TerminalDataReceived?.Invoke(
                this,
                new TerminalDataReceivedEventArgs(
                    terminalChannelId,
                    System.Text.Encoding.UTF8.GetBytes(text)));
        }

        public TerminalControlResult ResizeTerminal(ulong terminalChannelId, uint columns, uint rows)
        {
            ResizeTerminalCallCount++;
            LastTerminalColumns = columns;
            LastTerminalRows = rows;
            return new TerminalControlResult.Succeeded("resized");
        }

        public TerminalControlResult CloseTerminal(ulong terminalChannelId)
        {
            CloseTerminalCallCount++;
            return new TerminalControlResult.Succeeded("closed");
        }

        public CheckedEnvelope OpenSftp(ulong baseSessionId, HostKeyRequestId requestId)
        {
            OpenSftpCallCount++;
            return CreateEnvelope(
                CheckedFfiKind.SftpChannelOpened,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "sftp_session_id": "55",
                  "security_generation": "host_key_verified"
                }
                """);
        }

        public CheckedEnvelope ListSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            var entriesJson = remotePath == "/var"
                ? """
                    [
                      {
                        "name": "log",
                        "size": 0,
                        "permissions": "drwxr-xr-x",
                        "permissions_octal": 16877,
                        "modified_at_unix": 1700000000
                      }
                    ]
                  """
                : remotePath == "/batch"
                    ? """
                      [
                        {
                          "name": "folder",
                          "size": 0,
                          "permissions": "drwxr-xr-x",
                          "permissions_octal": 16877,
                          "modified_at_unix": 1700000000
                        },
                        {
                          "name": "one.txt",
                          "size": 12,
                          "permissions": "-rw-r--r--",
                          "permissions_octal": 33188,
                          "modified_at_unix": 1700000001
                        },
                        {
                          "name": "two.log",
                          "size": 24,
                          "permissions": "-rw-r-----",
                          "permissions_octal": 33184,
                          "modified_at_unix": 1700000002
                        }
                      ]
                      """
                : remotePath == "/replace"
                    ? BuildReplaceSftpEntriesJson()
                : """
                    [
                      {
                        "name": "syslog",
                        "size": 42,
                        "permissions": "-rw-r--r--",
                        "permissions_octal": 33188,
                        "modified_at_unix": 1700000000
                      }
                    ]
                  """;
            return CreateEnvelope(
                CheckedFfiKind.SftpDirectoryList,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "entries": {{entriesJson}}
                }
                """);
        }

        private string BuildReplaceSftpEntriesJson()
        {
            var entries = new List<object>
            {
                new
                {
                    name = "same.txt",
                    size = 8UL,
                    permissions = "-rw-r--r--",
                    permissions_octal = 33188U,
                    modified_at_unix = 1700000000UL,
                },
            };
            if (LastSftpUploadRemotePath is { } uploadedPath &&
                uploadedPath.StartsWith("/replace/.", StringComparison.Ordinal) &&
                uploadedPath.EndsWith(".upload", StringComparison.Ordinal))
            {
                entries.Add(new
                {
                    name = Path.GetFileName(uploadedPath),
                    size = 42UL,
                    permissions = "-rw-------",
                    permissions_octal = 33152U,
                    modified_at_unix = 1700000001UL,
                });
            }

            return JsonSerializer.Serialize(entries);
        }

        public CheckedEnvelope ReadSftpTextFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            return CreateEnvelope(
                CheckedFfiKind.SftpTextFile,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "byte_length": 12,
                  "content": "hello\nworld\n"
                }
                """);
        }

        public CheckedEnvelope DownloadSftpFile(ulong sftpSessionId, string remotePath, string localPath, HostKeyRequestId requestId)
        {
            DownloadSftpFileCallCount++;
            SftpDownloadSessionIds.Add(sftpSessionId);
            if (SftpDownloadDelayMilliseconds > 0)
            {
                Thread.Sleep(SftpDownloadDelayMilliseconds);
            }
            return CreateEnvelope(
                CheckedFfiKind.SftpDownloadCompleted,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "byte_length": 42
                }
                """);
        }

        public bool CancelSftpTransfer(HostKeyRequestId requestId)
        {
            CancelSftpTransferCallCount++;
            return true;
        }

        public CheckedEnvelope UploadSftpFile(ulong sftpSessionId, string localPath, string remotePath, HostKeyRequestId requestId)
        {
            UploadSftpFileCallCount++;
            LastSftpUploadSessionId = sftpSessionId;
            LastSftpUploadLocalPath = localPath;
            LastSftpUploadRemotePath = remotePath;
            var concurrent = Interlocked.Increment(ref sftpUploadInFlight);
            while (true)
            {
                var observedMaximum = Volatile.Read(ref maxConcurrentSftpUploads);
                if (concurrent <= observedMaximum ||
                    Interlocked.CompareExchange(ref maxConcurrentSftpUploads, concurrent, observedMaximum) == observedMaximum)
                {
                    break;
                }
            }
            try
            {
                if (SftpUploadDelayMilliseconds > 0)
                {
                    Thread.Sleep(SftpUploadDelayMilliseconds);
                }
                if (SftpUploadReleaseGate is { } releaseGate &&
                    !releaseGate.Wait(TimeSpan.FromSeconds(10)))
                {
                    throw new TimeoutException("Timed out waiting to release the deterministic SFTP upload gate.");
                }
                if (SftpUploadFailuresRemaining > 0)
                {
                    SftpUploadFailuresRemaining--;
                    return new CheckedEnvelope(
                        1,
                        "error",
                        requestId.Value,
                        null,
                        new CheckedErrorPayload("sftp_upload_failed", "error.sftp.upload_failed", requestId.Value));
                }
                return CreateEnvelope(
                    CheckedFfiKind.SftpUploadCompleted,
                    requestId.Value,
                    $$"""
                    {
                      "sftp_session_id": "{{sftpSessionId}}",
                      "path": "{{remotePath}}",
                      "security_generation": "host_key_verified",
                      "byte_length": 42
                    }
                    """);
            }
            finally
            {
                Interlocked.Decrement(ref sftpUploadInFlight);
            }
        }

        public CheckedEnvelope CreateSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            LastCreatedSftpDirectoryPath = remotePath;
            return CreateMutationEnvelope(sftpSessionId, "mkdir", remotePath, null, requestId);
        }

        public CheckedEnvelope CreateSftpFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            LastCreatedSftpFilePath = remotePath;
            return CreateMutationEnvelope(sftpSessionId, "create_file", remotePath, null, requestId);
        }

        public CheckedEnvelope RenameSftpEntry(
            ulong sftpSessionId,
            string oldRemotePath,
            string newRemotePath,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            LastRenamedSftpSourcePath = oldRemotePath;
            LastRenamedSftpDestinationPath = newRemotePath;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "rename", oldRemotePath, newRemotePath, requestId);
        }

        public CheckedEnvelope RemoveSftpEntry(
            ulong sftpSessionId,
            string remotePath,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            RemoveSftpEntryCallCount++;
            LastRemovedSftpPath = remotePath;
            RemovedSftpPaths.Add(remotePath);
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "remove", remotePath, null, requestId);
        }

        public CheckedEnvelope ChangeSftpPermissions(
            ulong sftpSessionId,
            string remotePath,
            uint mode,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            ChangeSftpPermissionsCallCount++;
            LastSftpPermissionsMode = mode;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "chmod", remotePath, null, requestId);
        }

        public CheckedEnvelope WriteSftpTextFile(
            ulong sftpSessionId,
            string remotePath,
            string content,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            LastWrittenSftpTextPath = remotePath;
            LastWrittenSftpTextContent = content;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "write_text", remotePath, null, requestId);
        }

        private static CheckedEnvelope CreateMutationEnvelope(
            ulong sftpSessionId,
            string operation,
            string path,
            string? destinationPath,
            HostKeyRequestId requestId)
        {
            var destinationJson = destinationPath is null
                ? "null"
                : System.Text.Json.JsonSerializer.Serialize(destinationPath);
            return CreateEnvelope(
                CheckedFfiKind.SftpMutationCompleted,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "operation": "{{operation}}",
                  "path": "{{path}}",
                  "destination_path": {{destinationJson}},
                  "security_generation": "host_key_verified"
                }
                """);
        }

        public CheckedEnvelope MonitorSnapshot(ulong baseSessionId, HostKeyRequestId requestId)
        {
            MonitorSnapshotCallCount++;
            if (MonitorFailureCode is { } failureCode)
            {
                return new CheckedEnvelope(
                    1,
                    CheckedFfiKind.MonitorSnapshot,
                    requestId.Value,
                    null,
                    new CheckedErrorPayload(failureCode, "error.monitor.snapshot_failed", requestId.Value));
            }

            return CreateEnvelope(
                CheckedFfiKind.MonitorSnapshot,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "stats": {
                    "sampled_at_unix": 1700000000,
                    "cpu_usage_percent": 12.5,
                    "mem_available_mb": 512,
                    "mem_used_percent": 48.0,
                    "disk_used_percent": 61.0,
                    "ping_latency_ms": null,
                    "rx_rate_kbps": 1.5,
                    "tx_rate_kbps": 2.5,
                    "system_info": {
                      "os_name": "Debian GNU/Linux",
                      "cpu_core_count": 4,
                      "cpu_thread_count": 8,
                      "memory_total_mb": 8192,
                      "swap_total_mb": 2048,
                      "swap_used_mb": 128,
                      "disk_total_mb": 102400,
                      "disk_used_mb": 62464
                    }
                  },
                  "diagnostics": [
                    "ping_unavailable"
                  ]
                }
                """);
        }

        public CheckedEnvelope DockerList(ulong baseSessionId, HostKeyRequestId requestId)
        {
            DockerListCallCount++;
            return CreateEnvelope(
                CheckedFfiKind.DockerContainers,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "containers": [
                    {
                      "id": "abcdef1234567890",
                      "name": "web",
                      "image": "nginx:stable",
                      "state": "running",
                      "status": "Up 3 minutes",
                      "running_for": "3 minutes"
                    },
                    {
                      "id": "123456abcdef7890",
                      "name": "worker",
                      "image": "alpine:latest",
                      "state": "exited",
                      "status": "Exited (0) 1 hour ago",
                      "running_for": "1 hour"
                    }
                  ]
                }
                """);
        }

        public CheckedEnvelope DockerStats(ulong baseSessionId, HostKeyRequestId requestId)
        {
            DockerStatsCallCount++;
            if (DockerStatsDelayMilliseconds > 0)
            {
                Thread.Sleep(DockerStatsDelayMilliseconds);
            }
            return CreateEnvelope(
                CheckedFfiKind.DockerStats,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "stats": [
                    {
                      "id": "abcdef1234567890",
                      "name": "web",
                      "cpu_percent": 12.5,
                      "mem_percent": 48.0,
                      "mem_usage": "128MiB / 256MiB",
                      "net_io": "1.2kB / 2.3kB",
                      "block_io": "4.5kB / 6.7kB",
                      "pids": 7
                    },
                    {
                      "id": "123456abcdef7890",
                      "name": "worker",
                      "cpu_percent": 0.0,
                      "mem_percent": 5.5,
                      "mem_usage": "14MiB / 256MiB",
                      "net_io": "0B / 0B",
                      "block_io": "0B / 0B",
                      "pids": 1
                    }
                  ]
                }
                """);
        }

        public CheckedEnvelope DockerLogs(ulong baseSessionId, string containerId, uint tailLines, HostKeyRequestId requestId)
        {
            DockerLogsCallCount++;
            LastDockerLogsContainerId = containerId;
            LastDockerLogsTailLines = tailLines;
            return CreateEnvelope(
                CheckedFfiKind.DockerLogs,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "container_id": "{{containerId}}",
                  "logs": "line one\nline two\n"
                }
                """);
        }

        public CheckedEnvelope DockerAction(ulong baseSessionId, string containerId, string action, HostKeyRequestId requestId)
        {
            DockerActionCallCount++;
            LastDockerActionContainerId = containerId;
            LastDockerAction = action;
            if (DockerActionDelayMilliseconds > 0)
            {
                Thread.Sleep(DockerActionDelayMilliseconds);
            }
            return CreateEnvelope(
                CheckedFfiKind.DockerActionResult,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "container_id": "{{containerId}}",
                  "action": "{{action}}",
                  "status": "completed"
                }
                """);
        }

        public CheckedEnvelope Exec(ulong baseSessionId, string command, HostKeyRequestId requestId)
        {
            ExecCallCount++;
            LastExecCommand = command;
            ExecutedCommands.Add(command);
            if (ExecDelayMilliseconds > 0)
            {
                Thread.Sleep(ExecDelayMilliseconds);
            }
            return CreateEnvelope(
                CheckedFfiKind.ExecResult,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "exit_status": 0,
                  "stdout": {{System.Text.Json.JsonSerializer.Serialize(ExecStdout)}},
                  "stderr": "",
                  "timed_out": false,
                  "stdout_truncated": false,
                  "stderr_truncated": false
                }
                """);
        }

        public CheckedEnvelope StartLocalTunnel(ulong baseSessionId, string bindHost, int bindPort, string destinationHost, int destinationPort, HostKeyRequestId requestId) =>
            CreateEnvelope("local_tunnel_started", requestId.Value, $$"""{"base_session_id":"{{baseSessionId}}","tunnel_id":"1407374883553281","security_generation":"host_key_verified","bind_host":"127.0.0.1","bind_port":15432}""");

        public CheckedEnvelope StopLocalTunnel(ulong tunnelId, HostKeyRequestId requestId) =>
            CreateEnvelope("local_tunnel_stopped", requestId.Value, $$"""{"tunnel_id":"{{tunnelId}}"}""");

        public string? LastExecCommand { get; private set; }

        private static CheckedEnvelope CreateEnvelope(string kind, string requestId, string dataJson)
        {
            using var document = System.Text.Json.JsonDocument.Parse(dataJson);
            return new CheckedEnvelope(1, kind, requestId, document.RootElement.Clone(), null);
        }
    }

    private sealed class MemoryCredentialVault : ICredentialVault
    {
        private CredentialMaterial credential = new(string.Empty, string.Empty, string.Empty);

        public Guid LastSavedCredentialId { get; private set; }

        public CredentialMaterial LastSavedCredential { get; private set; } = new(string.Empty, string.Empty, string.Empty);

        public Guid LastDeletedCredentialId { get; private set; }

        public ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            return ValueTask.FromResult(credential);
        }

        public ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken)
        {
            LastSavedCredentialId = credentialId;
            LastSavedCredential = credential;
            this.credential = credential;
            return ValueTask.CompletedTask;
        }

        public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            LastDeletedCredentialId = credentialId;
            credential = new CredentialMaterial(string.Empty, string.Empty, string.Empty);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemoryServerAssetStore : IServerAssetStore
    {
        private IReadOnlyList<ServerAssetRecord> loadedAssets = [];

        public IReadOnlyList<ServerAssetRecord> SavedAssets { get; private set; } = [];

        public void Seed(params ServerAssetRecord[] assets)
        {
            loadedAssets = assets;
        }

        public ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(loadedAssets);
        }

        public ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SavedAssets = assets.ToArray();
            loadedAssets = SavedAssets;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemorySnippetStore : ISnippetStore
    {
        public IReadOnlyList<SnippetRecord> SavedSnippets { get; private set; } = [];

        public ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(SavedSnippets);
        }

        public ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SavedSnippets = snippets.ToArray();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeKnownHostsPathProvider : IKnownHostsPathProvider
    {
        public string GetKnownHostsPath()
        {
            return "/tmp/orbitterm-known-hosts";
        }
    }
}
