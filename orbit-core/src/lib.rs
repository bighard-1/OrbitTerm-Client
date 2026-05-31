use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "android")]
use base64::Engine;
use once_cell::sync::Lazy;
use russh::client;
use russh::ChannelMsg;
use russh::Disconnect;
use russh_sftp::client::SftpSession;
use thiserror::Error;
use tokio::io::{AsyncRead, ReadBuf};
use tokio::sync::mpsc;

mod crypto;
mod crypto_ffi;
mod docker;
mod monitor;
mod portable;
mod portable_ffi;
mod sftp;
mod ssh_session;
pub use crypto::{decrypt_config, encrypt_config};
use monitor::NetSnapshot;

#[cfg(target_os = "android")]
use portable::{parse_portable_config, portable_changed_fields, portable_merge};

#[cfg(target_os = "android")]
use jni::objects::{JByteArray, JObject, JString};
#[cfg(target_os = "android")]
use jni::sys::{jlong, jstring};
#[cfg(target_os = "android")]
use jni::JNIEnv;

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
    id: u64,
    host: String,
    #[allow(dead_code)]
    username: String,
    key: String,
    ssh: tokio::sync::Mutex<client::Handle<OrbitSshClientHandler>>,
    net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
    channel_ref_count: AtomicU64,
    keepalive_watch_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

pub(crate) struct OrbitSftpSession {
    pub(crate) base: Arc<OrbitBaseSession>,
    pub(crate) sftp: SftpSession,
}

enum TerminalCommand {
    Write(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
}

struct OrbitTerminalChannel {
    base_id: u64,
    tx: mpsc::UnboundedSender<TerminalCommand>,
}

static ORBIT_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to initialize orbit tokio runtime")
});

type TerminalDataCallback = extern "C" fn(u64, *const u8, usize);
type ConnectionEventCallback = extern "C" fn(u64, *const c_char);

static BASE_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitBaseSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static BASE_SESSION_KEY_INDEX: Lazy<Mutex<HashMap<String, u64>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static SFTP_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitSftpSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static TERMINAL_CHANNELS: Lazy<Mutex<HashMap<u64, OrbitTerminalChannel>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static TERMINAL_DATA_CALLBACK: Lazy<Mutex<Option<TerminalDataCallback>>> =
    Lazy::new(|| Mutex::new(None));
static CONNECTION_EVENT_CALLBACK: Lazy<Mutex<Option<ConnectionEventCallback>>> =
    Lazy::new(|| Mutex::new(None));
static NEXT_BASE_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_SFTP_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_TERMINAL_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);

struct SliceAsyncReader {
    data: Vec<u8>,
    offset: usize,
}

impl SliceAsyncReader {
    fn new(data: Vec<u8>) -> Self {
        Self { data, offset: 0 }
    }
}

impl AsyncRead for SliceAsyncReader {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if self.offset >= self.data.len() {
            return std::task::Poll::Ready(Ok(()));
        }

        let remaining = self.data.len() - self.offset;
        let to_copy = remaining.min(buf.remaining());
        let end = self.offset + to_copy;
        buf.put_slice(&self.data[self.offset..end]);
        self.offset = end;
        std::task::Poll::Ready(Ok(()))
    }
}

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
        "pty" => open_terminal_channel(base, 120, 36).await,
        _ => Err(OrbitCoreError::InvalidInput),
    }
}

async fn open_terminal_channel(
    base: Arc<OrbitBaseSession>,
    cols: u32,
    rows: u32,
) -> Result<u64, OrbitCoreError> {
    let ssh = base.ssh.lock().await;
    let channel = ssh
        .channel_open_session()
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;
    drop(ssh);

    channel
        .request_pty(true, "xterm-256color", cols, rows, 0, 0, &[])
        .await
        .map_err(|e| OrbitCoreError::SshFailed(format!("request pty failed: {e}")))?;
    channel
        .request_shell(true)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(format!("request shell failed: {e}")))?;

    base.channel_ref_count.fetch_add(1, Ordering::SeqCst);
    let (mut read_half, write_half) = channel.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<TerminalCommand>();
    let terminal_id = NEXT_TERMINAL_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
    let base_id = base.id;

    lock_terminal_channels()?.insert(terminal_id, OrbitTerminalChannel { base_id, tx });

    tokio::spawn(async move {
        loop {
            tokio::select! {
                cmd = rx.recv() => {
                    match cmd {
                        Some(TerminalCommand::Write(bytes)) => {
                            if !bytes.is_empty() {
                                let _ = write_half.data(SliceAsyncReader::new(bytes)).await;
                            }
                        }
                        Some(TerminalCommand::Resize { cols, rows }) => {
                            let _ = write_half.window_change(cols, rows, 0, 0).await;
                        }
                        Some(TerminalCommand::Close) | None => {
                            let _ = write_half.eof().await;
                            let _ = write_half.close().await;
                            break;
                        }
                    }
                }
                msg = read_half.wait() => {
                    match msg {
                        Some(ChannelMsg::Data { data }) => emit_terminal_data(terminal_id, &data),
                        Some(ChannelMsg::ExtendedData { data, .. }) => emit_terminal_data(terminal_id, &data),
                        Some(ChannelMsg::ExitStatus { .. }) | Some(ChannelMsg::Eof) | None => {
                            break;
                        }
                        _ => {}
                    }
                }
            }
        }

        if let Ok(mut map) = TERMINAL_CHANNELS.lock() {
            map.remove(&terminal_id);
        }
        let _ = release_base_session(base_id).await;
    });

    Ok(terminal_id)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_write(terminal_channel_id: u64, data: Vec<u8>) -> Result<(), OrbitCoreError> {
    let tx = lock_terminal_channels()?
        .get(&terminal_channel_id)
        .map(|ch| ch.tx.clone())
        .ok_or_else(|| OrbitCoreError::SshFailed("terminal channel not found".to_string()))?;

    tx.send(TerminalCommand::Write(data))
        .map_err(|_| OrbitCoreError::SshFailed("terminal write channel closed".to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_resize(
    terminal_channel_id: u64,
    cols: u32,
    rows: u32,
) -> Result<(), OrbitCoreError> {
    let tx = lock_terminal_channels()?
        .get(&terminal_channel_id)
        .map(|ch| ch.tx.clone())
        .ok_or_else(|| OrbitCoreError::SshFailed("terminal channel not found".to_string()))?;

    tx.send(TerminalCommand::Resize { cols, rows })
        .map_err(|_| OrbitCoreError::SshFailed("terminal resize channel closed".to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn terminal_close(terminal_channel_id: u64) -> Result<(), OrbitCoreError> {
    let channel = lock_terminal_channels()?.remove(&terminal_channel_id);
    if let Some(ch) = channel {
        let _ = ch.tx.send(TerminalCommand::Close);
        return Ok(());
    }
    Err(OrbitCoreError::SshFailed(
        "terminal channel not found".to_string(),
    ))
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

fn lock_terminal_channels(
) -> Result<std::sync::MutexGuard<'static, HashMap<u64, OrbitTerminalChannel>>, OrbitCoreError> {
    TERMINAL_CHANNELS
        .lock()
        .map_err(|_| OrbitCoreError::Internal("terminal channel lock poisoned".to_string()))
}

fn emit_terminal_data(channel_id: u64, bytes: &[u8]) {
    let cb_opt = TERMINAL_DATA_CALLBACK.lock().ok().and_then(|guard| *guard);

    if let Some(cb) = cb_opt {
        cb(channel_id, bytes.as_ptr(), bytes.len());
    }
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

async fn get_or_create_base_session(
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
    if let Some(term) = lock_terminal_channels()?.get(&session_or_channel_id) {
        if let Some(base) = lock_base_sessions()?.get(&term.base_id).cloned() {
            return Ok(base);
        }
    }

    Err(OrbitCoreError::SshFailed(
        "unable to resolve base session".to_string(),
    ))
}

async fn release_base_session(base_id: u64) -> Result<(), OrbitCoreError> {
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

#[cfg(target_os = "android")]
fn jstring_to_rust(env: &mut JNIEnv, value: JString) -> Result<String, OrbitCoreError> {
    env.get_string(&value)
        .map(|s| s.to_string_lossy().into_owned())
        .map_err(|_| OrbitCoreError::InvalidInput)
}

#[cfg(target_os = "android")]
fn java_string(env: &mut JNIEnv, value: String) -> jstring {
    env.new_string(value)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitEncryptConfig(
    mut env: JNIEnv,
    _this: JObject,
    master_password: JString,
    plaintext: JByteArray,
    _plaintext_len: jlong,
) -> jstring {
    let password = match jstring_to_rust(&mut env, master_password) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let bytes = match env.convert_byte_array(plaintext) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:参数不合法".to_string()),
    };
    match encrypt_config(password, bytes) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDecryptConfig(
    mut env: JNIEnv,
    _this: JObject,
    master_password: JString,
    encrypted_base64: JString,
) -> jstring {
    let password = match jstring_to_rust(&mut env, master_password) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let encrypted_b64 = match jstring_to_rust(&mut env, encrypted_base64) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:Base64 解码失败".to_string()),
    };
    match decrypt_config(password, encrypted) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableValidate(
    mut env: JNIEnv,
    _this: JObject,
    portable_json: JString,
) -> jstring {
    let raw = match jstring_to_rust(&mut env, portable_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    match parse_portable_config(&raw).and_then(|portable| {
        serde_json::to_string(&portable)
            .map_err(|e| OrbitCoreError::Internal(format!("PortableServerConfig 编码失败: {e}")))
    }) {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableChangedFields(
    mut env: JNIEnv,
    _this: JObject,
    base_json: JString,
    newer_json: JString,
) -> jstring {
    let base_raw = match jstring_to_rust(&mut env, base_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let newer_raw = match jstring_to_rust(&mut env, newer_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let result = parse_portable_config(&base_raw).and_then(|base| {
        parse_portable_config(&newer_raw).and_then(|newer| {
            serde_json::to_string(&portable_changed_fields(&base, &newer))
                .map_err(|e| OrbitCoreError::Internal(format!("字段差异编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableMerge(
    mut env: JNIEnv,
    _this: JObject,
    remote_json: JString,
    local_json: JString,
    local_changed_fields_json: JString,
) -> jstring {
    let remote_raw = match jstring_to_rust(&mut env, remote_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let local_raw = match jstring_to_rust(&mut env, local_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let fields_raw = match jstring_to_rust(&mut env, local_changed_fields_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let result = parse_portable_config(&remote_raw).and_then(|remote| {
        parse_portable_config(&local_raw).and_then(|local| {
            let fields: Vec<String> =
                serde_json::from_str(&fields_raw).map_err(|_| OrbitCoreError::InvalidInput)?;
            serde_json::to_string(&portable_merge(remote, local, &fields))
                .map_err(|e| OrbitCoreError::Internal(format!("合并结果编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitVectorClockBump(
    mut env: JNIEnv,
    _this: JObject,
    vector_clock_json: JString,
    actor: JString,
) -> jstring {
    let raw = match jstring_to_rust(&mut env, vector_clock_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let actor = match jstring_to_rust(&mut env, actor) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let clean_actor = actor.trim();
    if clean_actor.is_empty() {
        return java_string(&mut env, "ERR:参数不合法".to_string());
    }
    let mut map: HashMap<String, i64> = serde_json::from_str(&raw).unwrap_or_default();
    map.insert(
        clean_actor.to_string(),
        map.get(clean_actor).copied().unwrap_or(0) + 1,
    );
    match serde_json::to_string(&map) {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
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

    let result = ORBIT_RUNTIME.block_on(get_or_create_base_session(
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
    let result = ORBIT_RUNTIME.block_on(release_base_session(base_session_id));
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
