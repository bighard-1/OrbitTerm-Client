using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using OrbitTerm.Presentation;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class MainWindowViewModelTests
{
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
        Assert.Equal(asset.CredentialId, credentialVault.LastSavedCredentialId);

        viewModel.DeleteAssetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Assets.Count == 0);

        Assert.Equal(asset.CredentialId, credentialVault.LastDeletedCredentialId);
        Assert.Equal("Asset deleted", viewModel.AssetEditorStatus);
    }

    [Fact]
    public void WorkspaceTabsPreserveConnectionDraftsWhenSwitching()
    {
        var viewModel = CreateViewModel();
        var firstTab = viewModel.SelectedWorkspaceTab;

        Assert.NotNull(firstTab);
        Assert.Equal("1 workspace tab", viewModel.WorkspaceTabSummary);

        viewModel.OpenWorkspaceTabCommand.Execute(null);

        Assert.Equal(2, viewModel.WorkspaceTabs.Count);
        Assert.Equal("2 workspace tabs", viewModel.WorkspaceTabSummary);
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
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        var firstTerminalChannelId = coreClient.LastOpenedTerminalChannelId;

        Assert.True(viewModel.OpenWorkspaceTabCommand.CanExecute(null));
        Assert.False(viewModel.CloseWorkspaceTabCommand.CanExecute(null));

        viewModel.SelectedWorkspaceTab = secondTab;

        Assert.Same(secondTab, viewModel.SelectedWorkspaceTab);
        Assert.False(viewModel.IsConnected);
        Assert.False(viewModel.IsTerminalOpen);

        viewModel.AssetName = "Second";
        viewModel.Host = "second.example";
        viewModel.Username = "ops";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

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

        Assert.Equal("New Server", viewModel.AssetName);
        Assert.Equal(string.Empty, viewModel.Host);
        Assert.Equal("22", viewModel.PortText);
        Assert.Equal("Workspace tab reset", viewModel.Status);
        Assert.Equal("1 workspace tab", viewModel.WorkspaceTabSummary);
    }

    [Fact]
    public async Task WorkspaceTabsRestoreTerminalHistoryAndSftpDraftState()
    {
        var viewModel = CreateViewModel();
        var firstTab = viewModel.SelectedWorkspaceTab;
        viewModel.SftpPathText = "/var/log";
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        viewModel.CommandText = "uptime";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0);
        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected && !viewModel.IsTerminalOpen);

        Assert.True(viewModel.HasTerminalOutput);
        Assert.Equal("1 commands in history", viewModel.CommandHistorySummary);

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
        Assert.Equal("1 commands in history", viewModel.CommandHistorySummary);
        Assert.Equal("/", viewModel.SftpPathText);

        viewModel.SelectedWorkspaceTab = secondTab;

        Assert.False(viewModel.HasTerminalOutput);
        Assert.Equal("/opt/app", viewModel.SftpPathText);
        Assert.Equal("Scratch", viewModel.AssetName);
    }

    [Fact]
    public async Task WorkbenchStateTracksVerifiedSessionAndTerminal()
    {
        var viewModel = CreateViewModel();

        Assert.Equal("Disconnected", viewModel.ConnectionStateLabel);
        Assert.Equal("Waiting", viewModel.SecurityBadgeText);
        Assert.Equal("No terminal channel", viewModel.TerminalStateLabel);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.Equal("Verified SSH", viewModel.ConnectionStateLabel);
        Assert.Equal("Host key verified", viewModel.SecurityBadgeText);
        Assert.Equal("ssh-ed25519  SHA256:abc", viewModel.SecurityStatus);

        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);

        Assert.Equal("example.com:22", viewModel.TerminalTitle);
        Assert.Equal("PTY 120x32", viewModel.TerminalStateLabel);
        Assert.Equal("1 terminal events", viewModel.ActivitySummary);
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
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0);

        viewModel.CommandText = "uptime";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.ActivitySummary == "3 terminal events");

        Assert.Equal("1 commands in history", viewModel.CommandHistorySummary);

        viewModel.PreviousCommandHistoryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText == "uptime");
        viewModel.NextCommandHistoryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0);

        viewModel.ClearTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.ActivitySummary == "No terminal activity");
        Assert.Equal("Terminal cleared", viewModel.Status);
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
    public async Task TerminalOutputIsBoundedAndVisibleTranscriptCanBeCopied()
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
            coreClient.EmitTerminalData(77, $"line-{index:000}");
        }

        await WaitUntilAsync(() => viewModel.TerminalOutputSummary == "500 visible, 6 hidden");
        Assert.Equal(500, viewModel.TerminalLines.Count);
        Assert.Equal("line-005", viewModel.TerminalLines[0].Text);
        Assert.Equal("line-504", viewModel.TerminalLines[^1].Text);

        var transcript = viewModel.PrepareTerminalTranscriptCopy();

        Assert.StartsWith("line-005", transcript, StringComparison.Ordinal);
        Assert.EndsWith("line-504", transcript, StringComparison.Ordinal);
        Assert.DoesNotContain("Connected to example.com", transcript, StringComparison.Ordinal);
        Assert.Equal("Copied 500 visible lines", viewModel.Status);
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
        Assert.Equal("Disconnected", viewModel.ConnectionStateLabel);
        Assert.Equal("Waiting", viewModel.SecurityBadgeText);
        Assert.Equal("No verified session", viewModel.SecurityStatus);
        Assert.Equal("Open a terminal to enable input", viewModel.TerminalInputHint);
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

        Assert.True(viewModel.OpenSftpCommand.CanExecute(null));
        viewModel.OpenSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        Assert.Equal(1, coreClient.OpenSftpCallCount);
        Assert.Equal("SFTP 55", viewModel.SftpStateLabel);
        Assert.Equal("SFTP channel open", viewModel.SftpStatus);
        Assert.True(viewModel.PrepareSftpBrowseCommand.CanExecute(null));
        Assert.True(viewModel.RefreshSftpBrowseCommand.CanExecute(null));
        Assert.True(viewModel.GoParentSftpCommand.CanExecute(null));
        Assert.False(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));
        Assert.Equal("SFTP ready", viewModel.SessionActionSummary);
        Assert.False(viewModel.OpenSftpCommand.CanExecute(null));

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected && !viewModel.IsSftpOpen);

        Assert.Equal("No SFTP channel", viewModel.SftpStateLabel);
        Assert.Equal("/", viewModel.SftpPathText);
        Assert.Equal("Open SFTP to prepare browsing", viewModel.SftpBrowserStatus);
        Assert.Equal("No SFTP listing", viewModel.SftpListingSummary);
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
        viewModel.OpenSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.SftpPathText = "  //var//./log/  ";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "Listed /var/log");

        Assert.Equal("/var/log", viewModel.SftpPathText);
        Assert.Equal("1 SFTP entries", viewModel.SftpListingSummary);
        Assert.Equal("Directory listing complete; upload and download are available", viewModel.SftpOperationStatus);
        Assert.Single(viewModel.SftpEntries);
        Assert.Equal("syslog", viewModel.SftpEntries[0].Name);
        Assert.Equal("/var/log/syslog", viewModel.SftpEntries[0].Path);
        Assert.Equal("File", viewModel.SftpEntries[0].KindText);
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
        viewModel.OpenSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.SftpPathText = "/var";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "Listed /var");

        Assert.Single(viewModel.SftpEntries);
        Assert.Equal("log", viewModel.SftpEntries[0].Name);
        Assert.Equal("/var/log", viewModel.SftpEntries[0].Path);
        Assert.Equal("Folder", viewModel.SftpEntries[0].KindText);
        Assert.True(viewModel.SftpEntries[0].IsDirectory);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        Assert.True(viewModel.OpenSelectedSftpEntryCommand.CanExecute(null));
        viewModel.OpenSelectedSftpEntryCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "Listed /var/log");

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
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "Listed /var/log");

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
            viewModel.OpenSftpCommand.Execute(null);
            await WaitUntilAsync(() => viewModel.IsSftpOpen);
            viewModel.SftpPathText = "/var/log";

            await viewModel.UploadSftpFileAsync(localPath, "report.txt", CancellationToken.None);

            Assert.Equal(1, coreClient.UploadSftpFileCallCount);
            Assert.Equal(55UL, coreClient.LastSftpUploadSessionId);
            Assert.Equal(localPath, coreClient.LastSftpUploadLocalPath);
            Assert.Equal("/var/log/report.txt", coreClient.LastSftpUploadRemotePath);
            Assert.Equal("Listed /var/log", viewModel.SftpBrowserStatus);
            Assert.Equal("Uploaded 42 B to /var/log/report.txt", viewModel.SftpOperationStatus);
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
        viewModel.OpenSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);
        viewModel.SftpPathText = "/var/log";
        viewModel.PrepareSftpBrowseCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.SftpBrowserStatus == "Listed /var/log");

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
        Assert.Equal("Renamed to /var/log/syslog.old", viewModel.SftpOperationStatus);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        var chmodEntry = viewModel.SelectedSftpEntry;
        Assert.NotNull(chmodEntry);
        await viewModel.ChangeSelectedSftpPermissionsConfirmedAsync(
            chmodEntry!,
            "640",
            CancellationToken.None);
        Assert.Equal(0x1A0U, coreClient.LastSftpPermissionsMode);
        Assert.Equal("Permissions changed to 640", viewModel.SftpOperationStatus);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        var confirmed = viewModel.SelectedSftpEntry;
        Assert.NotNull(confirmed);
        viewModel.SelectedSftpEntry = null;
        await viewModel.RemoveSelectedSftpEntryConfirmedAsync(confirmed!, CancellationToken.None);
        Assert.Equal(0, coreClient.RemoveSftpEntryCallCount);
        Assert.Equal("SFTP selection changed; review the entry again", viewModel.SftpOperationStatus);

        viewModel.SelectedSftpEntry = viewModel.SftpEntries[0];
        confirmed = viewModel.SelectedSftpEntry;
        Assert.NotNull(confirmed);
        await viewModel.RemoveSelectedSftpEntryConfirmedAsync(confirmed!, CancellationToken.None);
        Assert.Equal(1, coreClient.RemoveSftpEntryCallCount);
        Assert.Equal("/var/log/syslog", coreClient.LastRemovedSftpPath);
        Assert.Equal("Removed /var/log/syslog", viewModel.SftpOperationStatus);
    }

    [Fact]
    public async Task BatchCommandRequiresVerifiedSessionAndKeepsPerTabResult()
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
        await WaitUntilAsync(() => viewModel.BatchStatus == "Batch command completed");

        Assert.Equal("uname -a", coreClient.LastExecCommand);
        Assert.Equal("batch output\n", viewModel.BatchOutputText);

        var firstTab = viewModel.SelectedWorkspaceTab;
        viewModel.OpenWorkspaceTabCommand.Execute(null);
        Assert.Equal("Batch ready", viewModel.BatchStatus);
        viewModel.SelectedWorkspaceTab = firstTab;
        Assert.Equal("batch output\n", viewModel.BatchOutputText);

        viewModel.BatchCommandText = "bad\ncommand";
        Assert.False(viewModel.RunBatchCommand.CanExecute(null));
    }

    [Fact]
    public async Task SnippetsPersistAndReuseExistingTerminalAndBatchInputs()
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
        Assert.Equal("Snippet created", viewModel.SnippetStatus);
        Assert.False(viewModel.InsertSnippetCommand.CanExecute(null));
        Assert.True(viewModel.FillBatchFromSnippetCommand.CanExecute(null));

        viewModel.FillBatchFromSnippetCommand.Execute(null);
        Assert.Equal("uptime", viewModel.BatchCommandText);

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
        await WaitUntilAsync(() => viewModel.SnippetStatus == "Snippet sent to terminal");

        viewModel.DeleteSnippetCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.Snippets.Count == 0);
        Assert.Empty(store.SavedSnippets);

        await viewModel.SaveSnippetAsync(null, "Bad", "bad\ncommand", "System", CancellationToken.None);
        Assert.Empty(viewModel.Snippets);
        Assert.StartsWith("Snippet rejected", viewModel.SnippetStatus);
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
        viewModel.FillBatchFromSnippetCommand.Execute(null);
        Assert.Equal("Resolve Snippet variables before Batch reuse", viewModel.SnippetStatus);
        Assert.Equal(string.Empty, viewModel.BatchCommandText);

        var variables = SnippetVariableResolver.Extract(viewModel.SelectedSnippet.Command);
        Assert.Equal(new[] { "service" }, variables);
        var resolved = SnippetVariableResolver.Resolve(
            viewModel.SelectedSnippet.Command,
            new Dictionary<string, string> { ["service"] = "sshd" });
        Assert.Equal("journalctl -u sshd", resolved);
        viewModel.FillBatchFromResolvedSnippet(resolved);
        Assert.Equal("journalctl -u sshd", viewModel.BatchCommandText);

        Assert.Throws<ArgumentException>(() => SnippetVariableResolver.Resolve(
            "echo {{value}}",
            new Dictionary<string, string> { ["value"] = "bad\nvalue" }));
        Assert.Throws<ArgumentException>(() => viewModel.FillBatchFromResolvedSnippet("echo {{value}}"));
    }

    [Fact]
    public async Task DiagnosticsCopyExportsSanitizedRuntimeState()
    {
        var viewModel = CreateViewModel();
        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);
        viewModel.OpenTerminalCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsTerminalOpen);
        viewModel.OpenSftpCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsSftpOpen);

        viewModel.CommandText = "cat /var/log/auth.log";
        viewModel.SendCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.CommandText.Length == 0);
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
        Assert.Contains("\"docker_stats_count\": 0", json);
        Assert.Contains("\"has_docker_log_preview\": true", json);
        Assert.Contains("\"sftp_entry_count\": 0", json);
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
        Assert.Equal("Monitor idle", viewModel.MonitorStatus);
        Assert.Equal("No monitor snapshot", viewModel.MonitorSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.True(viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));

        viewModel.RefreshMonitorSnapshotCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.MonitorStatus.StartsWith("Monitor snapshot ", StringComparison.Ordinal));

        Assert.Equal(1, coreClient.MonitorSnapshotCallCount);
        Assert.Contains("CPU 12.5%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("MEM 48%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("Disk 61%", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("ping n/a", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Contains("ping_unavailable", viewModel.MonitorSummary, StringComparison.Ordinal);
        Assert.Equal("Monitor snapshot ready", viewModel.SessionActionSummary);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("Monitor idle", viewModel.MonitorStatus);
        Assert.Equal("No monitor snapshot", viewModel.MonitorSummary);
        Assert.False(viewModel.RefreshMonitorSnapshotCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerContainerListRequiresVerifiedSessionAndShowsContainers()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.RefreshDockerContainersCommand.CanExecute(null));
        Assert.Equal("Docker idle", viewModel.DockerStatus);
        Assert.Equal("No Docker containers", viewModel.DockerSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.True(viewModel.RefreshDockerContainersCommand.CanExecute(null));

        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerStatus == "Docker containers refreshed");

        Assert.Equal(1, coreClient.DockerListCallCount);
        Assert.Equal("2 Docker containers", viewModel.DockerSummary);
        Assert.Equal(2, viewModel.DockerContainers.Count);
        Assert.Equal("web", viewModel.DockerContainers[0].Name);
        Assert.Equal("nginx:stable", viewModel.DockerContainers[0].Image);
        Assert.Equal("running", viewModel.DockerContainers[0].State);
        Assert.Equal("abcdef123456", viewModel.DockerContainers[0].ShortId);
        Assert.Equal("Docker list ready", viewModel.SessionActionSummary);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("Docker idle", viewModel.DockerStatus);
        Assert.Equal("No Docker containers", viewModel.DockerSummary);
        Assert.Empty(viewModel.DockerContainers);
        Assert.False(viewModel.RefreshDockerContainersCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerStatsRequiresVerifiedSessionAndShowsReadOnlySnapshot()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.RefreshDockerStatsCommand.CanExecute(null));
        Assert.Equal("Docker idle", viewModel.DockerStatus);
        Assert.Equal("No Docker stats", viewModel.DockerStatsSummary);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.True(viewModel.RefreshDockerStatsCommand.CanExecute(null));

        viewModel.RefreshDockerStatsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerStatus == "Docker stats refreshed");

        Assert.Equal(1, coreClient.DockerStatsCallCount);
        Assert.Equal("2 Docker stats", viewModel.DockerStatsSummary);
        Assert.Equal(2, viewModel.DockerStats.Count);
        Assert.Equal("web", viewModel.DockerStats[0].Name);
        Assert.Equal("12.5%", viewModel.DockerStats[0].CpuPercent);
        Assert.Equal("48%", viewModel.DockerStats[0].MemoryPercent);
        Assert.Equal("128MiB / 256MiB", viewModel.DockerStats[0].MemoryUsage);
        Assert.Equal("1.2kB / 2.3kB", viewModel.DockerStats[0].NetworkIo);
        Assert.Equal("4.5kB / 6.7kB", viewModel.DockerStats[0].BlockIo);
        Assert.Equal("7", viewModel.DockerStats[0].Pids);
        Assert.Equal("Docker stats ready", viewModel.SessionActionSummary);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("Docker idle", viewModel.DockerStatus);
        Assert.Equal("No Docker stats", viewModel.DockerStatsSummary);
        Assert.Empty(viewModel.DockerStats);
        Assert.False(viewModel.RefreshDockerStatsCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerLogsRequireSelectedContainerAndShowBoundedPreview()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));
        Assert.Equal("No Docker log preview", viewModel.DockerLogStatus);
        Assert.Equal(string.Empty, viewModel.DockerLogText);

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));

        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);

        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];
        Assert.True(viewModel.PreviewDockerLogsCommand.CanExecute(null));

        viewModel.PreviewDockerLogsCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerLogStatus == "Docker log preview abcdef123456");

        Assert.Equal(1, coreClient.DockerLogsCallCount);
        Assert.Equal("abcdef1234567890", coreClient.LastDockerLogsContainerId);
        Assert.Equal(100U, coreClient.LastDockerLogsTailLines);
        Assert.Equal("line one\nline two\n", viewModel.DockerLogText);
        Assert.Equal("Docker logs ready", viewModel.SessionActionSummary);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.Equal("No Docker log preview", viewModel.DockerLogStatus);
        Assert.Equal(string.Empty, viewModel.DockerLogText);
        Assert.Null(viewModel.SelectedDockerContainer);
        Assert.False(viewModel.PreviewDockerLogsCommand.CanExecute(null));
    }

    [Fact]
    public async Task DockerActionsRequireSelectedContainerAndUseAllowedActionTokens()
    {
        var coreClient = new FakeCheckedCoreClient();
        var viewModel = CreateViewModel(coreClient);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));

        viewModel.Password = "secret";
        viewModel.ConnectCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.IsConnected);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));

        viewModel.RefreshDockerContainersCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerContainers.Count == 2);
        viewModel.SelectedDockerContainer = viewModel.DockerContainers[0];

        Assert.True(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.True(viewModel.RestartDockerContainerCommand.CanExecute(null));

        viewModel.RestartDockerContainerCommand.Execute(null);
        await WaitUntilAsync(() => viewModel.DockerStatus == "Docker restart completed; containers refreshed");

        Assert.Equal(1, coreClient.DockerActionCallCount);
        Assert.Equal(2, coreClient.DockerListCallCount);
        Assert.Equal("abcdef1234567890", coreClient.LastDockerActionContainerId);
        Assert.Equal("restart", coreClient.LastDockerAction);
        Assert.NotNull(viewModel.SelectedDockerContainer);
        Assert.Equal("abcdef1234567890", viewModel.SelectedDockerContainer.Id);
        Assert.Equal("Docker restart ready", viewModel.SessionActionSummary);

        viewModel.EndSessionCommand.Execute(null);
        await WaitUntilAsync(() => !viewModel.IsConnected);

        Assert.False(viewModel.StartDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.StopDockerContainerCommand.CanExecute(null));
        Assert.False(viewModel.RestartDockerContainerCommand.CanExecute(null));
    }

    private static MainWindowViewModel CreateViewModel(
        FakeCheckedCoreClient? coreClient = null,
        MemoryCredentialVault? credentialVault = null,
        IServerAssetStore? assetStore = null,
        ISnippetStore? snippetStore = null,
        bool seedDefaultAsset = true)
    {
        credentialVault ??= new MemoryCredentialVault();
        var orchestrator = new SessionOrchestrator(
            coreClient ?? new FakeCheckedCoreClient(),
            credentialVault,
            new FakeKnownHostsPathProvider(),
            new VerifiedSessionRegistry(),
            new TerminalSessionRegistry());

        var viewModel = new MainWindowViewModel(orchestrator, credentialVault, assetStore, snippetStore);
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

        public int CloseTerminalCallCount { get; private set; }
        public int OpenSftpCallCount { get; private set; }
        public int UploadSftpFileCallCount { get; private set; }
        public int RemoveSftpEntryCallCount { get; private set; }
        public int ChangeSftpPermissionsCallCount { get; private set; }
        public int MonitorSnapshotCallCount { get; private set; }
        public int DockerListCallCount { get; private set; }
        public int DockerStatsCallCount { get; private set; }
        public int DockerLogsCallCount { get; private set; }
        public int DockerActionCallCount { get; private set; }
        public string LastDockerLogsContainerId { get; private set; } = string.Empty;
        public uint LastDockerLogsTailLines { get; private set; }
        public string LastDockerActionContainerId { get; private set; } = string.Empty;
        public string LastDockerAction { get; private set; } = string.Empty;
        public ulong LastOpenedTerminalChannelId { get; private set; }
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
            return new CheckedConnectOutcome.Connected(new ConnectedPayload(
                "9",
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
            return new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
                baseSessionId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                LastOpenedTerminalChannelId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                CheckedSecurityGeneration.HostKeyVerified,
                columns,
                rows));
        }

        public TerminalControlResult WriteTerminal(ulong terminalChannelId, ReadOnlyMemory<byte> data)
        {
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

        public CheckedEnvelope UploadSftpFile(ulong sftpSessionId, string localPath, string remotePath, HostKeyRequestId requestId)
        {
            UploadSftpFileCallCount++;
            LastSftpUploadSessionId = sftpSessionId;
            LastSftpUploadLocalPath = localPath;
            LastSftpUploadRemotePath = remotePath;
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
                    "tx_rate_kbps": 2.5
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
            LastExecCommand = command;
            return CreateEnvelope(
                CheckedFfiKind.ExecResult,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "security_generation": "host_key_verified",
                  "exit_status": 0,
                  "stdout": "batch output\n",
                  "stderr": "",
                  "timed_out": false,
                  "stdout_truncated": false,
                  "stderr_truncated": false
                }
                """);
        }

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

        public Guid LastDeletedCredentialId { get; private set; }

        public ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            return ValueTask.FromResult(credential);
        }

        public ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken)
        {
            LastSavedCredentialId = credentialId;
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
