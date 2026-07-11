using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

internal static class TerminalOutputRouter
{
    private const int MaxCallbackBytes = 1024 * 1024;
    private static readonly NativeMethods.OrbitTerminalDataCallback Callback = OnTerminalData;
    private static int isRegistered;

    public static event EventHandler<TerminalDataReceivedEventArgs>? DataReceived;

    public static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref isRegistered, 1) == 0)
        {
            NativeMethods.orbit_terminal_set_callback(Callback);
        }
    }

    private static void OnTerminalData(ulong terminalChannelId, IntPtr data, nuint length)
    {
        if (terminalChannelId == 0 || data == IntPtr.Zero || length == 0 || length > MaxCallbackBytes)
        {
            return;
        }

        var managed = new byte[checked((int)length)];
        Marshal.Copy(data, managed, 0, managed.Length);
        DataReceived?.Invoke(null, new TerminalDataReceivedEventArgs(terminalChannelId, managed));
    }
}
