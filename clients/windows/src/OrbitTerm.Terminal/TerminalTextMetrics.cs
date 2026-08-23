using System.Text;

namespace OrbitTerm.Terminal;

public static class TerminalTextMetrics
{
    public static int CellWidth(Rune rune)
    {
        var value = rune.Value;
        if (value is 0x200D or 0xFE0F || value is >= 0x300 and <= 0x36F)
        {
            return 0;
        }

        return value is >= 0x1100 and <= 0x115F or
            >= 0x2329 and <= 0x232A or
            >= 0x2E80 and <= 0xA4CF or
            >= 0xAC00 and <= 0xD7A3 or
            >= 0xF900 and <= 0xFAFF or
            >= 0xFE10 and <= 0xFE19 or
            >= 0xFE30 and <= 0xFE6F or
            >= 0xFF00 and <= 0xFF60 or
            >= 0xFFE0 and <= 0xFFE6 or
            >= 0x1F300 and <= 0x1FAFF or
            >= 0x20000 and <= 0x3FFFD
            ? 2
            : 1;
    }

    public static int CellWidth(string text) =>
        text.EnumerateRunes().Sum(CellWidth);
}
