use std::collections::HashMap;
use std::ffi::CString;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

use once_cell::sync::Lazy;
use russh::client;
use russh::Disconnect;
use russh_sftp::client::SftpSession;

use crate::monitor::NetSnapshot;
use crate::{
    ssh_session, terminal, OrbitCoreError, OrbitSshClientHandler, CONNECTION_EVENT_CALLBACK,
};

pub(crate) struct OrbitBaseSession {
    pub(crate) id: u64,
    pub(crate) host: String,
    #[allow(dead_code)]
    pub(crate) username: String,
    pub(crate) key: String,
    pub(crate) ssh: tokio::sync::Mutex<client::Handle<OrbitSshClientHandler>>,
    pub(crate) net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
    pub(crate) channel_ref_count: AtomicU64,
    pub(crate) keepalive_watch_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

pub(crate) struct OrbitSftpSession {
    pub(crate) base: Arc<OrbitBaseSession>,
    pub(crate) sftp: SftpSession,
}

static BASE_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitBaseSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static BASE_SESSION_KEY_INDEX: Lazy<Mutex<HashMap<String, u64>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static SFTP_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitSftpSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_BASE_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_SFTP_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) fn get_sftp_session(session_id: u64) -> Result<Arc<OrbitSftpSession>, OrbitCoreError> {
    let sessions = lock_sftp_sessions()?;
    sessions
        .get(&session_id)
        .cloned()
        .ok_or_else(|| OrbitCoreError::SftpFailed("session not found".to_string()))
}

pub(crate) fn insert_sftp_session(
    base: Arc<OrbitBaseSession>,
    sftp: SftpSession,
    increment_base_ref: bool,
) -> Result<u64, OrbitCoreError> {
    if increment_base_ref {
        base.channel_ref_count.fetch_add(1, Ordering::SeqCst);
    }

    let channel_id = NEXT_SFTP_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
    let wrapper = Arc::new(OrbitSftpSession { base, sftp });
    lock_sftp_sessions()?.insert(channel_id, wrapper);
    Ok(channel_id)
}

pub(crate) fn remove_sftp_session(
    session_id: u64,
) -> Result<Arc<OrbitSftpSession>, OrbitCoreError> {
    let session = {
        let mut sessions = lock_sftp_sessions()?;
        sessions.remove(&session_id)
    }
    .ok_or_else(|| OrbitCoreError::SftpFailed("session not found".to_string()))?;
    Ok(session)
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

pub(crate) fn resolve_base_session(
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

fn lock_sftp_sessions(
) -> Result<std::sync::MutexGuard<'static, HashMap<u64, Arc<OrbitSftpSession>>>, OrbitCoreError> {
    SFTP_SESSIONS
        .lock()
        .map_err(|_| OrbitCoreError::Internal("sftp session lock poisoned".to_string()))
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
