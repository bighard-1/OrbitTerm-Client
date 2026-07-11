namespace OrbitTerm.NativeBridge;

public static class CheckedFfiKind
{
    public const string Connected = "connected";
    public const string HostKeyChallenge = "host_key_challenge";
    public const string HostKeyBlocked = "host_key_blocked";
    public const string HostKeyTrustPersisted = "host_key_trust_persisted";
    public const string TerminalChannelOpened = "terminal_channel_opened";
    public const string SftpChannelOpened = "sftp_channel_opened";
    public const string SftpDirectoryList = "sftp_directory_list";
    public const string SftpTextFile = "sftp_text_file";
    public const string SftpDownloadCompleted = "sftp_download_completed";
    public const string SftpUploadCompleted = "sftp_upload_completed";
    public const string SftpMutationCompleted = "sftp_mutation_completed";
    public const string MonitorSnapshot = "monitor_snapshot";
    public const string DockerContainers = "docker_containers";
    public const string DockerStats = "docker_stats";
    public const string DockerLogs = "docker_logs";
    public const string DockerActionResult = "docker_action_result";
    public const string ExecResult = "exec_result";
    public const string Error = "error";
}
