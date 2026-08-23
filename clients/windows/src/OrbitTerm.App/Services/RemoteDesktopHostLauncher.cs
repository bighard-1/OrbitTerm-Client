using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;

namespace OrbitTerm.App.Services;

internal sealed class RemoteDesktopHostLauncher
{
    public async Task<RemoteDesktopHostSession> LaunchAsync(RemoteDesktopHostRequest request)
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "rdp-host", "OrbitTerm.RdpHost.exe");
        if (!File.Exists(executable))
            throw new FileNotFoundException("OrbitTerm 远程桌面组件未安装完整。", executable);
        // Keep this in lockstep with the RDP host's strict one-time pipe-name
        // validator. Dots are valid to Windows, but intentionally not accepted
        // by the isolated host's reduced character set.
        var pipeName = $"OrbitTermRdp_{Guid.NewGuid():N}";
        await using var pipe = new NamedPipeServerStream(
            pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(executable)!,
            },
            EnableRaisingEvents = true,
        };
        process.StartInfo.ArgumentList.Add("--pipe");
        process.StartInfo.ArgumentList.Add(pipeName);
        var startupExited = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        void ProcessExitedDuringStartup(object? sender, EventArgs args) => startupExited.TrySetResult();
        process.Exited += ProcessExitedDuringStartup;
        if (!process.Start()) throw new InvalidOperationException("Windows 远程桌面隔离进程未能启动。");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            var connection = pipe.WaitForConnectionAsync(timeout.Token);
            if (await Task.WhenAny(connection, startupExited.Task) == startupExited.Task)
                throw new InvalidOperationException("Windows 远程桌面组件启动后意外退出，请重新安装完整客户端。");
            await connection;
            await JsonSerializer.SerializeAsync(pipe, request, cancellationToken: timeout.Token);
            await pipe.FlushAsync(timeout.Token);
            // Give the isolated host enough time to create its STA ActiveX
            // surface. If initialization fails, report it instead of returning
            // a session which has already vanished without user feedback.
            var startupGrace = Task.Delay(TimeSpan.FromMilliseconds(750), timeout.Token);
            if (await Task.WhenAny(startupGrace, startupExited.Task) == startupExited.Task)
                throw new InvalidOperationException("Windows 远程桌面窗口初始化失败，请检查系统远程桌面组件后重试。");
            await startupGrace;
            return new RemoteDesktopHostSession(process);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            process.Dispose();
            throw new TimeoutException("Windows 远程桌面组件启动超时，请重试。");
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            process.Dispose();
            throw;
        }
        finally
        {
            process.Exited -= ProcessExitedDuringStartup;
        }
    }
}

internal sealed class RemoteDesktopHostSession : IDisposable
{
    private readonly Process process;
    public RemoteDesktopHostSession(Process process)
    {
        this.process = process;
        process.Exited += ProcessExited;
    }
    public event EventHandler? Exited;
    private void ProcessExited(object? sender, EventArgs e) => Exited?.Invoke(this, EventArgs.Empty);
    public void Close()
    {
        try { if (!process.HasExited) process.CloseMainWindow(); } catch { }
    }
    public void Dispose()
    {
        process.Exited -= ProcessExited;
        process.Dispose();
    }
}

internal sealed record RemoteDesktopHostRequest(
    string DisplayName, string Host, int Port, string Username, string Password,
    bool ClipboardEnabled, bool DriveRedirectionEnabled,
    bool PrinterRedirectionEnabled, bool DarkTheme);
