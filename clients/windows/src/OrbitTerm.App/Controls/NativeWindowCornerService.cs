using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Requests the Windows 11 native rounded-window treatment without clipping
/// the app surface. Windows 10 safely keeps its native square window frame.
/// </summary>
internal static class NativeWindowCornerService
{
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwcpRound = 2;
    private const int DwmwaUseImmersiveDarkModeBefore20H1 = 19;
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int Windows10CornerRadius = 12;
    private const int GwlStyle = -16;
    private const long WsThickFrame = 0x00040000L;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private const uint WmNcHitTest = 0x0084;
    private const uint WmNcCalcSize = 0x0083;
    private const uint WmNcDestroy = 0x0082;
    private const uint WmNcLeftButtonDown = 0x00A1;
    private const uint WmSystemCommand = 0x0112;
    private const int ScSize = 0xF000;
    private const int HtNowhere = 0;
    private const int HtClient = 1;
    private const int HtCaption = 2;
    private const int HtLeft = 10;
    private const int HtRight = 11;
    private const int HtTop = 12;
    private const int HtTopLeft = 13;
    private const int HtTopRight = 14;
    private const int HtBottom = 15;
    private const int HtBottomLeft = 16;
    private const int HtBottomRight = 17;
    private const int HtBorder = 18;
    private const int WmszLeft = 1;
    private const int WmszRight = 2;
    private const int WmszTop = 3;
    private const int WmszTopLeft = 4;
    private const int WmszTopRight = 5;
    private const int WmszBottom = 6;
    private const int WmszBottomLeft = 7;
    private const int WmszBottomRight = 8;
    private static readonly UIntPtr ResizeSubclassId = new(0x4F544652);
    private static readonly WindowSubclassProc ResizeSubclassProc = Windows10ResizeSubclass;

    public static void Apply(Window window)
    {
        var windowHandle = WindowNative.GetWindowHandle(window);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            ApplyWindows10Region(windowHandle);
            window.AppWindow.Changed += (_, args) =>
            {
                if (args.DidSizeChange || args.DidPresenterChange)
                {
                    ApplyWindows10Region(windowHandle);
                }
            };
            return;
        }

        var preference = DwmwcpRound;
        _ = DwmSetWindowAttribute(
            windowHandle,
            DwmwaWindowCornerPreference,
            ref preference,
            Marshal.SizeOf<int>());
    }

    public static void ApplyVisibleFrameTheme(Window window, bool dark)
    {
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            return;
        }

        var windowHandle = WindowNative.GetWindowHandle(window);
        if (!IsWindowVisible(windowHandle))
        {
            return;
        }

        // Keep the real Win10 sizing frame. Returning custom HTLEFT/HTRIGHT
        // values after removing WS_THICKFRAME works on some builds but LTSC
        // 2021 can ignore the horizontal/corner sizing loop. The native frame
        // is the dependable implementation across supported Win10 builds.
        // Use Win10's dark non-client attribute so the frame does not remain
        // bright when the application switches to a dark palette.
        _ = RemoveWindowSubclass(windowHandle, ResizeSubclassProc, ResizeSubclassId);
        var darkMode = dark ? 1 : 0;
        if (DwmSetWindowAttribute(
                windowHandle,
                DwmwaUseImmersiveDarkMode,
                ref darkMode,
                Marshal.SizeOf<int>()) != 0)
        {
            _ = DwmSetWindowAttribute(
                windowHandle,
                DwmwaUseImmersiveDarkModeBefore20H1,
                ref darkMode,
                Marshal.SizeOf<int>());
        }
        var style = GetWindowLongPtr(windowHandle, GwlStyle).ToInt64();
        if ((style & WsThickFrame) == 0)
        {
            _ = SetWindowLongPtr(windowHandle, GwlStyle, new nint(style | WsThickFrame));
            _ = SetWindowPos(
                windowHandle,
                nint.Zero,
                0,
                0,
                0,
                0,
                SwpNoSize | SwpNoMove | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
        }
        ApplyWindows10Region(windowHandle);
    }

    private static nint Windows10ResizeSubclass(
        nint windowHandle,
        uint message,
        nint wParam,
        nint lParam,
        UIntPtr subclassId,
        nint referenceData)
    {
        if (message == WmNcDestroy)
        {
            _ = RemoveWindowSubclass(windowHandle, ResizeSubclassProc, ResizeSubclassId);
            return DefSubclassProc(windowHandle, message, wParam, lParam);
        }
        if (message == WmNcLeftButtonDown && !IsZoomed(windowHandle))
        {
            var resizeDirection = wParam.ToInt32() switch
            {
                HtLeft => WmszLeft,
                HtRight => WmszRight,
                HtTop => WmszTop,
                HtTopLeft => WmszTopLeft,
                HtTopRight => WmszTopRight,
                HtBottom => WmszBottom,
                HtBottomLeft => WmszBottomLeft,
                HtBottomRight => WmszBottomRight,
                _ => 0,
            };
            if (resizeDirection != 0)
            {
                // Win10 can report the correct HTLEFT/HTRIGHT value but still
                // decline to start sizing after its visible WS_THICKFRAME was
                // removed. Temporarily expose that capability only while the
                // native SC_SIZE loop is active. No frame recalculation is
                // requested, so the light Win10 system border stays hidden.
                var style = GetWindowLongPtr(windowHandle, GwlStyle).ToInt64();
                var restoredThickFrame = (style & WsThickFrame) == 0;
                if (restoredThickFrame)
                {
                    _ = SetWindowLongPtr(windowHandle, GwlStyle, new nint(style | WsThickFrame));
                }

                try
                {
                    _ = ReleaseCapture();
                    _ = SendMessage(
                        windowHandle,
                        WmSystemCommand,
                        new nint(ScSize + resizeDirection),
                        nint.Zero);
                }
                finally
                {
                    if (restoredThickFrame)
                    {
                        var currentStyle = GetWindowLongPtr(windowHandle, GwlStyle).ToInt64();
                        _ = SetWindowLongPtr(
                            windowHandle,
                            GwlStyle,
                            new nint(currentStyle & ~WsThickFrame));
                        ApplyWindows10Region(windowHandle);
                    }
                }
                return nint.Zero;
            }
        }
        if (message == WmNcCalcSize && wParam != nint.Zero)
        {
            // Keep WS_CAPTION so Windows App SDK retains caption buttons,
            // drag-to-move and snap integration, but make the WinUI client
            // cover the system-owned side and bottom caption frame. Returning
            // zero is the documented borderless-client calculation for a
            // custom frame; our hit-test branch restores resizing.
            return nint.Zero;
        }
        if (message != WmNcHitTest || IsZoomed(windowHandle))
        {
            return DefSubclassProc(windowHandle, message, wParam, lParam);
        }

        var fallback = DefSubclassProc(windowHandle, message, wParam, lParam);
        var fallbackHit = fallback.ToInt32();
        // Once WS_THICKFRAME is removed Windows 10 commonly reports
        // HTNOWHERE on the left/right edge while it still reports HTCLIENT or
        // HTCAPTION near the top/bottom. Treat all three as areas where our
        // custom resize frame may take ownership. Caption buttons and other
        // non-client controls keep their original hit-test result.
        if ((fallbackHit != HtNowhere && fallbackHit != HtClient && fallbackHit != HtCaption &&
             fallbackHit != HtBorder) ||
            !GetWindowRect(windowHandle, out var bounds))
        {
            return fallback;
        }

        var packed = lParam.ToInt64();
        var pointerX = unchecked((short)(packed & 0xFFFF));
        var pointerY = unchecked((short)((packed >> 16) & 0xFFFF));
        var scale = Math.Max(1d, GetDpiForWindow(windowHandle) / 96d);
        var edge = (int)Math.Ceiling(8 * scale);
        var corner = (int)Math.Ceiling(16 * scale);
        var nearLeft = pointerX >= bounds.Left && pointerX < bounds.Left + edge;
        var nearRight = pointerX <= bounds.Right && pointerX > bounds.Right - edge;
        var nearTop = pointerY >= bounds.Top && pointerY < bounds.Top + edge;
        var nearBottom = pointerY <= bounds.Bottom && pointerY > bounds.Bottom - edge;
        var inLeftCorner = pointerX < bounds.Left + corner;
        var inRightCorner = pointerX > bounds.Right - corner;
        var inTopCorner = pointerY < bounds.Top + corner;
        var inBottomCorner = pointerY > bounds.Bottom - corner;

        if (nearTop && inLeftCorner) return new nint(HtTopLeft);
        if (nearTop && inRightCorner) return new nint(HtTopRight);
        if (nearBottom && inLeftCorner) return new nint(HtBottomLeft);
        if (nearBottom && inRightCorner) return new nint(HtBottomRight);
        if (nearLeft && inTopCorner) return new nint(HtTopLeft);
        if (nearLeft && inBottomCorner) return new nint(HtBottomLeft);
        if (nearRight && inTopCorner) return new nint(HtTopRight);
        if (nearRight && inBottomCorner) return new nint(HtBottomRight);
        if (nearLeft) return new nint(HtLeft);
        if (nearRight) return new nint(HtRight);
        if (nearTop) return new nint(HtTop);
        if (nearBottom) return new nint(HtBottom);
        return fallback;
    }

    private static void ApplyWindows10Region(nint windowHandle)
    {
        if (IsZoomed(windowHandle))
        {
            _ = SetWindowRgn(windowHandle, nint.Zero, true);
            return;
        }
        if (!GetWindowRect(windowHandle, out var bounds))
        {
            return;
        }

        var scale = Math.Max(1d, GetDpiForWindow(windowHandle) / 96d);
        var radius = (int)Math.Round(Windows10CornerRadius * 2 * scale);
        var region = CreateRoundRectRgn(0, 0, bounds.Right - bounds.Left + 1, bounds.Bottom - bounds.Top + 1, radius, radius);
        if (region == nint.Zero)
        {
            return;
        }
        if (SetWindowRgn(windowHandle, region, true) == 0)
        {
            _ = DeleteObject(region);
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        nint windowHandle,
        int attribute,
        ref int attributeValue,
        int attributeSize);

    [DllImport("gdi32.dll")]
    private static extern nint CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(nint handle);

    [DllImport("user32.dll")]
    private static extern int SetWindowRgn(nint windowHandle, nint region, [MarshalAs(UnmanagedType.Bool)] bool redraw);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint windowHandle, out NativeRect bounds);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsZoomed(nint windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint windowHandle);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern nint GetWindowLongPtr(nint windowHandle, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetWindowLongPtr(nint windowHandle, int index, nint newValue);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        nint windowHandle,
        nint insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern nint SendMessage(
        nint windowHandle,
        uint message,
        nint wParam,
        nint lParam);

    private delegate nint WindowSubclassProc(
        nint windowHandle,
        uint message,
        nint wParam,
        nint lParam,
        UIntPtr subclassId,
        nint referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        nint windowHandle,
        WindowSubclassProc subclassProc,
        UIntPtr subclassId,
        nint referenceData);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(
        nint windowHandle,
        WindowSubclassProc subclassProc,
        UIntPtr subclassId);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(
        nint windowHandle,
        uint message,
        nint wParam,
        nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

}
