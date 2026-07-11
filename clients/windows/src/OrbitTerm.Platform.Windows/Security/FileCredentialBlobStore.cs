namespace OrbitTerm.Platform.Windows.Security;

internal sealed class FileCredentialBlobStore : ICredentialBlobStore
{
    private const int MaxEncryptedBytes = 4 * 1024 * 1024;
    private readonly string directory;

    public FileCredentialBlobStore(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory))
        {
            throw new ArgumentException("Credential directory must not be empty.", nameof(directory));
        }

        this.directory = directory;
    }

    public async ValueTask<byte[]> ReadAsync(Guid credentialId, CancellationToken cancellationToken)
    {
        var path = PathFor(credentialId);
        if (!File.Exists(path))
        {
            return [];
        }

        var file = new FileInfo(path);
        if (file.Length is <= 0 or > MaxEncryptedBytes)
        {
            throw new InvalidDataException("Credential blob size is invalid.");
        }

        return await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask WriteAsync(Guid credentialId, byte[] encrypted, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(encrypted);
        if (encrypted.Length is <= 0 or > MaxEncryptedBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(encrypted), "Encrypted credential blob size is invalid.");
        }

        Directory.CreateDirectory(directory);
        var path = PathFor(credentialId);
        var tempPath = string.Concat(path, ".", Guid.NewGuid().ToString("N"), ".tmp");

        try
        {
            await File.WriteAllBytesAsync(tempPath, encrypted, cancellationToken).ConfigureAwait(false);
            File.Move(tempPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
    }

    public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var path = PathFor(credentialId);
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        return ValueTask.CompletedTask;
    }

    private string PathFor(Guid credentialId)
    {
        if (credentialId == Guid.Empty)
        {
            throw new ArgumentException("Credential identifier must not be empty.", nameof(credentialId));
        }

        return Path.Combine(directory, string.Concat(credentialId.ToString("N"), ".bin"));
    }
}
