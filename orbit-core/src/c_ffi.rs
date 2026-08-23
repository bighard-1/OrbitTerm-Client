use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::Arc;

use crate::{
    c_ptr_to_string, docker_action, exec_command, fetch_docker_containers, fetch_docker_logs,
    fetch_docker_stats, fetch_system_stats, request_channel, session_pool, sftp_chmod,
    sftp_connect, sftp_create_file, sftp_disconnect, sftp_download_file, sftp_list_dir, sftp_mkdir,
    sftp_read_text_file, sftp_remove_file, sftp_rename, sftp_upload_file, sftp_write_text_file,
    terminal_close, terminal_resize, terminal_write, test_ssh_connection, to_c_string_ptr,
    OrbitCoreError, CONNECTION_EVENT_CALLBACK, ORBIT_RUNTIME, TERMINAL_DATA_CALLBACK,
};

/// Validates portable SSH private-key material with the same decoder and
/// algorithm policy used by real connections. No key material is retained or
/// included in the returned value.
#[no_mangle]
pub extern "C" fn orbit_validate_ssh_private_key_v1(
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
) -> *mut c_char {
    let private_key_content = match c_ptr_to_string(private_key_content) {
        Ok(value) => value,
        Err(_) => return to_c_string_ptr("ERR:key_material_invalid".to_string()),
    };
    let private_key_passphrase = match c_ptr_to_string(private_key_passphrase) {
        Ok(value) => value,
        Err(_) => return to_c_string_ptr("ERR:key_passphrase_invalid".to_string()),
    };
    match crate::ssh_session::decode_supported_private_key(
        &private_key_content,
        &private_key_passphrase,
    ) {
        Ok(key) => to_c_string_ptr(format!("OK:{}", key.algorithm().as_str())),
        Err(OrbitCoreError::SshFailed(message)) if message.starts_with("不支持的") => {
            to_c_string_ptr("ERR:key_algorithm_unsupported".to_string())
        }
        Err(_) => to_c_string_ptr("ERR:key_parse_failed".to_string()),
    }
}

/// Checked, correlated SSH private-key validation envelope for desktop
/// clients. The response never contains private-key material or passphrases.
#[no_mangle]
pub extern "C" fn orbit_validate_ssh_private_key_checked_v2(
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    let request_id = match c_ptr_to_string(request_id) {
        Ok(value)
            if !value.is_empty()
                && value.len() <= 256
                && value.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-')
                }) =>
        {
            value
        }
        _ => {
            return to_c_string_ptr(
                serde_json::json!({
                    "schema_version": 1,
                    "request_id": null,
                    "kind": "error",
                    "data": null,
                    "error": {
                        "code": "invalid_request",
                        "message_key": "error.request.invalid",
                        "request_id": null
                    }
                })
                .to_string(),
            )
        }
    };
    let private_key_content = match c_ptr_to_string(private_key_content) {
        Ok(value) => value,
        Err(_) => {
            return ssh_key_validation_error(
                &request_id,
                "ssh_key_material_invalid",
                "error.ssh_key.material_invalid",
            )
        }
    };
    let private_key_passphrase = match c_ptr_to_string(private_key_passphrase) {
        Ok(value) => value,
        Err(_) => {
            return ssh_key_validation_error(
                &request_id,
                "ssh_key_passphrase_invalid",
                "error.ssh_key.passphrase_invalid",
            )
        }
    };

    match crate::ssh_session::decode_supported_private_key(
        &private_key_content,
        &private_key_passphrase,
    ) {
        Ok(key) => to_c_string_ptr(
            serde_json::json!({
                "schema_version": 1,
                "request_id": request_id,
                "kind": "ssh_private_key_validated",
                "data": { "algorithm": key.algorithm().as_str() },
                "error": null
            })
            .to_string(),
        ),
        Err(OrbitCoreError::SshFailed(message)) if message.starts_with("不支持的") => {
            ssh_key_validation_error(
                &request_id,
                "ssh_key_algorithm_unsupported",
                "error.ssh_key.algorithm_unsupported",
            )
        }
        Err(_) => ssh_key_validation_error(
            &request_id,
            "ssh_key_parse_failed",
            "error.ssh_key.parse_failed",
        ),
    }
}

fn ssh_key_validation_error(request_id: &str, code: &str, message_key: &str) -> *mut c_char {
    to_c_string_ptr(
        serde_json::json!({
            "schema_version": 1,
            "request_id": request_id,
            "kind": "error",
            "data": null,
            "error": {
                "code": code,
                "message_key": message_key,
                "request_id": request_id
            }
        })
        .to_string(),
    )
}

fn legacy_network_disabled_response() -> Option<*mut c_char> {
    crate::legacy_network::LegacyNetworkGate::require_current()
        .err()
        .map(|error| to_c_string_ptr(format!("ERR:{}", error.error_code())))
}

struct ConnectionArguments {
    ip: String,
    port: u16,
    username: String,
    password: String,
    private_key_content: String,
    private_key_passphrase: String,
    allow_password_fallback: bool,
}

fn parse_connection_arguments(
    ip: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
) -> Result<ConnectionArguments, OrbitCoreError> {
    Ok(ConnectionArguments {
        ip: c_ptr_to_string(ip)?,
        port: normalize_port(port)?,
        username: c_ptr_to_string(username)?,
        password: c_ptr_to_string(password)?,
        private_key_content: c_ptr_to_string(private_key_content)?,
        private_key_passphrase: c_ptr_to_string(private_key_passphrase)?,
        allow_password_fallback: allow_password_fallback != 0,
    })
}

#[no_mangle]
pub extern "C" fn orbit_test_ssh_connection(
    ip: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let args = match parse_connection_arguments(
        ip,
        port,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback,
    ) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(test_ssh_connection(
        args.ip,
        args.port,
        args.username,
        args.password,
        args.private_key_content,
        args.private_key_passphrase,
        args.allow_password_fallback,
    ));
    match result {
        Ok(msg) => to_c_string_ptr(format!("OK:{}", msg)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_ssh_connect(
    ip: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let args = match parse_connection_arguments(
        ip,
        port,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback,
    ) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(session_pool::get_or_create_base_session(
        &args.ip,
        args.port,
        &args.username,
        &args.password,
        &args.private_key_content,
        &args.private_key_passphrase,
        args.allow_password_fallback,
    ));
    match result {
        Ok(base) => to_c_string_ptr(format!("OK:session:{}", base.id)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_connect(
    ip: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key_content: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let args = match parse_connection_arguments(
        ip,
        port,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback,
    ) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_connect(
        args.ip,
        args.port,
        args.username,
        args.password,
        args.private_key_content,
        args.private_key_passphrase,
        args.allow_password_fallback,
    ));
    match result {
        Ok(session_id) => to_c_string_ptr(format!("OK:{}", session_id)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_ssh_disconnect(base_session_id: u64) -> *mut c_char {
    let result = ORBIT_RUNTIME.block_on(session_pool::release_base_session(base_session_id));
    match result {
        Ok(_) => to_c_string_ptr("OK:disconnected".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

fn normalize_port(port: i32) -> Result<u16, OrbitCoreError> {
    if (1..=65535).contains(&port) {
        Ok(port as u16)
    } else {
        Err(OrbitCoreError::InvalidInput)
    }
}

pub type OrbitTerminalDataCallback = extern "C" fn(u64, *const u8, usize);
pub type OrbitConnectionEventCallback = extern "C" fn(u64, *const c_char);
pub type OrbitSftpProgressCallback = extern "C" fn(*const c_char, u64, u64, bool);

#[no_mangle]
pub extern "C" fn orbit_terminal_set_callback(callback: Option<OrbitTerminalDataCallback>) {
    if let Ok(mut holder) = TERMINAL_DATA_CALLBACK.lock() {
        *holder = callback;
    }
}

#[no_mangle]
pub extern "C" fn orbit_connection_set_callback(callback: Option<OrbitConnectionEventCallback>) {
    if let Ok(mut holder) = CONNECTION_EVENT_CALLBACK.lock() {
        *holder = callback;
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_set_progress_callback(callback: Option<OrbitSftpProgressCallback>) {
    match callback {
        Some(callback) => {
            crate::security::checked_sftp_ffi::install_sftp_progress_sink(Arc::new(
                move |request_id, transferred, total| {
                    let Ok(request_id) = CString::new(request_id) else {
                        return;
                    };
                    callback(
                        request_id.as_ptr(),
                        transferred,
                        total.unwrap_or(0),
                        total.is_some(),
                    );
                },
            ));
        }
        None => crate::security::checked_sftp_ffi::clear_sftp_progress_sink(),
    }
}

#[no_mangle]
pub extern "C" fn orbit_request_channel(
    session_or_channel_id: u64,
    channel_type: *const c_char,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let channel_type = match c_ptr_to_string(channel_type) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(request_channel(session_or_channel_id, channel_type));
    match result {
        Ok(channel_id) => to_c_string_ptr(format!("OK:{}", channel_id)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_terminal_write(
    terminal_channel_id: u64,
    data_ptr: *const u8,
    data_len: usize,
) -> *mut c_char {
    if data_ptr.is_null() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }
    let bytes = unsafe { std::slice::from_raw_parts(data_ptr, data_len) }.to_vec();
    let result = ORBIT_RUNTIME.block_on(terminal_write(terminal_channel_id, bytes));
    match result {
        Ok(_) => to_c_string_ptr("OK:wrote".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_terminal_resize(
    terminal_channel_id: u64,
    cols: u32,
    rows: u32,
) -> *mut c_char {
    let result = ORBIT_RUNTIME.block_on(terminal_resize(terminal_channel_id, cols, rows));
    match result {
        Ok(_) => to_c_string_ptr("OK:resized".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_terminal_close(terminal_channel_id: u64) -> *mut c_char {
    let result = ORBIT_RUNTIME.block_on(terminal_close(terminal_channel_id));
    match result {
        Ok(_) => to_c_string_ptr("OK:closed".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_disconnect(session_id: u64) -> *mut c_char {
    let result = ORBIT_RUNTIME.block_on(sftp_disconnect(session_id));
    match result {
        Ok(_) => to_c_string_ptr("OK:disconnected".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_list_dir(session_id: u64, remote_path: *const c_char) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_list_dir(session_id, remote_path));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_upload_file(
    session_id: u64,
    local_path: *const c_char,
    remote_path: *const c_char,
) -> *mut c_char {
    let local_path = match c_ptr_to_string(local_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_upload_file(session_id, local_path, remote_path));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_download_file(
    session_id: u64,
    remote_path: *const c_char,
    local_path: *const c_char,
    resume_offset: u64,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let local_path = match c_ptr_to_string(local_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_download_file(
        session_id,
        remote_path,
        local_path,
        resume_offset,
    ));

    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_read_text_file(
    session_id: u64,
    remote_path: *const c_char,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_read_text_file(session_id, remote_path));
    match result {
        Ok(text) => to_c_string_ptr(format!("OK:{}", text)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_write_text_file(
    session_id: u64,
    remote_path: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let content = match c_ptr_to_string(content) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_write_text_file(session_id, remote_path, content));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_remove_file(
    session_id: u64,
    remote_path: *const c_char,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_remove_file(session_id, remote_path));
    match result {
        Ok(_) => to_c_string_ptr("OK:removed".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_rename(
    session_id: u64,
    old_remote_path: *const c_char,
    new_remote_path: *const c_char,
) -> *mut c_char {
    let old_remote_path = match c_ptr_to_string(old_remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let new_remote_path = match c_ptr_to_string(new_remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_rename(session_id, old_remote_path, new_remote_path));
    match result {
        Ok(_) => to_c_string_ptr("OK:renamed".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_mkdir(session_id: u64, remote_path: *const c_char) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_mkdir(session_id, remote_path));
    match result {
        Ok(_) => to_c_string_ptr("OK:mkdir".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_create_file(
    session_id: u64,
    remote_path: *const c_char,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_create_file(session_id, remote_path));
    match result {
        Ok(_) => to_c_string_ptr("OK:create_file".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_chmod(
    session_id: u64,
    remote_path: *const c_char,
    mode_octal: *const c_char,
) -> *mut c_char {
    let remote_path = match c_ptr_to_string(remote_path) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let mode_octal = match c_ptr_to_string(mode_octal) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_chmod(session_id, remote_path, mode_octal));
    match result {
        Ok(_) => to_c_string_ptr("OK:chmod".to_string()),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_system_stats(session_id: u64) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let result = ORBIT_RUNTIME.block_on(fetch_system_stats(session_id));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_docker_containers(session_id: u64) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let result = ORBIT_RUNTIME.block_on(fetch_docker_containers(session_id));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_docker_stats(session_id: u64) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let result = ORBIT_RUNTIME.block_on(fetch_docker_stats(session_id));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_docker_action(
    session_id: u64,
    container_id: *const c_char,
    action: *const c_char,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let container_id = match c_ptr_to_string(container_id) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let action = match c_ptr_to_string(action) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(docker_action(session_id, container_id, action));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_docker_logs(
    session_id: u64,
    container_id: *const c_char,
    tail_lines: u32,
) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let container_id = match c_ptr_to_string(container_id) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(fetch_docker_logs(session_id, container_id, tail_lines));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_exec_command(session_id: u64, command: *const c_char) -> *mut c_char {
    if let Some(response) = legacy_network_disabled_response() {
        return response;
    }
    let command = match c_ptr_to_string(command) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(exec_command(session_id, command));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_generate_ed25519_key_pair_v1(comment: *const c_char) -> *mut c_char {
    let comment = match c_ptr_to_string(comment) {
        Ok(value) => value,
        Err(error) => return to_c_string_ptr(format!("ERR:{error}")),
    };
    match crate::key_generation::generate_ed25519_key_pair(&comment).and_then(|pair| {
        serde_json::to_string(&pair)
            .map_err(|_| OrbitCoreError::Internal("key_pair_serialization_failed".to_string()))
    }) {
        Ok(payload) => to_c_string_ptr(format!("OK:{payload}")),
        Err(error) => to_c_string_ptr(format!("ERR:{error}")),
    }
}

#[no_mangle]
pub extern "C" fn orbit_ssh_public_key_from_private_v1(
    private_key: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let private_key = match c_ptr_to_string(private_key) {
        Ok(value) => value,
        Err(error) => return to_c_string_ptr(format!("ERR:{error}")),
    };
    let passphrase = match c_ptr_to_string(passphrase) {
        Ok(value) => value,
        Err(error) => return to_c_string_ptr(format!("ERR:{error}")),
    };
    match crate::key_generation::derive_public_key(&private_key, &passphrase) {
        Ok(public_key) => to_c_string_ptr(format!("OK:{public_key}")),
        Err(error) => to_c_string_ptr(format!("ERR:{error}")),
    }
}

#[no_mangle]
pub extern "C" fn orbit_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

#[cfg(test)]
mod tests {
    #[cfg(not(feature = "legacy-network-internal"))]
    use std::ffi::CStr;
    #[cfg(not(feature = "legacy-network-internal"))]
    use std::ptr;

    use super::*;

    #[test]
    fn normalizes_valid_ports() {
        assert_eq!(normalize_port(1).expect("minimum port"), 1);
        assert_eq!(normalize_port(65_535).expect("maximum port"), 65_535);
    }

    #[test]
    fn rejects_out_of_range_ports() {
        assert!(normalize_port(0).is_err());
        assert!(normalize_port(65_536).is_err());
        assert!(normalize_port(-1).is_err());
    }

    #[test]
    fn checked_private_key_validation_returns_correlated_json_without_key_material() {
        let private_key = CString::new("not-private-key").expect("private key fixture");
        let passphrase = CString::new("secret-passphrase").expect("passphrase fixture");
        let request_id = CString::new("request-123").expect("request fixture");
        let pointer = orbit_validate_ssh_private_key_checked_v2(
            private_key.as_ptr(),
            passphrase.as_ptr(),
            request_id.as_ptr(),
        );
        assert!(!pointer.is_null());
        let response = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .expect("checked validation must be UTF-8")
            .to_string();
        orbit_free_string(pointer);
        let json: serde_json::Value = serde_json::from_str(&response).expect("checked JSON");
        assert_eq!(json["schema_version"], 1);
        assert_eq!(json["request_id"], "request-123");
        assert_eq!(json["kind"], "error");
        assert_eq!(json["error"]["code"], "ssh_key_parse_failed");
        assert!(!response.contains("not-private-key"));
        assert!(!response.contains("secret-passphrase"));
    }

    #[cfg(not(feature = "legacy-network-internal"))]
    fn assert_release_disabled(pointer: *mut c_char) {
        assert!(!pointer.is_null());
        let response = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .expect("legacy gate response must be UTF-8")
            .to_string();
        orbit_free_string(pointer);
        assert_eq!(response, "ERR:legacy_network_disabled");
        for forbidden in [
            "password",
            "private_key",
            "known_hosts",
            "sensitive-command",
            "192.0.2.1",
        ] {
            assert!(!response.contains(forbidden));
        }
    }

    #[cfg(not(feature = "legacy-network-internal"))]
    #[test]
    fn release_c_abi_legacy_symbols_fail_before_pointer_parsing_or_lookup() {
        assert_release_disabled(orbit_test_ssh_connection(
            ptr::null(),
            22,
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            0,
        ));
        assert_release_disabled(orbit_ssh_connect(
            ptr::null(),
            22,
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            0,
        ));
        assert_release_disabled(orbit_sftp_connect(
            ptr::null(),
            22,
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            0,
        ));
        assert_release_disabled(orbit_request_channel(0, ptr::null()));
        assert_release_disabled(orbit_exec_command(0, ptr::null()));
        assert_release_disabled(orbit_fetch_system_stats(0));
        assert_release_disabled(orbit_fetch_docker_containers(0));
        assert_release_disabled(orbit_fetch_docker_stats(0));
        assert_release_disabled(orbit_fetch_docker_logs(0, ptr::null(), 0));
        assert_release_disabled(orbit_docker_action(0, ptr::null(), ptr::null()));
    }
}
