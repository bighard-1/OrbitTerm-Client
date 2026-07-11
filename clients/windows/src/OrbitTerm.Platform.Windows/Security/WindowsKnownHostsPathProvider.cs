using OrbitTerm.Application.Security;

namespace OrbitTerm.Platform.Windows.Security;

public sealed class WindowsKnownHostsPathProvider : IKnownHostsPathProvider
{
    private const string FileName = "known_hosts";

    public string GetKnownHostsPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var directory = Path.Combine(root, "OrbitTerm", "security");
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, FileName);
    }
}
