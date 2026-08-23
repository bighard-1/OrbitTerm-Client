using OrbitTerm.Presentation;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalRowReflowTests
{
    [Fact]
    public void WiderHistoryWrapsToCurrentPtyColumnsWithoutMovingCursorRow()
    {
        var accent = TerminalStyle.Default with { Foreground = TerminalColor.Bright(2) };
        var screen = new TerminalScreenSnapshot(
            [
                new TerminalScreenRow("abcdefghij", [new TerminalTextRun("abcdefghij", accent)]),
                new TerminalScreenRow("$ ", [new TerminalTextRun("$ ", TerminalStyle.Default)]),
            ],
            CursorColumn: 2,
            CursorRow: 1,
            Size: new TerminalSize(5, 2),
            DiscardedHistoryLines: 0,
            HistoryRowCount: 1);

        var display = TerminalRowReflow.Reflow(screen);

        Assert.Equal(["abcde", "fghij", "$ "], display.Rows.Select(row => row.Text).ToArray());
        Assert.Equal(2, display.CursorRow);
        Assert.Equal(2, display.CursorColumn);
        Assert.All(display.Rows.Take(2), row => Assert.All(row.Runs, run => Assert.Equal(accent, run.Style)));
    }

    [Fact]
    public void WideCharactersNeverSplitAcrossWrappedRows()
    {
        var row = new TerminalScreenRow(
            "AB你CD",
            [new TerminalTextRun("AB你CD", TerminalStyle.Default)]);
        var screen = new TerminalScreenSnapshot(
            [row],
            CursorColumn: 0,
            CursorRow: 0,
            Size: new TerminalSize(3, 1),
            DiscardedHistoryLines: 0,
            HistoryRowCount: 0);

        var display = TerminalRowReflow.Reflow(screen);

        Assert.Equal(["AB", "你C", "D"], display.Rows.Select(item => item.Text).ToArray());
    }
}
