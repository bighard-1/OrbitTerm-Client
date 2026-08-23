using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalScreenTests
{
    [Fact]
    public void OscWindowTitleIsCapturedWithoutLeakingIntoTerminalRows()
    {
        var screen = new TerminalScreen(new TerminalSize(80, 4));

        screen.Write("\u001b]0;ubuntu@instance-20260819-1542: ~\u0007");
        screen.Write("ubuntu@instance-20260819-1542:~$ ");

        var snapshot = screen.Snapshot();
        Assert.Equal("ubuntu@instance-20260819-1542: ~", snapshot.WindowTitle);
        Assert.Equal("ubuntu@instance-20260819-1542:~$", snapshot.Rows[0].Text);
        Assert.DoesNotContain("0;", snapshot.Rows[0].Text, StringComparison.Ordinal);
    }

    [Fact]
    public void FragmentedOscUsingStringTerminatorDoesNotLeakIntoTerminalRows()
    {
        var screen = new TerminalScreen(new TerminalSize(80, 4));

        screen.Write("\u001b]2;root@host-name:");
        screen.Write(" /tmp\u001b");
        screen.Write("\\prompt$ ");

        var snapshot = screen.Snapshot();
        Assert.Equal("root@host-name: /tmp", snapshot.WindowTitle);
        Assert.Equal("prompt$", snapshot.Rows[0].Text);
    }

    [Fact]
    public void IncrementalSgrSequenceProducesStyledRuns()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 4));

        screen.Write("\u001b[3");
        screen.Write("1m红\u001b[0m text");

        var row = screen.Snapshot().Rows[0];
        Assert.Equal("红 text", row.Text);
        Assert.Equal(TerminalColor.Standard(1), row.Runs[0].Style.Foreground);
        Assert.Equal(TerminalColor.Default, row.Runs[1].Style.Foreground);
    }

    [Fact]
    public void CarriageReturnOverwritesCurrentLineWithoutCreatingAnotherLine()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 4));

        screen.Write("hello\rHi");

        Assert.Equal("Hillo", screen.Snapshot().Rows[0].Text);
    }

    [Fact]
    public void ScrollingRetainsBoundedHistoryAndReportsDiscardedRows()
    {
        var screen = new TerminalScreen(new TerminalSize(8, 2), maximumHistoryLines: 1);

        // LF preserves the column in a terminal; CRLF is the line-ending emitted
        // by the interactive shells covered by this scrolling scenario.
        screen.Write("one\r\ntwo\r\nthree\r\nfour");

        var snapshot = screen.Snapshot();
        Assert.Equal(new[] { "two", "three", "four" }, snapshot.Rows.Select(row => row.Text));
        Assert.Equal(1, snapshot.DiscardedHistoryLines);
    }

    [Fact]
    public void DefaultScrollbackRetainsLongOperationalOutputBeyondLegacyLimit()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 4));
        for (var index = 0; index < 800; index++)
        {
            screen.Write($"row-{index}\r\n");
        }

        var snapshot = screen.Snapshot();
        Assert.Equal(0, snapshot.DiscardedHistoryLines);
        Assert.Contains(snapshot.Rows, row => row.Text == "row-0");
        Assert.Contains(snapshot.Rows, row => row.Text == "row-799");
    }

    [Fact]
    public void ResizePreservesVisibleCellsAndClampsCursor()
    {
        var screen = new TerminalScreen(new TerminalSize(8, 2));
        screen.Write("abcdef");

        screen.Resize(new TerminalSize(4, 1));

        var snapshot = screen.Snapshot();
        Assert.Equal("abcd", snapshot.Rows[0].Text);
        Assert.InRange(snapshot.CursorColumn, 0, 3);
        Assert.Equal(0, snapshot.CursorRow);
    }

    [Fact]
    public void ResizeRestoresTemporarilyHiddenColumnsAfterExpansion()
    {
        var screen = new TerminalScreen(new TerminalSize(8, 2));
        screen.Write("abcdef");

        screen.Resize(new TerminalSize(4, 2));
        Assert.Equal("abcd", screen.Snapshot().Rows[0].Text);

        screen.Resize(new TerminalSize(8, 2));

        Assert.Equal("abcdef", screen.Snapshot().Rows[0].Text);
    }

    [Theory]
    [InlineData("你A")]
    [InlineData("😀A")]
    public void WideUnicodeCellsAdvanceTheCursorByTwoColumns(string text)
    {
        var screen = new TerminalScreen(new TerminalSize(8, 2));

        screen.Write(text);

        var snapshot = screen.Snapshot();
        Assert.Equal(text, snapshot.Rows[0].Text);
        Assert.Equal(3, snapshot.CursorColumn);
    }

    [Fact]
    public void WideUnicodeAtRightEdgeWrapsAsTwoCellsWithoutSplittingTheRune()
    {
        var screen = new TerminalScreen(new TerminalSize(3, 2));

        screen.Write("AB你");

        var snapshot = screen.Snapshot();
        Assert.Equal("AB", snapshot.Rows[0].Text);
        Assert.Equal("你", snapshot.Rows[1].Text);
        Assert.Equal(2, snapshot.CursorColumn);
        Assert.Equal(1, snapshot.CursorRow);
    }

    [Fact]
    public void IndexedAnsiColoursRemainInTheScreenStyleRuns()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 2));

        screen.Write("\u001b[38;5;196;48;5;22m彩\u001b[0m");

        var run = Assert.Single(screen.Snapshot().Rows[0].Runs);
        Assert.Equal("彩", run.Text);
        Assert.Equal(TerminalColor.Indexed(196), run.Style.Foreground);
        Assert.Equal(TerminalColor.Indexed(22), run.Style.Background);
    }

    [Fact]
    public void TwentyFourBitAnsiColoursRemainInTheScreenStyleRuns()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 2));

        screen.Write("\u001b[38;2;12;34;56;48;2;210;190;170m彩\u001b[0m");

        var run = Assert.Single(screen.Snapshot().Rows[0].Runs);
        Assert.Equal(TerminalColor.TrueColor(12, 34, 56), run.Style.Foreground);
        Assert.Equal(TerminalColor.TrueColor(210, 190, 170), run.Style.Background);
    }

    [Fact]
    public void AlternateScreenRefreshReplacesTopFrameWithoutGrowingScrollback()
    {
        var screen = new TerminalScreen(new TerminalSize(24, 4));
        screen.Write("shell prompt$ top\r\n");

        screen.Write("\u001b[?1049h\u001b[H\u001b[2Jtop frame one\r\ncpu 10%");
        screen.Write("\u001b[H\u001b[2Jtop frame two\r\ncpu 20%");

        var active = screen.Snapshot();
        Assert.Equal(new[] { "top frame two", "cpu 20%" }, active.Rows.Select(row => row.Text));
        Assert.DoesNotContain(active.Rows, row => row.Text.Contains("frame one", StringComparison.Ordinal));
        Assert.Equal(0, active.DiscardedHistoryLines);

        screen.Write("\u001b[?1049l");
        var restored = screen.Snapshot();
        Assert.Contains(restored.Rows, row => row.Text.Contains("shell prompt$ top", StringComparison.Ordinal));
        Assert.DoesNotContain(restored.Rows, row => row.Text.Contains("frame two", StringComparison.Ordinal));
    }

    [Fact]
    public void AlternateScreenBottomScrollDoesNotLeakFramesIntoHistory()
    {
        var screen = new TerminalScreen(new TerminalSize(12, 2), maximumHistoryLines: 10);
        screen.Write("\u001b[?1049h");

        screen.Write("one\r\ntwo\r\nthree\r\nfour");

        var snapshot = screen.Snapshot();
        Assert.Equal(new[] { "three", "four" }, snapshot.Rows.Select(row => row.Text));
        Assert.Equal(0, snapshot.DiscardedHistoryLines);
    }
}
