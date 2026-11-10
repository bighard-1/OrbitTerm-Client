using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class RestoredWindowBoundsPolicyTests
{
    [Theory]
    [InlineData(28, 166, 980, 572, 0, 0, 1280, 648, 28, 76, 980, 572)]
    [InlineData(100, 100, 980, 560, 0, 0, 1280, 720, 100, 100, 980, 560)]
    [InlineData(0, 0, 980, 560, 48, 40, 1232, 680, 48, 40, 980, 560)]
    [InlineData(-1800, -100, 980, 560, -1920, -200, 1920, 1040, -1800, -100, 980, 560)]
    [InlineData(-2400, -800, 1500, 900, -1600, -400, 1280, 720, -1600, -400, 1280, 720)]
    [InlineData(2600, 1400, 980, 700, 0, 0, 1280, 648, 300, 0, 980, 648)]
    [InlineData(20, 20, 980, 560, 0, 0, 800, 480, 0, 0, 800, 480)]
    [InlineData(int.MaxValue, int.MinValue, 1000, 600, int.MaxValue - 800, int.MinValue, 800, 600, int.MaxValue - 800, int.MinValue, 800, 600)]
    public void RecoveryKeepsTheWholeWindowInTheSelectedWorkArea(
        int x, int y, int width, int height,
        int areaX, int areaY, int areaWidth, int areaHeight,
        int expectedX, int expectedY, int expectedWidth, int expectedHeight)
    {
        var area = new WindowBounds(areaX, areaY, areaWidth, areaHeight);
        var result = RestoredWindowBoundsPolicy.FitToWorkArea(new WindowBounds(x, y, width, height), area);

        Assert.Equal(new WindowBounds(expectedX, expectedY, expectedWidth, expectedHeight), result);
        Assert.True(result.X >= area.X && result.Y >= area.Y);
        Assert.True((long)result.X + result.Width <= (long)area.X + area.Width);
        Assert.True((long)result.Y + result.Height <= (long)area.Y + area.Height);
        Assert.Equal(result, RestoredWindowBoundsPolicy.FitToWorkArea(result, area));
    }

    [Fact]
    public void UnavailableWorkAreaDoesNotInventARecoveryRectangle()
    {
        var window = new WindowBounds(-1400, 90, 980, 560);
        Assert.Equal(window, RestoredWindowBoundsPolicy.FitToWorkArea(window, new WindowBounds(0, 0, 0, 0)));
    }
}
