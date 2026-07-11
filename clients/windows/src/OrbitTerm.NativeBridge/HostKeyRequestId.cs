using System.Globalization;
using System.Security.Cryptography;

namespace OrbitTerm.NativeBridge;

public readonly record struct HostKeyRequestId(string Value)
{
    public static HostKeyRequestId Create()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        return new HostKeyRequestId(Convert.ToHexString(bytes).ToLower(CultureInfo.InvariantCulture));
    }

    public override string ToString() => Value;
}
