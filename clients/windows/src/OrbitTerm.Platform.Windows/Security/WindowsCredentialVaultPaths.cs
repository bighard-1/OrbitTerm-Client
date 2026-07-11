namespace OrbitTerm.Platform.Windows.Security;

internal static class WindowsCredentialVaultPaths
{
    public static string DefaultDirectory
    {
        get
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(localAppData))
            {
                throw new InvalidOperationException("Local application data directory is unavailable.");
            }

            return Path.Combine(localAppData, "OrbitTerm", "Credentials");
        }
    }
}
