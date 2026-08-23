use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use once_cell::sync::Lazy;
use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use crate::security::CheckedChannelAccessError;
use crate::session_pool::require_active_verified_base_session;

const MAX_ACTIVE_LOCAL_TUNNELS: usize = 64;
const TUNNEL_ID_NAMESPACE: u64 = 0x05_u64 << 48;
const TUNNEL_ID_COUNTER_MASK: u64 = (1_u64 << 48) - 1;

static NEXT_TUNNEL_ID: AtomicU64 = AtomicU64::new(1);
static ACTIVE_LOCAL_TUNNELS: Lazy<Mutex<HashMap<u64, LocalTunnelRuntime>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

struct LocalTunnelRuntime {
    cancel: watch::Sender<bool>,
    task: tokio::task::JoinHandle<()>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StartedLocalTunnel {
    pub(crate) tunnel_id: u64,
    pub(crate) bind_host: String,
    pub(crate) bind_port: u16,
}

pub(crate) async fn start_local_tunnel(
    base_session_id: u64,
    bind_host: String,
    bind_port: u16,
    destination_host: String,
    destination_port: u16,
) -> Result<StartedLocalTunnel, CheckedChannelAccessError> {
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    if !matches!(bind_host.as_str(), "127.0.0.1" | "::1" | "localhost") {
        return Err(CheckedChannelAccessError::InvalidChannelRequest);
    }
    let listener = TcpListener::bind((bind_host.as_str(), bind_port))
        .await
        .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
    let local_address = listener
        .local_addr()
        .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
    let tunnel_id = next_tunnel_id()?;
    let (cancel, cancel_rx) = watch::channel(false);
    let task = tokio::spawn(run_local_tunnel(
        tunnel_id,
        listener,
        cancel_rx,
        base_session_id,
        destination_host,
        destination_port,
    ));
    let mut active = ACTIVE_LOCAL_TUNNELS
        .lock()
        .map_err(|_| CheckedChannelAccessError::InternalInvariantViolation)?;
    if active.len() >= MAX_ACTIVE_LOCAL_TUNNELS {
        let _ = cancel.send(true);
        task.abort();
        return Err(CheckedChannelAccessError::InternalInvariantViolation);
    }
    active.insert(tunnel_id, LocalTunnelRuntime { cancel, task });
    Ok(StartedLocalTunnel {
        tunnel_id,
        bind_host,
        bind_port: local_address.port(),
    })
}

pub(crate) async fn stop_local_tunnel(tunnel_id: u64) -> Result<(), CheckedChannelAccessError> {
    let runtime = ACTIVE_LOCAL_TUNNELS
        .lock()
        .map_err(|_| CheckedChannelAccessError::InternalInvariantViolation)?
        .remove(&tunnel_id)
        .ok_or(CheckedChannelAccessError::SessionNotFound)?;
    let _ = runtime.cancel.send(true);
    let _ = tokio::time::timeout(Duration::from_secs(2), runtime.task).await;
    Ok(())
}

async fn run_local_tunnel(
    tunnel_id: u64,
    listener: TcpListener,
    mut cancel: watch::Receiver<bool>,
    base_session_id: u64,
    destination_host: String,
    destination_port: u16,
) {
    let mut lifecycle_check = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            changed = cancel.changed() => {
                if changed.is_err() || *cancel.borrow() { break; }
            }
            _ = lifecycle_check.tick() => {
                if require_active_verified_base_session(base_session_id).is_err() { break; }
            }
            accepted = listener.accept() => {
                let Ok((stream, peer)) = accepted else { break; };
                let destination_host = destination_host.clone();
                tokio::spawn(async move {
                    let _ = forward_connection(
                        base_session_id, stream, peer.ip().to_string(), peer.port(),
                        destination_host, destination_port,
                    ).await;
                });
            }
        }
    }
    if let Ok(mut active) = ACTIVE_LOCAL_TUNNELS.lock() {
        active.remove(&tunnel_id);
    }
}

async fn forward_connection(
    base_session_id: u64,
    mut local_stream: TcpStream,
    originator_host: String,
    originator_port: u16,
    destination_host: String,
    destination_port: u16,
) -> Result<(), CheckedChannelAccessError> {
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    let ssh = guard.base().ssh.lock().await;
    let channel = ssh
        .channel_open_direct_tcpip(
            destination_host,
            u32::from(destination_port),
            originator_host,
            u32::from(originator_port),
        )
        .await
        .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
    drop(ssh);
    let mut remote_stream = channel.into_stream();
    copy_bidirectional(&mut local_stream, &mut remote_stream)
        .await
        .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
    Ok(())
}

fn next_tunnel_id() -> Result<u64, CheckedChannelAccessError> {
    let counter = NEXT_TUNNEL_ID.fetch_add(1, Ordering::SeqCst);
    if counter == 0 || counter > TUNNEL_ID_COUNTER_MASK {
        return Err(CheckedChannelAccessError::InternalInvariantViolation);
    }
    Ok(TUNNEL_ID_NAMESPACE | counter)
}
