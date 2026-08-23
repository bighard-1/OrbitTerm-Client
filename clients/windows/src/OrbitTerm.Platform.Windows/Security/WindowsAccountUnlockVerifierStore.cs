using OrbitTerm.Application.Accounts;

namespace OrbitTerm.Platform.Windows.Security;

public sealed class WindowsAccountUnlockVerifierStore : IAccountUnlockVerifierStore
{
    private readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OrbitTerm", "Account", "verifiers");
    public async ValueTask<byte[]?> ReadAsync(string scope, CancellationToken cancellationToken)
    {
        var path = Path.Combine(directory, scope + ".dpapi");
        if (!File.Exists(path)) return null;
        var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        return WindowsDpapi.Unprotect(encrypted);
    }
    public async ValueTask SaveAsync(string scope, byte[] verifier, CancellationToken cancellationToken)
    {
        if (verifier.Length != 32) throw new ArgumentException("验证器长度无效。", nameof(verifier));
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, scope + ".dpapi");
        var temporary = string.Concat(destination, ".", Guid.NewGuid().ToString("N"), ".tmp");
        var protectedVerifier = WindowsDpapi.Protect(verifier);
        try
        {
            await File.WriteAllBytesAsync(temporary, protectedVerifier, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(protectedVerifier);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
