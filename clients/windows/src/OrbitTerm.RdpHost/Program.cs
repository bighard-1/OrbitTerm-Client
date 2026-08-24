using System.IO.Pipes;
using System.Text;
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
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut);
            pipe.Connect(15_000);
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true);
            var requestLine = reader.ReadLine();
            var launch = requestLine is null
                ? null
                : JsonSerializer.Deserialize<RdpHostLaunch>(requestLine);
            if (launch is null) return;
            using var reporter = new RdpHostStatusReporter(pipe);
            reporter.Report("Starting", "正在创建 Windows 远程桌面窗口…");
            Application.Run(new RemoteDesktopWindow(launch, reporter));
        }
        catch
        {
            // The parent workstation owns user-facing diagnostics. This host
            // exits silently when its one-time channel cannot be authenticated.
        }
    }
}

internal sealed record RdpHostLaunch(
    Guid AssetId,
    string DisplayName,
    string Host,
    int Port,
    string Username,
    string Password,
    bool ClipboardEnabled,
    bool DriveRedirectionEnabled,
    bool PrinterRedirectionEnabled,
    bool DarkTheme);

internal sealed class RdpHostStatusReporter(Stream stream) : IDisposable
{
    private readonly object gate = new();
    private readonly StreamWriter writer = new(stream, new UTF8Encoding(false), leaveOpen: true)
    {
        AutoFlush = true,
    };
    private bool available = true;

    public void Report(
        string phase,
        string message,
        string failureKind = "None",
        string errorCode = "",
        bool canRetry = false)
    {
        lock (gate)
        {
            if (!available) return;
            try
            {
                writer.WriteLine(JsonSerializer.Serialize(new RdpHostUpdate(
                    phase, message, failureKind, errorCode, canRetry)));
            }
            catch (IOException)
            {
                available = false;
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            available = false;
            writer.Dispose();
        }
    }
}

internal sealed record RdpHostUpdate(
    string Phase,
    string Message,
    string FailureKind = "None",
    string ErrorCode = "",
    bool CanRetry = false);
