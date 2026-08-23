namespace OrbitTerm.Presentation;

public sealed record DockerLogSessionContext(
    Guid WorkspaceTabId,
    Guid WorkspaceId,
    Guid AssetId,
    string ContainerId,
    string ContainerName,
    string Image);

public sealed record DockerLogFrame(
    string Text,
    string Status,
    bool IsError = false);

/// <summary>
/// Owns the bounded refresh lifecycle for one verified Docker log context.
/// It never opens a connection itself and it serializes refreshes so a slow
/// SSH round-trip cannot create an overlapping request backlog.
/// </summary>
public sealed class DockerLogSessionController : IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<DockerLogFrame>> capture;
    private readonly TimeSpan refreshInterval;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly object wakeGate = new();
    private TaskCompletionSource<bool>? wakeCompletion;
    private CancellationTokenSource? cancellationSource;
    private Task? loopTask;
    private bool isPaused;
    private bool isDisposed;

    public DockerLogSessionController(
        DockerLogSessionContext context,
        Func<CancellationToken, Task<DockerLogFrame>> capture,
        TimeSpan? refreshInterval = null)
    {
        Context = context ?? throw new ArgumentNullException(nameof(context));
        this.capture = capture ?? throw new ArgumentNullException(nameof(capture));
        this.refreshInterval = refreshInterval ?? TimeSpan.FromSeconds(2);
        if (this.refreshInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(refreshInterval));
        }
    }

    public DockerLogSessionContext Context { get; }

    public DockerLogFrame? LatestFrame { get; private set; }

    public bool IsRunning => loopTask is { IsCompleted: false };

    public bool IsPaused => isPaused;

    public event Action<DockerLogFrame>? FrameReceived;

    public event Action<bool>? PauseChanged;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(isDisposed, this);
        if (IsRunning)
        {
            return;
        }

        cancellationSource = new CancellationTokenSource();
        loopTask = RunLoopAsync(cancellationSource.Token);
    }

    public void Pause()
    {
        if (!IsRunning || isPaused)
        {
            return;
        }

        isPaused = true;
        PauseChanged?.Invoke(true);
        Wake();
    }

    public void Resume()
    {
        if (!IsRunning || !isPaused)
        {
            return;
        }

        isPaused = false;
        PauseChanged?.Invoke(false);
        Wake();
    }

    public async Task RefreshNowAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(isDisposed, this);
        await CaptureOnceAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task StopAsync()
    {
        var source = cancellationSource;
        var running = loopTask;
        cancellationSource = null;
        loopTask = null;
        if (source is null)
        {
            return;
        }

        source.Cancel();
        Wake();
        if (running is not null)
        {
            try
            {
                await running.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (source.IsCancellationRequested)
            {
            }
        }

        source.Dispose();
        isPaused = false;
    }

    public static IReadOnlyList<int> FindMatches(string text, string query, int maximumMatches = 10_000)
    {
        if (string.IsNullOrEmpty(text) || string.IsNullOrWhiteSpace(query) || maximumMatches <= 0)
        {
            return [];
        }

        var matches = new List<int>();
        var cursor = 0;
        while (cursor <= text.Length - query.Length && matches.Count < maximumMatches)
        {
            var index = text.IndexOf(query, cursor, StringComparison.CurrentCultureIgnoreCase);
            if (index < 0)
            {
                break;
            }

            matches.Add(index);
            cursor = index + Math.Max(1, query.Length);
        }

        return matches;
    }

    public async ValueTask DisposeAsync()
    {
        if (isDisposed)
        {
            return;
        }

        await StopAsync().ConfigureAwait(false);
        isDisposed = true;
        refreshGate.Dispose();
    }

    private async Task RunLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            if (!isPaused)
            {
                await CaptureOnceAsync(cancellationToken).ConfigureAwait(false);
            }

            await WaitForWakeOrDelayAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
    }

    private async Task CaptureOnceAsync(CancellationToken cancellationToken)
    {
        if (!await refreshGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return;
        }

        try
        {
            // The checked native Docker call is synchronous below its Task
            // shaped boundary. Run it away from the UI thread while this
            // controller continues to serialize requests with refreshGate.
            var frame = await Task.Run(
                () => capture(cancellationToken),
                cancellationToken).ConfigureAwait(false);
            LatestFrame = frame;
            FrameReceived?.Invoke(frame);
        }
        finally
        {
            refreshGate.Release();
        }
    }

    private void Wake()
    {
        TaskCompletionSource<bool>? completion;
        lock (wakeGate)
        {
            completion = wakeCompletion;
            wakeCompletion = null;
        }

        completion?.TrySetResult(true);
    }

    private async Task WaitForWakeOrDelayAsync(CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (wakeGate)
        {
            wakeCompletion = completion;
        }

        try
        {
            await Task.WhenAny(
                Task.Delay(refreshInterval, cancellationToken),
                completion.Task).ConfigureAwait(false);
        }
        finally
        {
            lock (wakeGate)
            {
                if (ReferenceEquals(wakeCompletion, completion))
                {
                    wakeCompletion = null;
                }
            }
        }
    }
}
