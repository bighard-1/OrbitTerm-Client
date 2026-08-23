using System.Text;
using OrbitTerm.Terminal;

namespace OrbitTerm.Presentation;

public sealed record TerminalDisplayRows(
    IReadOnlyList<TerminalScreenRow> Rows,
    int CursorRow,
    int CursorColumn);

/// <summary>
/// Reflows physical scrollback rows that were produced by a wider PTY. Active
/// screen rows are already constrained by TerminalScreen; this closes the gap
/// for history after the inspector or window narrows without introducing an
/// unsafe horizontal scroll surface.
/// </summary>
public static class TerminalRowReflow
{
    public static TerminalDisplayRows Reflow(TerminalScreenSnapshot screen)
    {
        var columns = checked((int)screen.Size.Columns);
        var result = new List<TerminalScreenRow>(screen.Rows.Count);
        var cursorRow = 0;
        var cursorColumn = screen.CursorColumn;

        for (var sourceIndex = 0; sourceIndex < screen.Rows.Count; sourceIndex++)
        {
            var segments = Split(screen.Rows[sourceIndex], columns);
            if (sourceIndex == screen.CursorRow)
            {
                var cursorSegment = Math.Clamp(screen.CursorColumn / columns, 0, segments.Count - 1);
                cursorRow = result.Count + cursorSegment;
                cursorColumn = screen.CursorColumn % columns;
            }
            result.AddRange(segments);
        }

        return new TerminalDisplayRows(result, cursorRow, cursorColumn);
    }

    private static IReadOnlyList<TerminalScreenRow> Split(TerminalScreenRow row, int columns)
    {
        if (row.Text.Length == 0 || TerminalTextMetrics.CellWidth(row.Text) <= columns)
        {
            return [row];
        }

        var sourceRuns = row.Runs.Count == 0
            ? [new TerminalTextRun(row.Text, TerminalStyle.Default)]
            : row.Runs;
        var rows = new List<TerminalScreenRow>();
        var lineRuns = new List<TerminalTextRun>();
        var runText = new StringBuilder();
        var lineText = new StringBuilder();
        var activeStyle = TerminalStyle.Default;
        var hasActiveStyle = false;
        var usedColumns = 0;

        void FlushRun()
        {
            if (runText.Length == 0)
            {
                return;
            }
            lineRuns.Add(new TerminalTextRun(runText.ToString(), activeStyle));
            runText.Clear();
        }

        void FlushLine()
        {
            FlushRun();
            rows.Add(new TerminalScreenRow(lineText.ToString(), lineRuns.ToArray()));
            lineText.Clear();
            lineRuns.Clear();
            hasActiveStyle = false;
            usedColumns = 0;
        }

        foreach (var sourceRun in sourceRuns)
        {
            foreach (var rune in sourceRun.Text.EnumerateRunes())
            {
                var width = TerminalTextMetrics.CellWidth(rune);
                if (width > 0 && usedColumns > 0 && usedColumns + width > columns)
                {
                    FlushLine();
                }
                if (!hasActiveStyle || activeStyle != sourceRun.Style)
                {
                    FlushRun();
                    activeStyle = sourceRun.Style;
                    hasActiveStyle = true;
                }
                var text = rune.ToString();
                runText.Append(text);
                lineText.Append(text);
                usedColumns += width;
            }
        }

        if (lineText.Length > 0 || rows.Count == 0)
        {
            FlushLine();
        }
        return rows;
    }
}
