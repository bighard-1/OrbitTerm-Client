using System.Security.Cryptography;

namespace OrbitTerm.Platform.Windows.Security;

internal static class CryptographicBuffer
{
    public static void Zero(byte[]? buffer)
    {
        if (buffer is { Length: > 0 })
        {
            CryptographicOperations.ZeroMemory(buffer);
        }
    }
}
