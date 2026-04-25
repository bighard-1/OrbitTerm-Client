#ifndef ORBIT_CORE_H
#define ORBIT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *orbit_encrypt_config(const char *master_password, const unsigned char *plaintext_ptr, size_t plaintext_len);
char *orbit_decrypt_config(const char *master_password, const char *encrypted_base64);
char *orbit_test_ssh_connection(
    const char *ip,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key_content,
    const char *private_key_passphrase,
    int32_t allow_password_fallback
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

char *orbit_sftp_connect(
    const char *ip,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key_content,
    const char *private_key_passphrase,
    int32_t allow_password_fallback
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
char *orbit_fetch_docker_containers(uint64_t session_id);
char *orbit_fetch_docker_stats(uint64_t session_id);
char *orbit_docker_action(uint64_t session_id, const char *container_id, const char *action);
char *orbit_fetch_docker_logs(uint64_t session_id, const char *container_id, uint32_t tail_lines);

typedef void (*orbit_terminal_data_callback_t)(uint64_t terminal_channel_id, const uint8_t *data, size_t len);
void orbit_terminal_set_callback(orbit_terminal_data_callback_t callback);
char *orbit_request_channel(uint64_t session_or_channel_id, const char *channel_type);
char *orbit_terminal_write(uint64_t terminal_channel_id, const uint8_t *data_ptr, size_t data_len);
char *orbit_terminal_resize(uint64_t terminal_channel_id, uint32_t cols, uint32_t rows);
char *orbit_terminal_close(uint64_t terminal_channel_id);

void orbit_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif // ORBIT_CORE_H
