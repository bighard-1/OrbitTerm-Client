use std::future::Future;
use std::pin::Pin;

use russh_sftp::client::SftpSession;

use crate::security::CheckedChannelAccessError;
use crate::session_pool::{
    insert_checked_sftp_session, release_base_session, remove_sftp_session,
    require_active_verified_base_session, VerifiedBaseSessionGuard,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct SftpSessionId(pub(crate) u64);

impl SftpSessionId {
    pub(crate) const fn get(self) -> u64 {
        self.0
    }
}

pub(crate) trait CheckedSftpBackend {
    type Session;

    fn open<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
    ) -> Pin<Box<dyn Future<Output = Result<Self::Session, CheckedChannelAccessError>> + Send + 'a>>;

    fn register(
        &self,
        guard: &VerifiedBaseSessionGuard,
        session: Self::Session,
    ) -> Result<SftpSessionId, CheckedChannelAccessError>;
}

struct RusshCheckedSftpBackend;

impl CheckedSftpBackend for RusshCheckedSftpBackend {
    type Session = SftpSession;

    fn open<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
    ) -> Pin<Box<dyn Future<Output = Result<Self::Session, CheckedChannelAccessError>> + Send + 'a>>
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
                .request_subsystem(true, "sftp")
                .await
                .map_err(|_| CheckedChannelAccessError::SubsystemRequestFailed)?;
            SftpSession::new(channel.into_stream())
                .await
                .map_err(|_| CheckedChannelAccessError::SubsystemRequestFailed)
        })
    }

    fn register(
        &self,
        guard: &VerifiedBaseSessionGuard,
        session: Self::Session,
    ) -> Result<SftpSessionId, CheckedChannelAccessError> {
        insert_checked_sftp_session(guard, session).map(SftpSessionId)
    }
}

pub(crate) async fn open_sftp_channel_checked(
    base_session_id: u64,
) -> Result<SftpSessionId, CheckedChannelAccessError> {
    open_sftp_channel_checked_with_backend(base_session_id, &RusshCheckedSftpBackend).await
}

pub(crate) async fn open_sftp_channel_checked_with_backend<B: CheckedSftpBackend>(
    base_session_id: u64,
    backend: &B,
) -> Result<SftpSessionId, CheckedChannelAccessError> {
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    let session = backend.open(&guard).await?;
    guard.revalidate()?;
    backend.register(&guard, session)
}

pub(crate) async fn discard_sftp_channel_checked(session_id: SftpSessionId) {
    let Ok(session) = remove_sftp_session(session_id.get()) else {
        return;
    };
    let base_session_id = session.base.id;
    let _ = session.sftp.close().await;
    let _ = release_base_session(base_session_id).await;
}
