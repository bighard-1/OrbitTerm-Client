use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine;
use once_cell::sync::Lazy;
use rand::{rngs::OsRng, RngCore};
use regex::Regex;
use russh::client;
use russh::ChannelMsg;
use russh::Disconnect;
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use serde::Serialize;
use serde_json::Value;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWriteExt, ReadBuf};
use tokio::process::Command;
use tokio::sync::mpsc;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const HEADER_MAGIC: &[u8; 4] = b"OTC1";
const SFTP_IO_BUF_SIZE: usize = 64 * 1024;

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
struct OrbitSshClientHandler;

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

struct OrbitBaseSession {
    id: u64,
    host: String,
    username: String,
    key: String,
    ssh: tokio::sync::Mutex<client::Handle<OrbitSshClientHandler>>,
    net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
    channel_ref_count: AtomicU64,
}

struct OrbitSftpSession {
    base: Arc<OrbitBaseSession>,
    sftp: SftpSession,
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

#[derive(Debug, Serialize)]
struct SftpListItem {
    name: String,
    size: u64,
    permissions: String,
    permissions_octal: u32,
    modified_at_unix: u64,
}

#[derive(Debug, Serialize)]
struct SftpTransferResult {
    bytes: u64,
}

#[derive(Debug)]
struct NetSnapshot {
    rx_bytes: u64,
    tx_bytes: u64,
    at_unix_secs: u64,
}

#[derive(Debug, Serialize)]
struct SystemStatsResponse {
    sampled_at_unix: u64,
    cpu_usage_percent: f64,
    mem_available_mb: u64,
    mem_used_percent: f64,
    disk_used_percent: f64,
    ping_latency_ms: Option<f64>,
    rx_rate_kbps: f64,
    tx_rate_kbps: f64,
}

#[derive(Debug, Serialize)]
struct DockerContainerItem {
    id: String,
    name: String,
    image: String,
    state: String,
    status: String,
    running_for: String,
}

#[derive(Debug, Serialize)]
struct DockerStatsItem {
    id: String,
    name: String,
    cpu_percent: f64,
    mem_percent: f64,
    mem_usage: String,
    net_io: String,
    block_io: String,
    pids: u32,
}

#[uniffi::export]
pub fn encrypt_config(
    master_password: String,
    plaintext: Vec<u8>,
) -> Result<Vec<u8>, OrbitCoreError> {
    if master_password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);

    let key = derive_key(master_password.as_bytes(), &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| OrbitCoreError::EncryptFailed)?;

    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext.as_slice())
        .map_err(|_| OrbitCoreError::EncryptFailed)?;

    let mut out = Vec::with_capacity(4 + 1 + 1 + SALT_LEN + NONCE_LEN + encrypted.len());
    out.extend_from_slice(HEADER_MAGIC);
    out.push(SALT_LEN as u8);
    out.push(NONCE_LEN as u8);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&encrypted);

    Ok(out)
}

#[uniffi::export]
pub fn decrypt_config(
    master_password: String,
    encrypted_blob: Vec<u8>,
) -> Result<Vec<u8>, OrbitCoreError> {
    if master_password.is_empty() || encrypted_blob.len() < 4 + 1 + 1 + SALT_LEN + NONCE_LEN {
        return Err(OrbitCoreError::InvalidInput);
    }

    if &encrypted_blob[0..4] != HEADER_MAGIC {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt_len = encrypted_blob[4] as usize;
    let nonce_len = encrypted_blob[5] as usize;

    if salt_len == 0 || nonce_len != NONCE_LEN {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt_start = 6;
    let nonce_start = salt_start + salt_len;
    let cipher_start = nonce_start + nonce_len;

    if encrypted_blob.len() <= cipher_start {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt = &encrypted_blob[salt_start..nonce_start];
    let nonce = &encrypted_blob[nonce_start..cipher_start];
    let ciphertext = &encrypted_blob[cipher_start..];

    let key = derive_key(master_password.as_bytes(), salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| OrbitCoreError::DecryptFailed)?;

    let plaintext = cipher
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .map_err(|_| OrbitCoreError::DecryptFailed)?;

    Ok(plaintext)
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

    let config = Arc::new(client::Config::default());
    let addr = normalize_host_port(&ip, port);

    let mut ssh_session = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    authenticate_ssh(
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
    let wrapper = Arc::new(OrbitSftpSession {
        base,
        sftp,
    });

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
    if path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let path_for_log = path.clone();
    let entries = session
        .sftp
        .read_dir(path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

    let items: Vec<SftpListItem> = entries
        .map(|entry| {
            let metadata = entry.metadata();
            SftpListItem {
                name: entry.file_name(),
                size: metadata.size.unwrap_or(0),
                permissions: metadata.permissions().to_string(),
                permissions_octal: metadata.permissions.unwrap_or(0),
                modified_at_unix: metadata.mtime.unwrap_or(0) as u64,
            }
        })
        .collect();

    eprintln!(
        "[orbit-core][sftp_list_dir] session={} path={} items={}",
        session_id,
        path_for_log,
        items.len()
    );

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_upload_file(
    session_id: u64,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;

    let mut local = tokio::fs::File::open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open local file failed: {e}")))?;

    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let mut buf = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut total: u64 = 0;

    loop {
        let n = local
            .read(&mut buf)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read local file failed: {e}")))?;
        if n == 0 {
            break;
        }

        eprintln!(
            "[orbit-core][sftp_upload_file] session={} chunk_bytes={} remote={}",
            session_id, n, remote_for_log
        );

        remote
            .write_all(&buf[..n])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write remote file failed: {e}")))?;
        total += n as u64;
    }

    remote
        .shutdown()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("shutdown remote file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult { bytes: total })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_download_file(
    session_id: u64,
    remote_path: String,
    local_path: String,
    resume_offset: u64,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;

    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    if resume_offset > 0 {
        remote
            .seek(std::io::SeekFrom::Start(resume_offset))
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("seek remote failed: {e}")))?;
    }

    let mut local = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .read(true)
        .open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open local file failed: {e}")))?;

    if resume_offset == 0 {
        local
            .set_len(0)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("truncate local file failed: {e}")))?;
    }

    local
        .seek(std::io::SeekFrom::Start(resume_offset))
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("seek local failed: {e}")))?;

    let mut buf = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut downloaded: u64 = 0;

    loop {
        let n = remote
            .read(&mut buf)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read remote file failed: {e}")))?;
        if n == 0 {
            break;
        }

        eprintln!(
            "[orbit-core][sftp_download_file] session={} chunk_bytes={} remote={}",
            session_id, n, remote_for_log
        );

        local
            .write_all(&buf[..n])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write local file failed: {e}")))?;
        downloaded += n as u64;
    }

    local
        .flush()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("flush local file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult { bytes: downloaded })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_read_text_file(session_id: u64, remote_path: String) -> Result<String, OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let mut remote = session
        .sftp
        .open(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let mut data = Vec::new();
    remote
        .read_to_end(&mut data)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("read remote file failed: {e}")))?;

    if data.len() > 2 * 1024 * 1024 {
        return Err(OrbitCoreError::SftpFailed("文件超过 2MB，暂不支持在线编辑".to_string()));
    }

    String::from_utf8(data)
        .map_err(|_| OrbitCoreError::SftpFailed("文件不是 UTF-8 文本，暂不支持在线编辑".to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_write_text_file(
    session_id: u64,
    remote_path: String,
    content: String,
) -> Result<String, OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let bytes = content.into_bytes();
    remote
        .write_all(&bytes)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("write remote file failed: {e}")))?;
    remote
        .shutdown()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("shutdown remote file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult {
        bytes: bytes.len() as u64,
    })
    .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_remove_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    if session
        .sftp
        .remove_file(remote_path.clone())
        .await
        .is_ok()
    {
        return Ok(());
    }

    // 兼容目录删除：先尝试删文件，失败后再尝试删空目录。
    session
        .sftp
        .remove_dir(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_rename(
    session_id: u64,
    old_remote_path: String,
    new_remote_path: String,
) -> Result<(), OrbitCoreError> {
    if old_remote_path.trim().is_empty() || new_remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    session
        .sftp
        .rename(old_remote_path, new_remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_mkdir(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let session = get_sftp_session(session_id)?;
    let cmd = format!("mkdir -p -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command(&session.base, &cmd).await?;
    Ok(())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_create_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let session = get_sftp_session(session_id)?;
    let cmd = format!("touch -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command(&session.base, &cmd).await?;
    Ok(())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_chmod(
    session_id: u64,
    remote_path: String,
    mode_octal: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let mode = mode_octal.trim();
    let mode_re = Regex::new(r"^[0-7]{3,4}$")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    if !mode_re.is_match(mode) {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let cmd = format!(
        "chmod {} -- {}",
        mode,
        shell_single_quote(remote_path.trim())
    );
    let _ = run_remote_command(&session.base, &cmd).await?;
    Ok(())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_system_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;

    // 采集策略：优先 Linux 常见命令，失败时回退到 /proc，避免因单命令缺失导致整体失败。
    let top_output = run_remote_command(&session.base, "top -bn1 | head -n 8")
        .await
        .unwrap_or_default();
    let cpu_proc = run_remote_command(
        &session.base,
        "cat /proc/stat 2>/dev/null | awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}'",
    )
    .await
    .unwrap_or_default();
    let free_output = run_remote_command(&session.base, "free -m 2>/dev/null")
        .await
        .unwrap_or_default();
    let meminfo_output = run_remote_command(&session.base, "cat /proc/meminfo 2>/dev/null")
        .await
        .unwrap_or_default();
    let disk_output = run_remote_command(&session.base, "df -P / 2>/dev/null")
        .await
        .unwrap_or_default();
    let net_output = run_remote_command(&session.base, "cat /proc/net/dev 2>/dev/null")
        .await
        .unwrap_or_default();

    let cpu_usage_percent = parse_cpu_usage(&top_output)
        .or_else(|_| parse_cpu_from_proc_stat(&cpu_proc))
        .unwrap_or(0.0);
    let (mem_available_mb, mem_used_percent) = parse_memory_stats(&free_output)
        .or_else(|_| parse_memory_from_meminfo(&meminfo_output))
        .unwrap_or((0, 0.0));
    let disk_used_percent = parse_disk_usage(&disk_output).unwrap_or(0.0);
    let (rx_rate_kbps, tx_rate_kbps) = compute_network_rate_kbps(&session.base, &net_output)
        .await
        .unwrap_or((0.0, 0.0));
    let ping_latency_ms = measure_ping_ms(&session.base.host).await;
    let sampled_at_unix = current_unix_secs();

    let payload = SystemStatsResponse {
        sampled_at_unix,
        cpu_usage_percent,
        mem_available_mb,
        mem_used_percent,
        disk_used_percent,
        ping_latency_ms,
        rx_rate_kbps,
        tx_rate_kbps,
    };

    serde_json::to_string(&payload).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_containers(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    let output = run_remote_command(&session.base, "docker ps -a --format '{{json .}}'").await?;
    let mut items: Vec<DockerContainerItem> = Vec::new();

    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = serde_json::from_str(line)
            .map_err(|e| OrbitCoreError::Internal(format!("docker ps json parse failed: {e}")))?;

        items.push(DockerContainerItem {
            id: value
                .get("ID")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            name: value
                .get("Names")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            image: value
                .get("Image")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            state: value
                .get("State")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            status: value
                .get("Status")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            running_for: value
                .get("RunningFor")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
        });
    }

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;
    let output =
        run_remote_command(&session.base, "docker stats --no-stream --format '{{json .}}'").await?;
    let mut items: Vec<DockerStatsItem> = Vec::new();

    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = serde_json::from_str(line).map_err(|e| {
            OrbitCoreError::Internal(format!("docker stats json parse failed: {e}"))
        })?;

        let cpu_percent = parse_percent(value.get("CPUPerc").and_then(|v| v.as_str()).unwrap_or(""));
        let mem_percent = parse_percent(value.get("MemPerc").and_then(|v| v.as_str()).unwrap_or(""));
        let pids = value
            .get("PIDs")
            .and_then(|v| v.as_str())
            .and_then(|s| s.trim().parse::<u32>().ok())
            .unwrap_or(0);

        items.push(DockerStatsItem {
            id: value
                .get("ID")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            name: value
                .get("Name")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            cpu_percent,
            mem_percent,
            mem_usage: value
                .get("MemUsage")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            net_io: value
                .get("NetIO")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            block_io: value
                .get("BlockIO")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            pids,
        });
    }

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn docker_action(
    session_id: u64,
    container_id: String,
    action: String,
) -> Result<String, OrbitCoreError> {
    if container_id.trim().is_empty() || action.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let normalized_action = action.trim().to_lowercase();
    if !matches!(
        normalized_action.as_str(),
        "start" | "stop" | "restart" | "kill" | "remove"
    ) {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let cmd = if normalized_action == "remove" {
        format!("docker rm -f {}", container_id.trim())
    } else {
        format!("docker {} {}", normalized_action, container_id.trim())
    };
    let result = run_remote_command(&session.base, &cmd).await?;
    Ok(result)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_docker_logs(
    session_id: u64,
    container_id: String,
    tail_lines: u32,
) -> Result<String, OrbitCoreError> {
    if container_id.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let safe_tail = if tail_lines == 0 { 200 } else { tail_lines.min(2000) };
    let cmd = format!(
        "docker logs --tail {} {} 2>&1",
        safe_tail,
        container_id.trim()
    );
    run_remote_command(&session.base, &cmd).await
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

            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|e| OrbitCoreError::SftpFailed(format!("request subsystem failed: {e}")))?;

            let sftp = SftpSession::new(channel.into_stream())
                .await
                .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

            base.channel_ref_count.fetch_add(1, Ordering::SeqCst);
            let channel_id = NEXT_SFTP_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
            let wrapper = Arc::new(OrbitSftpSession {
                base,
                sftp,
            });
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

    lock_terminal_channels()?.insert(
        terminal_id,
        OrbitTerminalChannel { base_id, tx },
    );

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

async fn run_remote_command(
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

fn parse_cpu_usage(top_output: &str) -> Result<f64, OrbitCoreError> {
    let cpu_line = Regex::new(r"(?mi)(?:^%?Cpu\(s\):|^Cpu\(s\):).*?([0-9]+(?:\.[0-9]+)?)\s*id")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = cpu_line.captures(top_output) {
        let idle = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok((100.0 - idle).clamp(0.0, 100.0));
    }

    // macOS/BSD top 格式: "CPU usage: 12.34% user, 5.00% sys, 82.66% idle"
    let bsd = Regex::new(
        r"(?mi)cpu usage:\s*([0-9]+(?:\.[0-9]+)?)%\s*user,\s*([0-9]+(?:\.[0-9]+)?)%\s*sys",
    )
    .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    if let Some(caps) = bsd.captures(top_output) {
        let user = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        let sys = caps
            .get(2)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok((user + sys).clamp(0.0, 100.0));
    }

    Err(OrbitCoreError::Internal("无法解析 CPU 使用率".to_string()))
}

fn parse_cpu_from_proc_stat(raw: &str) -> Result<f64, OrbitCoreError> {
    let nums: Vec<u64> = raw
        .split_whitespace()
        .filter_map(|v| v.parse::<u64>().ok())
        .collect();
    if nums.len() < 4 {
        return Err(OrbitCoreError::Internal("proc stat 字段不足".to_string()));
    }

    let idle = nums[3] as f64;
    let total: f64 = nums.iter().map(|v| *v as f64).sum();
    if total <= 0.0 {
        return Ok(0.0);
    }
    Ok(((total - idle) / total * 100.0).clamp(0.0, 100.0))
}

fn parse_memory_stats(free_output: &str) -> Result<(u64, f64), OrbitCoreError> {
    let mem_line = free_output
        .lines()
        .find(|line| line.trim_start().starts_with("Mem:"))
        .ok_or_else(|| OrbitCoreError::Internal("无法解析内存信息".to_string()))?;

    let nums: Vec<u64> = mem_line
        .split_whitespace()
        .skip(1)
        .filter_map(|v| v.parse::<u64>().ok())
        .collect();

    if nums.len() < 3 {
        return Err(OrbitCoreError::Internal("内存数据字段不足".to_string()));
    }

    let total = nums[0];
    let used = nums[1];
    let available = if nums.len() >= 6 { nums[5] } else { nums[2] };
    let used_percent = if total == 0 {
        0.0
    } else {
        (used as f64 / total as f64) * 100.0
    };

    Ok((available, used_percent.clamp(0.0, 100.0)))
}

fn parse_memory_from_meminfo(meminfo_output: &str) -> Result<(u64, f64), OrbitCoreError> {
    let mut total_kb = 0u64;
    let mut available_kb = 0u64;
    for line in meminfo_output.lines() {
        if line.starts_with("MemTotal:") {
            total_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        } else if line.starts_with("MemAvailable:") {
            available_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        }
    }

    if total_kb == 0 {
        return Err(OrbitCoreError::Internal("meminfo 缺少总内存".to_string()));
    }

    let used_kb = total_kb.saturating_sub(available_kb);
    let used_percent = (used_kb as f64 / total_kb as f64 * 100.0).clamp(0.0, 100.0);
    Ok((available_kb / 1024, used_percent))
}

fn parse_disk_usage(df_output: &str) -> Result<f64, OrbitCoreError> {
    let re = Regex::new(r"(?m)^\S+\s+\S+\s+\S+\s+\S+\s+(\d+)%\s+/\s*$")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = re.captures(df_output) {
        let used = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok(used.clamp(0.0, 100.0));
    }

    Err(OrbitCoreError::Internal("无法解析磁盘使用率".to_string()))
}

fn parse_percent(raw: &str) -> f64 {
    raw.trim()
        .trim_end_matches('%')
        .parse::<f64>()
        .unwrap_or(0.0)
}

fn shell_single_quote(input: &str) -> String {
    format!("'{}'", input.replace('\'', "'\"'\"'"))
}

async fn compute_network_rate_kbps(
    session: &Arc<OrbitBaseSession>,
    net_dev_output: &str,
) -> Result<(f64, f64), OrbitCoreError> {
    let re = Regex::new(
        r"(?m)^\s*([^:]+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s*(\d+)",
    )
    .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    let mut rx_total = 0u64;
    let mut tx_total = 0u64;

    for caps in re.captures_iter(net_dev_output) {
        let iface = caps.get(1).map(|m| m.as_str().trim()).unwrap_or_default();
        if iface == "lo" {
            continue;
        }

        let rx = caps
            .get(2)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        let tx = caps
            .get(3)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        rx_total = rx_total.saturating_add(rx);
        tx_total = tx_total.saturating_add(tx);
    }

    let now = current_unix_secs();
    let mut snapshot = session.net_snapshot.lock().await;
    let (rx_rate_kbps, tx_rate_kbps) = if let Some(last) = snapshot.as_ref() {
        let elapsed = now.saturating_sub(last.at_unix_secs).max(1);
        let rx_rate = rx_total.saturating_sub(last.rx_bytes) as f64 / elapsed as f64 / 1024.0;
        let tx_rate = tx_total.saturating_sub(last.tx_bytes) as f64 / elapsed as f64 / 1024.0;
        (rx_rate, tx_rate)
    } else {
        (0.0, 0.0)
    };

    *snapshot = Some(NetSnapshot {
        rx_bytes: rx_total,
        tx_bytes: tx_total,
        at_unix_secs: now,
    });

    Ok((rx_rate_kbps.max(0.0), tx_rate_kbps.max(0.0)))
}

async fn measure_ping_ms(host: &str) -> Option<f64> {
    let target = host_without_port(host).to_string();
    if target.is_empty() {
        return None;
    }

    let mut cmd = Command::new("ping");
    cmd.arg("-c").arg("1");
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        cmd.arg("-W").arg("1000");
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        cmd.arg("-W").arg("1");
    }
    cmd.arg(&target);

    let output = tokio::time::timeout(Duration::from_secs(3), cmd.output())
        .await
        .ok()?
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let re = Regex::new(r"time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms").ok()?;
    re.captures(&text)
        .and_then(|caps| caps.get(1))
        .and_then(|m| m.as_str().parse::<f64>().ok())
}

fn host_without_port(host: &str) -> &str {
    let trimmed = host.trim();
    if trimmed.starts_with('[') {
        if let Some(end) = trimmed.find(']') {
            return &trimmed[1..end];
        }
    }
    // 仅一个冒号时，按 host:port 处理；多个冒号视为 IPv6 地址本体。
    if trimmed.matches(':').count() == 1 {
        return trimmed.split(':').next().unwrap_or(trimmed);
    }
    trimmed
}

fn current_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn derive_key(master_password: &[u8], salt: &[u8]) -> Result<[u8; 32], OrbitCoreError> {
    let params = Params::new(64 * 1024, 3, 2, Some(32))
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(master_password, salt, &mut key)
        .map_err(|_| OrbitCoreError::Internal("Argon2 key derivation failed".to_string()))?;
    Ok(key)
}

fn normalize_host_port(ip: &str, port: u16) -> String {
    let host = ip.trim();
    if host.is_empty() {
        return format!("127.0.0.1:{port}");
    }

    if host.starts_with('[') && host.contains("]:") {
        return host.to_string();
    }
    if host.matches(':').count() == 1 && !host.starts_with('[') {
        return host.to_string();
    }
    if host.matches(':').count() > 1 {
        if host.starts_with('[') {
            return format!("{host}:{port}");
        }
        return format!("[{host}]:{port}");
    }

    format!("{host}:{port}")
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
    let cb_opt = TERMINAL_DATA_CALLBACK
        .lock()
        .ok()
        .and_then(|guard| *guard);

    if let Some(cb) = cb_opt {
        cb(channel_id, bytes.as_ptr(), bytes.len());
    }
}

fn base_session_key(ip: &str, port: u16, username: &str) -> String {
    format!("{}|{}", normalize_host_port(ip, port), username.trim())
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

    let config = Arc::new(client::Config::default());
    let addr = normalize_host_port(ip, port);

    let mut ssh = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    authenticate_ssh(
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
    });

    lock_base_sessions()?.insert(base_id, base.clone());
    lock_base_key_index()?.insert(key, base_id);
    Ok(base)
}

fn resolve_base_session(session_or_channel_id: u64) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
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

    let ssh = base.ssh.lock().await;
    let _ = ssh
        .disconnect(Disconnect::ByApplication, "session released", "en")
        .await;
    Ok(())
}

fn c_ptr_to_string(ptr: *const c_char) -> Result<String, OrbitCoreError> {
    if ptr.is_null() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let raw = unsafe { CStr::from_ptr(ptr) };
    raw.to_str()
        .map(|s| s.to_string())
        .map_err(|_| OrbitCoreError::InvalidInput)
}

async fn authenticate_ssh(
    ssh_session: &mut client::Handle<OrbitSshClientHandler>,
    username: &str,
    password: &str,
    private_key_content: &str,
    private_key_passphrase: &str,
    allow_password_fallback: bool,
) -> Result<(), OrbitCoreError> {
    let trimmed_key = private_key_content.trim();
    let mut key_auth_failed = false;
    if !trimmed_key.is_empty() {
        let passphrase = if private_key_passphrase.is_empty() {
            None
        } else {
            Some(private_key_passphrase)
        };

        let private_key = decode_secret_key(trimmed_key, passphrase)
            .map_err(|e| OrbitCoreError::SshFailed(format!("私钥解析失败: {e}")))?;
        let hash_alg = ssh_session
            .best_supported_rsa_hash()
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?
            .flatten();

        let auth_result = ssh_session
            .authenticate_publickey(
                username.to_string(),
                PrivateKeyWithHashAlg::new(Arc::new(private_key), hash_alg),
            )
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

        if auth_result.success() {
            return Ok(());
        }

        key_auth_failed = true;
        if !allow_password_fallback {
            return Err(OrbitCoreError::SshFailed(
                "SSH 密钥认证失败（已禁用密码回退）".to_string(),
            ));
        }
    }

    if !password.is_empty() {
        let auth_result = ssh_session
            .authenticate_password(username.to_string(), password.to_string())
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

        if auth_result.success() {
            return Ok(());
        }

        if key_auth_failed {
            return Err(OrbitCoreError::SshFailed(
                "SSH 认证失败：密钥与密码均失败".to_string(),
            ));
        }
        return Err(OrbitCoreError::SshFailed(
            "SSH 密码认证失败".to_string(),
        ));
    }

    if key_auth_failed {
        Err(OrbitCoreError::SshFailed(
            "SSH 认证失败：密钥失败且未提供可用密码".to_string(),
        ))
    } else {
        Err(OrbitCoreError::InvalidInput)
    }
}

fn to_c_string_ptr(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("internal string error").expect("fallback CString must be valid")
        })
        .into_raw()
}

#[no_mangle]
pub extern "C" fn orbit_encrypt_config(
    master_password: *const c_char,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
) -> *mut c_char {
    let password = match c_ptr_to_string(master_password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    if plaintext_ptr.is_null() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }

    let plaintext = unsafe { std::slice::from_raw_parts(plaintext_ptr, plaintext_len) };
    match encrypt_config(password, plaintext.to_vec()) {
        Ok(bytes) => {
            let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
            to_c_string_ptr(format!("OK:{}", b64))
        }
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_decrypt_config(
    master_password: *const c_char,
    encrypted_base64: *const c_char,
) -> *mut c_char {
    let password = match c_ptr_to_string(master_password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let encrypted_b64 = match c_ptr_to_string(encrypted_base64) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return to_c_string_ptr("ERR:Base64 解码失败".to_string()),
    };

    match decrypt_config(password, encrypted) {
        Ok(bytes) => {
            let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
            to_c_string_ptr(format!("OK:{}", b64))
        }
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
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

fn normalize_port(port: i32) -> Result<u16, OrbitCoreError> {
    if (1..=65535).contains(&port) {
        Ok(port as u16)
    } else {
        Err(OrbitCoreError::InvalidInput)
    }
}

pub type OrbitTerminalDataCallback = extern "C" fn(u64, *const u8, usize);

#[no_mangle]
pub extern "C" fn orbit_terminal_set_callback(callback: Option<OrbitTerminalDataCallback>) {
    if let Ok(mut holder) = TERMINAL_DATA_CALLBACK.lock() {
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
pub extern "C" fn orbit_sftp_remove_file(session_id: u64, remote_path: *const c_char) -> *mut c_char {
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
pub extern "C" fn orbit_sftp_create_file(session_id: u64, remote_path: *const c_char) -> *mut c_char {
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
pub extern "C" fn orbit_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}
