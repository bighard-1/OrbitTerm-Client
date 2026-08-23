namespace OrbitTerm.Presentation;

public sealed record SftpDirectoryEntryViewModel(
    string Name,
    string Path,
    string KindText,
    bool IsDirectory,
    ulong Size,
    uint PermissionsOctal,
    ulong ModifiedAtUnix,
    string SizeText,
    string Permissions,
    string ModifiedText)
{
    // Segoe Fluent Icons are the Windows-native icon language. Remote files cannot
    // safely inherit arbitrary application icons, so classify them by extension.
    public string IconGlyph => IsDirectory
        ? ""
        : GetFileIconGlyph(Name);

    public string IconTone => IsDirectory
        ? "Folder"
        : GetFileIconTone(Name);

    public string AccessibilityDescription => IsDirectory
        ? string.Concat("文件夹：", Name, "，权限 ", Permissions, "，修改于 ", ModifiedText)
        : string.Concat("文件：", Name, "，大小 ", SizeText, "，权限 ", Permissions, "，修改于 ", ModifiedText);

    private static string GetFileIconGlyph(string name)
    {
        var extension = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return extension switch
        {
            ".txt" or ".log" or ".md" or ".conf" or ".ini" or ".yaml" or ".yml" => "",
            ".json" or ".xml" or ".html" or ".css" or ".js" or ".ts" or ".cs" or ".rs" or ".py" or ".sh" => "",
            ".jpg" or ".jpeg" or ".png" or ".gif" or ".webp" or ".bmp" or ".svg" => "",
            ".mp3" or ".wav" or ".flac" or ".m4a" or ".ogg" => "",
            ".mp4" or ".mkv" or ".mov" or ".avi" or ".webm" => "",
            ".zip" or ".gz" or ".tar" or ".bz2" or ".xz" or ".7z" or ".rar" => "",
            ".pdf" => "",
            ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx" => "",
            _ => "",
        };
    }

    private static string GetFileIconTone(string name)
    {
        var extension = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return extension switch
        {
            ".jpg" or ".jpeg" or ".png" or ".gif" or ".webp" or ".bmp" or ".svg" => "Image",
            ".mp3" or ".wav" or ".flac" or ".m4a" or ".ogg" => "Media",
            ".mp4" or ".mkv" or ".mov" or ".avi" or ".webm" => "Media",
            ".json" or ".xml" or ".html" or ".css" or ".js" or ".ts" or ".cs" or ".rs" or ".py" or ".sh" => "Code",
            _ => "Document",
        };
    }
}
