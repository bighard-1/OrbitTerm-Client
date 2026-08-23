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
    private readonly RdpActiveXHost rdpHost = new();
    private readonly Label statusLabel = new();
    private readonly System.Windows.Forms.Timer stateTimer = new() { Interval = 500 };
    private readonly RdpHostLaunch launch;
    private string password;
    private bool connected;
    private bool closing;

    public RemoteDesktopWindow(RdpHostLaunch launch)
    {
        this.launch = launch;
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

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = surface, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var titleBar = new Panel { Dock = DockStyle.Fill, BackColor = chrome, Margin = Padding.Empty };
        var title = new Label { Text = Text, AutoEllipsis = true, ForeColor = foreground, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), Location = new Point(14, 4), Height = 32, Width = 470, TextAlign = ContentAlignment.MiddleLeft };
        statusLabel.Text = "正在准备安全连接…";
        statusLabel.AutoEllipsis = true;
        statusLabel.ForeColor = launch.DarkTheme ? Color.FromArgb(190, 207, 227) : Color.FromArgb(64, 82, 107);
        statusLabel.Location = new Point(520, 4);
        statusLabel.Size = new Size(390, 32);
        statusLabel.TextAlign = ContentAlignment.MiddleRight;
        statusLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        var minimize = CaptionButton("\uE921", foreground, chrome);
        var maximize = CaptionButton("\uE922", foreground, chrome);
        var close = CaptionButton("\uE8BB", foreground, chrome);
        minimize.Click += (_, _) => WindowState = FormWindowState.Minimized;
        maximize.Click += (_, _) => ToggleMaximize();
        close.Click += (_, _) => Close();
        close.MouseEnter += (_, _) => close.BackColor = Color.FromArgb(196, 43, 28);
        close.MouseLeave += (_, _) => close.BackColor = chrome;
        title.MouseDown += TitleBarMouseDown;
        titleBar.MouseDown += TitleBarMouseDown;
        title.DoubleClick += (_, _) => ToggleMaximize();
        titleBar.DoubleClick += (_, _) => ToggleMaximize();
        titleBar.Resize += (_, _) =>
        {
            close.SetBounds(titleBar.ClientSize.Width - 46, 0, 46, 40);
            maximize.SetBounds(close.Left - 46, 0, 46, 40);
            minimize.SetBounds(maximize.Left - 46, 0, 46, 40);
            statusLabel.Left = Math.Max(title.Right + 8, minimize.Left - statusLabel.Width - 8);
        };
        titleBar.Controls.AddRange([title, statusLabel, minimize, maximize, close]);

        ((ISupportInitialize)rdpHost).BeginInit();
        rdpHost.Dock = DockStyle.Fill;
        rdpHost.Margin = Padding.Empty;
        root.Controls.Add(titleBar, 0, 0);
        root.Controls.Add(rdpHost, 0, 1);
        Controls.Add(root);
        ((ISupportInitialize)rdpHost).EndInit();
        Shown += (_, _) => Connect();
        FormClosing += RemoteDesktopWindowClosing;
        stateTimer.Tick += PollConnection;
    }

    private void Connect()
    {
        var stage = "创建系统远程桌面控件";
        try
        {
            rdpHost.CreateControl();
            stage = "读取远程桌面接口";
            var client = rdpHost.ActiveXObject;
            stage = "设置远程目标";
            SetComProperty(client, "Server", launch.Host);
            SetComProperty(client, "UserName", launch.Username);
            SetComProperty(client, "DesktopWidth", Math.Max(800, rdpHost.ClientSize.Width));
            SetComProperty(client, "DesktopHeight", Math.Max(600, rdpHost.ClientSize.Height));
            SetComProperty(client, "ColorDepth", 32);

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
                connected = true;
                statusLabel.Text = $"已连接 {launch.Host}:{launch.Port} · NLA";
            }
            else if (connected) { statusLabel.Text = "远程桌面会话已断开"; stateTimer.Stop(); }
        }
        catch { stateTimer.Stop(); }
    }

    private void RemoteDesktopWindowClosing(object? sender, FormClosingEventArgs e)
    {
        if (closing) return;
        closing = true;
        stateTimer.Stop();
        password = string.Empty;
        try
        {
            var client = rdpHost.ActiveXObject;
            if (Convert.ToInt32(GetComProperty(client, "Connected"), CultureInfo.InvariantCulture) != 0)
                InvokeComMethod(client, "Disconnect");
        }
        catch { }
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
        if (e.Button != MouseButtons.Left) return;
        _ = ReleaseCapture();
        _ = SendMessage(Handle, WmNcLButtonDown, (nint)HtCaption, nint.Zero);
    }

    private void ToggleMaximize() => WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
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
    [DllImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern nint SendMessage(nint handle, int message, nint wParam, nint lParam);
    private sealed class RdpActiveXHost() : AxHost(RdpClient9NotSafeForScriptingClassId) { public object ActiveXObject => GetOcx() ?? throw new InvalidOperationException(); }
}
