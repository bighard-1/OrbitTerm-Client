use std::ffi::CString;
use std::os::raw::c_char;

use crate::{
    c_ptr_to_string, docker_action, exec_command, fetch_docker_containers, fetch_docker_logs,
    fetch_docker_stats, fetch_system_stats, request_channel, session_pool, sftp_chmod,
    sftp_connect, sftp_create_file, sftp_disconnect, sftp_download_file, sftp_list_dir, sftp_mkdir,
    sftp_read_text_file, sftp_remove_file, sftp_rename, sftp_upload_file, sftp_write_text_file,
    terminal_close, terminal_resize, terminal_write, test_ssh_connection, to_c_string_ptr,
    OrbitCoreError, CONNECTION_EVENT_CALLBACK, ORBIT_RUNTIME, TERMINAL_DATA_CALLBACK,
};

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
    let ip = match c_ptr_to_string(ip) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let username = match c_ptr_to_string(username) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let password = match c_ptr_to_string(password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_content = match c_ptr_to_string(private_key_content) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_passphrase = match c_ptr_to_string(private_key_passphrase) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let port = match normalize_port(port) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(test_ssh_connection(
        ip,
        port,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback != 0,
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
    let ip = match c_ptr_to_string(ip) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let username = match c_ptr_to_string(username) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let password = match c_ptr_to_string(password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_content = match c_ptr_to_string(private_key_content) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_passphrase = match c_ptr_to_string(private_key_passphrase) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let port = match normalize_port(port) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(session_pool::get_or_create_base_session(
        &ip,
        port,
        &username,
        &password,
        &private_key_content,
        &private_key_passphrase,
        allow_password_fallback != 0,
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
    let ip = match c_ptr_to_string(ip) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let username = match c_ptr_to_string(username) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let password = match c_ptr_to_string(password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_content = match c_ptr_to_string(private_key_content) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let private_key_passphrase = match c_ptr_to_string(private_key_passphrase) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let port = match normalize_port(port) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = ORBIT_RUNTIME.block_on(sftp_connect(
        ip,
        port,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback != 0,
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
pub extern "C" fn orbit_request_channel(
    session_or_channel_id: u64,
    channel_type: *const c_char,
) -> *mut c_char {
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
    let result = ORBIT_RUNTIME.block_on(fetch_system_stats(session_id));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_docker_containers(session_id: u64) -> *mut c_char {
    let result = ORBIT_RUNTIME.block_on(fetch_docker_containers(session_id));
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_fetch_docker_stats(session_id: u64) -> *mut c_char {
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
pub extern "C" fn orbit_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}
