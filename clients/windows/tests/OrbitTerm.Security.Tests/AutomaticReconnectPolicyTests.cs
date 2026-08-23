using OrbitTerm.Application.Sessions;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class AutomaticReconnectPolicyTests
{
    [Fact]
    public void UsesBoundedExponentialBackoff()
    {
        var delays = Enumerable.Range(1, AutomaticReconnectPolicy.MaximumAttempts)
            .Select(AutomaticReconnectPolicy.DelayBeforeAttempt)
            .ToArray();

        Assert.Equal(TimeSpan.FromSeconds(1), delays[0]);
        Assert.Equal(TimeSpan.FromSeconds(15), delays[4]);
        Assert.All(delays.Skip(5), delay => Assert.Equal(TimeSpan.FromSeconds(30), delay));
    }
}
