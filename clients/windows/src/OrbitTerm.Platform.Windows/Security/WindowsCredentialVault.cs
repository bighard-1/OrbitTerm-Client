using System.Runtime.Versioning;
using OrbitTerm.Application.Security;

namespace OrbitTerm.Platform.Windows.Security;

public sealed class WindowsCredentialVault : ICredentialVault
{
    private readonly ICredentialBlobStore store;
    private readonly ICredentialProtector protector;

    public WindowsCredentialVault()
        : this(
            new FileCredentialBlobStore(WindowsCredentialVaultPaths.DefaultDirectory),
            new DpapiCredentialProtector())
    {
    }

    internal WindowsCredentialVault(ICredentialBlobStore store, ICredentialProtector protector)
    {
        this.store = store;
        this.protector = protector;
    }

    public async ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken)
    {
        ValidateCredentialId(credentialId);
        cancellationToken.ThrowIfCancellationRequested();

        var encrypted = await store.ReadAsync(credentialId, cancellationToken).ConfigureAwait(false);
        if (encrypted.Length == 0)
        {
            return new CredentialMaterial(string.Empty, string.Empty, string.Empty);
        }

        var plaintext = protector.Unprotect(encrypted);
        try
        {
            return CredentialVaultSerializer.Deserialize(plaintext);
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
        }
    }

    public async ValueTask SaveAsync(
        Guid credentialId,
        CredentialMaterial credential,
        CancellationToken cancellationToken)
    {
        ValidateCredentialId(credentialId);
        ArgumentNullException.ThrowIfNull(credential);
        cancellationToken.ThrowIfCancellationRequested();

        if (credential.IsEmpty)
        {
            await DeleteAsync(credentialId, cancellationToken).ConfigureAwait(false);
            return;
        }

        var plaintext = CredentialVaultSerializer.Serialize(credential);
        try
        {
            var encrypted = protector.Protect(plaintext);
            await store.WriteAsync(credentialId, encrypted, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicBuffer.Zero(plaintext);
        }
    }

    public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
    {
        ValidateCredentialId(credentialId);
        cancellationToken.ThrowIfCancellationRequested();
        return store.DeleteAsync(credentialId, cancellationToken);
    }

    private static void ValidateCredentialId(Guid credentialId)
    {
        if (credentialId == Guid.Empty)
        {
            throw new ArgumentException("Credential identifier must not be empty.", nameof(credentialId));
        }
    }
}

internal interface ICredentialProtector
{
    byte[] Protect(byte[] plaintext);

    byte[] Unprotect(byte[] ciphertext);
}

internal interface ICredentialBlobStore
{
    ValueTask<byte[]> ReadAsync(Guid credentialId, CancellationToken cancellationToken);

    ValueTask WriteAsync(Guid credentialId, byte[] encrypted, CancellationToken cancellationToken);

    ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken);
}

[SupportedOSPlatform("windows")]
internal sealed class DpapiCredentialProtector : ICredentialProtector
{
    public byte[] Protect(byte[] plaintext)
    {
        EnsureWindows();
        ArgumentNullException.ThrowIfNull(plaintext);
        return WindowsDpapi.Protect(plaintext);
    }

    public byte[] Unprotect(byte[] ciphertext)
    {
        EnsureWindows();
        ArgumentNullException.ThrowIfNull(ciphertext);
        return WindowsDpapi.Unprotect(ciphertext);
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows credential vault requires Windows DPAPI.");
        }
    }
}
