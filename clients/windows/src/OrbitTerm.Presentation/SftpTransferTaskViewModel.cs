using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public enum SftpTransferDirection
{
    Upload,
    Download,
    Delete,
}

public enum SftpTransferTaskState
{
    Queued,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
    Skipped,
}

public enum SftpUploadConflictPolicy
{
    Skip,
    KeepBoth,
    Replace,
}

public sealed class SftpTransferTaskViewModel : ObservableObject
{
    private double bytesPerSecond;
    private DateTimeOffset? lastSampleAt;
    private ulong lastSampleBytes;
    private double progress;
    private bool isCancellationRequested;
    private string statusText;
    private SftpTransferTaskState state;
    private ulong? totalBytes;
    private ulong transferredBytes;
    private readonly SftpTransferControl transferControl = new();

    public SftpTransferTaskViewModel(
        Guid id,
        string fileName,
        string remotePath,
        SftpTransferDirection direction,
        string statusText)
    {
        Id = id;
        FileName = fileName;
        RemotePath = remotePath;
        Direction = direction;
        this.statusText = statusText;
        state = SftpTransferTaskState.Queued;
    }

    public Guid Id { get; }

    public string FileName { get; }

    public string RemotePath { get; }

    public SftpTransferDirection Direction { get; }

    public SftpTransferControl TransferControl => transferControl;

    public string DirectionText => Direction switch
    {
        SftpTransferDirection.Upload => "上传",
        SftpTransferDirection.Download => "下载",
        SftpTransferDirection.Delete => "删除",
        _ => "传输",
    };

    public string StatusText
    {
        get => statusText;
        private set => SetProperty(ref statusText, value);
    }

    public double Progress
    {
        get => progress;
        private set => SetProperty(ref progress, Math.Clamp(value, 0, 1));
    }

    public ulong TransferredBytes
    {
        get => transferredBytes;
        private set
        {
            if (SetProperty(ref transferredBytes, value))
            {
                OnPropertyChanged(nameof(TransferDetailText));
            }
        }
    }

    public ulong? TotalBytes
    {
        get => totalBytes;
        private set
        {
            if (SetProperty(ref totalBytes, value))
            {
                OnPropertyChanged(nameof(TransferDetailText));
            }
        }
    }

    public double BytesPerSecond
    {
        get => bytesPerSecond;
        private set
        {
            if (SetProperty(ref bytesPerSecond, value))
            {
                OnPropertyChanged(nameof(TransferDetailText));
            }
        }
    }

    public string TransferDetailText
    {
        get
        {
            if (Direction == SftpTransferDirection.Delete)
            {
                return string.Empty;
            }

            var transferred = FormatBytes(TransferredBytes);
            var total = TotalBytes is { } knownTotal ? string.Concat(" / ", FormatBytes(knownTotal)) : string.Empty;
            if (State != SftpTransferTaskState.Running || BytesPerSecond <= 0)
            {
                return string.Concat(transferred, total);
            }

            var speed = string.Concat(FormatBytes((ulong)Math.Max(0, BytesPerSecond)), "/s");
            if (TotalBytes is not { } totalLength || totalLength <= TransferredBytes)
            {
                return string.Concat(transferred, total, " · ", speed);
            }

            var remainingSeconds = (totalLength - TransferredBytes) / BytesPerSecond;
            return string.Concat(transferred, total, " · ", speed, " · 剩余 ", FormatDuration(remainingSeconds));
        }
    }

    public SftpTransferTaskState State
    {
        get => state;
        private set
        {
            if (SetProperty(ref state, value))
            {
                OnPropertyChanged(nameof(CanRetry));
                OnPropertyChanged(nameof(CanPause));
                OnPropertyChanged(nameof(CanResume));
                OnPropertyChanged(nameof(CanCancel));
            }
        }
    }

    public bool CanRetry => State is SftpTransferTaskState.Failed or SftpTransferTaskState.Cancelled;

    public bool IsCancellationRequested
    {
        get => isCancellationRequested;
        private set
        {
            if (SetProperty(ref isCancellationRequested, value))
            {
                OnPropertyChanged(nameof(CanPause));
                OnPropertyChanged(nameof(CanResume));
                OnPropertyChanged(nameof(CanCancel));
            }
        }
    }

    public bool CanPause => !IsCancellationRequested && State == SftpTransferTaskState.Running;

    public bool CanResume => !IsCancellationRequested && State == SftpTransferTaskState.Paused;

    public bool CanCancel => !IsCancellationRequested &&
        State is (SftpTransferTaskState.Running or SftpTransferTaskState.Paused);

    public void MarkRunning(string text)
    {
        transferControl.Resume();
        IsCancellationRequested = false;
        State = SftpTransferTaskState.Running;
        StatusText = text;
        Progress = 0;
        TransferredBytes = 0;
        TotalBytes = null;
        BytesPerSecond = 0;
        lastSampleAt = null;
        lastSampleBytes = 0;
    }

    public void Pause()
    {
        if (!CanPause)
        {
            return;
        }

        transferControl.Pause();
        State = SftpTransferTaskState.Paused;
        StatusText = "已暂停";
        BytesPerSecond = 0;
    }

    public void Resume()
    {
        if (!CanResume)
        {
            return;
        }

        transferControl.Resume();
        State = SftpTransferTaskState.Running;
        StatusText = Direction == SftpTransferDirection.Upload ? "正在上传" : "正在下载";
        lastSampleAt = null;
        lastSampleBytes = TransferredBytes;
    }

    public bool BeginCancellation(string text)
    {
        if (!CanCancel)
        {
            return false;
        }

        IsCancellationRequested = true;
        StatusText = text;
        BytesPerSecond = 0;
        return true;
    }

    public void ReleasePauseForCancellation()
    {
        transferControl.Resume();
    }

    public void UpdateProgress(ulong transferred, ulong? total, DateTimeOffset? sampledAt = null)
    {
        var now = sampledAt ?? DateTimeOffset.UtcNow;
        if (lastSampleAt is { } previousTime && transferred >= lastSampleBytes)
        {
            var seconds = (now - previousTime).TotalSeconds;
            if (seconds > 0.02)
            {
                var currentRate = (transferred - lastSampleBytes) / seconds;
                BytesPerSecond = BytesPerSecond <= 0
                    ? currentRate
                    : (BytesPerSecond * 0.7) + (currentRate * 0.3);
            }
        }

        lastSampleAt = now;
        lastSampleBytes = transferred;
        TransferredBytes = transferred;
        TotalBytes = total;
        if (total is > 0)
        {
            Progress = (double)transferred / total.Value;
        }
    }

    public void MarkCompleted(string text)
    {
        transferControl.Resume();
        if (TotalBytes is { } knownTotal)
        {
            TransferredBytes = knownTotal;
        }
        Progress = 1;
        StatusText = text;
        State = SftpTransferTaskState.Completed;
        BytesPerSecond = 0;
    }

    public void MarkFailed(string text)
    {
        transferControl.Resume();
        StatusText = text;
        State = SftpTransferTaskState.Failed;
    }

    public void MarkCancelled(string text)
    {
        transferControl.Resume();
        StatusText = text;
        State = SftpTransferTaskState.Cancelled;
    }

    public void MarkSkipped(string text)
    {
        transferControl.Resume();
        StatusText = text;
        State = SftpTransferTaskState.Skipped;
    }

    private static string FormatBytes(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{value:0.#} {units[unitIndex]}");
    }

    private static string FormatDuration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0)
        {
            return "计算中";
        }
        if (seconds < 60)
        {
            return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Math.Max(1, Math.Ceiling(seconds)):0} 秒");
        }
        if (seconds < 3600)
        {
            return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Math.Ceiling(seconds / 60):0} 分钟");
        }
        return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Math.Ceiling(seconds / 3600):0} 小时");
    }
}

public sealed record SftpUploadSource(string LocalPath, string FileName, ulong ByteLength);
