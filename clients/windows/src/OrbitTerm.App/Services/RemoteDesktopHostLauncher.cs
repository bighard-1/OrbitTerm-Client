using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using OrbitTerm.Application.Sessions;

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
        var pipe = new NamedPipeServerStream(
            pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
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
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true)
            {
                AutoFlush = true,
            };
            await writer.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), timeout.Token);

            var session = new RemoteDesktopHostSession(process, pipe, request.AssetId);
            var initialUpdate = await session.WaitForInitialUpdateAsync(timeout.Token);
            if (initialUpdate.Phase == RemoteDesktopSessionPhase.Failed)
            {
                var message = RemoteDesktopFailurePresentation.UserMessage(initialUpdate);
                session.Close();
                session.Dispose();
                throw new InvalidOperationException(message);
            }
            return session;
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
            pipe.Dispose();
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
    private readonly NamedPipeServerStream pipe;
    private readonly CancellationTokenSource lifetime = new();
    private readonly TaskCompletionSource<RemoteDesktopSessionUpdate> initialUpdate =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly RemoteDesktopSessionStateMachine stateMachine = new();
    private readonly Task statusPump;
    private bool disposed;

    public RemoteDesktopHostSession(Process process, NamedPipeServerStream pipe, Guid assetId)
    {
        this.process = process;
        this.pipe = pipe;
        AssetId = assetId;
        process.Exited += ProcessExited;
        statusPump = PumpStatusAsync(lifetime.Token);
    }

    public Guid AssetId { get; }
    public RemoteDesktopSessionUpdate Current => stateMachine.Current;
    public event EventHandler? Exited;
    public event EventHandler<RemoteDesktopSessionUpdate>? StateChanged;

    public Task<RemoteDesktopSessionUpdate> WaitForInitialUpdateAsync(CancellationToken cancellationToken) =>
        initialUpdate.Task.WaitAsync(cancellationToken);

    private async Task PumpStatusAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true);
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(cancellationToken);
                if (line is null) break;
                RemoteDesktopHostWireUpdate? wire;
                try { wire = JsonSerializer.Deserialize<RemoteDesktopHostWireUpdate>(line); }
                catch (JsonException) { continue; }
                if (wire is null || !Enum.TryParse<RemoteDesktopSessionPhase>(wire.Phase, true, out var phase))
                    continue;
                var failure = Enum.TryParse<RemoteDesktopFailureKind>(wire.FailureKind, true, out var parsedFailure)
                    ? parsedFailure
                    : RemoteDesktopFailureKind.Unknown;
                var update = new RemoteDesktopSessionUpdate(
                    phase,
                    Bound(wire.Message, 240),
                    failure,
                    Bound(wire.ErrorCode, 32),
                    wire.CanRetry);
                if (!stateMachine.TryTransition(update)) continue;
                initialUpdate.TrySetResult(update);
                StateChanged?.Invoke(this, update);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (IOException) { }
    }

    private static string Bound(string? value, int maxLength)
    {
        var text = value?.Trim() ?? string.Empty;
        return text.Length <= maxLength ? text : text[..maxLength];
    }

    private void ProcessExited(object? sender, EventArgs e)
    {
        initialUpdate.TrySetException(new InvalidOperationException(
            "Windows 远程桌面组件启动后意外退出，请重新安装完整客户端。"));
        Exited?.Invoke(this, EventArgs.Empty);
    }

    public void Close()
    {
        try { if (!process.HasExited) process.CloseMainWindow(); } catch { }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        process.Exited -= ProcessExited;
        lifetime.Cancel();
        pipe.Dispose();
        lifetime.Dispose();
        process.Dispose();
        if (statusPump.IsFaulted) _ = statusPump.Exception;
    }
}

internal sealed record RemoteDesktopHostRequest(
    Guid AssetId, string DisplayName, string Host, int Port, string Username, string Password,
    bool ClipboardEnabled, bool DriveRedirectionEnabled,
    bool PrinterRedirectionEnabled, bool DarkTheme);

internal sealed record RemoteDesktopHostWireUpdate(
    string Phase,
    string Message,
    string FailureKind = "None",
    string ErrorCode = "",
    bool CanRetry = false);
