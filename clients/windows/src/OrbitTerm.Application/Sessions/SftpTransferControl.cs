namespace OrbitTerm.Application.Sessions;

/// <summary>
/// Cooperative transfer control shared by the presentation queue and the
/// checked native progress boundary. Pausing never abandons a partial file;
/// the native transfer simply waits after its current SFTP chunk.
/// </summary>
public sealed class SftpTransferControl
{
    private readonly ManualResetEventSlim resumeGate = new(initialState: true);
    private volatile bool isPaused;

    public bool IsPaused => isPaused;

    public void Pause()
    {
        isPaused = true;
        resumeGate.Reset();
    }

    public void Resume()
    {
        isPaused = false;
        resumeGate.Set();
    }

    internal bool WaitWhilePaused(CancellationToken cancellationToken)
    {
        while (isPaused && !cancellationToken.IsCancellationRequested)
        {
            resumeGate.Wait(TimeSpan.FromMilliseconds(100));
        }

        return !cancellationToken.IsCancellationRequested;
    }
}
