using System.ComponentModel;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace OrbitTerm.RdpHost;

internal sealed class RemoteDesktopWindow : Form
{
    // Microsoft documents this as the desktop-safe RDP client 9 class. The
    // former scriptable CLSID can create a blank surface but reject credential
    // and security settings when hosted by a native desktop application.
    private const string RdpClient9NotSafeForScriptingClassId = "8B918B82-7985-4C24-89DF-C33AD2BBFBCD";
    private const int WmNcHitTest = 0x0084;
    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 2;
    private const int NormalChromeHeight = 40;
    private const int FullScreenCollapsedChromeHeight = 24;
    private readonly RdpActiveXHost rdpHost = new();
    private readonly Label statusLabel = new();
    private readonly System.Windows.Forms.Timer stateTimer = new() { Interval = 500 };
    private readonly System.Windows.Forms.Timer resizeTimer = new() { Interval = 120 };
    private readonly ToolTip chromeToolTip = new();
    private readonly RdpHostLaunch launch;
    private readonly RdpHostStatusReporter reporter;
    private readonly TableLayoutPanel root;
    private readonly Panel titleBar;
    private readonly Panel rdpViewport;
    private readonly Label titleLabel;
    private readonly Button minimizeButton;
    private readonly Button maximizeButton;
    private readonly Button reconnectButton;
    private readonly Button fullScreenButton;
    private readonly Button closeButton;
    private readonly Button fullScreenChromeToggle;
    private readonly Control[] standardChromeControls;
    private string password;
    private bool connected;
    private bool closing;
    private bool awaitingDecisionReported;
    private bool fullScreen;
    private bool fullScreenChromeExpanded;
    private Size remoteDesktopSize;
    private DateTimeOffset connectionStartedAt;
    private Rectangle restoredBounds;
    private FormWindowState restoredWindowState;

    public RemoteDesktopWindow(RdpHostLaunch launch, RdpHostStatusReporter reporter)
    {
        this.launch = launch;
        this.reporter = reporter;
        password = launch.Password;
        Text = $"远程桌面 · {launch.DisplayName}";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(900, 620);
        Size = new Size(1280, 800);
        FormBorderStyle = FormBorderStyle.None;
        Padding = new Padding(1);

        var surface = launch.DarkTheme ? Color.FromArgb(24, 31, 44) : Color.FromArgb(248, 250, 254);
        var chrome = launch.DarkTheme ? Color.FromArgb(30, 39, 54) : Color.FromArgb(238, 244, 251);
        var stroke = launch.DarkTheme ? Color.FromArgb(78, 94, 117) : Color.FromArgb(188, 203, 222);
        var foreground = launch.DarkTheme ? Color.FromArgb(244, 247, 252) : Color.FromArgb(23, 32, 51);
        BackColor = stroke;

        root = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = surface, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, NormalChromeHeight));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        titleBar = new Panel { Dock = DockStyle.Fill, BackColor = chrome, Margin = Padding.Empty };
        titleLabel = new Label { Text = Text, AutoEllipsis = true, ForeColor = foreground, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), Location = new Point(14, 4), Height = 32, Width = 470, TextAlign = ContentAlignment.MiddleLeft };
        statusLabel.Text = "正在准备安全连接…";
        statusLabel.AutoEllipsis = true;
        statusLabel.ForeColor = launch.DarkTheme ? Color.FromArgb(190, 207, 227) : Color.FromArgb(64, 82, 107);
        statusLabel.Location = new Point(520, 4);
        statusLabel.Size = new Size(390, 32);
        statusLabel.TextAlign = ContentAlignment.MiddleRight;
        statusLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        minimizeButton = CaptionButton("\uE921", foreground, chrome);
        maximizeButton = CaptionButton("\uE922", foreground, chrome);
        reconnectButton = CaptionButton("\uE72C", foreground, chrome);
        fullScreenButton = CaptionButton("\uE740", foreground, chrome);
        closeButton = CaptionButton("\uE8BB", foreground, chrome);
        fullScreenChromeToggle = ToolbarToggleButton("显示工具栏  ▼", foreground, chrome);
        fullScreenChromeToggle.Visible = false;
        minimizeButton.Click += (_, _) => WindowState = FormWindowState.Minimized;
        maximizeButton.Click += (_, _) => ToggleMaximize();
        reconnectButton.Click += (_, _) => Reconnect();
        fullScreenButton.Click += (_, _) => ToggleFullScreen();
        closeButton.Click += (_, _) => Close();
        fullScreenChromeToggle.Click += (_, _) => ToggleFullScreenChrome();
        chromeToolTip.SetToolTip(reconnectButton, "重新连接");
        chromeToolTip.SetToolTip(fullScreenButton, "全屏（F11）");
        chromeToolTip.SetToolTip(minimizeButton, "最小化");
        chromeToolTip.SetToolTip(maximizeButton, "最大化/还原");
        chromeToolTip.SetToolTip(closeButton, "断开并关闭远程桌面");
        chromeToolTip.SetToolTip(fullScreenChromeToggle, "显示远程桌面工具栏");
        closeButton.MouseEnter += (_, _) => closeButton.BackColor = Color.FromArgb(196, 43, 28);
        closeButton.MouseLeave += (_, _) => closeButton.BackColor = chrome;
        titleLabel.MouseDown += TitleBarMouseDown;
        titleBar.MouseDown += TitleBarMouseDown;
        titleLabel.DoubleClick += (_, _) => ToggleMaximize();
        titleBar.DoubleClick += (_, _) => ToggleMaximize();
        titleBar.Resize += (_, _) => LayoutTitleBarControls();
        standardChromeControls =
        [
            titleLabel,
            statusLabel,
            reconnectButton,
            fullScreenButton,
            minimizeButton,
            maximizeButton,
            closeButton,
        ];
        titleBar.Controls.AddRange(
        [
            .. standardChromeControls,
            fullScreenChromeToggle,
        ]);

        ((ISupportInitialize)rdpHost).BeginInit();
        rdpHost.Dock = DockStyle.None;
        rdpHost.Margin = Padding.Empty;
        rdpViewport = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Black,
            Margin = Padding.Empty,
        };
        rdpViewport.Controls.Add(rdpHost);
        rdpViewport.Resize += (_, _) =>
        {
            LayoutRdpSurface();
            QueueLocalSmartSizingRefresh();
        };
        root.Controls.Add(titleBar, 0, 0);
        root.Controls.Add(rdpViewport, 0, 1);
        Controls.Add(root);
        ((ISupportInitialize)rdpHost).EndInit();
        KeyPreview = true;
        Shown += (_, _) => Connect();
        Resize += (_, _) => UpdateMaximizeButtonPresentation();
        FormClosing += RemoteDesktopWindowClosing;
        stateTimer.Tick += PollConnection;
        resizeTimer.Tick += (_, _) =>
        {
            resizeTimer.Stop();
            ApplyLocalSmartSizing();
        };
        UpdateMaximizeButtonPresentation();
    }

    private void Connect(bool reconnecting = false)
    {
        var stage = "创建系统远程桌面控件";
        try
        {
            connected = false;
            awaitingDecisionReported = false;
            connectionStartedAt = DateTimeOffset.UtcNow;
            if (reconnecting)
                reporter.Report("Reconnecting", "正在重新连接远程桌面…");
            rdpHost.CreateControl();
            stage = "读取远程桌面接口";
            var client = rdpHost.ActiveXObject;
            stage = "设置远程目标";
            SetComProperty(client, "Server", launch.Host);
            SetComProperty(client, "UserName", launch.Username);
            remoteDesktopSize = new Size(
                Math.Max(800, rdpViewport.ClientSize.Width),
                Math.Max(600, rdpViewport.ClientSize.Height));
            LayoutRdpSurface();
            SetComProperty(client, "DesktopWidth", remoteDesktopSize.Width);
            SetComProperty(client, "DesktopHeight", remoteDesktopSize.Height);
            SetComProperty(client, "ColorDepth", 32);

            // SmartSizing alone can remain capped at the negotiated desktop
            // size when the host becomes larger. EnableZoom is the native RDP
            // opt-in that permits local upscaling without changing the remote
            // session resolution.
            stage = "启用远程桌面等比例放大";
            EnableNativeUpscaling(client);

            stage = "读取高级安全设置";
            var advanced = GetComProperty(client, "AdvancedSettings9");
            stage = "设置远程端口";
            SetComProperty(advanced, "RDPPort", launch.Port);
            stage = "启用网络级别身份验证";
            SetComProperty(advanced, "EnableCredSspSupport", true);
            // Match the native mstsc experience: validate the remote certificate,
            // but let the user explicitly cancel or continue when validation fails.
            // Level 0 would silently disable server authentication and is forbidden.
            SetComProperty(advanced, "AuthenticationLevel", 2);
            stage = "设置窗口缩放";
            SetComProperty(advanced, "SmartSizing", true);
            stage = "设置本机资源重定向";
            SetComProperty(advanced, "RedirectClipboard", launch.ClipboardEnabled);
            SetComProperty(advanced, "RedirectDrives", launch.DriveRedirectionEnabled);
            SetComProperty(advanced, "RedirectPrinters", launch.PrinterRedirectionEnabled);
            SetComProperty(advanced, "RedirectPorts", false);
            SetComProperty(advanced, "RedirectSmartCards", false);
            if (!string.IsNullOrEmpty(password))
            {
                stage = "提交会话凭据";
                SetComProperty(advanced, "ClearTextPassword", password);
            }
            statusLabel.Text = $"正在连接 {launch.Host}:{launch.Port} · NLA 已启用";
            reporter.Report("Authenticating", "正在进行 NLA 身份验证和服务器证书检查…");
            stage = "发起远程桌面连接";
            InvokeComMethod(client, "Connect");
            password = string.Empty;
            stateTimer.Start();
        }
        catch (Exception exception)
        {
            password = string.Empty;
            var code = $"0x{exception.HResult:X8}";
            statusLabel.Text = $"远程桌面初始化失败 · {stage} · {code}";
            var failureKind = exception.HResult == unchecked((int)0x80040154)
                ? "EngineUnavailable"
                : "ProtocolError";
            reporter.Report(
                "Failed",
                "远程桌面初始化失败",
                failureKind,
                code,
                canRetry: true);
            WriteDiagnostic(stage, exception);
        }
    }

    private void PollConnection(object? sender, EventArgs e)
    {
        try
        {
            var client = rdpHost.ActiveXObject;
            if (Convert.ToInt32(GetComProperty(client, "Connected"), CultureInfo.InvariantCulture) != 0)
            {
                if (!connected)
                {
                    connected = true;
                    RefreshNegotiatedDesktopSize(client);
                    ApplyLocalSmartSizing();
                    reporter.Report("Connected", "远程桌面已连接");
                }
                statusLabel.Text = $"已连接 {launch.Host}:{launch.Port} · NLA";
            }
            else if (connected)
            {
                connected = false;
                statusLabel.Text = "远程桌面会话已断开 · 可点击重新连接";
                reporter.Report(
                    "Disconnected",
                    "远程桌面连接已断开",
                    "NetworkUnavailable",
                    canRetry: true);
                stateTimer.Stop();
            }
            else
            {
                var elapsed = DateTimeOffset.UtcNow - connectionStartedAt;
                if (!awaitingDecisionReported && elapsed >= TimeSpan.FromSeconds(3))
                {
                    awaitingDecisionReported = true;
                    statusLabel.Text = "等待 Windows 完成证书或凭据确认…";
                    reporter.Report(
                        "AwaitingUserDecision",
                        "等待 Windows 证书或凭据确认",
                        canRetry: true);
                }
                if (elapsed >= TimeSpan.FromSeconds(60))
                {
                    statusLabel.Text = "连接等待超时 · 请检查系统提示或重新连接";
                    reporter.Report(
                        "Failed",
                        "远程桌面连接等待超时",
                        "TimedOut",
                        canRetry: true);
                    stateTimer.Stop();
                }
            }
        }
        catch (Exception exception)
        {
            var code = $"0x{exception.HResult:X8}";
            statusLabel.Text = "无法读取远程桌面连接状态 · 可重新连接";
            reporter.Report("Failed", "无法读取远程桌面连接状态", "Unknown", code, canRetry: true);
            WriteDiagnostic("读取连接状态", exception);
            stateTimer.Stop();
        }
    }

    private void Reconnect()
    {
        if (closing) return;
        stateTimer.Stop();
        try
        {
            var client = rdpHost.ActiveXObject;
            if (Convert.ToInt32(GetComProperty(client, "Connected"), CultureInfo.InvariantCulture) != 0)
                InvokeComMethod(client, "Disconnect");
        }
        catch { }
        Connect(reconnecting: true);
    }

    private void RemoteDesktopWindowClosing(object? sender, FormClosingEventArgs e)
    {
        if (closing) return;
        closing = true;
        stateTimer.Stop();
        resizeTimer.Stop();
        password = string.Empty;
        try
        {
            var client = rdpHost.ActiveXObject;
            if (Convert.ToInt32(GetComProperty(client, "Connected"), CultureInfo.InvariantCulture) != 0)
                InvokeComMethod(client, "Disconnect");
        }
        catch { }
        reporter.Report("Closed", "远程桌面窗口已关闭");
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.F11)
        {
            ToggleFullScreen();
            return true;
        }
        if (keyData == Keys.Escape && fullScreen)
        {
            ToggleFullScreen();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmNcHitTest && WindowState == FormWindowState.Normal)
        {
            base.WndProc(ref message);
            if ((int)message.Result != 1) return;
            var point = PointToClient(Cursor.Position);
            const int edge = 8;
            var left = point.X <= edge;
            var right = point.X >= ClientSize.Width - edge;
            var top = point.Y <= edge;
            var bottom = point.Y >= ClientSize.Height - edge;
            message.Result = (nint)(left && top ? 13 : right && top ? 14 : left && bottom ? 16 : right && bottom ? 17 : left ? 10 : right ? 11 : top ? 12 : bottom ? 15 : 1);
            return;
        }
        base.WndProc(ref message);
    }

    private void TitleBarMouseDown(object? sender, MouseEventArgs e)
    {
        if (fullScreen || e.Button != MouseButtons.Left) return;
        _ = ReleaseCapture();
        _ = SendMessage(Handle, WmNcLButtonDown, (nint)HtCaption, nint.Zero);
    }

    private void ToggleMaximize()
    {
        if (fullScreen)
        {
            ExitFullScreen();
            return;
        }
        WindowState = WindowState == FormWindowState.Maximized
            ? FormWindowState.Normal
            : FormWindowState.Maximized;
    }

    private void ToggleFullScreen()
    {
        if (!fullScreen)
        {
            restoredBounds = Bounds;
            restoredWindowState = WindowState;
            WindowState = FormWindowState.Normal;
            Bounds = Screen.FromControl(this).Bounds;
            fullScreen = true;
            fullScreenChromeExpanded = false;
            ApplyChromeVisibility();
            UpdateMaximizeButtonPresentation();
            rdpHost.Focus();
            return;
        }

        ExitFullScreen();
    }

    private void ExitFullScreen()
    {
        fullScreen = false;
        fullScreenChromeExpanded = false;
        ApplyChromeVisibility();
        WindowState = restoredWindowState;
        if (restoredWindowState == FormWindowState.Normal && !restoredBounds.IsEmpty)
            Bounds = restoredBounds;
        UpdateMaximizeButtonPresentation();
    }

    private void ToggleFullScreenChrome()
    {
        if (!fullScreen) return;
        fullScreenChromeExpanded = !fullScreenChromeExpanded;
        ApplyChromeVisibility();
        if (!fullScreenChromeExpanded)
            rdpHost.Focus();
    }

    private void ApplyChromeVisibility()
    {
        var showStandardChrome = !fullScreen || fullScreenChromeExpanded;
        foreach (var control in standardChromeControls)
            control.Visible = showStandardChrome;

        fullScreenChromeToggle.Visible = fullScreen;
        fullScreenChromeToggle.Text = fullScreenChromeExpanded
            ? "隐藏工具栏  ▲"
            : "显示工具栏  ▼";
        chromeToolTip.SetToolTip(
            fullScreenButton,
            fullScreen ? "退出全屏（F11）" : "全屏（F11）");
        chromeToolTip.SetToolTip(
            fullScreenChromeToggle,
            fullScreenChromeExpanded ? "隐藏远程桌面工具栏" : "显示远程桌面工具栏");
        root.RowStyles[0].Height = fullScreen
            ? fullScreenChromeExpanded ? NormalChromeHeight : FullScreenCollapsedChromeHeight
            : NormalChromeHeight;
        LayoutTitleBarControls();
        LayoutRdpSurface();
        QueueLocalSmartSizingRefresh();
    }

    private void LayoutTitleBarControls()
    {
        closeButton.SetBounds(titleBar.ClientSize.Width - 46, 0, 46, NormalChromeHeight);
        maximizeButton.SetBounds(closeButton.Left - 46, 0, 46, NormalChromeHeight);
        minimizeButton.SetBounds(maximizeButton.Left - 46, 0, 46, NormalChromeHeight);
        fullScreenButton.SetBounds(minimizeButton.Left - 46, 0, 46, NormalChromeHeight);
        reconnectButton.SetBounds(fullScreenButton.Left - 46, 0, 46, NormalChromeHeight);

        // Keep the reveal and hide action in exactly the same place so the
        // toolbar does not appear to jump after the user expands it.
        fullScreenChromeToggle.SetBounds(
            Math.Max(0, (titleBar.ClientSize.Width - 124) / 2),
            0,
            124,
            fullScreenChromeExpanded ? NormalChromeHeight : FullScreenCollapsedChromeHeight);
        var chromeLeft = fullScreenChromeExpanded
            ? Math.Min(fullScreenChromeToggle.Left, reconnectButton.Left)
            : reconnectButton.Left;
        var titleWidth = Math.Max(120, Math.Min(470, chromeLeft - titleLabel.Left - 8));
        titleLabel.Width = titleWidth;
        var statusLeft = titleLabel.Right + 8;
        var statusWidth = Math.Max(0, chromeLeft - statusLeft - 8);
        statusLabel.Visible = (!fullScreen || fullScreenChromeExpanded) && statusWidth >= 120;
        statusLabel.SetBounds(statusLeft, 4, statusWidth, 32);
        fullScreenChromeToggle.BringToFront();
    }

    private void UpdateMaximizeButtonPresentation()
    {
        var restoresWindow = fullScreen || WindowState == FormWindowState.Maximized;
        maximizeButton.Text = restoresWindow ? "\uE923" : "\uE922";
        chromeToolTip.SetToolTip(maximizeButton, restoresWindow ? "还原窗口" : "最大化");
    }

    private void LayoutRdpSurface()
    {
        var available = rdpViewport.ClientSize;
        if (available.Width <= 0 || available.Height <= 0) return;
        if (remoteDesktopSize.Width <= 0 || remoteDesktopSize.Height <= 0)
        {
            rdpHost.Bounds = new Rectangle(Point.Empty, available);
            return;
        }

        var scale = Math.Min(
            (double)available.Width / remoteDesktopSize.Width,
            (double)available.Height / remoteDesktopSize.Height);
        var width = Math.Max(1, (int)Math.Floor(remoteDesktopSize.Width * scale));
        var height = Math.Max(1, (int)Math.Floor(remoteDesktopSize.Height * scale));
        rdpHost.Bounds = new Rectangle(
            (available.Width - width) / 2,
            (available.Height - height) / 2,
            width,
            height);
    }

    private void QueueLocalSmartSizingRefresh()
    {
        if (!connected || closing) return;
        resizeTimer.Stop();
        resizeTimer.Start();
    }

    private void RefreshNegotiatedDesktopSize(object client)
    {
        try
        {
            var width = Convert.ToInt32(
                GetComProperty(client, "DesktopWidth"),
                CultureInfo.InvariantCulture);
            var height = Convert.ToInt32(
                GetComProperty(client, "DesktopHeight"),
                CultureInfo.InvariantCulture);
            if (width <= 0 || height <= 0) return;
            remoteDesktopSize = new Size(width, height);
            LayoutRdpSurface();
        }
        catch
        {
            // Keep the requested size when an older server does not expose the
            // negotiated desktop dimensions through the ActiveX interface.
        }
    }

    private void ApplyLocalSmartSizing()
    {
        if (!connected || closing) return;
        try
        {
            var advanced = GetComProperty(rdpHost.ActiveXObject, "AdvancedSettings9");
            SetComProperty(advanced, "SmartSizing", true);
        }
        catch
        {
            // A resize can race with native disconnect. The connection poller
            // owns the user-visible lifecycle message; resizing must stay quiet.
        }
    }

    private static void EnableNativeUpscaling(object client)
    {
        var extended = (IMsRdpExtendedSettings)client;
        object enabled = true;
        var result = extended.put_Property("EnableZoom", ref enabled);
        Marshal.ThrowExceptionForHR(result);
    }

    private static Button ToolbarToggleButton(string text, Color foreground, Color background) => new()
    {
        Text = text,
        FlatStyle = FlatStyle.Flat,
        FlatAppearance = { BorderSize = 1, BorderColor = Color.FromArgb(112, 132, 158), MouseOverBackColor = Color.FromArgb(54, 68, 88) },
        ForeColor = foreground,
        BackColor = background,
        Font = new Font("Segoe UI", 9, FontStyle.Bold),
        TextAlign = ContentAlignment.MiddleCenter,
        TabStop = false,
    };
    private static Button CaptionButton(string text, Color foreground, Color background) => new()
    {
        Text = text,
        FlatStyle = FlatStyle.Flat,
        FlatAppearance = { BorderSize = 0, MouseOverBackColor = Color.FromArgb(54, 68, 88) },
        ForeColor = foreground,
        BackColor = background,
        Font = new Font("Segoe MDL2 Assets", 9),
        TextAlign = ContentAlignment.MiddleCenter,
        TabStop = false,
    };

    private static void WriteDiagnostic(string stage, Exception exception)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OrbitTerm", "Diagnostics");
            Directory.CreateDirectory(directory);
            var line = $"{DateTimeOffset.Now:O}\tstage={stage}\ttype={exception.GetType().Name}\thresult=0x{exception.HResult:X8}{Environment.NewLine}";
            File.AppendAllText(Path.Combine(directory, "rdp-host.log"), line);
        }
        catch { }
    }

    private static object GetComProperty(object target, string name) =>
        ComDispatch.Invoke(target, name, DispatchFlags.PropertyGet) ??
        throw new InvalidOperationException($"远程桌面控件未返回属性 {name}。");

    private static void SetComProperty(object target, string name, object value) =>
        _ = ComDispatch.Invoke(target, name, DispatchFlags.PropertyPut, value);

    private static void InvokeComMethod(object target, string name) =>
        _ = ComDispatch.Invoke(target, name, DispatchFlags.Method);

    [Flags]
    private enum DispatchFlags : ushort
    {
        Method = 0x1,
        PropertyGet = 0x2,
        PropertyPut = 0x4,
    }

    private static class ComDispatch
    {
        private const int DispatchPropertyPut = -3;
        private const int DispatchUnknownName = unchecked((int)0x80020006);
        private static readonly Guid TscAxInterfaceId = new("8C11EFAE-92C3-11D1-BC1E-00C04FA31489");
        private static readonly Guid RdpClientInterfaceId = new("92B4A539-7115-4B7C-A5A9-E5D9EFC2780A");
        private static readonly Guid RdpClient9InterfaceId = new("28904001-04B6-436C-A55B-0AF1A0883DC9");
        private static readonly Guid AdvancedSettings8InterfaceId = new("89ACB528-2557-4D16-8625-226A30E97E9A");
        private static readonly Guid DispatchInterfaceId = new("00020400-0000-0000-C000-000000000046");
        private static readonly Guid[] DispatchInterfaceCandidates =
        [
            TscAxInterfaceId,
            RdpClientInterfaceId,
            RdpClient9InterfaceId,
            DispatchInterfaceId,
        ];

        public static object? Invoke(
            object target,
            string memberName,
            DispatchFlags flags,
            object? argument = null)
        {
            var iid = Guid.Empty;
            var (dispatchPointer, memberId) = ResolveDispatchMember(target, memberName);

            var parameters = new DispatchParameters();
            var exception = new EXCEPINFO();
            uint argumentError = 0;
            var variant = IntPtr.Zero;
            var namedArgument = IntPtr.Zero;
            var resultVariant = IntPtr.Zero;
            try
            {
                if ((flags & DispatchFlags.PropertyPut) != 0)
                {
                    variant = Marshal.AllocCoTaskMem(32);
                    Marshal.GetNativeVariantForObject(argument, variant);
                    namedArgument = Marshal.AllocCoTaskMem(sizeof(int));
                    Marshal.WriteInt32(namedArgument, DispatchPropertyPut);
                    parameters = new DispatchParameters
                    {
                        Arguments = variant,
                        NamedArguments = namedArgument,
                        ArgumentCount = 1,
                        NamedArgumentCount = 1,
                    };
                }

                resultVariant = Marshal.AllocCoTaskMem(32);
                for (var offset = 0; offset < 32; offset += IntPtr.Size)
                    Marshal.WriteIntPtr(resultVariant, offset, IntPtr.Zero);
                var vtable = Marshal.ReadIntPtr(dispatchPointer);
                var invoke = Marshal.GetDelegateForFunctionPointer<InvokeDelegate>(
                    Marshal.ReadIntPtr(vtable, IntPtr.Size * 6));
                var result = invoke(
                    dispatchPointer, memberId, ref iid, 0, (ushort)flags,
                    ref parameters, resultVariant, ref exception, out argumentError);
                if (result < 0)
                {
                    var effective = exception.scode < 0 ? exception.scode : result;
                    Marshal.ThrowExceptionForHR(effective);
                }
                return Marshal.GetObjectForNativeVariant(resultVariant);
            }
            finally
            {
                if (resultVariant != IntPtr.Zero)
                {
                    _ = VariantClear(resultVariant);
                    Marshal.FreeCoTaskMem(resultVariant);
                }
                if (variant != IntPtr.Zero)
                {
                    _ = VariantClear(variant);
                    Marshal.FreeCoTaskMem(variant);
                }
                if (namedArgument != IntPtr.Zero)
                    Marshal.FreeCoTaskMem(namedArgument);
                Marshal.Release(dispatchPointer);
            }
        }

        private static (IntPtr DispatchPointer, int MemberId) ResolveDispatchMember(
            object target,
            string memberName)
        {
            var unknown = Marshal.GetIUnknownForObject(target);
            var memberNamePointer = Marshal.StringToCoTaskMemUni(memberName);
            var memberNamesPointer = Marshal.AllocCoTaskMem(IntPtr.Size);
            var memberIdPointer = Marshal.AllocCoTaskMem(sizeof(int));
            try
            {
                var contract = ResolveKnownContract(memberName);
                if (contract.HasValue)
                {
                    var interfaceId = contract.Value.InterfaceId;
                    Marshal.ThrowExceptionForHR(Marshal.QueryInterface(
                        unknown, in interfaceId, out var knownDispatch));
                    return (knownDispatch, contract.Value.MemberId);
                }

                Marshal.WriteIntPtr(memberNamesPointer, memberNamePointer);
                foreach (var candidate in DispatchInterfaceCandidates)
                {
                    var interfaceId = candidate;
                    if (Marshal.QueryInterface(unknown, in interfaceId, out var dispatch) < 0)
                        continue;

                    var keep = false;
                    try
                    {
                        var vtable = Marshal.ReadIntPtr(dispatch);
                        var getIdsOfNames = Marshal.GetDelegateForFunctionPointer<GetIdsOfNamesDelegate>(
                            Marshal.ReadIntPtr(vtable, IntPtr.Size * 5));
                        var iid = Guid.Empty;
                        var result = getIdsOfNames(
                            dispatch, ref iid, memberNamesPointer, 1, 0, memberIdPointer);
                        if (result >= 0)
                        {
                            keep = true;
                            return (dispatch, Marshal.ReadInt32(memberIdPointer));
                        }
                        if (result != DispatchUnknownName)
                            Marshal.ThrowExceptionForHR(result);
                    }
                    finally
                    {
                        if (!keep)
                            Marshal.Release(dispatch);
                    }
                }

                throw new COMException($"远程桌面接口不支持成员 {memberName}。", DispatchUnknownName);
            }
            finally
            {
                Marshal.FreeCoTaskMem(memberIdPointer);
                Marshal.FreeCoTaskMem(memberNamesPointer);
                Marshal.FreeCoTaskMem(memberNamePointer);
                Marshal.Release(unknown);
            }
        }

        private static (Guid InterfaceId, int MemberId)? ResolveKnownContract(string memberName) =>
            memberName switch
            {
                "Server" => (TscAxInterfaceId, 1),
                "UserName" => (TscAxInterfaceId, 3),
                "Connected" => (TscAxInterfaceId, 6),
                "DesktopWidth" => (TscAxInterfaceId, 12),
                "DesktopHeight" => (TscAxInterfaceId, 13),
                "Connect" => (TscAxInterfaceId, 30),
                "Disconnect" => (TscAxInterfaceId, 31),
                "ColorDepth" => (RdpClientInterfaceId, 100),
                "AdvancedSettings9" => (RdpClient9InterfaceId, 701),
                "EnableCredSspSupport" => (AdvancedSettings8InterfaceId, 17),
                "RDPPort" => (AdvancedSettings8InterfaceId, 108),
                "SmartSizing" => (AdvancedSettings8InterfaceId, 184),
                "ClearTextPassword" => (AdvancedSettings8InterfaceId, 186),
                "RedirectDrives" => (AdvancedSettings8InterfaceId, 191),
                "RedirectPrinters" => (AdvancedSettings8InterfaceId, 192),
                "RedirectPorts" => (AdvancedSettings8InterfaceId, 193),
                "RedirectSmartCards" => (AdvancedSettings8InterfaceId, 194),
                "AuthenticationLevel" => (AdvancedSettings8InterfaceId, 212),
                "RedirectClipboard" => (AdvancedSettings8InterfaceId, 213),
                _ => null,
            };

        [StructLayout(LayoutKind.Sequential)]
        private struct DispatchParameters
        {
            public IntPtr Arguments;
            public IntPtr NamedArguments;
            public uint ArgumentCount;
            public uint NamedArgumentCount;
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetIdsOfNamesDelegate(
            IntPtr instance,
            ref Guid interfaceId,
            IntPtr names,
            uint nameCount,
            uint locale,
            IntPtr memberIds);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int InvokeDelegate(
            IntPtr instance,
            int memberId,
            ref Guid interfaceId,
            uint locale,
            ushort flags,
            ref DispatchParameters parameters,
            IntPtr result,
            ref EXCEPINFO exception,
            out uint argumentError);

        [DllImport("oleaut32.dll")]
        private static extern int VariantClear(IntPtr variant);
    }

    [ComImport]
    [Guid("302D8188-0052-4807-806A-362B628F9AC5")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMsRdpExtendedSettings
    {
        [PreserveSig]
        int put_Property(
            [MarshalAs(UnmanagedType.BStr)] string propertyName,
            [In, MarshalAs(UnmanagedType.Struct)] ref object value);

        [PreserveSig]
        int get_Property(
            [MarshalAs(UnmanagedType.BStr)] string propertyName,
            [Out, MarshalAs(UnmanagedType.Struct)] out object value);
    }

    [DllImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern nint SendMessage(nint handle, int message, nint wParam, nint lParam);
    private sealed class RdpActiveXHost() : AxHost(RdpClient9NotSafeForScriptingClassId) { public object ActiveXObject => GetOcx() ?? throw new InvalidOperationException(); }
}
