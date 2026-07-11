using System.Reflection;
using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

public static class OrbitNativeLibraryLoader
{
    private const string LibraryName = "orbit_core";
    private static int registered;

    public static void Register()
    {
        if (Interlocked.Exchange(ref registered, 1) == 1)
        {
            return;
        }

        NativeLibrary.SetDllImportResolver(
            typeof(OrbitNativeLibraryLoader).Assembly,
            Resolve);
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, LibraryName, StringComparison.Ordinal))
        {
            return IntPtr.Zero;
        }

        foreach (var candidate in CandidatePaths())
        {
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
            {
                return handle;
            }
        }

        return IntPtr.Zero;
    }

    private static IEnumerable<string> CandidatePaths()
    {
        var baseDirectory = AppContext.BaseDirectory;
        var fileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? "orbit_core.dll"
            : RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
                ? "liborbit_core.dylib"
                : "liborbit_core.so";

        yield return Path.Combine(baseDirectory, fileName);
        yield return Path.Combine(baseDirectory, "runtimes", "win-x64", "native", "orbit_core.dll");
        yield return Path.Combine(baseDirectory, "native", fileName);
    }
}
