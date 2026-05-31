use std::collections::HashMap;
use std::sync::{atomic::Ordering, Arc, Mutex};

use once_cell::sync::Lazy;
use russh::ChannelMsg;
use tokio::io::{AsyncRead, ReadBuf};
use tokio::sync::mpsc;

use crate::{session_pool, OrbitBaseSession, OrbitCoreError, TERMINAL_DATA_CALLBACK};

enum TerminalCommand {
    Write(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
}

struct OrbitTerminalChannel {
    base_id: u64,
    tx: mpsc::UnboundedSender<TerminalCommand>,
}

static TERMINAL_CHANNELS: Lazy<Mutex<HashMap<u64, OrbitTerminalChannel>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_TERMINAL_CHANNEL_ID: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(1);

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

pub(crate) async fn open_channel(
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
        let _ = session_pool::release_base_session(base_id).await;
    });

    Ok(terminal_id)
}

pub(crate) async fn write(terminal_channel_id: u64, data: Vec<u8>) -> Result<(), OrbitCoreError> {
    let tx = lock_terminal_channels()?
        .get(&terminal_channel_id)
        .map(|ch| ch.tx.clone())
        .ok_or_else(|| OrbitCoreError::SshFailed("terminal channel not found".to_string()))?;

    tx.send(TerminalCommand::Write(data))
        .map_err(|_| OrbitCoreError::SshFailed("terminal write channel closed".to_string()))
}

pub(crate) async fn resize(
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

pub(crate) async fn close(terminal_channel_id: u64) -> Result<(), OrbitCoreError> {
    let channel = lock_terminal_channels()?.remove(&terminal_channel_id);
    if let Some(ch) = channel {
        let _ = ch.tx.send(TerminalCommand::Close);
        return Ok(());
    }
    Err(OrbitCoreError::SshFailed(
        "terminal channel not found".to_string(),
    ))
}

pub(crate) fn base_id_for_channel(terminal_channel_id: u64) -> Result<Option<u64>, OrbitCoreError> {
    Ok(lock_terminal_channels()?
        .get(&terminal_channel_id)
        .map(|ch| ch.base_id))
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
