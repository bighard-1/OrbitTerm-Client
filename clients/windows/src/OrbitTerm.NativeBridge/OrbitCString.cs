using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

internal readonly struct OrbitCString : IDisposable
{
    private readonly IntPtr value;

    public OrbitCString(IntPtr value)
    {
        this.value = value;
    }

    public bool IsNull => value == IntPtr.Zero;

    public string ToOwnedString()
    {
        if (IsNull)
        {
            throw new OrbitNativeException("orbit_core returned a null string pointer.");
        }

        return Marshal.PtrToStringUTF8(value)
            ?? throw new OrbitNativeException("orbit_core returned invalid UTF-8.");
    }

    public void Dispose()
    {
        if (!IsNull)
        {
            NativeMethods.orbit_free_string(value);
        }
    }
}
