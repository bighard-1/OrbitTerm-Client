namespace OrbitTerm.Presentation;

/// <summary>
/// Describes the operations that are meaningful for an SFTP context target.
/// Unsupported operations are omitted from the menu instead of being exposed
/// as misleading disabled commands.
/// </summary>
public sealed record SftpContextMenuPolicy(
    bool PreserveExistingSelection,
    int SelectionCount,
    bool ShowEnterDirectory,
    bool ShowPreviewOrEdit,
    bool ShowRename,
    bool ShowPermissions,
    string DownloadText,
    string RenameText,
    string PermissionsText,
    string DeleteText)
{
    public static SftpContextMenuPolicy Resolve(
        SftpDirectoryEntryViewModel contextEntry,
        IEnumerable<SftpDirectoryEntryViewModel> selectedEntries)
    {
        ArgumentNullException.ThrowIfNull(contextEntry);
        ArgumentNullException.ThrowIfNull(selectedEntries);

        var selection = selectedEntries
            .DistinctBy(static entry => entry.Path, StringComparer.Ordinal)
            .ToList();
        var preserveExistingSelection = selection.Count > 1 &&
            selection.Any(entry => string.Equals(entry.Path, contextEntry.Path, StringComparison.Ordinal));
        var selectionCount = preserveExistingSelection ? selection.Count : 1;
        var isMultiple = selectionCount > 1;
        var objectName = contextEntry.IsDirectory ? "文件夹" : "文件";

        return new SftpContextMenuPolicy(
            preserveExistingSelection,
            selectionCount,
            ShowEnterDirectory: !isMultiple && contextEntry.IsDirectory,
            ShowPreviewOrEdit: !isMultiple && !contextEntry.IsDirectory,
            ShowRename: !isMultiple,
            ShowPermissions: !isMultiple,
            DownloadText: isMultiple ? $"下载所选 {selectionCount} 项" : $"下载{objectName}",
            RenameText: $"重命名{objectName}",
            PermissionsText: $"修改{objectName}权限",
            DeleteText: isMultiple ? $"删除所选 {selectionCount} 项" : $"删除{objectName}");
    }
}
