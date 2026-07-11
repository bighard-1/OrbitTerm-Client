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
    string ModifiedText);
