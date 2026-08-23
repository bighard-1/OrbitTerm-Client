using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Accounts;

namespace OrbitTerm.Platform.Windows.Security;

/// <summary>DPAPI-protected acknowledgement cursor, isolated per account scope.</summary>
public sealed class WindowsEncryptedSyncStateStore : IEncryptedSyncStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "Account",
        "sync-state");

    public async ValueTask<EncryptedSyncState?> ReadAsync(string accountScope, CancellationToken cancellationToken)
    {
        var path = PathFor(accountScope);
        if (!File.Exists(path)) return null;

        var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        var plaintext = WindowsDpapi.Unprotect(encrypted);
        try
        {
            var state = JsonSerializer.Deserialize<EncryptedSyncState>(plaintext, JsonOptions);
            return state is null || state.DeviceId == Guid.Empty ? null : state;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public async ValueTask SaveAsync(string accountScope, EncryptedSyncState state, CancellationToken cancellationToken)
    {
        if (state.DeviceId == Guid.Empty) throw new ArgumentException("同步设备标识无效。", nameof(state));
        var path = PathFor(accountScope);
        Directory.CreateDirectory(directory);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions);
        byte[] encrypted = [];
        var temporaryPath = string.Concat(path, ".", Guid.NewGuid().ToString("N"), ".tmp");
        try
        {
            encrypted = WindowsDpapi.Protect(plaintext);
            await File.WriteAllBytesAsync(temporaryPath, encrypted, cancellationToken).ConfigureAwait(false);
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(encrypted);
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private string PathFor(string accountScope)
    {
        if (accountScope.Length != 64 || !accountScope.All(Uri.IsHexDigit))
        {
            throw new ArgumentException("账户同步作用域无效。", nameof(accountScope));
        }

        return Path.Combine(directory, string.Concat(accountScope.ToLowerInvariant(), ".dpapi"));
    }
}
