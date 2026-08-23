using System.Text.Json;
using OrbitTerm.Application.Accounts;

namespace OrbitTerm.Platform.Windows.Security;

/// <summary>
/// Persists the account refresh material separately from server credentials.
/// DPAPI binds the blob to the current Windows user profile.
/// </summary>
public sealed class WindowsAccountSessionStore : IAccountSessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string path;

    public WindowsAccountSessionStore()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OrbitTerm",
            "Account",
            "session.dpapi"))
    {
    }

    internal WindowsAccountSessionStore(string path)
    {
        this.path = string.IsNullOrWhiteSpace(path)
            ? throw new ArgumentException("Account session path must not be empty.", nameof(path))
            : path;
    }

    public async ValueTask<AccountSessionRecord?> ReadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(path))
        {
            return null;
        }

        var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        if (encrypted.Length == 0)
        {
            return null;
        }

        var plaintext = WindowsDpapi.Unprotect(encrypted);
        try
        {
            var session = JsonSerializer.Deserialize<AccountSessionRecord>(plaintext, JsonOptions);
            return IsValid(session) ? session : null;
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
        }
    }

    public async ValueTask SaveAsync(AccountSessionRecord session, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsValid(session))
        {
            throw new ArgumentException("Account session is incomplete or incompatible.", nameof(session));
        }

        var plaintext = JsonSerializer.SerializeToUtf8Bytes(session, JsonOptions);
        try
        {
            var encrypted = WindowsDpapi.Protect(plaintext);
            var directory = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(directory);
            var temporaryPath = string.Concat(path, ".", Guid.NewGuid().ToString("N"), ".tmp");
            try
            {
                await File.WriteAllBytesAsync(temporaryPath, encrypted, cancellationToken).ConfigureAwait(false);
                File.Move(temporaryPath, path, true);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
        }
    }

    public ValueTask ClearAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        return ValueTask.CompletedTask;
    }

    private static bool IsValid(AccountSessionRecord? session) =>
        session is { ProtocolVersion: AccountProtocolContracts.Version } &&
        !string.IsNullOrWhiteSpace(session.Username) &&
        !string.IsNullOrWhiteSpace(session.AccessToken) &&
        !string.IsNullOrWhiteSpace(session.RefreshToken);
}
