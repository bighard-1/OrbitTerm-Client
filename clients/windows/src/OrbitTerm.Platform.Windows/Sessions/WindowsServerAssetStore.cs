using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Platform.Windows.Sessions;

public sealed class WindowsServerAssetStore : IServerAssetStore
{
    private const int MaximumAssets = 512;
    private const long MaximumAssetFileBytes = 1024 * 1024;
    private const int MaximumTagsPerAsset = 16;
    private const int MaximumGroupLength = 64;
    private const int MaximumTagLength = 32;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly string filePath;

    public WindowsServerAssetStore()
        : this(DefaultFilePath)
    {
    }

    internal WindowsServerAssetStore(string filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath))
        {
            throw new ArgumentException("Asset file path must not be empty.", nameof(filePath));
        }

        this.filePath = filePath;
    }

    public async ValueTask<IReadOnlyList<ServerAssetRecord>> LoadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(filePath))
        {
            return [];
        }

        var file = new FileInfo(filePath);
        if (file.Length is <= 0 or > MaximumAssetFileBytes)
        {
            throw new InvalidDataException("Server asset file size is invalid.");
        }

        await using var stream = File.OpenRead(filePath);
        var document = await JsonSerializer.DeserializeAsync<ServerAssetDocument>(
            stream,
            JsonOptions,
            cancellationToken).ConfigureAwait(false);

        return NormalizeAssets(document?.Assets ?? []);
    }

    public async ValueTask SaveAsync(IReadOnlyList<ServerAssetRecord> assets, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(assets);
        if (assets.Count > MaximumAssets)
        {
            throw new ArgumentOutOfRangeException(nameof(assets), "Too many server assets.");
        }

        var normalized = NormalizeAssets(assets);
        var document = new ServerAssetDocument(1, normalized);
        var directory = Path.GetDirectoryName(filePath)
            ?? throw new InvalidOperationException("Asset directory is unavailable.");
        Directory.CreateDirectory(directory);

        var tempPath = string.Concat(filePath, ".", Guid.NewGuid().ToString("N"), ".tmp");
        try
        {
            await using (var stream = File.Create(tempPath))
            {
                await JsonSerializer.SerializeAsync(stream, document, JsonOptions, cancellationToken).ConfigureAwait(false);
            }

            File.Move(tempPath, filePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
    }

    private static string DefaultFilePath
    {
        get
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(localAppData))
            {
                throw new InvalidOperationException("Local application data directory is unavailable.");
            }

            return Path.Combine(localAppData, "OrbitTerm", "Assets", "assets.json");
        }
    }

    private static IReadOnlyList<ServerAssetRecord> NormalizeAssets(IReadOnlyList<ServerAssetRecord> assets)
    {
        var normalized = new List<ServerAssetRecord>(Math.Min(assets.Count, MaximumAssets));
        var seen = new HashSet<Guid>();

        foreach (var asset in assets.Take(MaximumAssets))
        {
            if (asset.Id == Guid.Empty ||
                asset.CredentialId == Guid.Empty ||
                !seen.Add(asset.Id) ||
                string.IsNullOrWhiteSpace(asset.Host) ||
                string.IsNullOrWhiteSpace(asset.Username) ||
                asset.Port is <= 0 or > 65535)
            {
                continue;
            }

            var name = string.IsNullOrWhiteSpace(asset.Name)
                ? asset.Host.Trim()
                : asset.Name.Trim();
            normalized.Add(asset with
            {
                Name = name,
                Host = asset.Host.Trim(),
                Username = asset.Username.Trim(),
                Group = NormalizeGroup(asset.Group),
                Tags = NormalizeTags(asset.Tags),
                Transport = asset.Transport,
                JumpHost = NormalizeJumpHost(asset.JumpHost),
                StorageScope = Enum.IsDefined(asset.StorageScope)
                    ? asset.StorageScope
                    : AssetStorageScope.AccountSynced,
                OwnerAccountScope = NormalizeAccountScope(asset.OwnerAccountScope),
            });
        }

        return normalized;
    }

    private static JumpHostRecord? NormalizeJumpHost(JumpHostRecord? jump)
    {
        if (jump is null)
        {
            return null;
        }
        var host = NormalizeText(jump.Host, 255);
        var username = NormalizeText(jump.Username, 120);
        if (jump.CredentialId == Guid.Empty || string.IsNullOrWhiteSpace(host) ||
            string.IsNullOrWhiteSpace(username) || jump.Port is < 1 or > 65535)
        {
            return null;
        }
        return jump with { Host = host, Username = username };
    }

    private static string NormalizeGroup(string? group)
    {
        var normalized = NormalizeText(group, MaximumGroupLength);
        return string.IsNullOrWhiteSpace(normalized) ? "未分组" : normalized;
    }

    private static IReadOnlyList<string> NormalizeTags(IReadOnlyList<string>? tags)
    {
        if (tags is null)
        {
            return [];
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var normalized = new List<string>(Math.Min(tags.Count, MaximumTagsPerAsset));
        foreach (var tag in tags)
        {
            var value = NormalizeText(tag, MaximumTagLength);
            if (!string.IsNullOrWhiteSpace(value) && seen.Add(value))
            {
                normalized.Add(value);
            }

            if (normalized.Count == MaximumTagsPerAsset)
            {
                break;
            }
        }

        return normalized;
    }

    private static string? NormalizeAccountScope(string? accountScope)
    {
        if (string.IsNullOrWhiteSpace(accountScope))
        {
            return null;
        }

        var normalized = accountScope.Trim().ToLowerInvariant();
        return normalized.Length == 64 && normalized.All(Uri.IsHexDigit)
            ? normalized
            : null;
    }

    private static string NormalizeText(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var cleaned = new string(value.Trim().Where(character => !char.IsControl(character)).ToArray());
        return cleaned.Length <= maximumLength ? cleaned : cleaned[..maximumLength];
    }

    private sealed record ServerAssetDocument(int Version, IReadOnlyList<ServerAssetRecord> Assets);
}
