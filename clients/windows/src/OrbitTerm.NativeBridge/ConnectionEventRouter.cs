using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

internal static class ConnectionEventRouter
{
    private static readonly NativeMethods.OrbitConnectionEventCallback Callback = OnConnectionEvent;
    private static int isRegistered;

    public static event EventHandler<ConnectionEventReceivedEventArgs>? EventReceived;

    public static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref isRegistered, 1) == 0)
        {
            NativeMethods.orbit_connection_set_callback(Callback);
        }
    }

    private static void OnConnectionEvent(ulong sessionOrChannelId, IntPtr code)
    {
        if (sessionOrChannelId == 0 || code == IntPtr.Zero)
        {
            return;
        }

        var kind = Marshal.PtrToStringUTF8(code) switch
        {
            "ERR_CONNECTION_LOST" => OrbitConnectionEventKind.ConnectionLost,
            "ERR_TERMINAL_CLOSED" => OrbitConnectionEventKind.TerminalClosed,
            _ => (OrbitConnectionEventKind?)null,
        };
        if (kind is { } accepted)
        {
            EventReceived?.Invoke(null, new ConnectionEventReceivedEventArgs(sessionOrChannelId, accepted));
        }
    }
}
