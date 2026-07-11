using System.Text.Json;
using System.Runtime.Versioning;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Platform.Windows.Security;

namespace OrbitTerm.Platform.Windows.Sessions;

[SupportedOSPlatform("windows")]
public sealed class WindowsSnippetStore : ISnippetStore
{
    private const int MaximumSnippets = 512;
    private const long MaximumFileBytes = 2 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    private readonly string filePath;

    public WindowsSnippetStore() : this(DefaultFilePath)
    {
    }

    internal WindowsSnippetStore(string filePath)
    {
        this.filePath = string.IsNullOrWhiteSpace(filePath)
            ? throw new ArgumentException("Snippet file path must not be empty.", nameof(filePath))
            : filePath;
    }

    public async ValueTask<IReadOnlyList<SnippetRecord>> LoadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(filePath))
        {
            return [];
        }

        var info = new FileInfo(filePath);
        if (info.Length is <= 0 or > MaximumFileBytes)
        {
            throw new InvalidDataException("Snippet file size is invalid.");
        }

        var encrypted = await File.ReadAllBytesAsync(filePath, cancellationToken).ConfigureAwait(false);
        var plaintext = WindowsDpapi.Unprotect(encrypted);
        try
        {
            using var stream = new MemoryStream(plaintext, writable: false);
            var document = await JsonSerializer.DeserializeAsync<SnippetDocument>(
                stream,
                JsonOptions,
                cancellationToken).ConfigureAwait(false);
            if (document is null || document.Version != 1)
            {
                throw new InvalidDataException("Snippet document version is unsupported.");
            }

            return Normalize(document.Snippets);
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
        }
    }

    public async ValueTask SaveAsync(IReadOnlyList<SnippetRecord> snippets, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snippets);
        if (snippets.Count > MaximumSnippets)
        {
            throw new ArgumentOutOfRangeException(nameof(snippets), "Too many snippets.");
        }

        var directory = Path.GetDirectoryName(filePath)
            ?? throw new InvalidOperationException("Snippet directory is unavailable.");
        Directory.CreateDirectory(directory);
        var tempPath = string.Concat(filePath, ".", Guid.NewGuid().ToString("N"), ".tmp");
        byte[] plaintext = [];
        byte[] encrypted = [];
        try
        {
            await using (var stream = new MemoryStream())
            {
                await JsonSerializer.SerializeAsync(
                    stream,
                    new SnippetDocument(1, Normalize(snippets)),
                    JsonOptions,
                    cancellationToken).ConfigureAwait(false);
                plaintext = stream.ToArray();
            }

            encrypted = WindowsDpapi.Protect(plaintext);
            await File.WriteAllBytesAsync(tempPath, encrypted, cancellationToken).ConfigureAwait(false);
            File.Move(tempPath, filePath, overwrite: true);
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
            CryptographicBuffer.Zero(encrypted);
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
            var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return string.IsNullOrWhiteSpace(root)
                ? throw new InvalidOperationException("Local application data directory is unavailable.")
                : Path.Combine(root, "OrbitTerm", "Snippets", "snippets.dat");
        }
    }

    private static IReadOnlyList<SnippetRecord> Normalize(IReadOnlyList<SnippetRecord> source)
    {
        var seen = new HashSet<Guid>();
        var result = new List<SnippetRecord>(Math.Min(source.Count, MaximumSnippets));
        foreach (var snippet in source.Take(MaximumSnippets))
        {
            if (snippet.Id == Guid.Empty || !seen.Add(snippet.Id))
            {
                continue;
            }

            var title = snippet.Title.Trim();
            var command = snippet.Command.Trim();
            var category = snippet.Category.Trim();
            if (title.Length is < 1 or > 120 || command.Length is < 1 or > 8192 ||
                category.Length > 80 || command.Any(char.IsControl))
            {
                continue;
            }

            result.Add(snippet with
            {
                Title = title,
                Command = command,
                Category = category.Length == 0 ? "Uncategorized" : category,
            });
        }

        return result.OrderByDescending(item => item.UpdatedAt).ToArray();
    }

    private sealed record SnippetDocument(int Version, IReadOnlyList<SnippetRecord> Snippets);
}
