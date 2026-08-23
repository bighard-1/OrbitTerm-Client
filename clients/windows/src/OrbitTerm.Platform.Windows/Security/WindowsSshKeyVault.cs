using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Security;

namespace OrbitTerm.Platform.Windows.Security;

/// <summary>
/// Current-user DPAPI vault for reusable SSH keys. Metadata and key material
/// share one encrypted document so names, assignments and fingerprints never
/// appear in ordinary JSON configuration.
/// </summary>
public sealed class WindowsSshKeyVault : ISshKeyVault
{
    private const int SchemaVersion = 1;
    private const int MaximumKeyCount = 128;
    private const long MaximumEncryptedBytes = 32 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    private readonly string path;
    private readonly SemaphoreSlim gate = new(1, 1);

    public WindowsSshKeyVault()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OrbitTerm",
            "Security",
            "ssh-key-library.dpapi"))
    {
    }

    internal WindowsSshKeyVault(string path)
    {
        this.path = string.IsNullOrWhiteSpace(path)
            ? throw new ArgumentException("SSH key vault path must not be empty.", nameof(path))
            : path;
    }

    public async ValueTask<IReadOnlyList<SshKeyRecord>> ListAsync(CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = await ReadDocumentAsync(cancellationToken).ConfigureAwait(false);
            return document.Keys
                .Select(ToEntry)
                .Select(item => item.Record)
                .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(item => item.Id)
                .ToArray();
        }
        finally
        {
            gate.Release();
        }
    }

    public async ValueTask<SshKeyVaultEntry?> ReadAsync(Guid keyId, CancellationToken cancellationToken)
    {
        ValidateKeyId(keyId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = await ReadDocumentAsync(cancellationToken).ConfigureAwait(false);
            var item = document.Keys.SingleOrDefault(candidate => candidate.Id == keyId);
            return item is null ? null : ToEntry(item);
        }
        finally
        {
            gate.Release();
        }
    }

    public async ValueTask SaveAsync(SshKeyVaultEntry entry, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ValidateKeyId(entry.Record.Id);
        var normalized = Normalize(entry);

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = await ReadDocumentAsync(cancellationToken).ConfigureAwait(false);
            var keys = document.Keys.Where(item => item.Id != normalized.Record.Id).ToList();
            if (keys.Count >= MaximumKeyCount)
            {
                throw new InvalidOperationException($"密钥库最多保存 {MaximumKeyCount} 个密钥。");
            }

            keys.Add(ToStored(normalized));
            await WriteDocumentAsync(new StoredDocument(SchemaVersion, keys), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public async ValueTask DeleteAsync(Guid keyId, CancellationToken cancellationToken)
    {
        ValidateKeyId(keyId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = await ReadDocumentAsync(cancellationToken).ConfigureAwait(false);
            var keys = document.Keys.Where(item => item.Id != keyId).ToArray();
            if (keys.Length == document.Keys.Count)
            {
                return;
            }

            await WriteDocumentAsync(new StoredDocument(SchemaVersion, keys), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    private async ValueTask<StoredDocument> ReadDocumentAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return new StoredDocument(SchemaVersion, []);
        }

        var file = new FileInfo(path);
        if (file.Length is <= 0 or > MaximumEncryptedBytes)
        {
            throw new InvalidDataException("SSH key vault size is invalid.");
        }

        var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        byte[] plaintext = [];
        try
        {
            plaintext = WindowsDpapi.Unprotect(encrypted);
            var document = JsonSerializer.Deserialize<StoredDocument>(plaintext, JsonOptions)
                ?? throw new InvalidDataException("SSH key vault is empty.");
            if (document.Version != SchemaVersion || document.Keys is null || document.Keys.Count > MaximumKeyCount)
            {
                throw new InvalidDataException("SSH key vault version or item count is invalid.");
            }

            return document;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private async ValueTask WriteDocumentAsync(StoredDocument document, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
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
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static SshKeyVaultEntry Normalize(SshKeyVaultEntry entry)
    {
        var privateKey = SshKeyMaterialPolicy.NormalizePrivateKey(entry.Secret.PrivateKey);
        var record = entry.Record with
        {
            Name = SshKeyMaterialPolicy.NormalizeName(entry.Record.Name),
            Format = SshKeyMaterialPolicy.DetectContainer(privateKey),
            MaterialFingerprint = SshKeyMaterialPolicy.MaterialFingerprint(privateKey),
            AssignedAssetIds = entry.Record.AssignedAssetIds
                .Where(id => id != Guid.Empty)
                .Distinct()
                .Order()
                .Take(512)
                .ToArray(),
        };
        return new SshKeyVaultEntry(
            record,
            new SshKeySecret(privateKey, SshKeyMaterialPolicy.NormalizePassphrase(entry.Secret.Passphrase)));
    }

    private static StoredKey ToStored(SshKeyVaultEntry entry) => new(
        entry.Record.Id,
        entry.Record.Name,
        entry.Record.Format,
        entry.Record.MaterialFingerprint,
        entry.Record.CreatedAt,
        entry.Record.UpdatedAt,
        entry.Record.Origin,
        entry.Record.AssignedAssetIds,
        entry.Record.SyncScope,
        entry.Record.OwnerAccountScope,
        entry.Secret.PrivateKey,
        entry.Secret.Passphrase);

    private static SshKeyVaultEntry ToEntry(StoredKey key) => Normalize(new SshKeyVaultEntry(
        new SshKeyRecord(
            key.Id,
            key.Name,
            key.Format,
            key.MaterialFingerprint,
            key.CreatedAt,
            key.UpdatedAt,
            key.Origin,
            key.AssignedAssetIds ?? [],
            key.SyncScope,
            key.OwnerAccountScope),
        new SshKeySecret(key.PrivateKey, key.Passphrase)));

    private static void ValidateKeyId(Guid keyId)
    {
        if (keyId == Guid.Empty)
        {
            throw new ArgumentException("SSH key identifier must not be empty.", nameof(keyId));
        }
    }

    private sealed record StoredDocument(int Version, IReadOnlyList<StoredKey> Keys);

    private sealed record StoredKey(
        Guid Id,
        string Name,
        string Format,
        string MaterialFingerprint,
        DateTimeOffset CreatedAt,
        DateTimeOffset UpdatedAt,
        SshKeyOrigin Origin,
        IReadOnlyList<Guid>? AssignedAssetIds,
        SshKeySyncScope SyncScope,
        string? OwnerAccountScope,
        string PrivateKey,
        string Passphrase);
}
