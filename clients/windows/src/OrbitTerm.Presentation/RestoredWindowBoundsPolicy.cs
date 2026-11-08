namespace OrbitTerm.Presentation;

public readonly record struct WindowBounds(int X, int Y, int Width, int Height);

/// <summary>Fits a restored window to one display's usable screen coordinates.</summary>
public static class RestoredWindowBoundsPolicy
{
    public static WindowBounds FitToWorkArea(WindowBounds window, WindowBounds workArea)
    {
        // A transient display enumeration failure must not collapse the window.
        if (workArea.Width <= 0 || workArea.Height <= 0 || window.Width <= 0 || window.Height <= 0)
        {
            return window;
        }

        var width = Math.Min(window.Width, workArea.Width);
        var height = Math.Min(window.Height, workArea.Height);
        // Displays to the left or above the primary display legitimately use
        // negative coordinates. Use long arithmetic for coordinate + extent.
        var x = Math.Clamp((long)window.X, workArea.X, (long)workArea.X + workArea.Width - width);
        var y = Math.Clamp((long)window.Y, workArea.Y, (long)workArea.Y + workArea.Height - height);
        return new WindowBounds((int)x, (int)y, width, height);
    }
}
