using System.Runtime.InteropServices;

namespace OrbitTerm.NativeBridge;

internal static partial class NativeMethods
{
    private const string LibraryName = "orbit_core";

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial OrbitCString orbit_ssh_connect_checked_v1(
        string host,
        int port,
        string username,
        string password,
        string private_key,
        string private_key_passphrase,
        int allow_password_fallback,
        string known_hosts_path,
        string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_terminal_open_checked_v1(
        ulong base_session_id,
        uint cols,
        uint rows,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_terminal_write(
        ulong terminal_channel_id,
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] data_ptr,
        nuint data_len);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_terminal_resize(
        ulong terminal_channel_id,
        uint cols,
        uint rows);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_terminal_close(ulong terminal_channel_id);

    [DllImport(LibraryName)]
    internal static extern void orbit_terminal_set_callback(OrbitTerminalDataCallback? callback);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_open_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_list_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_read_text_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_download_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string local_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_upload_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string local_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_mkdir_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_create_file_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_rename_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string old_remote_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string new_remote_path,
        ulong expected_size,
        uint expected_permissions_octal,
        ulong expected_modified_at_unix,
        int expected_is_directory,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_remove_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        ulong expected_size,
        uint expected_permissions_octal,
        ulong expected_modified_at_unix,
        int expected_is_directory,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_chmod_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        uint mode,
        ulong expected_size,
        uint expected_permissions_octal,
        ulong expected_modified_at_unix,
        int expected_is_directory,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_sftp_write_text_checked_v1(
        ulong sftp_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string remote_path,
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 3)] byte[] content_ptr,
        nuint content_len,
        ulong expected_size,
        uint expected_permissions_octal,
        ulong expected_modified_at_unix,
        int expected_is_directory,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_monitor_snapshot_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_docker_list_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_docker_stats_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_docker_logs_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string container_id,
        uint tail,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_docker_action_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string container_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string action,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_exec_checked_v1(
        ulong base_session_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string command,
        uint timeout_seconds,
        uint max_stdout_bytes,
        uint max_stderr_bytes,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request_id);

    [LibraryImport(LibraryName)]
    internal static partial OrbitCString orbit_hostkey_challenge_accept_and_persist_v1(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string challenge_id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string known_hosts_path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string comment);

    [LibraryImport(LibraryName)]
    internal static partial void orbit_free_string(IntPtr value);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void OrbitTerminalDataCallback(
        ulong terminal_channel_id,
        IntPtr data_ptr,
        nuint data_len);
}
