using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SftpContextMenuPolicyTests
{
    [Fact]
    public void FileContextOnlyExposesFileSpecificSingleItemActions()
    {
        var file = CreateEntry("notes.txt", "/srv/notes.txt", isDirectory: false);

        var policy = SftpContextMenuPolicy.Resolve(file, [file]);

        Assert.False(policy.PreserveExistingSelection);
        Assert.False(policy.ShowEnterDirectory);
        Assert.True(policy.ShowPreviewOrEdit);
        Assert.True(policy.ShowRename);
        Assert.True(policy.ShowPermissions);
        Assert.Equal("下载文件", policy.DownloadText);
        Assert.Equal("重命名文件", policy.RenameText);
        Assert.Equal("修改文件权限", policy.PermissionsText);
        Assert.Equal("删除文件", policy.DeleteText);
    }

    [Fact]
    public void DirectoryContextOnlyExposesDirectorySpecificSingleItemActions()
    {
        var directory = CreateEntry("logs", "/srv/logs", isDirectory: true);

        var policy = SftpContextMenuPolicy.Resolve(directory, [directory]);

        Assert.False(policy.ShowPreviewOrEdit);
        Assert.True(policy.ShowEnterDirectory);
        Assert.Equal("下载文件夹", policy.DownloadText);
        Assert.Equal("重命名文件夹", policy.RenameText);
        Assert.Equal("修改文件夹权限", policy.PermissionsText);
        Assert.Equal("删除文件夹", policy.DeleteText);
    }

    [Fact]
    public void ExistingMixedSelectionOnlyExposesBatchActions()
    {
        var file = CreateEntry("notes.txt", "/srv/notes.txt", isDirectory: false);
        var directory = CreateEntry("logs", "/srv/logs", isDirectory: true);

        var policy = SftpContextMenuPolicy.Resolve(directory, [file, directory]);

        Assert.True(policy.PreserveExistingSelection);
        Assert.Equal(2, policy.SelectionCount);
        Assert.False(policy.ShowEnterDirectory);
        Assert.False(policy.ShowPreviewOrEdit);
        Assert.False(policy.ShowRename);
        Assert.False(policy.ShowPermissions);
        Assert.Equal("下载所选 2 项", policy.DownloadText);
        Assert.Equal("删除所选 2 项", policy.DeleteText);
    }

    [Fact]
    public void ContextOutsideExistingSelectionBecomesTheOnlyTarget()
    {
        var first = CreateEntry("one.txt", "/srv/one.txt", isDirectory: false);
        var second = CreateEntry("two.txt", "/srv/two.txt", isDirectory: false);
        var directory = CreateEntry("logs", "/srv/logs", isDirectory: true);

        var policy = SftpContextMenuPolicy.Resolve(directory, [first, second]);

        Assert.False(policy.PreserveExistingSelection);
        Assert.Equal(1, policy.SelectionCount);
        Assert.True(policy.ShowEnterDirectory);
        Assert.Equal("下载文件夹", policy.DownloadText);
    }

    private static SftpDirectoryEntryViewModel CreateEntry(string name, string path, bool isDirectory)
    {
        return new SftpDirectoryEntryViewModel(
            name,
            path,
            isDirectory ? "文件夹" : "文件",
            isDirectory,
            0,
            isDirectory ? 0x41EDU : 0x81A4U,
            0,
            isDirectory ? "—" : "0 B",
            isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
            "—");
    }
}
