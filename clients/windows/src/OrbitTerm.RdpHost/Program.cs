using System.IO.Pipes;
using System.Text.Json;

namespace OrbitTerm.RdpHost;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args is not ["--pipe", var pipeName] ||
            pipeName.Length is < 20 or > 128 ||
            pipeName.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_'))
            return;

        ApplicationConfiguration.Initialize();
        try
        {
            // The Windows RDP ActiveX control must be created and pumped by the
            // original STA entry thread. An async Main can resume on an MTA
            // worker before Application.Run, causing a silent COM failure.
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.In);
            pipe.Connect(15_000);
            var launch = JsonSerializer.Deserialize<RdpHostLaunch>(pipe);
            if (launch is null) return;
            Application.Run(new RemoteDesktopWindow(launch));
        }
        catch
        {
            // The parent workstation owns user-facing diagnostics. This host
            // exits silently when its one-time channel cannot be authenticated.
        }
    }
}

internal sealed record RdpHostLaunch(
    string DisplayName,
    string Host,
    int Port,
    string Username,
    string Password,
    bool ClipboardEnabled,
    bool DriveRedirectionEnabled,
    bool PrinterRedirectionEnabled,
    bool DarkTheme);
