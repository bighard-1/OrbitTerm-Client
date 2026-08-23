namespace OrbitTerm.Application.Sessions;

/// <summary>
/// Bounded reconnect policy shared by the presentation layer and tests. The
/// final delay is capped so a rebooting host gets a useful recovery window
/// without causing an unbounded connection storm.
/// </summary>
public static class AutomaticReconnectPolicy
{
    public const int MaximumAttempts = 8;

    public static TimeSpan DelayBeforeAttempt(int oneBasedAttempt)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(oneBasedAttempt, 1);
        var seconds = oneBasedAttempt switch
        {
            1 => 1,
            2 => 2,
            3 => 4,
            4 => 8,
            5 => 15,
            _ => 30,
        };
        return TimeSpan.FromSeconds(seconds);
    }
}
