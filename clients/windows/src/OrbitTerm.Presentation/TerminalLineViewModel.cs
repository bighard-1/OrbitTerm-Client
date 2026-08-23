using OrbitTerm.Terminal;

namespace OrbitTerm.Presentation;

public sealed class TerminalLineViewModel : ObservableObject
{
    private string text;
    private IReadOnlyList<TerminalTextRun> runs;
    private bool isCursorRow;
    private int cursorColumn;

    public TerminalLineViewModel(string text, bool isCommand)
        : this(text, isCommand, [new TerminalTextRun(text, TerminalStyle.Default)], false, -1)
    {
    }

    public TerminalLineViewModel(string text, bool isCommand, IReadOnlyList<TerminalTextRun> runs, bool isCursorRow, int cursorColumn = -1)
    {
        this.text = text;
        IsCommand = isCommand;
        this.runs = runs;
        this.isCursorRow = isCursorRow;
        this.cursorColumn = cursorColumn;
    }

    public string Text
    {
        get => text;
        private set => SetProperty(ref text, value);
    }

    public bool IsCommand { get; }

    public IReadOnlyList<TerminalTextRun> Runs
    {
        get => runs;
        private set => SetProperty(ref runs, value);
    }

    public bool IsCursorRow
    {
        get => isCursorRow;
        private set => SetProperty(ref isCursorRow, value);
    }

    public int CursorColumn
    {
        get => cursorColumn;
        private set => SetProperty(ref cursorColumn, value);
    }

    public void Apply(TerminalScreenRow row, bool isCursor, int nextCursorColumn)
    {
        Text = row.Text;
        if (!Runs.SequenceEqual(row.Runs))
        {
            Runs = row.Runs;
        }
        IsCursorRow = isCursor;
        CursorColumn = isCursor ? Math.Max(0, nextCursorColumn) : -1;
    }

    /// <summary>
    /// Gives the command composer immediate, prompt-correct feedback while the
    /// native SSH write is queued. The next authoritative PTY snapshot replaces
    /// this preview, so it cannot duplicate the remote shell echo.
    /// </summary>
    public bool TryPreviewInputAtCursor(string input)
    {
        if (!IsCursorRow || CursorColumn < Text.Length || string.IsNullOrEmpty(input))
        {
            return false;
        }

        var padding = new string(' ', CursorColumn - Text.Length);
        var preview = string.Concat(padding, input);
        var style = Runs.LastOrDefault()?.Style ?? TerminalStyle.Default;
        Text = string.Concat(Text, preview);
        Runs = [.. Runs, new TerminalTextRun(preview, style)];
        CursorColumn += input.Length;
        return true;
    }
}
