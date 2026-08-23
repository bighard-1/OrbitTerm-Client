using System.Text;

namespace OrbitTerm.Terminal;

/// <summary>
/// A small, platform-neutral VT screen model. It owns terminal state; UI layers
/// render its immutable snapshots and must not attempt to interpret ANSI bytes.
/// </summary>
public sealed class TerminalScreen
{
    private const int MaximumEscapeSequenceLength = 64;
    private const int MaximumOperatingSystemCommandLength = 4_096;

    private readonly List<TerminalScreenRow> history = [];
    private readonly List<Cell[]> rows = [];
    private readonly StringBuilder escape = new();
    private readonly StringBuilder operatingSystemCommand = new();
    private readonly int maximumHistoryLines;
    private TerminalStyle style = TerminalStyle.Default;
    private TerminalSize size;
    private int cursorColumn;
    private int cursorRow;
    private int savedCursorColumn;
    private int savedCursorRow;
    private EscapeState escapeState;
    private int discardedHistoryLines;
    private bool isAlternateScreen;
    private MainBufferState? savedMainBuffer;
    private string? windowTitle;

    public TerminalScreen(TerminalSize size, int maximumHistoryLines = 4_968)
    {
        size.Validate();
        if (maximumHistoryLines < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumHistoryLines));
        }

        this.size = size;
        this.maximumHistoryLines = maximumHistoryLines;
        ResetRows();
    }

    public TerminalSize Size => size;

    public void Write(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        foreach (var rune in text.EnumerateRunes())
        {
            Consume(rune);
        }
    }

    public void Resize(TerminalSize nextSize)
    {
        nextSize.Validate();
        if (nextSize == size)
        {
            return;
        }

        var existing = rows.Select(row => row.ToArray()).ToArray();
        size = nextSize;
        rows.Clear();

        // A narrower PTY must not permanently erase the cells that are merely
        // outside its temporary viewport. Retaining the row capacity lets a
        // later expansion restore scrollback exactly instead of filling the
        // previously clipped area with blanks.
        for (var rowIndex = 0; rowIndex < checked((int)size.Rows); rowIndex++)
        {
            if (rowIndex >= existing.Length)
            {
                rows.Add(CreateRow());
                continue;
            }

            var previous = existing[rowIndex];
            var capacity = Math.Max(previous.Length, checked((int)size.Columns));
            var resized = CreateRow(capacity);
            Array.Copy(previous, resized, previous.Length);
            rows.Add(resized);
        }

        cursorColumn = Math.Min(cursorColumn, checked((int)size.Columns - 1));
        cursorRow = Math.Min(cursorRow, checked((int)size.Rows - 1));
        savedCursorColumn = Math.Min(savedCursorColumn, checked((int)size.Columns - 1));
        savedCursorRow = Math.Min(savedCursorRow, checked((int)size.Rows - 1));
    }

    public TerminalScreenSnapshot Snapshot()
    {
        var lastVisibleRow = cursorRow;
        for (var index = rows.Count - 1; index > lastVisibleRow; index--)
        {
            if (rows[index].Any(cell => cell.Text != " " && !cell.IsContinuation))
            {
                lastVisibleRow = index;
                break;
            }
        }

        var result = new List<TerminalScreenRow>(history.Count + lastVisibleRow + 1);
        result.AddRange(history);
        for (var index = 0; index <= lastVisibleRow; index++)
        {
            result.Add(ToSnapshotRow(rows[index], checked((int)size.Columns)));
        }
        return new TerminalScreenSnapshot(
            result,
            cursorColumn,
            history.Count + cursorRow,
            size,
            discardedHistoryLines,
            history.Count,
            windowTitle);
    }

    /// <summary>
    /// Clears only this client's rendered terminal history and screen state.
    /// The checked SSH channel remains open, so later output starts from a clean
    /// local screen instead of replaying the old snapshot.
    /// </summary>
    public TerminalScreenSnapshot ClearPresentation()
    {
        Reset();
        return Snapshot();
    }

    private void Consume(Rune rune)
    {
        var character = rune.Value <= char.MaxValue ? (char)rune.Value : '\0';
        if (escapeState == EscapeState.Escape)
        {
            ConsumeEscape(character);
            return;
        }

        if (escapeState == EscapeState.ControlSequence)
        {
            ConsumeControlSequence(character);
            return;
        }

        if (escapeState == EscapeState.OperatingSystemCommand)
        {
            ConsumeOperatingSystemCommand(rune);
            return;
        }

        if (escapeState == EscapeState.OperatingSystemCommandEscape)
        {
            if (character == '\\')
            {
                CompleteOperatingSystemCommand();
            }
            else
            {
                // A non-ST escape inside an OSC payload is malformed. Keep
                // suppressing it instead of leaking title bytes into the PTY.
                escapeState = EscapeState.OperatingSystemCommand;
            }
            return;
        }

        switch (character)
        {
            case '\u001b':
                escapeState = EscapeState.Escape;
                return;
            case '\r':
                cursorColumn = 0;
                return;
            case '\n':
                LineFeed();
                return;
            case '\b':
                cursorColumn = Math.Max(0, cursorColumn - 1);
                return;
            case '\t':
                var target = Math.Min(checked((int)size.Columns - 1), ((cursorColumn / 8) + 1) * 8);
                while (cursorColumn < target)
                {
                    PutCharacter(new Rune(' '));
                }

                return;
            default:
                if (rune.Value >= ' ' && rune.Value != '\u007f')
                {
                    PutCharacter(rune);
                }

                return;
        }
    }

    private void ConsumeEscape(char character)
    {
        escapeState = EscapeState.None;
        switch (character)
        {
            case '[':
                escape.Clear();
                escapeState = EscapeState.ControlSequence;
                break;
            case ']':
                operatingSystemCommand.Clear();
                escapeState = EscapeState.OperatingSystemCommand;
                break;
            case '7':
                SaveCursor();
                break;
            case '8':
                RestoreCursor();
                break;
            case 'c':
                Reset();
                break;
        }
    }

    private void ConsumeControlSequence(char character)
    {
        if (character is >= '@' and <= '~')
        {
            ApplyControlSequence(escape.ToString(), character);
            escape.Clear();
            escapeState = EscapeState.None;
            return;
        }

        if (escape.Length >= MaximumEscapeSequenceLength || (character is not (>= '0' and <= '9') and not ';' and not '?' and not '>'))
        {
            escape.Clear();
            escapeState = EscapeState.None;
            return;
        }

        escape.Append(character);
    }

    private void ConsumeOperatingSystemCommand(Rune rune)
    {
        switch (rune.Value)
        {
            case '\u0007':
                CompleteOperatingSystemCommand();
                return;
            case '\u001b':
                escapeState = EscapeState.OperatingSystemCommandEscape;
                return;
        }

        if (rune.Value >= ' ' && operatingSystemCommand.Length < MaximumOperatingSystemCommandLength)
        {
            operatingSystemCommand.Append(rune.ToString());
        }
    }

    private void CompleteOperatingSystemCommand()
    {
        var payload = operatingSystemCommand.ToString();
        operatingSystemCommand.Clear();
        escapeState = EscapeState.None;

        var separator = payload.IndexOf(';');
        if (separator <= 0 ||
            !int.TryParse(payload.AsSpan(0, separator), out var command) ||
            command is not (0 or 2))
        {
            return;
        }

        var title = new string(payload[(separator + 1)..]
            .Where(character => !char.IsControl(character))
            .ToArray())
            .Trim();
        windowTitle = title.Length switch
        {
            0 => null,
            > 256 => title[..256],
            _ => title,
        };
    }

    private void ApplyControlSequence(string parameters, char command)
    {
        if (parameters.Length > 0 && parameters[0] == '?' && command is 'h' or 'l')
        {
            ApplyPrivateMode(parameters, command == 'h');
            return;
        }

        var values = ParseParameters(parameters);
        switch (command)
        {
            case 'A':
                cursorRow = Math.Max(0, cursorRow - ParameterOrDefault(values, 0, 1));
                break;
            case 'B':
                cursorRow = Math.Min(checked((int)size.Rows - 1), cursorRow + ParameterOrDefault(values, 0, 1));
                break;
            case 'C':
                cursorColumn = Math.Min(checked((int)size.Columns - 1), cursorColumn + ParameterOrDefault(values, 0, 1));
                break;
            case 'D':
                cursorColumn = Math.Max(0, cursorColumn - ParameterOrDefault(values, 0, 1));
                break;
            case 'G':
                cursorColumn = Math.Clamp(ParameterOrDefault(values, 0, 1) - 1, 0, checked((int)size.Columns - 1));
                break;
            case 'H':
            case 'f':
                cursorRow = Math.Clamp(ParameterOrDefault(values, 0, 1) - 1, 0, checked((int)size.Rows - 1));
                cursorColumn = Math.Clamp(ParameterOrDefault(values, 1, 1) - 1, 0, checked((int)size.Columns - 1));
                break;
            case 'J':
                EraseDisplay(ParameterOrDefault(values, 0, 0));
                break;
            case 'K':
                EraseLine(ParameterOrDefault(values, 0, 0));
                break;
            case 'm':
                ApplySgr(values);
                break;
            case 's':
                SaveCursor();
                break;
            case 'u':
                RestoreCursor();
                break;
        }
    }

    private void PutCharacter(Rune rune)
    {
        var width = TerminalTextMetrics.CellWidth(rune);
        if (width == 0)
        {
            return;
        }

        if (width == 2 && cursorColumn == size.Columns - 1)
        {
            cursorColumn = 0;
            LineFeed();
        }

        ClearWideCharacterAt(cursorRow, cursorColumn);
        rows[cursorRow][cursorColumn] = new Cell(rune.ToString(), style, false);
        if (width == 2)
        {
            rows[cursorRow][cursorColumn + 1] = new Cell(string.Empty, style, true);
        }

        cursorColumn += width;
        if (cursorColumn >= size.Columns)
        {
            cursorColumn = 0;
            LineFeed();
        }
    }

    private void LineFeed()
    {
        if (cursorRow < size.Rows - 1)
        {
            cursorRow++;
            return;
        }

        if (!isAlternateScreen)
        {
            history.Add(ToSnapshotRow(rows[0], checked((int)size.Columns)));
            while (history.Count > maximumHistoryLines)
            {
                history.RemoveAt(0);
                discardedHistoryLines++;
            }
        }

        rows.RemoveAt(0);
        rows.Add(CreateRow());
    }

    private void EraseDisplay(int mode)
    {
        switch (mode)
        {
            case 1:
                for (var row = 0; row <= cursorRow; row++)
                {
                    var end = row == cursorRow ? cursorColumn : checked((int)size.Columns - 1);
                    ClearCells(rows[row], 0, end);
                }

                break;
            case 2:
            case 3:
                foreach (var row in rows)
                {
                    ClearCells(row, 0, row.Length - 1);
                }

                if (mode == 3)
                {
                    discardedHistoryLines += history.Count;
                    history.Clear();
                }

                break;
            default:
                ClearCells(rows[cursorRow], cursorColumn, checked((int)size.Columns - 1));
                for (var row = cursorRow + 1; row < rows.Count; row++)
                {
                    ClearCells(rows[row], 0, checked((int)size.Columns - 1));
                }

                break;
        }
    }

    private void EraseLine(int mode)
    {
        switch (mode)
        {
            case 1:
                ClearCells(rows[cursorRow], 0, cursorColumn);
                break;
            case 2:
                ClearCells(rows[cursorRow], 0, checked((int)size.Columns - 1));
                break;
            default:
                ClearCells(rows[cursorRow], cursorColumn, checked((int)size.Columns - 1));
                break;
        }
    }

    private void ApplySgr(IReadOnlyList<int> values)
    {
        if (values.Count == 0)
        {
            style = TerminalStyle.Default;
            return;
        }

        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];
            switch (value)
            {
                case 0:
                    style = TerminalStyle.Default;
                    break;
                case 1:
                    style = style with { IsBold = true };
                    break;
                case 4:
                    style = style with { IsUnderlined = true };
                    break;
                case 7:
                    style = style with { IsInverse = true };
                    break;
                case 22:
                    style = style with { IsBold = false };
                    break;
                case 24:
                    style = style with { IsUnderlined = false };
                    break;
                case 27:
                    style = style with { IsInverse = false };
                    break;
                case >= 30 and <= 37:
                    style = style with { Foreground = TerminalColor.Standard(value - 30) };
                    break;
                case 39:
                    style = style with { Foreground = TerminalColor.Default };
                    break;
                case >= 40 and <= 47:
                    style = style with { Background = TerminalColor.Standard(value - 40) };
                    break;
                case 49:
                    style = style with { Background = TerminalColor.Default };
                    break;
                case >= 90 and <= 97:
                    style = style with { Foreground = TerminalColor.Bright(value - 90) };
                    break;
                case >= 100 and <= 107:
                    style = style with { Background = TerminalColor.Bright(value - 100) };
                    break;
                case 38 when index + 2 < values.Count && values[index + 1] == 5:
                    style = style with { Foreground = TerminalColor.Indexed(values[index + 2]) };
                    index += 2;
                    break;
                case 48 when index + 2 < values.Count && values[index + 1] == 5:
                    style = style with { Background = TerminalColor.Indexed(values[index + 2]) };
                    index += 2;
                    break;
                case 38 when index + 4 < values.Count && values[index + 1] == 2:
                    style = style with
                    {
                        Foreground = TerminalColor.TrueColor(
                            values[index + 2], values[index + 3], values[index + 4]),
                    };
                    index += 4;
                    break;
                case 48 when index + 4 < values.Count && values[index + 1] == 2:
                    style = style with
                    {
                        Background = TerminalColor.TrueColor(
                            values[index + 2], values[index + 3], values[index + 4]),
                    };
                    index += 4;
                    break;
            }
        }
    }

    private void SaveCursor()
    {
        savedCursorColumn = cursorColumn;
        savedCursorRow = cursorRow;
    }

    private void RestoreCursor()
    {
        cursorColumn = savedCursorColumn;
        cursorRow = savedCursorRow;
    }

    private void ApplyPrivateMode(string parameters, bool enabled)
    {
        foreach (var token in parameters[1..].Split(';'))
        {
            if (!int.TryParse(token, out var mode))
            {
                continue;
            }
            switch (mode)
            {
                case 1047:
                case 1049:
                    if (enabled)
                    {
                        EnterAlternateScreen();
                    }
                    else
                    {
                        ExitAlternateScreen();
                    }
                    break;
                case 1048:
                    if (enabled)
                    {
                        SaveCursor();
                    }
                    else
                    {
                        RestoreCursor();
                    }
                    break;
            }
        }
    }

    private void EnterAlternateScreen()
    {
        if (isAlternateScreen)
        {
            return;
        }

        savedMainBuffer = new MainBufferState(
            history.ToArray(),
            rows.Select(static row => row.ToArray()).ToArray(),
            style,
            cursorColumn,
            cursorRow,
            savedCursorColumn,
            savedCursorRow,
            discardedHistoryLines);
        isAlternateScreen = true;
        style = TerminalStyle.Default;
        history.Clear();
        discardedHistoryLines = 0;
        cursorColumn = 0;
        cursorRow = 0;
        savedCursorColumn = 0;
        savedCursorRow = 0;
        ResetRows();
    }

    private void ExitAlternateScreen()
    {
        if (!isAlternateScreen || savedMainBuffer is not { } main)
        {
            return;
        }

        isAlternateScreen = false;
        savedMainBuffer = null;
        history.Clear();
        history.AddRange(main.History);
        rows.Clear();
        for (var rowIndex = 0; rowIndex < checked((int)size.Rows); rowIndex++)
        {
            if (rowIndex >= main.Rows.Length)
            {
                rows.Add(CreateRow());
                continue;
            }
            var source = main.Rows[rowIndex];
            var restored = CreateRow(Math.Max(source.Length, checked((int)size.Columns)));
            Array.Copy(source, restored, source.Length);
            rows.Add(restored);
        }
        style = main.Style;
        cursorColumn = Math.Clamp(main.CursorColumn, 0, checked((int)size.Columns - 1));
        cursorRow = Math.Clamp(main.CursorRow, 0, checked((int)size.Rows - 1));
        savedCursorColumn = Math.Clamp(main.SavedCursorColumn, 0, checked((int)size.Columns - 1));
        savedCursorRow = Math.Clamp(main.SavedCursorRow, 0, checked((int)size.Rows - 1));
        discardedHistoryLines = main.DiscardedHistoryLines;
    }

    private void Reset()
    {
        style = TerminalStyle.Default;
        history.Clear();
        discardedHistoryLines = 0;
        cursorColumn = 0;
        cursorRow = 0;
        savedCursorColumn = 0;
        savedCursorRow = 0;
        ResetRows();
    }

    private void ResetRows()
    {
        rows.Clear();
        for (var index = 0; index < size.Rows; index++)
        {
            rows.Add(CreateRow());
        }
    }

    private Cell[] CreateRow() => CreateRow(checked((int)size.Columns));

    private static Cell[] CreateRow(int columns) =>
        Enumerable.Repeat(new Cell(" ", TerminalStyle.Default, false), columns).ToArray();

    private static void ClearCells(Cell[] row, int start, int end)
    {
        for (var index = start; index <= end; index++)
        {
            row[index] = new Cell(" ", TerminalStyle.Default, false);
        }
    }

    private static TerminalScreenRow ToSnapshotRow(Cell[] cells, int visibleColumns)
    {
        var end = Math.Min(cells.Length, visibleColumns) - 1;
        while (end >= 0 && cells[end].Text == " ")
        {
            end--;
        }

        if (end < 0)
        {
            return new TerminalScreenRow(string.Empty, []);
        }

        var text = new StringBuilder(end + 1);
        var runs = new List<TerminalTextRun>();
        var runStyle = TerminalStyle.Default;
        var hasRun = false;
        for (var index = 0; index <= end; index++)
        {
            var cell = cells[index];
            if (cell.IsContinuation)
            {
                continue;
            }

            if (hasRun && cell.Style != runStyle)
            {
                runs.Add(new TerminalTextRun(text.ToString(), runStyle));
                text.Clear();
                runStyle = cell.Style;
            }

            runStyle = cell.Style;
            hasRun = true;
            text.Append(cell.Text);
        }

        if (hasRun)
        {
            runs.Add(new TerminalTextRun(text.ToString(), runStyle));
        }

        return new TerminalScreenRow(string.Concat(runs.Select(run => run.Text)), runs);
    }

    private static List<int> ParseParameters(string parameters)
    {
        if (string.IsNullOrEmpty(parameters) || parameters[0] is '?' or '>')
        {
            return [];
        }

        return parameters.Split(';').Select(value => int.TryParse(value, out var parsed) ? parsed : 0).ToList();
    }

    private static int ParameterOrDefault(IReadOnlyList<int> values, int index, int defaultValue) =>
        index < values.Count && values[index] != 0 ? values[index] : defaultValue;

    private void ClearWideCharacterAt(int rowIndex, int columnIndex)
    {
        var row = rows[rowIndex];
        if (row[columnIndex].IsContinuation && columnIndex > 0)
        {
            row[columnIndex - 1] = new Cell(" ", TerminalStyle.Default, false);
        }

        if (!row[columnIndex].IsContinuation && columnIndex + 1 < row.Length && row[columnIndex + 1].IsContinuation)
        {
            row[columnIndex + 1] = new Cell(" ", TerminalStyle.Default, false);
        }
    }

    private readonly record struct Cell(string Text, TerminalStyle Style, bool IsContinuation);

    private sealed record MainBufferState(
        TerminalScreenRow[] History,
        Cell[][] Rows,
        TerminalStyle Style,
        int CursorColumn,
        int CursorRow,
        int SavedCursorColumn,
        int SavedCursorRow,
        int DiscardedHistoryLines);

    private enum EscapeState
    {
        None,
        Escape,
        ControlSequence,
        OperatingSystemCommand,
        OperatingSystemCommandEscape,
    }
}

public enum TerminalColorKind
{
    Default,
    Standard,
    Bright,
    Indexed,
    TrueColor,
}

public readonly record struct TerminalColor(TerminalColorKind Kind, int Value = 0)
{
    public static TerminalColor Default => new(TerminalColorKind.Default);

    public static TerminalColor Standard(int value) => new(TerminalColorKind.Standard, value);

    public static TerminalColor Bright(int value) => new(TerminalColorKind.Bright, value);

    public static TerminalColor Indexed(int value) => new(TerminalColorKind.Indexed, Math.Clamp(value, 0, 255));

    public static TerminalColor TrueColor(int red, int green, int blue) => new(
        TerminalColorKind.TrueColor,
        (Math.Clamp(red, 0, 255) << 16) |
        (Math.Clamp(green, 0, 255) << 8) |
        Math.Clamp(blue, 0, 255));
}

public readonly record struct TerminalStyle(
    TerminalColor Foreground,
    TerminalColor Background,
    bool IsBold,
    bool IsUnderlined,
    bool IsInverse)
{
    public static TerminalStyle Default => new(TerminalColor.Default, TerminalColor.Default, false, false, false);
}

public sealed record TerminalTextRun(string Text, TerminalStyle Style);

public sealed record TerminalScreenRow(string Text, IReadOnlyList<TerminalTextRun> Runs);

public sealed record TerminalScreenSnapshot(
    IReadOnlyList<TerminalScreenRow> Rows,
    int CursorColumn,
    int CursorRow,
    TerminalSize Size,
    int DiscardedHistoryLines,
    int HistoryRowCount,
    string? WindowTitle = null);
