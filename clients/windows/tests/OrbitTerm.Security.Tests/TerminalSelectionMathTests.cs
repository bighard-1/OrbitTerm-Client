using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalSelectionMathTests
{
    [Theory]
    [InlineData(10.0, 0)]
    [InlineData(17.9, 1)]
    [InlineData(18.1, 1)]
    [InlineData(25.9, 2)]
    [InlineData(58.0, 6)]
    public void ToCaretColumn_UsesNearestExclusiveTextBoundary(double pointerX, int expected)
    {
        Assert.Equal(expected, TerminalSelectionMath.ToCaretColumn(pointerX, 10, 8, 7));
    }

    [Theory]
    [InlineData(-100, 0)]
    [InlineData(1000, 7)]
    public void ToCaretColumn_ClampsToCurrentLine(double pointerX, int expected)
    {
        Assert.Equal(expected, TerminalSelectionMath.ToCaretColumn(pointerX, 10, 8, 7));
    }
}
