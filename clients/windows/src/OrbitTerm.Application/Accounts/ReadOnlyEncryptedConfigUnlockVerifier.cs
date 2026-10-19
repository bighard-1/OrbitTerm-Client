using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

/// <summary>First-device proof only: fetches ciphertext and never applies or acknowledges it.</summary>
public sealed class ReadOnlyEncryptedConfigUnlockVerifier(IOrbitEncryptedSyncProtocol sync) : IEncryptedConfigUnlockVerifier
{
    public async ValueTask<bool?> VerifyAsync(AccountSessionRecord session, string masterPassword, byte[] rootKey, CancellationToken cancellationToken)
    {
        const int pageSize = 100;
        const int maxPages = 100;
        ulong cursor = 0;
        var sawCiphertext = false;
        var currentSession = session;
        for (var pageIndex = 0; pageIndex < maxPages; pageIndex++)
        {
            var page = await sync.PullChangesAsync(currentSession, cursor, pageSize, cancellationToken).ConfigureAwait(false);
            currentSession = page.Session;
            foreach (var item in page.Value.Items)
            {
                // A purged tombstone intentionally has no ciphertext. It cannot
                // prove or disprove the master key and must not block later pages.
                if (string.Equals(item.State, "purged", StringComparison.OrdinalIgnoreCase) ||
                    string.IsNullOrWhiteSpace(item.EncryptedBlobBase64))
                    continue;

                sawCiphertext = true;
                byte[]? encrypted = null;
                try
                {
                    encrypted = Convert.FromBase64String(item.EncryptedBlobBase64);
                    if (encrypted.Length == 0) continue;
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
                        System.Security.Cryptography.CryptographicOperations.ZeroMemory(encrypted);
                }
            }

            if (!page.Value.HasMore) return sawCiphertext ? false : null;
            if (page.Value.NextCursor <= cursor)
                throw new InvalidOperationException("同步服务返回了不前进的验证游标。");
            cursor = page.Value.NextCursor;
        }
        throw new InvalidOperationException("同步服务的验证页数超过安全上限。");
    }

    private static bool IsV2ConfigBlob(ReadOnlySpan<byte> encrypted) =>
        encrypted.Length >= 4 && encrypted[..4].SequenceEqual("OTC2"u8);
}
