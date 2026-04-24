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
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use serde::Serialize;
use serde_json::Value;
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::process::Command;

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

struct OrbitSftpSession {
    host: String,
    ssh: tokio::sync::Mutex<client::Handle<OrbitSshClientHandler>>,
    sftp: SftpSession,
    net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
}

static ORBIT_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to initialize orbit tokio runtime")
});

static SFTP_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitSftpSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_SFTP_SESSION_ID: AtomicU64 = AtomicU64::new(1);

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
    username: String,
    password: String,
) -> Result<String, OrbitCoreError> {
    if ip.trim().is_empty() || username.trim().is_empty() || password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let config = Arc::new(client::Config::default());
    let addr = normalize_host_port(&ip);

    let mut ssh_session = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    let auth_result = ssh_session
        .authenticate_password(username, password)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    if auth_result.success() {
        Ok("SSH connection success".to_string())
    } else {
        Err(OrbitCoreError::SshFailed(
            "SSH authentication failed".to_string(),
        ))
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn sftp_connect(
    ip: String,
    username: String,
    password: String,
) -> Result<u64, OrbitCoreError> {
    if ip.trim().is_empty() || username.trim().is_empty() || password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let config = Arc::new(client::Config::default());
    let addr = normalize_host_port(&ip);

    let mut ssh = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    let auth_result = ssh
        .authenticate_password(username, password)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    if !auth_result.success() {
        return Err(OrbitCoreError::SshFailed(
            "SSH authentication failed".to_string(),
        ));
    }

    let channel = ssh
        .channel_open_session()
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("request subsystem failed: {e}")))?;

    let sftp = SftpSession::new(channel.into_stream())
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

    let session_id = NEXT_SFTP_SESSION_ID.fetch_add(1, Ordering::SeqCst);
    let wrapper = Arc::new(OrbitSftpSession {
        host: ip,
        ssh: tokio::sync::Mutex::new(ssh),
        sftp,
        net_snapshot: tokio::sync::Mutex::new(None),
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

    session
        .sftp
        .close()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

    let ssh = session.ssh.lock().await;
    ssh.disconnect(Disconnect::ByApplication, "sftp session closed", "en")
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

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
pub async fn sftp_remove_file(session_id: u64, remote_path: String) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    session
        .sftp
        .remove_file(remote_path)
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
pub async fn fetch_system_stats(session_id: u64) -> Result<String, OrbitCoreError> {
    let session = get_sftp_session(session_id)?;

    let top_output = run_remote_command(&session, "top -bn1 | head -n 5").await?;
    let free_output = run_remote_command(&session, "free -m").await?;
    let disk_output = run_remote_command(&session, "df -h /").await?;
    let net_output = run_remote_command(&session, "cat /proc/net/dev").await?;

    let cpu_usage_percent = parse_cpu_usage(&top_output)?;
    let (mem_available_mb, mem_used_percent) = parse_memory_stats(&free_output)?;
    let disk_used_percent = parse_disk_usage(&disk_output)?;
    let (rx_rate_kbps, tx_rate_kbps) = compute_network_rate_kbps(&session, &net_output).await?;
    let ping_latency_ms = measure_ping_ms(&session.host).await;
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
    let output = run_remote_command(&session, "docker ps -a --format '{{json .}}'").await?;
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
        run_remote_command(&session, "docker stats --no-stream --format '{{json .}}'").await?;
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
        "start" | "stop" | "restart" | "kill"
    ) {
        return Err(OrbitCoreError::InvalidInput);
    }

    let session = get_sftp_session(session_id)?;
    let cmd = format!("docker {} {}", normalized_action, container_id.trim());
    let result = run_remote_command(&session, &cmd).await?;
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
    run_remote_command(&session, &cmd).await
}

async fn run_remote_command(
    session: &Arc<OrbitSftpSession>,
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
    let cpu_line = Regex::new(r"(?mi)^%?Cpu\(s\):.*?([0-9]+(?:\.[0-9]+)?)\s*id")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = cpu_line.captures(top_output) {
        let idle = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok((100.0 - idle).clamp(0.0, 100.0));
    }

    Err(OrbitCoreError::Internal("无法解析 CPU 使用率".to_string()))
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

async fn compute_network_rate_kbps(
    session: &Arc<OrbitSftpSession>,
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
    host.split(':').next().unwrap_or(host)
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

fn normalize_host_port(ip: &str) -> String {
    if ip.contains(':') {
        ip.to_string()
    } else {
        format!("{}:22", ip)
    }
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

fn c_ptr_to_string(ptr: *const c_char) -> Result<String, OrbitCoreError> {
    if ptr.is_null() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let raw = unsafe { CStr::from_ptr(ptr) };
    raw.to_str()
        .map(|s| s.to_string())
        .map_err(|_| OrbitCoreError::InvalidInput)
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
    username: *const c_char,
    password: *const c_char,
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

    let result = ORBIT_RUNTIME.block_on(test_ssh_connection(ip, username, password));
    match result {
        Ok(msg) => to_c_string_ptr(format!("OK:{}", msg)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_connect(
    ip: *const c_char,
    username: *const c_char,
    password: *const c_char,
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

    let result = ORBIT_RUNTIME.block_on(sftp_connect(ip, username, password));
    match result {
        Ok(session_id) => to_c_string_ptr(format!("OK:{}", session_id)),
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
