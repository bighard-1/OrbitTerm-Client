use std::future::Future;
use std::pin::Pin;

use thiserror::Error;

use crate::security::CheckedChannelAccessError;
use crate::session_pool::{require_active_verified_base_session, VerifiedBaseSessionGuard};
use crate::terminal::{self, TerminalChannelMetadata};

pub(crate) const MIN_PTY_DIMENSION: u32 = 1;
pub(crate) const MAX_PTY_DIMENSION: u32 = 1_000;
const PREFERRED_TERMINAL_TYPE: &str = "xterm-256color";
const WINDOWS_COMPATIBLE_TERMINAL_TYPE: &str = "xterm";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct TerminalChannelId(u64);

impl TerminalChannelId {
    pub(crate) const fn new(value: u64) -> Self {
        Self(value)
    }

    pub(crate) const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CheckedPtySize {
    cols: u32,
    rows: u32,
}

impl CheckedPtySize {
    pub(crate) fn new(cols: u32, rows: u32) -> Result<Self, CheckedTerminalError> {
        if !(MIN_PTY_DIMENSION..=MAX_PTY_DIMENSION).contains(&cols)
            || !(MIN_PTY_DIMENSION..=MAX_PTY_DIMENSION).contains(&rows)
        {
            return Err(CheckedTerminalError::InvalidPtySize);
        }
        Ok(Self { cols, rows })
    }

    pub(crate) const fn cols(self) -> u32 {
        self.cols
    }

    pub(crate) const fn rows(self) -> u32 {
        self.rows
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedTerminalError {
    #[error(transparent)]
    ChannelAccess(#[from] CheckedChannelAccessError),
    #[error("checked PTY dimensions are invalid")]
    InvalidPtySize,
    #[error("PTY request failed")]
    PtyRequestFailed,
    #[error("terminal shell start failed")]
    ShellStartFailed,
    #[error("terminal channel registration failed")]
    TerminalRegistrationFailed,
}

pub(crate) trait CheckedTerminalBackend {
    fn open<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
        size: CheckedPtySize,
        terminal_type: &'static str,
    ) -> Pin<Box<dyn Future<Output = Result<TerminalChannelId, CheckedTerminalError>> + Send + 'a>>;
}

struct RusshCheckedTerminalBackend;

impl CheckedTerminalBackend for RusshCheckedTerminalBackend {
    fn open<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
        size: CheckedPtySize,
        terminal_type: &'static str,
    ) -> Pin<Box<dyn Future<Output = Result<TerminalChannelId, CheckedTerminalError>> + Send + 'a>>
    {
        Box::pin(async move {
            guard.revalidate()?;
            let ssh = guard.base().ssh.lock().await;
            let channel = ssh
                .channel_open_session()
                .await
                .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
            drop(ssh);

            channel
                .request_pty(true, terminal_type, size.cols(), size.rows(), 0, 0, &[])
                .await
                .map_err(|_| CheckedTerminalError::PtyRequestFailed)?;
            channel
                .request_shell(true)
                .await
                .map_err(|_| CheckedTerminalError::ShellStartFailed)?;

            guard.revalidate()?;
            let metadata = TerminalChannelMetadata::checked(guard, size.cols(), size.rows());
            terminal::register_open_channel(guard.base().clone(), channel, metadata)
                .map(TerminalChannelId::new)
                .map_err(|_| CheckedTerminalError::TerminalRegistrationFailed)
        })
    }
}

pub(crate) async fn open_terminal_channel_checked(
    base_session_id: u64,
    cols: u32,
    rows: u32,
) -> Result<TerminalChannelId, CheckedTerminalError> {
    open_terminal_channel_checked_with_backend(
        base_session_id,
        cols,
        rows,
        &RusshCheckedTerminalBackend,
    )
    .await
}

pub(crate) async fn open_terminal_channel_checked_with_backend<B: CheckedTerminalBackend>(
    base_session_id: u64,
    cols: u32,
    rows: u32,
    backend: &B,
) -> Result<TerminalChannelId, CheckedTerminalError> {
    let size = CheckedPtySize::new(cols, rows)?;
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    match backend.open(&guard, size, PREFERRED_TERMINAL_TYPE).await {
        // Some older Windows OpenSSH deployments reject xterm-256color while
        // accepting the baseline xterm value.  Retry only that capability
        // negotiation; authentication, host-key verification, and the base
        // session are unchanged.
        Err(CheckedTerminalError::PtyRequestFailed) => {
            guard.revalidate()?;
            backend
                .open(&guard, size, WINDOWS_COMPATIBLE_TERMINAL_TYPE)
                .await
        }
        result => result,
    }
}

pub(crate) async fn discard_terminal_channel_checked(terminal_id: TerminalChannelId) {
    let _ = terminal::close(terminal_id.get()).await;
}
