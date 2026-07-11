namespace OrbitTerm.NativeBridge;

public static class ForbiddenLegacyAbi
{
    public static readonly string[] Symbols =
    [
        "orbit_test_ssh_connection",
        "orbit_ssh_connect",
        "orbit_sftp_connect",
        "orbit_request_channel",
        "orbit_exec_command",
        "orbit_fetch_system_stats",
        "orbit_fetch_docker_containers",
        "orbit_fetch_docker_stats",
        "orbit_fetch_docker_logs",
        "orbit_docker_action",
    ];
}
