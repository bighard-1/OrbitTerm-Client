using System.Linq;

namespace OrbitTerm.NativeBridge;

public sealed class CheckedOrbitCoreClient : ICheckedOrbitCoreClient
{
    private const int MaxTerminalWriteBytes = 64 * 1024;

    public event EventHandler<TerminalDataReceivedEventArgs>? TerminalDataReceived
    {
        add
        {
            TerminalOutputRouter.EnsureRegistered();
            TerminalOutputRouter.DataReceived += value;
        }
        remove => TerminalOutputRouter.DataReceived -= value;
    }

    public event EventHandler<SftpTransferProgressEventArgs>? SftpTransferProgress
    {
        add
        {
            SftpProgressRouter.EnsureRegistered();
            SftpProgressRouter.ProgressChanged += value;
        }
        remove => SftpProgressRouter.ProgressChanged -= value;
    }

    public CheckedConnectOutcome Connect(CheckedConnectionRequest request, HostKeyRequestId requestId)
    {
        ValidateConnectRequest(request);

        var jump = request.JumpHost;
        using var result = NativeMethods.orbit_ssh_connect_checked_v2(
            request.Host.Trim(),
            request.Port,
            request.Username.Trim(),
            request.Password,
            request.PrivateKey,
            request.PrivateKeyPassphrase,
            request.AllowPasswordFallback ? 1 : 0,
            jump is null ? 0 : 1,
            jump?.Host.Trim() ?? string.Empty,
            jump?.Port ?? 22,
            jump?.Username.Trim() ?? string.Empty,
            jump?.Password ?? string.Empty,
            jump?.PrivateKey ?? string.Empty,
            jump?.PrivateKeyPassphrase ?? string.Empty,
            jump?.AllowPasswordFallback == true ? 1 : 0,
            request.KnownHostsPath,
            requestId.Value);

        return CheckedConnectOutcome.FromEnvelope(
            CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId));
    }

    public CheckedHostKeyTrustOutcome AcceptAndPersistHostKey(
        string challengeId,
        string knownHostsPath,
        string comment,
        HostKeyRequestId requestId)
    {
        if (string.IsNullOrWhiteSpace(challengeId) || string.IsNullOrWhiteSpace(knownHostsPath))
        {
            throw new ArgumentException("Host Key trust persistence requires a challenge and known_hosts path.");
        }

        using var result = NativeMethods.orbit_hostkey_challenge_accept_and_persist_v1(
            challengeId,
            knownHostsPath,
            SanitizeTrustComment(comment));

        return CheckedHostKeyTrustOutcome.FromEnvelope(
            CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId));
    }

    public CheckedTerminalOpenOutcome OpenTerminal(ulong baseSessionId, uint columns, uint rows, HostKeyRequestId requestId)
    {
        if (baseSessionId == 0 || columns is < 1 or > 1000 || rows is < 1 or > 1000)
        {
            throw new ArgumentOutOfRangeException(nameof(baseSessionId), "Terminal requests require a verified base session and bounded PTY size.");
        }

        using var result = NativeMethods.orbit_terminal_open_checked_v1(baseSessionId, columns, rows, requestId.Value);
        return CheckedTerminalOpenOutcome.FromEnvelope(
            CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId));
    }

    public TerminalControlResult WriteTerminal(ulong terminalChannelId, ReadOnlyMemory<byte> data)
    {
        EnsureTerminalChannel(terminalChannelId);

        if (data.IsEmpty || data.Length > MaxTerminalWriteBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(data), "Terminal writes must be non-empty and bounded.");
        }

        var payload = data.ToArray();
        using var result = NativeMethods.orbit_terminal_write(
            terminalChannelId,
            payload,
            checked((nuint)payload.Length));

        return TerminalControlResult.Decode(result.ToOwnedString());
    }

    public TerminalControlResult ResizeTerminal(ulong terminalChannelId, uint columns, uint rows)
    {
        EnsureTerminalChannel(terminalChannelId);
        if (columns is < 1 or > 1000 || rows is < 1 or > 1000)
        {
            throw new ArgumentOutOfRangeException(nameof(columns), "Terminal size must be between 1 and 1000 cells.");
        }

        using var result = NativeMethods.orbit_terminal_resize(terminalChannelId, columns, rows);
        return TerminalControlResult.Decode(result.ToOwnedString());
    }

    public TerminalControlResult CloseTerminal(ulong terminalChannelId)
    {
        EnsureTerminalChannel(terminalChannelId);

        using var result = NativeMethods.orbit_terminal_close(terminalChannelId);
        return TerminalControlResult.Decode(result.ToOwnedString());
    }

    public CheckedEnvelope StartLocalTunnel(
        ulong baseSessionId,
        string bindHost,
        int bindPort,
        string destinationHost,
        int destinationPort,
        HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        if (bindPort is < 0 or > 65535 || destinationPort is < 1 or > 65535)
            throw new ArgumentOutOfRangeException(nameof(bindPort));
        if (!string.Equals(bindHost, "127.0.0.1", StringComparison.Ordinal) &&
            !string.Equals(bindHost, "::1", StringComparison.Ordinal) &&
            !string.Equals(bindHost, "localhost", StringComparison.Ordinal))
            throw new ArgumentException("Local tunnel listeners must remain on loopback.", nameof(bindHost));
        if (string.IsNullOrWhiteSpace(destinationHost) || destinationHost.Any(char.IsWhiteSpace) || destinationHost.Any(char.IsControl))
            throw new ArgumentException("Tunnel destination host is invalid.", nameof(destinationHost));

        using var result = NativeMethods.orbit_local_tunnel_start_checked_v1(
            baseSessionId, bindHost, checked((ushort)bindPort), destinationHost,
            checked((ushort)destinationPort), requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope StopLocalTunnel(ulong tunnelId, HostKeyRequestId requestId)
    {
        if (tunnelId == 0) throw new ArgumentOutOfRangeException(nameof(tunnelId));
        using var result = NativeMethods.orbit_local_tunnel_stop_checked_v1(tunnelId, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope OpenSftp(ulong baseSessionId, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        using var result = NativeMethods.orbit_sftp_open_checked_v1(baseSessionId, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope ListSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        EnsureSftpPath(remotePath);

        using var result = NativeMethods.orbit_sftp_list_checked_v1(
            sftpSessionId,
            remotePath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope ReadSftpTextFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        EnsureSftpPath(remotePath);

        using var result = NativeMethods.orbit_sftp_read_text_checked_v1(
            sftpSessionId,
            remotePath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope DownloadSftpFile(ulong sftpSessionId, string remotePath, string localPath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        EnsureSftpPath(remotePath);
        EnsureNewLocalDownloadPath(localPath);

        using var result = NativeMethods.orbit_sftp_download_checked_v1(
            sftpSessionId,
            remotePath,
            localPath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public bool CancelSftpTransfer(HostKeyRequestId requestId)
    {
        return NativeMethods.orbit_sftp_cancel_checked_v1(requestId.Value);
    }

    public CheckedEnvelope UploadSftpFile(ulong sftpSessionId, string localPath, string remotePath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        EnsureExistingLocalUploadPath(localPath);
        EnsureSftpPath(remotePath);

        using var result = NativeMethods.orbit_sftp_upload_checked_v1(
            sftpSessionId,
            localPath,
            remotePath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope CreateSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(remotePath, nameof(remotePath));
        using var result = NativeMethods.orbit_sftp_mkdir_checked_v1(
            sftpSessionId,
            remotePath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope CreateSftpFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(remotePath, nameof(remotePath));
        using var result = NativeMethods.orbit_sftp_create_file_checked_v1(
            sftpSessionId,
            remotePath,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope RenameSftpEntry(
        ulong sftpSessionId,
        string oldRemotePath,
        string newRemotePath,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(oldRemotePath, nameof(oldRemotePath));
        SftpMutationPolicy.EnsureCanonicalPath(newRemotePath, nameof(newRemotePath));
        if (string.Equals(oldRemotePath, newRemotePath, StringComparison.Ordinal))
        {
            throw new ArgumentException("SFTP rename paths must be distinct.", nameof(newRemotePath));
        }

        snapshot.Validate();
        using var result = NativeMethods.orbit_sftp_rename_checked_v1(
            sftpSessionId,
            oldRemotePath,
            newRemotePath,
            snapshot.Size,
            snapshot.PermissionsOctal,
            snapshot.ModifiedAtUnix,
            snapshot.IsDirectory ? 1 : 0,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope RemoveSftpEntry(
        ulong sftpSessionId,
        string remotePath,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(remotePath, nameof(remotePath));
        snapshot.Validate();
        using var result = NativeMethods.orbit_sftp_remove_checked_v1(
            sftpSessionId,
            remotePath,
            snapshot.Size,
            snapshot.PermissionsOctal,
            snapshot.ModifiedAtUnix,
            snapshot.IsDirectory ? 1 : 0,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope ChangeSftpPermissions(
        ulong sftpSessionId,
        string remotePath,
        uint mode,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(remotePath, nameof(remotePath));
        if (mode > 0xFFFU)
        {
            throw new ArgumentOutOfRangeException(nameof(mode), "SFTP permissions must fit four octal digits.");
        }

        snapshot.Validate();
        var fileType = snapshot.PermissionsOctal & 0xF000U;
        if (fileType != 0x4000U && fileType != 0x8000U)
        {
            throw new ArgumentException("SFTP permissions can only be changed for regular files or directories.", nameof(snapshot));
        }

        using var result = NativeMethods.orbit_sftp_chmod_checked_v1(
            sftpSessionId,
            remotePath,
            mode,
            snapshot.Size,
            snapshot.PermissionsOctal,
            snapshot.ModifiedAtUnix,
            snapshot.IsDirectory ? 1 : 0,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope WriteSftpTextFile(
        ulong sftpSessionId,
        string remotePath,
        string content,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId)
    {
        EnsureSftpSession(sftpSessionId);
        SftpMutationPolicy.EnsureCanonicalPath(remotePath, nameof(remotePath));
        ArgumentNullException.ThrowIfNull(content);
        var bytes = System.Text.Encoding.UTF8.GetBytes(content);
        if (bytes.Length > 2 * 1024 * 1024 || content.Contains('\0'))
        {
            throw new ArgumentException("SFTP text content must be bounded UTF-8 without null characters.", nameof(content));
        }

        snapshot.Validate();
        if (snapshot.IsDirectory || (snapshot.PermissionsOctal & 0xF000U) != 0x8000U)
        {
            throw new ArgumentException("SFTP text editing requires a regular file snapshot.", nameof(snapshot));
        }

        using var result = NativeMethods.orbit_sftp_write_text_checked_v1(
            sftpSessionId,
            remotePath,
            bytes,
            checked((nuint)bytes.Length),
            snapshot.Size,
            snapshot.PermissionsOctal,
            snapshot.ModifiedAtUnix,
            0,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope MonitorSnapshot(ulong baseSessionId, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        using var result = NativeMethods.orbit_monitor_snapshot_checked_v1(baseSessionId, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope DockerList(ulong baseSessionId, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        using var result = NativeMethods.orbit_docker_list_checked_v1(baseSessionId, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope DockerStats(ulong baseSessionId, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        using var result = NativeMethods.orbit_docker_stats_checked_v1(baseSessionId, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope DockerLogs(ulong baseSessionId, string containerId, uint tailLines, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        EnsureDockerContainerId(containerId);
        if (tailLines is < 1 or > 1_000)
        {
            throw new ArgumentOutOfRangeException(nameof(tailLines), "Docker log tail lines must be between 1 and 1000.");
        }

        using var result = NativeMethods.orbit_docker_logs_checked_v1(
            baseSessionId,
            containerId,
            tailLines,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope DockerAction(ulong baseSessionId, string containerId, string action, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        EnsureDockerContainerId(containerId);
        EnsureDockerAction(action);

        using var result = NativeMethods.orbit_docker_action_checked_v1(
            baseSessionId,
            containerId,
            action,
            requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    public CheckedEnvelope Exec(ulong baseSessionId, string command, HostKeyRequestId requestId)
    {
        EnsureBaseSession(baseSessionId);
        if (string.IsNullOrWhiteSpace(command))
        {
            throw new ArgumentException("Command must not be empty.", nameof(command));
        }

        if (System.Text.Encoding.UTF8.GetByteCount(command) > 8 * 1024 || command.Any(char.IsControl))
        {
            throw new ArgumentException("Command must be at most 8 KiB and contain no control characters.", nameof(command));
        }

        using var result = NativeMethods.orbit_exec_checked_v1(baseSessionId, command, 0, 0, 0, requestId.Value);
        return CheckedEnvelopeDecoder.Decode(result.ToOwnedString(), requestId);
    }

    private static void ValidateConnectRequest(CheckedConnectionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Host) ||
            string.IsNullOrWhiteSpace(request.Username) ||
            request.Port is < 1 or > 65535 ||
            string.IsNullOrWhiteSpace(request.KnownHostsPath))
        {
            throw new ArgumentException("Checked connection request is incomplete.", nameof(request));
        }

        if (string.IsNullOrEmpty(request.Password) && string.IsNullOrEmpty(request.PrivateKey))
        {
            throw new ArgumentException("Checked connection requires either a password or a private key.", nameof(request));
        }

        if (request.JumpHost is { } jump &&
            (string.IsNullOrWhiteSpace(jump.Host) || string.IsNullOrWhiteSpace(jump.Username) ||
             jump.Port is < 1 or > 65535 ||
             (string.IsNullOrEmpty(jump.Password) && string.IsNullOrEmpty(jump.PrivateKey))))
        {
            throw new ArgumentException("Jump host request is incomplete or has no usable credential.", nameof(request));
        }
    }

    private static void EnsureBaseSession(ulong baseSessionId)
    {
        if (baseSessionId == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(baseSessionId), "A checked operation requires a verified base session.");
        }
    }

    private static void EnsureDockerContainerId(string containerId)
    {
        if (string.IsNullOrWhiteSpace(containerId) ||
            containerId.Length > 128 ||
            containerId.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new ArgumentException("Docker container ID must be a bounded hex value.", nameof(containerId));
        }
    }

    private static void EnsureDockerAction(string action)
    {
        if (action is not (
            "start" or
            "stop" or
            "restart" or
            "kill" or
            "pause" or
            "unpause" or
            "remove"))
        {
            throw new ArgumentException(
                "Docker action must be start, stop, restart, kill, pause, unpause, or remove.",
                nameof(action));
        }
    }

    private static void EnsureTerminalChannel(ulong terminalChannelId)
    {
        if (terminalChannelId == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(terminalChannelId), "A terminal operation requires an open terminal channel.");
        }
    }

    private static void EnsureSftpSession(ulong sftpSessionId)
    {
        if (sftpSessionId == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sftpSessionId), "An SFTP operation requires an open checked SFTP channel.");
        }
    }

    private static void EnsureSftpPath(string remotePath)
    {
        if (string.IsNullOrWhiteSpace(remotePath) ||
            remotePath.Length > 512 ||
            !remotePath.StartsWith("/", StringComparison.Ordinal) ||
            remotePath.Contains('\\', StringComparison.Ordinal) ||
            remotePath.Any(char.IsControl) ||
            remotePath.Split('/').Any(segment => segment == ".."))
        {
            throw new ArgumentException("SFTP operation requires a bounded absolute remote path.", nameof(remotePath));
        }
    }

    private static void EnsureNewLocalDownloadPath(string localPath)
    {
        if (string.IsNullOrWhiteSpace(localPath) ||
            localPath.Length > 4096 ||
            localPath.Any(char.IsControl) ||
            !Path.IsPathFullyQualified(localPath) ||
            File.Exists(localPath))
        {
            throw new ArgumentException("SFTP download requires a new absolute local file path.", nameof(localPath));
        }
    }

    private static void EnsureExistingLocalUploadPath(string localPath)
    {
        if (string.IsNullOrWhiteSpace(localPath) ||
            localPath.Length > 4096 ||
            localPath.Any(char.IsControl) ||
            !Path.IsPathFullyQualified(localPath) ||
            !File.Exists(localPath))
        {
            throw new ArgumentException("SFTP upload requires an existing absolute local file path.", nameof(localPath));
        }
    }

    private static string SanitizeTrustComment(string comment)
    {
        if (string.IsNullOrWhiteSpace(comment))
        {
            return string.Empty;
        }

        var sanitized = new char[comment.Length];
        for (var index = 0; index < comment.Length; index++)
        {
            sanitized[index] = char.IsControl(comment[index]) ? ' ' : comment[index];
        }

        var trimmed = new string(sanitized).Trim();
        return trimmed.Length <= 120 ? trimmed : trimmed[..120];
    }
}
