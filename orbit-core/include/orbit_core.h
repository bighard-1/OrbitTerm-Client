#ifndef ORBIT_CORE_H
#define ORBIT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *orbit_encrypt_config(const char *master_password, const unsigned char *plaintext_ptr, size_t plaintext_len);
char *orbit_decrypt_config(const char *master_password, const char *encrypted_base64);
char *orbit_argon2id_derive(const char *password, const uint8_t *salt_ptr, size_t salt_len);
char *orbit_portable_validate(const char *portable_json);
char *orbit_portable_changed_fields(const char *base_json, const char *newer_json);
char *orbit_portable_merge(const char *remote_json, const char *local_json, const char *local_changed_fields_json);
char *orbit_vector_clock_bump(const char *vector_clock_json, const char *actor);
char *orbit_test_ssh_connection(
    const char *ip,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key_content,
    const char *private_key_passphrase,
    int32_t allow_password_fallback
);
/* Checked test-only connection. Returns a Host Key JSON envelope and never
 * creates a reusable session. Returned strings must be released with
 * orbit_free_string.
 */
char *orbit_test_ssh_connection_checked_v1(
    const char *host,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key,
    const char *private_key_passphrase,
    int32_t allow_password_fallback,
    const char *known_hosts_path,
    const char *request_id
);
char *orbit_ssh_connect(
    const char *ip,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key_content,
    const char *private_key_passphrase,
    int32_t allow_password_fallback
);
/* Checked reusable connection. Returns a Host Key JSON envelope and only
 * pools HostKeyVerified sessions. Returned strings must be released with
 * orbit_free_string.
 */
char *orbit_ssh_connect_checked_v1(
    const char *host,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key,
    const char *private_key_passphrase,
    int32_t allow_password_fallback,
    const char *known_hosts_path,
    const char *request_id
);
char *orbit_ssh_disconnect(uint64_t base_session_id);

char *orbit_sftp_connect(
    const char *ip,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key_content,
    const char *private_key_passphrase,
    int32_t allow_password_fallback
);
/* Opens SFTP only from an Active HostKeyVerified base session. IDs are
 * returned as decimal strings inside a versioned JSON envelope. Returned
 * strings must be released with orbit_free_string.
 */
char *orbit_sftp_open_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_sftp_disconnect(uint64_t session_id);
char *orbit_sftp_list_dir(uint64_t session_id, const char *remote_path);
char *orbit_sftp_upload_file(uint64_t session_id, const char *local_path, const char *remote_path);
char *orbit_sftp_download_file(uint64_t session_id, const char *remote_path, const char *local_path, uint64_t resume_offset);
char *orbit_sftp_read_text_file(uint64_t session_id, const char *remote_path);
char *orbit_sftp_write_text_file(uint64_t session_id, const char *remote_path, const char *content);
char *orbit_sftp_remove_file(uint64_t session_id, const char *remote_path);
char *orbit_sftp_rename(uint64_t session_id, const char *old_remote_path, const char *new_remote_path);
char *orbit_sftp_mkdir(uint64_t session_id, const char *remote_path);
char *orbit_sftp_create_file(uint64_t session_id, const char *remote_path);
char *orbit_sftp_chmod(uint64_t session_id, const char *remote_path, const char *mode_octal);
char *orbit_fetch_system_stats(uint64_t session_id);
/* Captures one monitor snapshot from an Active HostKeyVerified base session.
 * Does not reconnect or accept credentials. Returned strings must be released
 * with orbit_free_string.
 */
char *orbit_monitor_snapshot_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_fetch_docker_containers(uint64_t session_id);
char *orbit_fetch_docker_stats(uint64_t session_id);
char *orbit_docker_action(uint64_t session_id, const char *container_id, const char *action);
char *orbit_fetch_docker_logs(uint64_t session_id, const char *container_id, uint32_t tail_lines);
/* Docker operations on an existing Active HostKeyVerified base session.
 * These functions never connect or accept credentials. IDs are decimal
 * strings inside the JSON envelope. Returned strings must be released with
 * orbit_free_string.
 */
char *orbit_docker_list_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_docker_stats_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_docker_logs_checked_v1(
    uint64_t base_session_id,
    const char *container_id,
    uint32_t tail,
    const char *request_id
);
char *orbit_docker_action_checked_v1(
    uint64_t base_session_id,
    const char *container_id,
    const char *action,
    const char *request_id
);
char *orbit_exec_command(uint64_t session_id, const char *command);
/* Executes one bounded command only on an Active HostKeyVerified base session.
 * Zero option values select documented safe defaults. Returned JSON strings
 * must be released with orbit_free_string.
 */
char *orbit_exec_checked_v1(
    uint64_t base_session_id,
    const char *command,
    uint32_t timeout_seconds,
    uint32_t max_stdout_bytes,
    uint32_t max_stderr_bytes,
    const char *request_id
);

/* Host Key challenge protocol v1. Every result is a versioned JSON envelope.
 * Returned strings are Rust-owned and must be released with orbit_free_string.
 */
char *orbit_hostkey_challenge_accept_v1(const char *challenge_id);
char *orbit_hostkey_challenge_accept_and_persist_v1(
    const char *challenge_id,
    const char *known_hosts_path,
    const char *comment
);
char *orbit_hostkey_challenge_reject_v1(const char *challenge_id);
char *orbit_hostkey_challenge_status_v1(const char *challenge_id);
char *orbit_hostkey_challenge_cleanup_expired_v1(void);
char *orbit_hostkey_protocol_version_v1(void);

typedef void (*orbit_terminal_data_callback_t)(uint64_t terminal_channel_id, const uint8_t *data, size_t len);
typedef void (*orbit_connection_event_callback_t)(uint64_t base_session_id, const char *message);
void orbit_terminal_set_callback(orbit_terminal_data_callback_t callback);
void orbit_connection_set_callback(orbit_connection_event_callback_t callback);
char *orbit_request_channel(uint64_t session_or_channel_id, const char *channel_type);
/* Opens a PTY shell only on an existing Active HostKeyVerified base session.
 * IDs are decimal strings inside the JSON envelope. Returned strings must be
 * released with orbit_free_string.
 */
char *orbit_terminal_open_checked_v1(
    uint64_t base_session_id,
    uint32_t cols,
    uint32_t rows,
    const char *request_id
);
char *orbit_terminal_write(uint64_t terminal_channel_id, const uint8_t *data_ptr, size_t data_len);
char *orbit_terminal_resize(uint64_t terminal_channel_id, uint32_t cols, uint32_t rows);
char *orbit_terminal_close(uint64_t terminal_channel_id);

void orbit_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif // ORBIT_CORE_H
