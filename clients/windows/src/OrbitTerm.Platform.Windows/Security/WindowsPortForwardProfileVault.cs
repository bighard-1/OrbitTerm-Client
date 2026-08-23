using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Accounts;

namespace OrbitTerm.Platform.Windows.Security;

/// <summary>Current-user DPAPI storage, physically isolated by account scope.</summary>
public sealed class WindowsPortForwardProfileVault : IPortForwardProfileVault
{
    private const long MaximumBytes = 4 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    private readonly string directory;
    private readonly SemaphoreSlim gate = new(1, 1);

    public WindowsPortForwardProfileVault() : this(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm", "Security", "port-forward-profiles")) { }

    internal WindowsPortForwardProfileVault(string directory) => this.directory = directory;

    public async ValueTask<PortForwardProfileVaultDocument> ReadAsync(string accountScope, CancellationToken cancellationToken)
    {
        var path = PathFor(accountScope);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(path)) return Empty();
            if (new FileInfo(path).Length is <= 0 or > MaximumBytes) throw new InvalidDataException("端口映射配置库大小无效。");
            var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
            byte[] plaintext = [];
            try
            {
                plaintext = WindowsDpapi.Unprotect(encrypted);
                var document = JsonSerializer.Deserialize<PortForwardProfileVaultDocument>(plaintext, JsonOptions)
                    ?? throw new InvalidDataException("端口映射配置库为空。");
                if (document.Version != PortForwardProfileLibrary.SchemaVersion || document.Profiles is null || document.Tombstones is null)
                    throw new InvalidDataException("端口映射配置库版本无效。");
                return document;
            }
            finally { CryptographicOperations.ZeroMemory(encrypted); CryptographicOperations.ZeroMemory(plaintext); }
        }
        finally { gate.Release(); }
    }

    public async ValueTask SaveAsync(string accountScope, PortForwardProfileVaultDocument document, CancellationToken cancellationToken)
    {
        var path = PathFor(accountScope);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(directory);
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
            byte[] encrypted = [];
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                encrypted = WindowsDpapi.Protect(plaintext);
                await File.WriteAllBytesAsync(temporary, encrypted, cancellationToken).ConfigureAwait(false);
                File.Move(temporary, path, true);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plaintext); CryptographicOperations.ZeroMemory(encrypted);
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        finally { gate.Release(); }
    }

    public async ValueTask DeleteAccountAsync(string accountScope, CancellationToken cancellationToken)
    {
        var path = PathFor(accountScope);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { if (File.Exists(path)) File.Delete(path); }
        finally { gate.Release(); }
    }

    private string PathFor(string scope)
    {
        if (scope.Length != 64 || !scope.All(Uri.IsHexDigit)) throw new ArgumentException("账户同步作用域无效。", nameof(scope));
        return Path.Combine(directory, scope.ToLowerInvariant() + ".dpapi");
    }

    private static PortForwardProfileVaultDocument Empty() => new(PortForwardProfileLibrary.SchemaVersion, [], new Dictionary<Guid, long>());
}
