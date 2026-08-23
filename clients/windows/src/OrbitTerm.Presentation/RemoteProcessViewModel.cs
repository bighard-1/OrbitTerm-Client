namespace OrbitTerm.Presentation;

public sealed class RemoteProcessViewModel : ObservableObject
{
    private uint parentProcessId;
    private string user;
    private double cpuPercent;
    private double memoryPercent;
    private string state;
    private string command;
    private long startIdentity;

    public RemoteProcessViewModel(
        uint processId,
        uint parentProcessId,
        string user,
        double cpuPercent,
        double memoryPercent,
        string state,
        long startIdentity,
        string command)
    {
        ProcessId = processId;
        this.parentProcessId = parentProcessId;
        this.user = user;
        this.cpuPercent = cpuPercent;
        this.memoryPercent = memoryPercent;
        this.state = state;
        this.startIdentity = startIdentity;
        this.command = command;
    }

    public uint ProcessId { get; }

    public uint ParentProcessId => parentProcessId;

    public string ParentProcessIdText => ParentProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public string ProcessIdText => ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public string User => user;

    public double CpuPercent => cpuPercent;

    public double MemoryPercent => memoryPercent;

    public string CpuPercentText => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"{CpuPercent:0.#}%");

    public string MemoryPercentText => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"{MemoryPercent:0.#}%");

    public string State => state;

    public long StartIdentity => startIdentity;

    public string StartedAtText => DateTimeOffset.FromUnixTimeSeconds(StartIdentity)
        .ToLocalTime()
        .ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.CurrentCulture);

    public string ElapsedTimeText
    {
        get
        {
            var elapsed = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeSeconds(StartIdentity);
            if (elapsed < TimeSpan.Zero)
            {
                elapsed = TimeSpan.Zero;
            }
            return elapsed.TotalDays >= 1
                ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{(int)elapsed.TotalDays} 天 {elapsed.Hours} 小时")
                : elapsed.TotalHours >= 1
                    ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{(int)elapsed.TotalHours} 小时 {elapsed.Minutes} 分钟")
                    : elapsed.TotalMinutes >= 1
                        ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{(int)elapsed.TotalMinutes} 分钟 {elapsed.Seconds} 秒")
                        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Math.Max(0, (int)elapsed.TotalSeconds)} 秒");
        }
    }

    public string StateLabel => State.Length == 0 ? "未知" : State[0] switch
    {
        'R' => "运行中",
        'S' => "休眠",
        'D' => "等待 I/O",
        'I' => "空闲",
        'T' or 't' => "已停止",
        'Z' => "僵尸",
        'X' or 'x' => "已结束",
        _ => State,
    };

    public string Command => command;

    public string ProcessName
    {
        get
        {
            var executable = Command.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? Command;
            var separator = Math.Max(executable.LastIndexOf('/'), executable.LastIndexOf('\\'));
            return separator >= 0 && separator < executable.Length - 1
                ? executable[(separator + 1)..]
                : executable;
        }
    }

    public bool IsProtectedProcess => ProcessId <= 1;

    public bool IsPotentiallyCritical =>
        IsProtectedProcess ||
        ProcessName.Equals("systemd", StringComparison.OrdinalIgnoreCase) ||
        ProcessName.Equals("init", StringComparison.OrdinalIgnoreCase) ||
        ProcessName.StartsWith("sshd", StringComparison.OrdinalIgnoreCase) ||
        ProcessName.Equals("dockerd", StringComparison.OrdinalIgnoreCase) ||
        ProcessName.Equals("containerd", StringComparison.OrdinalIgnoreCase);

    public string DetailSummary => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"PID {ProcessId} · 父进程 {ParentProcessId} · 用户 {User} · {StateLabel} · 已运行 {ElapsedTimeText}");

    public string AccessibilityDescription => string.Create(
        System.Globalization.CultureInfo.InvariantCulture,
        $"进程 {ProcessId}，{Command}，用户 {User}，状态 {StateLabel}，CPU {CpuPercent:0.#}%，内存 {MemoryPercent:0.#}%");

    public void UpdateFrom(RemoteProcessViewModel source)
    {
        if (parentProcessId != source.ParentProcessId)
        {
            parentProcessId = source.ParentProcessId;
            OnPropertyChanged(nameof(ParentProcessId));
            OnPropertyChanged(nameof(ParentProcessIdText));
            OnPropertyChanged(nameof(DetailSummary));
        }
        if (!string.Equals(user, source.User, StringComparison.Ordinal))
        {
            user = source.User;
            OnPropertyChanged(nameof(User));
            OnPropertyChanged(nameof(DetailSummary));
        }
        if (cpuPercent != source.CpuPercent)
        {
            cpuPercent = source.CpuPercent;
            OnPropertyChanged(nameof(CpuPercent));
            OnPropertyChanged(nameof(CpuPercentText));
        }
        if (memoryPercent != source.MemoryPercent)
        {
            memoryPercent = source.MemoryPercent;
            OnPropertyChanged(nameof(MemoryPercent));
            OnPropertyChanged(nameof(MemoryPercentText));
        }
        if (!string.Equals(state, source.State, StringComparison.Ordinal))
        {
            state = source.State;
            OnPropertyChanged(nameof(State));
            OnPropertyChanged(nameof(StateLabel));
            OnPropertyChanged(nameof(DetailSummary));
        }
        if (startIdentity != source.StartIdentity)
        {
            startIdentity = source.StartIdentity;
            OnPropertyChanged(nameof(StartIdentity));
            OnPropertyChanged(nameof(StartedAtText));
            OnPropertyChanged(nameof(ElapsedTimeText));
        }
        if (!string.Equals(command, source.Command, StringComparison.Ordinal))
        {
            command = source.Command;
            OnPropertyChanged(nameof(Command));
            OnPropertyChanged(nameof(ProcessName));
            OnPropertyChanged(nameof(IsPotentiallyCritical));
        }
        OnPropertyChanged(nameof(ElapsedTimeText));
        OnPropertyChanged(nameof(DetailSummary));
        OnPropertyChanged(nameof(AccessibilityDescription));
    }

    public RemoteProcessViewModel Clone() => new(
        ProcessId,
        ParentProcessId,
        User,
        CpuPercent,
        MemoryPercent,
        State,
        StartIdentity,
        Command);
}
