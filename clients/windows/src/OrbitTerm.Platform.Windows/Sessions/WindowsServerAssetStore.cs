using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Platform.Windows.Sessions;

public sealed class WindowsServerAssetStore : IServerAssetStore
{
    private const int MaximumAssets = 512;
    private const long MaximumAssetFileBytes = 1024 * 1024;
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
                Transport = asset.Transport,
            });
        }

        return normalized;
    }

    private sealed record ServerAssetDocument(int Version, IReadOnlyList<ServerAssetRecord> Assets);
}
