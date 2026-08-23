namespace OrbitTerm.Terminal;

/// <summary>
/// Shared fixed-cell selection geometry. Selection columns are caret boundaries
/// and the end boundary is always exclusive.
/// </summary>
public static class TerminalSelectionMath
{
    public static int ToCaretColumn(
        double pointerX,
        double contentOriginX,
        double cellWidth,
        int lineCellWidth)
    {
        if (!double.IsFinite(pointerX) || !double.IsFinite(contentOriginX) ||
            !double.IsFinite(cellWidth) || cellWidth <= 0)
        {
            return 0;
        }

        var rawColumn = (pointerX - contentOriginX) / cellWidth;
        return Math.Clamp(
            (int)Math.Round(rawColumn, MidpointRounding.AwayFromZero),
            0,
            Math.Max(0, lineCellWidth));
    }
}
