using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace OrbitTerm.Platform.Windows.Security;

[SupportedOSPlatform("windows")]
internal static partial class WindowsDpapi
{
    private const uint CryptProtectUiForbidden = 0x1;

    public static byte[] Protect(byte[] plaintext)
    {
        return Transform(plaintext, protect: true);
    }

    public static byte[] Unprotect(byte[] ciphertext)
    {
        return Transform(ciphertext, protect: false);
    }

    private static byte[] Transform(byte[] input, bool protect)
    {
        if (input.Length == 0)
        {
            throw new ArgumentException("DPAPI input must not be empty.", nameof(input));
        }

        var inputHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        var inputBlob = new DataBlob((uint)input.Length, inputHandle.AddrOfPinnedObject());
        var outputBlob = new DataBlob();

        try
        {
            var succeeded = protect
                ? CryptProtectData(
                    ref inputBlob,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptProtectUiForbidden,
                    out outputBlob)
                : CryptUnprotectData(
                    ref inputBlob,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptProtectUiForbidden,
                    out outputBlob);

            if (!succeeded)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var output = new byte[outputBlob.ByteCount];
            Marshal.Copy(outputBlob.Data, output, 0, output.Length);
            return output;
        }
        finally
        {
            inputHandle.Free();
            if (outputBlob.Data != IntPtr.Zero)
            {
                LocalFree(outputBlob.Data);
            }
        }
    }

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptProtectData(
        ref DataBlob dataIn,
        IntPtr dataDescription,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        uint flags,
        out DataBlob dataOut);

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr dataDescription,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        uint flags,
        out DataBlob dataOut);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct DataBlob(uint byteCount, IntPtr data)
    {
        public readonly uint ByteCount = byteCount;
        public readonly IntPtr Data = data;
    }
}
