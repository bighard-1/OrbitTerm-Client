using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

/// <summary>First-device proof only: fetches ciphertext and never applies or acknowledges it.</summary>
public sealed class ReadOnlyEncryptedConfigUnlockVerifier(IOrbitEncryptedSyncProtocol sync) : IEncryptedConfigUnlockVerifier
{
    public async ValueTask<bool?> VerifyAsync(AccountSessionRecord session, string masterPassword, byte[] rootKey, CancellationToken cancellationToken)
    {
        var page = await sync.PullChangesAsync(session, 0, 100, cancellationToken).ConfigureAwait(false);
        if (page.Value.Items.Count == 0) return null;
        foreach (var item in page.Value.Items)
        {
            byte[]? encrypted = null;
            try
            {
                encrypted = Convert.FromBase64String(item.EncryptedBlobBase64);
                var plaintext = IsV2ConfigBlob(encrypted)
                    ? OrbitConfigCrypto.DecryptConfigV2(rootKey, encrypted)
                    : OrbitConfigCrypto.DecryptConfigLegacy(masterPassword, encrypted);
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(plaintext);
                return true;
            }
            catch (OrbitNativeException) { }
            catch (FormatException) { }
            finally
            {
                if (encrypted is not null)
                {
                    System.Security.Cryptography.CryptographicOperations.ZeroMemory(encrypted);
                }
            }
        }
        return false;
    }

    private static bool IsV2ConfigBlob(ReadOnlySpan<byte> encrypted) =>
        encrypted.Length >= 4 && encrypted[..4].SequenceEqual("OTC2"u8);
}
