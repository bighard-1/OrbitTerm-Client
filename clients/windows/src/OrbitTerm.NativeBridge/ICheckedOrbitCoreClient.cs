namespace OrbitTerm.NativeBridge;

public interface ICheckedOrbitCoreClient
{
    event EventHandler<TerminalDataReceivedEventArgs>? TerminalDataReceived;

    CheckedConnectOutcome Connect(CheckedConnectionRequest request, HostKeyRequestId requestId);

    CheckedHostKeyTrustOutcome AcceptAndPersistHostKey(
        string challengeId,
        string knownHostsPath,
        string comment,
        HostKeyRequestId requestId);

    CheckedTerminalOpenOutcome OpenTerminal(
        ulong baseSessionId,
        uint columns,
        uint rows,
        HostKeyRequestId requestId);

    TerminalControlResult WriteTerminal(ulong terminalChannelId, ReadOnlyMemory<byte> data);

    TerminalControlResult ResizeTerminal(ulong terminalChannelId, uint columns, uint rows);

    TerminalControlResult CloseTerminal(ulong terminalChannelId);

    CheckedEnvelope OpenSftp(ulong baseSessionId, HostKeyRequestId requestId);

    CheckedEnvelope ListSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId);

    CheckedEnvelope ReadSftpTextFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId);

    CheckedEnvelope DownloadSftpFile(ulong sftpSessionId, string remotePath, string localPath, HostKeyRequestId requestId);

    CheckedEnvelope UploadSftpFile(ulong sftpSessionId, string localPath, string remotePath, HostKeyRequestId requestId);

    CheckedEnvelope CreateSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId);

    CheckedEnvelope CreateSftpFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId);

    CheckedEnvelope RenameSftpEntry(
        ulong sftpSessionId,
        string oldRemotePath,
        string newRemotePath,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId);

    CheckedEnvelope RemoveSftpEntry(
        ulong sftpSessionId,
        string remotePath,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId);

    CheckedEnvelope ChangeSftpPermissions(
        ulong sftpSessionId,
        string remotePath,
        uint mode,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId);

    CheckedEnvelope WriteSftpTextFile(
        ulong sftpSessionId,
        string remotePath,
        string content,
        SftpEntrySnapshot snapshot,
        HostKeyRequestId requestId);

    CheckedEnvelope MonitorSnapshot(ulong baseSessionId, HostKeyRequestId requestId);

    CheckedEnvelope DockerList(ulong baseSessionId, HostKeyRequestId requestId);

    CheckedEnvelope DockerStats(ulong baseSessionId, HostKeyRequestId requestId);

    CheckedEnvelope DockerLogs(ulong baseSessionId, string containerId, uint tailLines, HostKeyRequestId requestId);

    CheckedEnvelope DockerAction(ulong baseSessionId, string containerId, string action, HostKeyRequestId requestId);

    CheckedEnvelope Exec(ulong baseSessionId, string command, HostKeyRequestId requestId);
}
