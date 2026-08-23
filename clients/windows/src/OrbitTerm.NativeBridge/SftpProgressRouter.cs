using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

internal static class SftpProgressRouter
{
    private const int MaximumRequestIdBytes = 256;
    private static readonly NativeMethods.OrbitSftpProgressCallback Callback = OnSftpProgress;
    private static int isRegistered;

    public static event EventHandler<SftpTransferProgressEventArgs>? ProgressChanged;

    public static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref isRegistered, 1) == 0)
        {
            NativeMethods.orbit_sftp_set_progress_callback(Callback);
        }
    }

    private static void OnSftpProgress(
        IntPtr requestIdPointer,
        ulong transferredBytes,
        ulong totalBytes,
        bool hasTotal)
    {
        if (requestIdPointer == IntPtr.Zero)
        {
            return;
        }

        var requestId = Marshal.PtrToStringUTF8(requestIdPointer);
        if (string.IsNullOrWhiteSpace(requestId) ||
            System.Text.Encoding.UTF8.GetByteCount(requestId) > MaximumRequestIdBytes)
        {
            return;
        }

        ProgressChanged?.Invoke(
            null,
            new SftpTransferProgressEventArgs(
                requestId,
                transferredBytes,
                hasTotal ? totalBytes : null));
    }
}
