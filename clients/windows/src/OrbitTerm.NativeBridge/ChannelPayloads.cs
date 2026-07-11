using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record TerminalChannelOpenedPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("terminal_channel_id")] string TerminalChannelId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("cols")] uint Columns,
    [property: JsonPropertyName("rows")] uint Rows)
{
    public ulong ParsedBaseSessionId => ParseId(BaseSessionId, "base_session_id");

    public ulong ParsedTerminalChannelId => ParseId(TerminalChannelId, "terminal_channel_id");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified)
        {
            throw new OrbitNativeException("Terminal channel is not bound to a HostKeyVerified session.");
        }

        if (Columns is < 1 or > 1000 || Rows is < 1 or > 1000)
        {
            throw new OrbitNativeException("Terminal channel contains an invalid PTY size.");
        }
    }

    private static ulong ParseId(string value, string field)
    {
        return ulong.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : throw new OrbitNativeException($"Terminal channel contains an invalid {field}.");
    }
}

public sealed record SftpChannelOpenedPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration)
{
    public ulong ParsedBaseSessionId => ParseId(BaseSessionId, "base_session_id");

    public ulong ParsedSftpSessionId => ParseId(SftpSessionId, "sftp_session_id");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified)
        {
            throw new OrbitNativeException("SFTP channel is not bound to a HostKeyVerified session.");
        }
    }

    private static ulong ParseId(string value, string field)
    {
        return ulong.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : throw new OrbitNativeException($"SFTP channel contains an invalid {field}.");
    }
}

public sealed record SftpDirectoryListPayload(
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("entries")] IReadOnlyList<SftpDirectoryEntryPayload> Entries)
{
    public ulong ParsedSftpSessionId => ParseId(SftpSessionId, "sftp_session_id");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified)
        {
            throw new OrbitNativeException("SFTP listing is not bound to a HostKeyVerified session.");
        }

        if (string.IsNullOrWhiteSpace(Path) ||
            Path.Length > 512 ||
            !Path.StartsWith("/", StringComparison.Ordinal) ||
            Path.Contains('\\', StringComparison.Ordinal) ||
            Path.Split('/').Any(segment => segment == "..") ||
            Entries.Count > 5000)
        {
            throw new OrbitNativeException("SFTP listing contains an invalid path or entry count.");
        }

        foreach (var entry in Entries)
        {
            entry.Validate();
        }
    }

    private static ulong ParseId(string value, string field)
    {
        return ulong.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : throw new OrbitNativeException($"SFTP listing contains an invalid {field}.");
    }
}

public sealed record SftpDirectoryEntryPayload(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("size")] ulong Size,
    [property: JsonPropertyName("permissions")] string Permissions,
    [property: JsonPropertyName("permissions_octal")] uint PermissionsOctal,
    [property: JsonPropertyName("modified_at_unix")] ulong ModifiedAtUnix)
{
    public void Validate()
    {
        if (string.IsNullOrEmpty(Name) ||
            Name.Length > 255 ||
            Name.Contains('/', StringComparison.Ordinal) ||
            Name.Any(char.IsControl) ||
            Permissions.Length > 32 ||
            Permissions.Any(char.IsControl))
        {
            throw new OrbitNativeException("SFTP listing contains an invalid entry.");
        }
    }
}

public sealed record SftpTextFilePayload(
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("byte_length")] ulong ByteLength,
    [property: JsonPropertyName("content")] string Content)
{
    public ulong ParsedSftpSessionId => ulong.TryParse(SftpSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("SFTP text preview contains an invalid sftp_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            string.IsNullOrWhiteSpace(Path) ||
            Path.Length > 512 ||
            !Path.StartsWith("/", StringComparison.Ordinal) ||
            Path.Contains('\\', StringComparison.Ordinal) ||
            Path.Split('/').Any(segment => segment == "..") ||
            Content.Length > 2 * 1024 * 1024 ||
            ByteLength != checked((ulong)System.Text.Encoding.UTF8.GetByteCount(Content)))
        {
            throw new OrbitNativeException("SFTP text preview payload is invalid.");
        }
    }
}

public sealed record SftpDownloadPayload(
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("byte_length")] ulong ByteLength)
{
    public ulong ParsedSftpSessionId => ulong.TryParse(SftpSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("SFTP download contains an invalid sftp_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            string.IsNullOrWhiteSpace(Path) ||
            Path.Length > 512 ||
            !Path.StartsWith("/", StringComparison.Ordinal) ||
            Path.Contains('\\', StringComparison.Ordinal) ||
            Path.Split('/').Any(segment => segment == ".."))
        {
            throw new OrbitNativeException("SFTP download payload is invalid.");
        }
    }
}

public sealed record SftpUploadPayload(
    [property: JsonPropertyName("sftp_session_id")] string SftpSessionId,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("byte_length")] ulong ByteLength)
{
    public ulong ParsedSftpSessionId => ulong.TryParse(SftpSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("SFTP upload contains an invalid sftp_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            string.IsNullOrWhiteSpace(Path) ||
            Path.Length > 512 ||
            !Path.StartsWith("/", StringComparison.Ordinal) ||
            Path.Contains('\\', StringComparison.Ordinal) ||
            Path.Split('/').Any(segment => segment == ".."))
        {
            throw new OrbitNativeException("SFTP upload payload is invalid.");
        }
    }
}

public sealed record MonitorSnapshotPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("stats")] MonitorSnapshotStatsPayload Stats,
    [property: JsonPropertyName("diagnostics")] IReadOnlyList<string> Diagnostics)
{
    public ulong ParsedBaseSessionId => ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("Monitor snapshot contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            Diagnostics.Count > 8 ||
            Diagnostics.Any(diagnostic => !string.Equals(diagnostic, "ping_unavailable", StringComparison.Ordinal)))
        {
            throw new OrbitNativeException("Monitor snapshot payload is invalid.");
        }

        Stats.Validate();
    }
}

public sealed record MonitorSnapshotStatsPayload(
    [property: JsonPropertyName("sampled_at_unix")] ulong SampledAtUnix,
    [property: JsonPropertyName("cpu_usage_percent")] double CpuUsagePercent,
    [property: JsonPropertyName("mem_available_mb")] ulong MemoryAvailableMegabytes,
    [property: JsonPropertyName("mem_used_percent")] double MemoryUsedPercent,
    [property: JsonPropertyName("disk_used_percent")] double DiskUsedPercent,
    [property: JsonPropertyName("ping_latency_ms")] double? PingLatencyMilliseconds,
    [property: JsonPropertyName("rx_rate_kbps")] double ReceiveRateKilobitsPerSecond,
    [property: JsonPropertyName("tx_rate_kbps")] double TransmitRateKilobitsPerSecond)
{
    public void Validate()
    {
        if (SampledAtUnix == 0 ||
            !IsPercent(CpuUsagePercent) ||
            !IsPercent(MemoryUsedPercent) ||
            !IsPercent(DiskUsedPercent) ||
            PingLatencyMilliseconds is < 0 ||
            !IsNonNegativeFinite(ReceiveRateKilobitsPerSecond) ||
            !IsNonNegativeFinite(TransmitRateKilobitsPerSecond))
        {
            throw new OrbitNativeException("Monitor snapshot stats are invalid.");
        }
    }

    private static bool IsPercent(double value)
    {
        return double.IsFinite(value) && value is >= 0 and <= 100;
    }

    private static bool IsNonNegativeFinite(double value)
    {
        return double.IsFinite(value) && value >= 0;
    }
}

public sealed record DockerContainersPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("containers")] IReadOnlyList<DockerContainerPayload> Containers)
{
    public ulong ParsedBaseSessionId => ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("Docker containers payload contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            Containers is null ||
            Containers.Count > 10_000)
        {
            throw new OrbitNativeException("Docker containers payload is invalid.");
        }

        foreach (var container in Containers)
        {
            if (container is null)
            {
                throw new OrbitNativeException("Docker containers payload is invalid.");
            }

            container.Validate();
        }
    }
}

public sealed record DockerContainerPayload(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("image")] string Image,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("running_for")] string RunningFor)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Id) ||
            Id.Length > 128 ||
            Id.Any(character => !Uri.IsHexDigit(character)) ||
            !IsBoundedText(Name) ||
            !IsBoundedText(Image) ||
            !IsBoundedText(State) ||
            !IsBoundedText(Status) ||
            !IsBoundedText(RunningFor))
        {
            throw new OrbitNativeException("Docker container payload is invalid.");
        }
    }

    private static bool IsBoundedText(string value)
    {
        return !string.IsNullOrWhiteSpace(value) &&
            value.Length <= 512 &&
            !value.Any(char.IsControl);
    }
}

public sealed record DockerStatsPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("stats")] IReadOnlyList<DockerStatsItemPayload> Stats)
{
    public ulong ParsedBaseSessionId => ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("Docker stats payload contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            Stats is null ||
            Stats.Count > 10_000)
        {
            throw new OrbitNativeException("Docker stats payload is invalid.");
        }

        foreach (var item in Stats)
        {
            if (item is null)
            {
                throw new OrbitNativeException("Docker stats payload is invalid.");
            }

            item.Validate();
        }
    }
}

public sealed record DockerStatsItemPayload(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("cpu_percent")] double CpuPercent,
    [property: JsonPropertyName("mem_percent")] double MemoryPercent,
    [property: JsonPropertyName("mem_usage")] string MemoryUsage,
    [property: JsonPropertyName("net_io")] string NetworkIo,
    [property: JsonPropertyName("block_io")] string BlockIo,
    [property: JsonPropertyName("pids")] uint Pids)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Id) ||
            Id.Length > 128 ||
            Id.Any(character => !Uri.IsHexDigit(character)) ||
            !IsNonNegativeFinite(CpuPercent) ||
            !IsPercent(MemoryPercent) ||
            !IsBoundedText(Name) ||
            !IsBoundedText(MemoryUsage) ||
            !IsBoundedText(NetworkIo) ||
            !IsBoundedText(BlockIo))
        {
            throw new OrbitNativeException("Docker stats item payload is invalid.");
        }
    }

    private static bool IsPercent(double value)
    {
        return double.IsFinite(value) && value is >= 0 and <= 100;
    }

    private static bool IsNonNegativeFinite(double value)
    {
        return double.IsFinite(value) && value >= 0;
    }

    private static bool IsBoundedText(string value)
    {
        return !string.IsNullOrWhiteSpace(value) &&
            value.Length <= 512 &&
            !value.Any(char.IsControl);
    }
}

public sealed record DockerLogsPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("container_id")] string ContainerId,
    [property: JsonPropertyName("logs")] string Logs)
{
    public ulong ParsedBaseSessionId => ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("Docker logs payload contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            string.IsNullOrWhiteSpace(ContainerId) ||
            ContainerId.Length > 128 ||
            ContainerId.Any(character => !Uri.IsHexDigit(character)) ||
            Logs is null ||
            Logs.Length > 1024 * 1024 ||
            Logs.Contains('\0', StringComparison.Ordinal))
        {
            throw new OrbitNativeException("Docker logs payload is invalid.");
        }
    }
}

public sealed record DockerActionResultPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("container_id")] string ContainerId,
    [property: JsonPropertyName("action")] string Action,
    [property: JsonPropertyName("status")] string Status)
{
    public ulong ParsedBaseSessionId => ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
        ? parsed
        : throw new OrbitNativeException("Docker action payload contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            string.IsNullOrWhiteSpace(ContainerId) ||
            ContainerId.Length > 128 ||
            ContainerId.Any(character => !Uri.IsHexDigit(character)) ||
            !IsAllowedAction(Action) ||
            !string.Equals(Status, "completed", StringComparison.Ordinal))
        {
            throw new OrbitNativeException("Docker action payload is invalid.");
        }
    }

    public static bool IsAllowedAction(string action)
    {
        return string.Equals(action, "start", StringComparison.Ordinal) ||
            string.Equals(action, "stop", StringComparison.Ordinal) ||
            string.Equals(action, "restart", StringComparison.Ordinal);
    }
}
