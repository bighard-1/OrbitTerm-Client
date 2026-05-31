use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;
use russh::client;
use russh::ChannelMsg;
use russh::Disconnect;
use russh_sftp::client::SftpSession;
use thiserror::Error;

#[cfg(target_os = "android")]
mod android_ffi;
mod c_ffi;
mod crypto;
mod crypto_ffi;
mod docker;
mod monitor;
mod portable;
mod portable_ffi;
mod sftp;
mod ssh_session;
mod terminal;
pub use crypto::{decrypt_config, encrypt_config};
use monitor::NetSnapshot;

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
}

impl From<russh::Error> for OrbitCoreError {
    fn from(value: russh::Error) -> Self {
        OrbitCoreError::SshFailed(value.to_string())
    }
}

#[derive(Clone, Default)]
pub(crate) struct OrbitSshClientHandler;

impl client::Handler for OrbitSshClientHandler {
    type Error = OrbitCoreError;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // 首版默认接受服务端公钥。
        // 生产环境建议接入 known_hosts / 指纹校验，防止 MITM。
        Ok(true)
    }
}

pub(crate) struct OrbitBaseSession {
    pub(crate) id: u64,
    host: String,
    #[allow(dead_code)]
    username: String,
    key: String,
    pub(crate) ssh: tokio::sync::Mutex<client::Handle<OrbitSshClientHandler>>,
    net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
    pub(crate) channel_ref_count: AtomicU64,
    keepalive_watch_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

pub(crate) struct OrbitSftpSession {
    pub(crate) base: Arc<OrbitBaseSession>,
    pub(crate) sftp: SftpSession,
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

static BASE_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitBaseSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static BASE_SESSION_KEY_INDEX: Lazy<Mutex<HashMap<String, u64>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static SFTP_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitSftpSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
pub(crate) static TERMINAL_DATA_CALLBACK: Lazy<Mutex<Option<TerminalDataCallback>>> =
    Lazy::new(|| Mutex::new(None));
pub(crate) static CONNECTION_EVENT_CALLBACK: Lazy<Mutex<Option<ConnectionEventCallback>>> =
    Lazy::new(|| Mutex::new(None));
static NEXT_BASE_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_SFTP_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);

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
    if ip.trim().is_empty() || username.trim().is_empty() || port == 0 {
        return Err(OrbitCoreError::InvalidInput);
    }

    let config = ssh_session::new_client_config();
    let addr = ssh_session::normalize_host_port(&ip, port);

    let mut ssh_session = client::connect(config, addr, OrbitSshClientHandler)
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
    if ip.trim().is_empty() || username.trim().is_empty() || port == 0 {
        return Err(OrbitCoreError::InvalidInput);
    }

    let base = get_or_create_base_session(
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

    let session_id = NEXT_SFTP_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
    let wrapper = Arc::new(OrbitSftpSession { base, sftp });

    let mut sessions = lock_sftp_sessions()?;
    sessions.insert(session_id, wrapper);
    Ok(session_id)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_disconnect(session_id: u64) -> Result<(), OrbitCoreError> {
    let session = {
        let mut sessions = lock_sftp_sessions()?;
        sessions.remove(&session_id)
    }
    .ok_or_else(|| OrbitCoreError::SftpFailed("session not found".to_string()))?;

    let base_id = session.base.id;
    session
        .sftp
        .close()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;
    release_base_session(base_id).await?;

    Ok(())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_list_dir(session_id: u64, path: String) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::list_dir(session_id, &session, path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_upload_file(
    session_id: u64,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::upload_file(session_id, &session, local_path, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_download_file(
    session_id: u64,
    remote_path: String,
    local_path: String,
    resume_offset: u64,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::download_file(session_id, &session, remote_path, local_path, resume_offset).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_read_text_file(
    session_id: u64,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::read_text_file(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_write_text_file(
    session_id: u64,
    remote_path: String,
    content: String,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::write_text_file(&session, remote_path, content).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_remove_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::remove_file(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_rename(
    session_id: u64,
    old_remote_path: String,
    new_remote_path: String,
) -> Result<(), OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::rename(&session, old_remote_path, new_remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_mkdir(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::mkdir(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_create_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::create_file(&session, remote_path).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_chmod(
    session_id: u64,
    remote_path: String,
    mode_octal: String,
) -> Result<(), OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    sftp::chmod(&session, remote_path, mode_octal).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_system_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    monitor::fetch_system_stats_for_base(&session.base).await
}
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_containers(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    docker::fetch_containers(&session.base).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    docker::fetch_stats(&session.base).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn docker_action(
    session_id: u64,
    container_id: String,
    action: String,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    docker::run_action(&session.base, &container_id, &action).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_logs(
    session_id: u64,
    container_id: String,
    tail_lines: u32,
) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    docker::fetch_logs(&session.base, &container_id, tail_lines).await
}
#[uniffi::export(async_runtime = "tokio")]
pub async fn exec_command(session_id: u64, command: String) -> Result<String, OrbitCoreError> {
    if command.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let session = get_sftp_session(session_id)?;
    run_remote_command(&session.base, command.trim()).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn request_channel(
    session_or_channel_id: u64,
    channel_type: String,
) -> Result<u64, OrbitCoreError> {
    let base = resolve_base_session(session_or_channel_id)?;
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

            base.channel_ref_count.fetch_add(1, Ordering::SeqCst);
            let channel_id = NEXT_SFTP_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
            let wrapper = Arc::new(OrbitSftpSession { base, sftp });
            lock_sftp_sessions()?.insert(channel_id, wrapper);
            Ok(channel_id)
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
    let ssh = session.ssh.lock().await;
    let mut channel = ssh
        .channel_open_session()
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    channel
        .exec(true, command)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(format!("exec '{command}' failed: {e}")))?;
    eprintln!("[orbit-core][exec] command={}", command);

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
        let err = String::from_utf8_lossy(&stderr).to_string();
        return Err(OrbitCoreError::SshFailed(format!(
            "command '{command}' exited with {exit_code}: {err}"
        )));
    }

    let output = String::from_utf8_lossy(&stdout).to_string();
    eprintln!(
        "[orbit-core][exec] command={} exit={} stdout_bytes={} stderr_bytes={}",
        command,
        exit_code,
        stdout.len(),
        stderr.len()
    );
    Ok(output)
}

pub(crate) fn current_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn lock_sftp_sessions(
) -> Result<std::sync::MutexGuard<'static, HashMap<u64, Arc<OrbitSftpSession>>>, OrbitCoreError> {
    SFTP_SESSIONS
        .lock()
        .map_err(|_| OrbitCoreError::Internal("sftp session lock poisoned".to_string()))
}

fn get_sftp_session(session_id: u64) -> Result<Arc<OrbitSftpSession>, OrbitCoreError> {
    let sessions = lock_sftp_sessions()?;
    sessions
        .get(&session_id)
        .cloned()
        .ok_or_else(|| OrbitCoreError::SftpFailed("session not found".to_string()))
}

fn lock_base_sessions(
) -> Result<std::sync::MutexGuard<'static, HashMap<u64, Arc<OrbitBaseSession>>>, OrbitCoreError> {
    BASE_SESSIONS
        .lock()
        .map_err(|_| OrbitCoreError::Internal("base session lock poisoned".to_string()))
}

fn lock_base_key_index(
) -> Result<std::sync::MutexGuard<'static, HashMap<String, u64>>, OrbitCoreError> {
    BASE_SESSION_KEY_INDEX
        .lock()
        .map_err(|_| OrbitCoreError::Internal("base key index lock poisoned".to_string()))
}

fn emit_connection_event(base_id: u64, message: &str) {
    let cb_opt = CONNECTION_EVENT_CALLBACK
        .lock()
        .ok()
        .and_then(|guard| *guard);

    if let Some(cb) = cb_opt {
        if let Ok(payload) = CString::new(message) {
            cb(base_id, payload.as_ptr());
        }
    }
}

fn spawn_keepalive_watch(base: Arc<OrbitBaseSession>) {
    let base_id = base.id;
    let watch_base = base.clone();
    let task = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;

            let still_exists = lock_base_sessions()
                .ok()
                .map(|sessions| sessions.contains_key(&base_id))
                .unwrap_or(false);
            if !still_exists {
                break;
            }

            let is_closed = {
                let ssh = watch_base.ssh.lock().await;
                ssh.is_closed()
            };
            if is_closed {
                emit_connection_event(base_id, "ERR_CONNECTION_LOST");
                break;
            }
        }
    });

    if let Ok(mut holder) = base.keepalive_watch_task.lock() {
        if let Some(existing) = holder.take() {
            existing.abort();
        }
        *holder = Some(task);
    }
}

fn base_session_key(ip: &str, port: u16, username: &str) -> String {
    format!(
        "{}|{}",
        ssh_session::normalize_host_port(ip, port),
        username.trim()
    )
}

pub(crate) async fn get_or_create_base_session(
    ip: &str,
    port: u16,
    username: &str,
    password: &str,
    private_key_content: &str,
    private_key_passphrase: &str,
    allow_password_fallback: bool,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    let key = base_session_key(ip, port, username);

    if let Some(existing_id) = lock_base_key_index()?.get(&key).copied() {
        if let Some(existing) = lock_base_sessions()?.get(&existing_id).cloned() {
            existing.channel_ref_count.fetch_add(1, Ordering::SeqCst);
            return Ok(existing);
        }
    }

    let config = ssh_session::new_client_config();
    let addr = ssh_session::normalize_host_port(ip, port);

    let mut ssh = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    ssh_session::authenticate_ssh(
        &mut ssh,
        username,
        password,
        private_key_content,
        private_key_passphrase,
        allow_password_fallback,
    )
    .await?;

    let base_id = NEXT_BASE_SESSION_ID.fetch_add(1, Ordering::SeqCst);
    let base = Arc::new(OrbitBaseSession {
        id: base_id,
        host: ip.to_string(),
        username: username.to_string(),
        key: key.clone(),
        ssh: tokio::sync::Mutex::new(ssh),
        net_snapshot: tokio::sync::Mutex::new(None),
        channel_ref_count: AtomicU64::new(1),
        keepalive_watch_task: Mutex::new(None),
    });

    lock_base_sessions()?.insert(base_id, base.clone());
    lock_base_key_index()?.insert(key, base_id);
    spawn_keepalive_watch(base.clone());
    Ok(base)
}

fn resolve_base_session(
    session_or_channel_id: u64,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    if let Some(base) = lock_base_sessions()?.get(&session_or_channel_id).cloned() {
        return Ok(base);
    }
    if let Some(sftp) = lock_sftp_sessions()?.get(&session_or_channel_id).cloned() {
        return Ok(sftp.base.clone());
    }
    if let Some(base_id) = terminal::base_id_for_channel(session_or_channel_id)? {
        if let Some(base) = lock_base_sessions()?.get(&base_id).cloned() {
            return Ok(base);
        }
    }

    Err(OrbitCoreError::SshFailed(
        "unable to resolve base session".to_string(),
    ))
}

pub(crate) async fn release_base_session(base_id: u64) -> Result<(), OrbitCoreError> {
    let maybe_base = lock_base_sessions()?.get(&base_id).cloned();
    let Some(base) = maybe_base else {
        return Ok(());
    };

    let prev = base.channel_ref_count.fetch_sub(1, Ordering::SeqCst);
    if prev > 1 {
        return Ok(());
    }

    {
        let mut bases = lock_base_sessions()?;
        bases.remove(&base_id);
    }
    {
        let mut index = lock_base_key_index()?;
        index.remove(&base.key);
    }
    if let Ok(mut holder) = base.keepalive_watch_task.lock() {
        if let Some(task) = holder.take() {
            task.abort();
        }
    }

    let ssh = base.ssh.lock().await;
    let _ = ssh
        .disconnect(Disconnect::ByApplication, "session released", "en")
        .await;
    Ok(())
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
