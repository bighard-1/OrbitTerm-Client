use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;
use russh::ChannelMsg;
use russh_sftp::client::SftpSession;
use thiserror::Error;

#[cfg(target_os = "android")]
mod android_ffi;
mod c_ffi;
#[allow(
    dead_code,
    reason = "typed Docker rename/update are intentionally not exposed through C until Swift migration"
)]
mod checked_docker;
#[cfg(test)]
mod checked_docker_tests;
mod checked_exec;
#[cfg(test)]
mod checked_exec_tests;
mod checked_monitor;
#[cfg(test)]
mod checked_monitor_tests;
mod checked_sftp;
#[cfg(test)]
mod checked_sftp_tests;
mod checked_terminal;
#[cfg(test)]
mod checked_terminal_tests;
mod crypto;
mod crypto_ffi;
mod docker;
#[allow(
    dead_code,
    reason = "typed Docker rename/update validators are intentionally staged before their C ABI"
)]
mod docker_validator;
#[cfg(test)]
mod docker_validator_tests;
mod legacy_network;
#[cfg(test)]
mod legacy_network_tests;
mod monitor;
mod portable;
mod portable_ffi;
pub mod security;
mod session_pool;
#[cfg(test)]
mod session_pool_tests;
mod sftp;
mod ssh_session;
mod terminal;
pub use crypto::{decrypt_config, encrypt_config};
pub(crate) use session_pool::{OrbitBaseSession, OrbitSftpSession};

uniffi::setup_scaffolding!();

#[derive(Debug, Error, uniffi::Error)]
pub enum OrbitCoreError {
    #[error("参数不合法")]
    InvalidInput,
    #[error("加密失败")]
    EncryptFailed,
    #[error("解密失败")]
    DecryptFailed,
    #[error("SSH 连接失败: {0}")]
    SshFailed(String),
    #[error("SFTP 错误: {0}")]
    SftpFailed(String),
    #[error("内部错误: {0}")]
    Internal(String),
    #[error("legacy_network_disabled")]
    LegacyNetworkDisabled,
}

impl From<legacy_network::LegacyNetworkDisabled> for OrbitCoreError {
    fn from(_: legacy_network::LegacyNetworkDisabled) -> Self {
        Self::LegacyNetworkDisabled
    }
}

impl From<russh::Error> for OrbitCoreError {
    fn from(value: russh::Error) -> Self {
        OrbitCoreError::SshFailed(value.to_string())
    }
}

pub(crate) static ORBIT_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to initialize orbit tokio runtime")
});

pub(crate) type TerminalDataCallback = extern "C" fn(u64, *const u8, usize);
pub(crate) type ConnectionEventCallback = extern "C" fn(u64, *const c_char);

pub(crate) static TERMINAL_DATA_CALLBACK: Lazy<std::sync::Mutex<Option<TerminalDataCallback>>> =
    Lazy::new(|| std::sync::Mutex::new(None));
pub(crate) static CONNECTION_EVENT_CALLBACK: Lazy<
    std::sync::Mutex<Option<ConnectionEventCallback>>,
> = Lazy::new(|| std::sync::Mutex::new(None));

#[uniffi::export(async_runtime = "tokio")]
pub async fn test_ssh_connection(
    ip: String,
    port: u16,
    username: String,
    password: String,
    private_key_content: String,
    private_key_passphrase: String,
    allow_password_fallback: bool,
) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;

    #[cfg(not(feature = "legacy-network-internal"))]
    {
        let _ = (
            ip,
            port,
            username,
            password,
            private_key_content,
            private_key_passphrase,
            allow_password_fallback,
        );
        Err(OrbitCoreError::LegacyNetworkDisabled)
    }

    #[cfg(feature = "legacy-network-internal")]
    {
        use security::insecure_legacy_host_key_handler::InsecureLegacyAcceptAllHostKeyHandler;

        if ip.trim().is_empty() || username.trim().is_empty() || port == 0 {
            return Err(OrbitCoreError::InvalidInput);
        }

        let config = ssh_session::new_client_config();
        let addr = ssh_session::normalize_host_port(&ip, port);

        let mut ssh_session =
            russh::client::connect(config, addr, InsecureLegacyAcceptAllHostKeyHandler)
                .await
                .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

        ssh_session::authenticate_ssh(
            &mut ssh_session,
            &username,
            &password,
            &private_key_content,
            &private_key_passphrase,
            allow_password_fallback,
        )
        .await?;

        Ok("SSH connection success".to_string())
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_connect(
    ip: String,
    port: u16,
    username: String,
    password: String,
    private_key_content: String,
    private_key_passphrase: String,
    allow_password_fallback: bool,
) -> Result<u64, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    if ip.trim().is_empty() || username.trim().is_empty() || port == 0 {
        return Err(OrbitCoreError::InvalidInput);
    }

    let base = session_pool::get_or_create_base_session(
        &ip,
        port,
        &username,
        &password,
        &private_key_content,
        &private_key_passphrase,
        allow_password_fallback,
    )
    .await?;

    let ssh = base.ssh.lock().await;
    let channel = ssh
        .channel_open_session()
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;
    drop(ssh);

    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("request subsystem failed: {e}")))?;

    let sftp = SftpSession::new(channel.into_stream())
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

    session_pool::insert_sftp_session(base, sftp, false)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_disconnect(session_id: u64) -> Result<(), OrbitCoreError> {
    let session = session_pool::remove_sftp_session(session_id)?;

    let base_id = session.base.id;
    session
        .sftp
        .close()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;
    session_pool::release_base_session(base_id).await?;

    Ok(())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_list_dir(session_id: u64, path: String) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::list_dir(session_id, &session, path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_upload_file(
    session_id: u64,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::upload_file(session_id, &session, local_path, remote_path).await
}

pub(crate) async fn sftp_upload_file_create_new(
    session_id: u64,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::upload_file_create_new(session_id, &session, local_path, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_download_file(
    session_id: u64,
    remote_path: String,
    local_path: String,
    resume_offset: u64,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::download_file(session_id, &session, remote_path, local_path, resume_offset).await
}

pub(crate) async fn sftp_download_file_create_new(
    session_id: u64,
    remote_path: String,
    local_path: String,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::download_file_create_new(session_id, &session, remote_path, local_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_read_text_file(
    session_id: u64,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::read_text_file(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_write_text_file(
    session_id: u64,
    remote_path: String,
    content: String,
) -> Result<String, OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::write_text_file(&session, remote_path, content).await
}

pub(crate) async fn sftp_write_text_file_checked_recoverable(
    session_id: u64,
    remote_path: String,
    content: Vec<u8>,
    expected: sftp::SftpEntrySnapshot,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::write_text_file_checked_recoverable(&session, remote_path, content, expected).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_remove_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::remove_file(&session, remote_path).await
}

pub(crate) async fn sftp_remove_checked(
    session_id: u64,
    remote_path: String,
    expected: sftp::SftpEntrySnapshot,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::remove_checked(&session, remote_path, expected).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_rename(
    session_id: u64,
    old_remote_path: String,
    new_remote_path: String,
) -> Result<(), OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::rename(&session, old_remote_path, new_remote_path).await
}

pub(crate) async fn sftp_rename_checked_no_overwrite(
    session_id: u64,
    old_remote_path: String,
    new_remote_path: String,
    expected: sftp::SftpEntrySnapshot,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::rename_checked_no_overwrite(&session, old_remote_path, new_remote_path, expected).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_mkdir(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::mkdir(&session, remote_path).await
}

pub(crate) async fn sftp_mkdir_checked_create_new(
    session_id: u64,
    remote_path: String,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::mkdir_checked_create_new(&session, remote_path).await
}

pub(crate) async fn sftp_create_file_checked_create_new(
    session_id: u64,
    remote_path: String,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::create_file_checked_create_new(&session, remote_path).await
}

pub(crate) async fn sftp_chmod_checked(
    session_id: u64,
    remote_path: String,
    mode: u32,
    expected: sftp::SftpEntrySnapshot,
) -> Result<(), sftp::SftpMutationError> {
    let session = session_pool::get_sftp_session(session_id)
        .map_err(|_| sftp::SftpMutationError::SessionUnavailable)?;
    sftp::chmod_checked(&session, remote_path, mode, expected).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_create_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::create_file(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_chmod(
    session_id: u64,
    remote_path: String,
    mode_octal: String,
) -> Result<(), OrbitCoreError> {
    let session = session_pool::get_sftp_session(session_id)?;
    sftp::chmod(&session, remote_path, mode_octal).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_system_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let session = session_pool::get_sftp_session(session_id)?;
    monitor::fetch_system_stats_for_base(&session.base).await
}
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_containers(session_id: u64) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let session = session_pool::get_sftp_session(session_id)?;
    docker::fetch_containers(&session.base).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let session = session_pool::get_sftp_session(session_id)?;
    docker::fetch_stats(&session.base).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn docker_action(
    session_id: u64,
    container_id: String,
    action: String,
) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let session = session_pool::get_sftp_session(session_id)?;
    docker::run_action(&session.base, &container_id, &action).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_logs(
    session_id: u64,
    container_id: String,
    tail_lines: u32,
) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let session = session_pool::get_sftp_session(session_id)?;
    docker::fetch_logs(&session.base, &container_id, tail_lines).await
}
#[uniffi::export(async_runtime = "tokio")]
pub async fn exec_command(session_id: u64, command: String) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    if command.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let session = session_pool::get_sftp_session(session_id)?;
    run_remote_command(&session.base, command.trim()).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn request_channel(
    session_or_channel_id: u64,
    channel_type: String,
) -> Result<u64, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    let base = session_pool::resolve_base_session(session_or_channel_id)?;
    let kind = channel_type.trim().to_lowercase();

    match kind.as_str() {
        "sftp" => {
            let ssh = base.ssh.lock().await;
            let channel = ssh
                .channel_open_session()
                .await
                .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;
            drop(ssh);

            channel.request_subsystem(true, "sftp").await.map_err(|e| {
                OrbitCoreError::SftpFailed(format!("request subsystem failed: {e}"))
            })?;

            let sftp = SftpSession::new(channel.into_stream())
                .await
                .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

            session_pool::insert_sftp_session(base, sftp, true)
        }
        "exec" => Ok(base.id),
        "pty" => terminal::open_channel(base, 120, 36).await,
        _ => Err(OrbitCoreError::InvalidInput),
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_write(terminal_channel_id: u64, data: Vec<u8>) -> Result<(), OrbitCoreError> {
    terminal::write(terminal_channel_id, data).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_resize(
    terminal_channel_id: u64,
    cols: u32,
    rows: u32,
) -> Result<(), OrbitCoreError> {
    terminal::resize(terminal_channel_id, cols, rows).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_close(terminal_channel_id: u64) -> Result<(), OrbitCoreError> {
    terminal::close(terminal_channel_id).await
}

pub(crate) async fn run_remote_command(
    session: &Arc<OrbitBaseSession>,
    command: &str,
) -> Result<String, OrbitCoreError> {
    legacy_network::LegacyNetworkGate::require_current()?;
    run_remote_command_transport(session, command).await
}

pub(crate) async fn run_remote_command_for_sftp_operation(
    session: &Arc<OrbitSftpSession>,
    command: &str,
) -> Result<String, OrbitCoreError> {
    session_pool::require_sftp_operation_access(session)?;
    run_remote_command_transport(&session.base, command).await
}

async fn run_remote_command_transport(
    session: &Arc<OrbitBaseSession>,
    command: &str,
) -> Result<String, OrbitCoreError> {
    let ssh = session.ssh.lock().await;
    let mut channel = ssh
        .channel_open_session()
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    channel
        .exec(true, command)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(format!("exec request failed: {e}")))?;
    if legacy_network::LegacyNetworkPolicy::current().allows_legacy_network()
        && std::env::var_os("ORBIT_CORE_DEBUG").is_some()
    {
        eprintln!("{}", remote_exec_start_diagnostic(command));
    }

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut exit_code = 0u32;

    loop {
        let Some(msg) = channel.wait().await else {
            break;
        };

        match msg {
            ChannelMsg::Data { data } => stdout.extend_from_slice(&data),
            ChannelMsg::ExtendedData { data, .. } => stderr.extend_from_slice(&data),
            ChannelMsg::ExitStatus { exit_status } => exit_code = exit_status,
            _ => {}
        }
    }

    if exit_code != 0 {
        return Err(OrbitCoreError::SshFailed(format!(
            "remote command exited with status {exit_code}"
        )));
    }

    let output = String::from_utf8_lossy(&stdout).to_string();
    if legacy_network::LegacyNetworkPolicy::current().allows_legacy_network()
        && std::env::var_os("ORBIT_CORE_DEBUG").is_some()
    {
        eprintln!(
            "{}",
            remote_exec_finish_diagnostic(command, exit_code, stdout.len(), stderr.len())
        );
    }
    Ok(output)
}

fn remote_exec_start_diagnostic(command: &str) -> String {
    format!("[orbit-core][exec] command_bytes={}", command.len())
}

fn remote_exec_finish_diagnostic(
    command: &str,
    exit_code: u32,
    stdout_bytes: usize,
    stderr_bytes: usize,
) -> String {
    format!(
        "[orbit-core][exec] command_bytes={} exit={} stdout_bytes={} stderr_bytes={}",
        command.len(),
        exit_code,
        stdout_bytes,
        stderr_bytes
    )
}

pub(crate) fn current_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub(crate) fn c_ptr_to_string(ptr: *const c_char) -> Result<String, OrbitCoreError> {
    if ptr.is_null() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let raw = unsafe { CStr::from_ptr(ptr) };
    raw.to_str()
        .map(|s| s.to_string())
        .map_err(|_| OrbitCoreError::InvalidInput)
}

pub(crate) fn to_c_string_ptr(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("internal string error").expect("fallback CString must be valid")
        })
        .into_raw()
}
