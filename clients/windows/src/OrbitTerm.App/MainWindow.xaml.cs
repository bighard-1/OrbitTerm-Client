using System.Reflection;
using System.Windows.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public sealed partial class MainWindow : Window
{
    public const int MinimumWindowWidth = 960;
    public const int MinimumWindowHeight = 640;

    private const string PreviousCommandHistoryCommandName = "PreviousCommandHistoryCommand";
    private const string NextCommandHistoryCommandName = "NextCommandHistoryCommand";
    private bool isSftpDialogOpen;
    private bool isSnippetDialogOpen;

    public MainWindow(
        SessionOrchestrator orchestrator,
        ICredentialVault credentialVault,
        IServerAssetStore serverAssetStore,
        ISnippetStore snippetStore)
    {
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(MinimumWindowWidth, MinimumWindowHeight));
        ViewModel = new MainWindowViewModel(
            orchestrator,
            credentialVault,
            serverAssetStore,
            snippetStore,
            action => DispatcherQueue.TryEnqueue(() => action()));
        Root.DataContext = ViewModel;
        ViewModel.PropertyChanged += ViewModelPropertyChanged;
        ViewModel.TerminalLines.CollectionChanged += TerminalLinesCollectionChanged;
        ViewModel.LoadAssetsCommand.Execute(null);
        ViewModel.LoadSnippetsCommand.Execute(null);
    }

    public MainWindowViewModel ViewModel { get; }

    private void PasswordBoxPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (sender is PasswordBox passwordBox)
        {
            ViewModel.Password = passwordBox.Password;
        }
    }

    private void ViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainWindowViewModel.Password) &&
            ViewModel.Password.Length == 0 &&
            CredentialPasswordBox.Password.Length != 0)
        {
            CredentialPasswordBox.Password = string.Empty;
        }
    }

    private void CommandTextBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Up && TryExecuteViewModelCommand(PreviousCommandHistoryCommandName))
        {
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Down && TryExecuteViewModelCommand(NextCommandHistoryCommandName))
        {
            e.Handled = true;
        }
    }

    private async void CommandTextBoxPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        if (sender is not TextBox textBox)
        {
            return;
        }

        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text))
        {
            ViewModel.ApplyCommandPaste(string.Empty, textBox.SelectionStart, textBox.SelectionLength);
            return;
        }

        var pastedText = await content.GetTextAsync();
        var edit = ViewModel.ApplyCommandPaste(pastedText, textBox.SelectionStart, textBox.SelectionLength);
        textBox.SelectionStart = edit.CaretIndex;
        textBox.SelectionLength = 0;
    }

    private void CopyTerminalOutputClick(object sender, RoutedEventArgs e)
    {
        var transcript = ViewModel.PrepareTerminalTranscriptCopy();
        if (transcript.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(transcript);
        Clipboard.SetContent(package);
    }

    private void CopySftpPreviewClick(object sender, RoutedEventArgs e)
    {
        var preview = ViewModel.PrepareSftpPreviewCopy();
        if (preview.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(preview);
        Clipboard.SetContent(package);
    }

    private async void SaveSftpPreviewClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.CanSaveSftpPreview)
        {
            await ViewModel.SaveSftpPreviewAsync(CancellationToken.None);
        }
    }

    private void RevertSftpPreviewClick(object sender, RoutedEventArgs e)
    {
        ViewModel.RevertSftpPreviewChanges();
    }

    private async void DownloadSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanDownloadSelectedSftpEntry || selected is null)
        {
            return;
        }

        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
        {
            var localPath = System.IO.Path.Combine(folder.Path, selected.Name);
            await ViewModel.DownloadSelectedSftpEntryAsync(localPath, CancellationToken.None);
        }
    }

    private async void UploadSftpFileClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            await ViewModel.UploadSftpFileAsync(file.Path, file.Name, CancellationToken.None);
        }
    }

    private async void CreateSftpDirectoryClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        var directoryName = await ShowSftpNameDialogAsync(
            "New folder",
            "Folder name",
            string.Empty,
            "Create");
        if (directoryName is not null)
        {
            await ViewModel.CreateSftpDirectoryAsync(directoryName, CancellationToken.None);
        }
    }

    private async void CreateSftpFileClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.IsSftpOpen)
        {
            return;
        }

        var fileName = await ShowSftpNameDialogAsync(
            "New file",
            "File name",
            string.Empty,
            "Create");
        if (fileName is not null)
        {
            await ViewModel.CreateSftpFileAsync(fileName, CancellationToken.None);
        }
    }

    private async void RenameSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanMutateSelectedSftpEntry || selected is null)
        {
            return;
        }

        var newName = await ShowSftpNameDialogAsync(
            "Rename entry",
            "New name",
            selected.Name,
            "Rename");
        if (newName is not null)
        {
            await ViewModel.RenameSelectedSftpEntryAsync(newName, CancellationToken.None);
        }
    }

    private async void RemoveSelectedSftpEntryClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanMutateSelectedSftpEntry || selected is null || isSftpDialogOpen)
        {
            return;
        }

        isSftpDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = selected.IsDirectory ? "Delete empty folder?" : "Delete file?",
                Content = new TextBlock
                {
                    Text = selected.Name,
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = "Delete",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await ViewModel.RemoveSelectedSftpEntryConfirmedAsync(selected, CancellationToken.None);
            }
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async void ChangeSelectedSftpPermissionsClick(object sender, RoutedEventArgs e)
    {
        var selected = ViewModel.SelectedSftpEntry;
        if (!ViewModel.CanChangeSelectedSftpPermissions || selected is null)
        {
            return;
        }

        var initialMode = Convert.ToString((long)(selected.PermissionsOctal & 0xFFFU), 8)
            .PadLeft(3, '0');
        var mode = await ShowSftpNameDialogAsync(
            "Change permissions",
            "Octal mode",
            initialMode,
            "Apply");
        if (mode is not null)
        {
            await ViewModel.ChangeSelectedSftpPermissionsConfirmedAsync(
                selected,
                mode,
                CancellationToken.None);
        }
    }

    private async Task<string?> ShowSftpNameDialogAsync(
        string title,
        string header,
        string initialValue,
        string primaryButtonText)
    {
        if (isSftpDialogOpen)
        {
            return null;
        }

        isSftpDialogOpen = true;
        try
        {
            var input = new TextBox
            {
                Header = header,
                Text = initialValue,
                MaxLength = 255,
            };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = title,
                Content = input,
                PrimaryButtonText = primaryButtonText,
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            return await dialog.ShowAsync() == ContentDialogResult.Primary
                ? input.Text
                : null;
        }
        finally
        {
            isSftpDialogOpen = false;
        }
    }

    private async void CreateSnippetClick(object sender, RoutedEventArgs e)
    {
        await ShowSnippetEditorAsync(null);
    }

    private async void EditSnippetClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedSnippet is { } selected)
        {
            await ShowSnippetEditorAsync(selected);
        }
    }

    private async Task ShowSnippetEditorAsync(SnippetViewModel? selected)
    {
        if (isSnippetDialogOpen)
        {
            return;
        }

        isSnippetDialogOpen = true;
        try
        {
            var titleBox = new TextBox
            {
                Header = "Title",
                MaxLength = 120,
                Text = selected?.Title ?? string.Empty,
            };
            var categoryBox = new TextBox
            {
                Header = "Category",
                MaxLength = 80,
                Text = selected?.Category ?? "Uncategorized",
            };
            var commandBox = new TextBox
            {
                Header = "Command",
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
                MaxLength = 8192,
                Text = selected?.Command ?? string.Empty,
            };
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(titleBox);
            content.Children.Add(categoryBox);
            content.Children.Add(commandBox);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = selected is null ? "New Snippet" : "Edit Snippet",
                Content = content,
                PrimaryButtonText = "Save",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await ViewModel.SaveSnippetAsync(
                    selected?.Id,
                    titleBox.Text,
                    commandBox.Text,
                    categoryBox.Text,
                    CancellationToken.None);
            }
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private async void DeleteSnippetClick(object sender, RoutedEventArgs e)
    {
        if (isSnippetDialogOpen || ViewModel.SelectedSnippet is not { } selected)
        {
            return;
        }

        isSnippetDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Delete Snippet?",
                Content = string.Concat("Delete ", selected.Title, " from this device?"),
                PrimaryButtonText = "Delete",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
                ViewModel.SelectedSnippet?.Id == selected.Id &&
                ViewModel.DeleteSnippetCommand.CanExecute(null))
            {
                ViewModel.DeleteSnippetCommand.Execute(null);
            }
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private async void InsertSnippetClick(object sender, RoutedEventArgs e)
    {
        var command = await ResolveSelectedSnippetAsync();
        if (command is not null)
        {
            ViewModel.InsertResolvedSnippet(command);
        }
    }

    private async void ExecuteSnippetClick(object sender, RoutedEventArgs e)
    {
        var command = await ResolveSelectedSnippetAsync();
        if (command is not null)
        {
            await ViewModel.ExecuteResolvedSnippetAsync(command, CancellationToken.None);
        }
    }

    private async void FillBatchFromSnippetClick(object sender, RoutedEventArgs e)
    {
        var command = await ResolveSelectedSnippetAsync();
        if (command is not null)
        {
            ViewModel.FillBatchFromResolvedSnippet(command);
        }
    }

    private async Task<string?> ResolveSelectedSnippetAsync()
    {
        if (isSnippetDialogOpen || ViewModel.SelectedSnippet is not { } selected)
        {
            return null;
        }

        var variables = SnippetVariableResolver.Extract(selected.Command);
        if (variables.Count == 0)
        {
            return selected.Command;
        }

        isSnippetDialogOpen = true;
        try
        {
            var inputs = new Dictionary<string, TextBox>(StringComparer.Ordinal);
            var content = new StackPanel { Spacing = 12 };
            foreach (var variable in variables)
            {
                var input = new TextBox
                {
                    Header = variable,
                    MaxLength = 1024,
                };
                inputs.Add(variable, input);
                content.Children.Add(input);
            }

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Snippet Variables",
                Content = content,
                PrimaryButtonText = "Apply",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return null;
            }

            var values = inputs.ToDictionary(item => item.Key, item => item.Value.Text, StringComparer.Ordinal);
            return SnippetVariableResolver.Resolve(selected.Command, values);
        }
        catch (ArgumentException)
        {
            return null;
        }
        finally
        {
            isSnippetDialogOpen = false;
        }
    }

    private void CopyDiagnosticsClick(object sender, RoutedEventArgs e)
    {
        var diagnostics = ViewModel.PrepareDiagnosticsBundleCopy();
        var package = new DataPackage();
        package.SetText(diagnostics);
        Clipboard.SetContent(package);
    }

    private void SelectWorkspaceTab1Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(0);
    }

    private void SelectWorkspaceTab2Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(1);
    }

    private void SelectWorkspaceTab3Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(2);
    }

    private void SelectWorkspaceTab4Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(3);
    }

    private void SelectWorkspaceTab5Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(4);
    }

    private void SelectWorkspaceTab6Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(5);
    }

    private void SelectWorkspaceTab7Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(6);
    }

    private void SelectWorkspaceTab8Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(7);
    }

    private void SelectWorkspaceTab9Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectWorkspaceTabAt(8);
    }

    private void TerminalLinesCollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (!ViewModel.IsAutoScrollEnabled)
        {
            return;
        }

        TerminalScrollViewer.ChangeView(null, TerminalScrollViewer.ScrollableHeight, null, true);
    }

    private void SftpPathTextBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && TryExecuteViewModelCommand("PrepareSftpBrowseCommand"))
        {
            e.Handled = true;
        }
    }

    private void SftpEntriesDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (TryExecuteViewModelCommand("OpenSelectedSftpEntryCommand"))
        {
            e.Handled = true;
        }
    }

    private bool TryExecuteViewModelCommand(string propertyName)
    {
        var property = typeof(MainWindowViewModel).GetProperty(
            propertyName,
            BindingFlags.Instance | BindingFlags.Public);
        if (property?.GetValue(ViewModel) is not ICommand command || !command.CanExecute(null))
        {
            return false;
        }

        command.Execute(null);
        return true;
    }
}
