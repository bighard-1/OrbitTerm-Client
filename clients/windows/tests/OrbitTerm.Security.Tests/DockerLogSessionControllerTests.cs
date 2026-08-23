using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class DockerLogSessionControllerTests
{
    [Fact]
    public async Task SessionRefreshesSeriallyAndPauseResumeOwnsTheLifecycle()
    {
        var captures = 0;
        var activeCaptures = 0;
        var maximumConcurrentCaptures = 0;
        var context = CreateContext();
        await using var controller = new DockerLogSessionController(
            context,
            async cancellationToken =>
            {
                var active = Interlocked.Increment(ref activeCaptures);
                maximumConcurrentCaptures = Math.Max(maximumConcurrentCaptures, active);
                try
                {
                    await Task.Delay(15, cancellationToken);
                    var capture = Interlocked.Increment(ref captures);
                    return new DockerLogFrame($"frame {capture}", $"capture {capture}");
                }
                finally
                {
                    Interlocked.Decrement(ref activeCaptures);
                }
            },
            TimeSpan.FromMilliseconds(10));

        controller.Start();
        await WaitUntilAsync(() => Volatile.Read(ref captures) >= 2);

        controller.Pause();
        await WaitUntilAsync(() => Volatile.Read(ref activeCaptures) == 0);
        var pausedCount = Volatile.Read(ref captures);
        await Task.Delay(70);

        Assert.Equal(pausedCount, Volatile.Read(ref captures));
        Assert.True(controller.IsPaused);
        Assert.Equal(1, maximumConcurrentCaptures);

        controller.Resume();
        await WaitUntilAsync(() => Volatile.Read(ref captures) > pausedCount);
        Assert.False(controller.IsPaused);
        Assert.Equal(context, controller.Context);
    }

    [Fact]
    public async Task StopPreventsFurtherFramesAndIsIdempotent()
    {
        var captures = 0;
        await using var controller = new DockerLogSessionController(
            CreateContext(),
            _ => Task.FromResult(new DockerLogFrame(
                $"frame {Interlocked.Increment(ref captures)}",
                "ok")),
            TimeSpan.FromMilliseconds(10));

        controller.Start();
        await WaitUntilAsync(() => Volatile.Read(ref captures) >= 2);
        await controller.StopAsync();
        var stoppedCount = Volatile.Read(ref captures);

        await Task.Delay(50);
        await controller.StopAsync();

        Assert.False(controller.IsRunning);
        Assert.Equal(stoppedCount, Volatile.Read(ref captures));
    }

    [Fact]
    public void SearchFindsBoundedCaseInsensitiveMatches()
    {
        var matches = DockerLogSessionController.FindMatches(
            "Error one\nnormal\nERROR two\nerror three",
            "error",
            maximumMatches: 2);

        Assert.Equal([0, 17], matches);
        Assert.Empty(DockerLogSessionController.FindMatches("content", ""));
    }

    private static DockerLogSessionContext CreateContext() => new(
        Guid.NewGuid(),
        Guid.NewGuid(),
        Guid.NewGuid(),
        "abcdef1234567890",
        "web",
        "example/web:latest");

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!condition())
        {
            timeout.Token.ThrowIfCancellationRequested();
            await Task.Delay(5, timeout.Token);
        }
    }
}
