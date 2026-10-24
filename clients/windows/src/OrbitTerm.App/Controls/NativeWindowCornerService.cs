using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Requests the Windows 11 native rounded-window treatment. Windows 10 keeps
/// WS_THICKFRAME for dependable native resizing while extending client paint
/// over the otherwise mismatched side/bottom frame.
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
    private const uint WmNcCalcSize = 0x0083;
    private const uint WmNcDestroy = 0x0082;
    private const uint WmNcLeftButtonDown = 0x00A1;
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
    private const int HtTransparent = -1;
    private static readonly UIntPtr ResizeSubclassId = new(0x4F544652);
    private static readonly UIntPtr ResizeChildSubclassId = new(0x4F544643);
    private static readonly WindowSubclassProc ResizeSubclassProc = Windows10ResizeSubclass;
    private static readonly WindowSubclassProc ResizeChildSubclassProc = Windows10ChildResizeSubclass;

    public static void Apply(Window window)
    {
        var windowHandle = WindowNative.GetWindowHandle(window);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            // Keep the real sizing style, but let the WinUI surface cover its
            // visible frame. WinUI's child HWND receives real mouse hit tests
            // before the top-level window, so both levels need a subclass.
            _ = SetWindowSubclass(windowHandle, ResizeSubclassProc, ResizeSubclassId, nint.Zero);
            AttachWindows10ResizeChildren(windowHandle);
            ApplyWindows10Region(windowHandle);
            window.Activated += (_, _) => AttachWindows10ResizeChildren(windowHandle);
            window.AppWindow.Changed += (_, args) =>
            {
                if (args.DidSizeChange || args.DidPresenterChange)
                {
                    ApplyWindows10Region(windowHandle);
                    AttachWindows10ResizeChildren(windowHandle);
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

        // LTSC 2021 can ignore horizontal/corner sizing without WS_THICKFRAME.
        // Preserve it; WM_NCCALCSIZE only removes its visible color strip.
        // Match the remaining non-client controls to the selected palette.
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
        }
        // Installing the subclass changes WM_NCCALCSIZE behavior; recalculate
        // the non-client area even when WS_THICKFRAME was already present.
        _ = SetWindowPos(
            windowHandle,
            nint.Zero,
            0,
            0,
            0,
            0,
            SwpNoSize | SwpNoMove | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
        ApplyWindows10Region(windowHandle);
        AttachWindows10ResizeChildren(windowHandle);
    }

    private static void AttachWindows10ResizeChildren(nint parentHandle)
    {
        var parentThread = GetWindowThreadProcessId(parentHandle, out _);
        _ = EnumChildWindows(parentHandle, (childHandle, referenceData) =>
        {
            // comctl32 subclassing must occur on the child's owning thread.
            if (GetWindowThreadProcessId(childHandle, out _) != parentThread)
            {
                return true;
            }

            var className = new StringBuilder(96);
            _ = GetClassName(childHandle, className, className.Capacity);
            if (className.ToString() is "Microsoft.UI.Content.DesktopChildSiteBridge" or
                "InputNonClientPointerSource")
            {
                _ = SetWindowSubclass(
                    childHandle,
                    ResizeChildSubclassProc,
                    ResizeChildSubclassId,
                    parentHandle);
            }
            return true;
        }, nint.Zero);
    }

    private static nint Windows10ChildResizeSubclass(
        nint childHandle,
        uint message,
        nint wParam,
        nint lParam,
        UIntPtr subclassId,
        nint parentHandle)
    {
        if (message == WmNcDestroy)
        {
            _ = RemoveWindowSubclass(childHandle, ResizeChildSubclassProc, ResizeChildSubclassId);
        }
        else if (message == WmNcHitTest &&
                 !IsZoomed(parentHandle) &&
                 GetResizeHit(parentHandle, lParam) != 0)
        {
            // HTTRANSPARENT passes the pointer to the parent HWND in this
            // same UI thread, where its native sizing frame handles the drag.
            return new nint(HtTransparent);
        }
        return DefSubclassProc(childHandle, message, wParam, lParam);
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
        if (message == WmNcLeftButtonDown &&
            !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
            !IsZoomed(windowHandle))
        {
            var hit = wParam.ToInt32();
            if (hit is HtLeft or HtRight or HtTop or HtTopLeft or HtTopRight or
                HtBottom or HtBottomLeft or HtBottomRight)
            {
                // Give DefWindowProc the original non-client mouse message,
                // including its screen coordinates. Synthesizing SC_SIZE with
                // lParam=0 enters a sizing mode but can ignore the held mouse
                // drag even though WM_NCHITTEST reports a sizing edge.
                var style = GetWindowLongPtr(windowHandle, GwlStyle).ToInt64();
                var restoredThickFrame = (style & WsThickFrame) == 0;
                if (restoredThickFrame)
                {
                    _ = SetWindowLongPtr(windowHandle, GwlStyle, new nint(style | WsThickFrame));
                }

                try
                {
                    return DefWindowProc(windowHandle, message, wParam, lParam);
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
            }
        }
        if (message == WmNcCalcSize &&
            !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
            !IsZoomed(windowHandle) &&
            wParam != nint.Zero)
        {
            // Keep WS_CAPTION and WS_THICKFRAME for caption/snap/resize, but
            // paint the client over the system-owned side and bottom strips.
            // Edge hit-testing below retains the sizing affordance.
            return nint.Zero;
        }
        if (message != WmNcHitTest || IsZoomed(windowHandle))
        {
            return DefSubclassProc(windowHandle, message, wParam, lParam);
        }

        var fallback = DefSubclassProc(windowHandle, message, wParam, lParam);
        var fallbackHit = fallback.ToInt32();
        // With client paint covering the sizing frame Windows 10 may report
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
        // GetWindowRect includes the invisible DWM resize margin on Windows 10.
        // Hit-testing against it misses the painted edge after WM_NCCALCSIZE
        // extends the client area over the native frame. Use the visible frame
        // in screen coordinates, falling back when DWM has no bounds yet.
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

    [DllImport("user32.dll", EntryPoint = "DefWindowProcW")]
    private static extern nint DefWindowProc(nint windowHandle, uint message, nint wParam, nint lParam);

    private delegate bool EnumChildWindowProc(nint childHandle, nint referenceData);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(
        nint parentHandle,
        EnumChildWindowProc callback,
        nint referenceData);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint windowHandle, StringBuilder className, int maximumCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint windowHandle, out uint processId);

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
