using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Requests the Windows 11 native rounded-window treatment. Windows 10 keeps
/// its system-owned sizing frame: WinUI child windows can otherwise consume
/// real pointer-down events even when a synthetic hit test reports an edge.
/// </summary>
internal static class NativeWindowCornerService
{
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwcpRound = 2;
    private const int DwmwaUseImmersiveDarkModeBefore20H1 = 19;
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaExtendedFrameBounds = 9;
    private const int Windows10CornerRadius = 12;
    private const int GwlStyle = -16;
    private const long WsThickFrame = 0x00040000L;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private const uint WmNcHitTest = 0x0084;
    private const uint WmNcDestroy = 0x0082;
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
    private static readonly UIntPtr ResizeSubclassId = new(0x4F544652);
    private static readonly WindowSubclassProc ResizeSubclassProc = Windows11ResizeSubclass;

    public static void Apply(Window window)
    {
        var windowHandle = WindowNative.GetWindowHandle(window);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            // The native non-client frame must own the press as well as its
            // hit test. Client-painted edge experiments passed synthetic hit
            // tests but failed actual Win10 mouse resizing on the QA machine.
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

        // WinUI extends client content into the frame. Explicit edge hit-tests
        // keep the native resize cursor and sizing loop discoverable over that
        // client-owned surface on Windows 11.
        _ = SetWindowSubclass(windowHandle, ResizeSubclassProc, ResizeSubclassId, nint.Zero);
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

        // LTSC 2021 can ignore horizontal/corner sizing when the WinUI client
        // covers the non-client edge, despite correct synthetic hit tests.
        // Preserve the system-owned WS_THICKFRAME and theme its controls.
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

    private static nint Windows11ResizeSubclass(
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
        if (message != WmNcHitTest || IsZoomed(windowHandle))
        {
            return DefSubclassProc(windowHandle, message, wParam, lParam);
        }

        var fallback = DefSubclassProc(windowHandle, message, wParam, lParam);
        var fallbackHit = fallback.ToInt32();
        // With client paint covering the sizing frame, WinUI may report
        // HTNOWHERE/HTCLIENT/HTCAPTION at edges. Only those cases are ours;
        // native caption buttons keep their original hit-test result.
        if (fallbackHit != HtNowhere && fallbackHit != HtClient && fallbackHit != HtCaption &&
            fallbackHit != HtBorder)
        {
            return fallback;
        }

        var resizeHit = GetResizeHit(windowHandle, lParam);
        return resizeHit == 0 ? fallback : new nint(resizeHit);
    }

    private static int GetResizeHit(nint windowHandle, nint lParam)
    {
        if (!GetVisibleWindowBounds(windowHandle, out var bounds))
        {
            return 0;
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

        if (nearTop && inLeftCorner) return HtTopLeft;
        if (nearTop && inRightCorner) return HtTopRight;
        if (nearBottom && inLeftCorner) return HtBottomLeft;
        if (nearBottom && inRightCorner) return HtBottomRight;
        if (nearLeft && inTopCorner) return HtTopLeft;
        if (nearLeft && inBottomCorner) return HtBottomLeft;
        if (nearRight && inTopCorner) return HtTopRight;
        if (nearRight && inBottomCorner) return HtBottomRight;
        if (nearLeft) return HtLeft;
        if (nearRight) return HtRight;
        if (nearTop) return HtTop;
        if (nearBottom) return HtBottom;
        return 0;
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

    private static bool GetVisibleWindowBounds(nint windowHandle, out NativeRect bounds)
    {
        // GetWindowRect may include an invisible DWM resize margin. WinUI's
        // painted edge needs the visible frame in screen coordinates; fall
        // back when DWM has not published those bounds yet.
        return DwmGetWindowAttribute(
                   windowHandle,
                   DwmwaExtendedFrameBounds,
                   out bounds,
                   Marshal.SizeOf<NativeRect>()) == 0 ||
               GetWindowRect(windowHandle, out bounds);
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        nint windowHandle,
        int attribute,
        ref int attributeValue,
        int attributeSize);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(
        nint windowHandle,
        int attribute,
        out NativeRect attributeValue,
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
