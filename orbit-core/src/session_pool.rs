use std::collections::HashMap;
use std::ffi::CString;
use std::fmt;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, Weak,
};
use std::time::{Duration, SystemTime};

use once_cell::sync::Lazy;
use russh::Disconnect;
use russh::{client, Channel};
use russh_sftp::client::SftpSession;

use crate::legacy_network::{LegacyNetworkGate, LegacyNetworkPolicy};
use crate::monitor::NetSnapshot;
#[cfg(feature = "legacy-network-internal")]
use crate::security::insecure_legacy_host_key_handler::InsecureLegacyAcceptAllHostKeyHandler;
use crate::security::{
    checked_host_key_handler::CheckedHostKeyHandler, session_security::validate_checked_generation,
    BaseSessionMetadata, CheckedChannelAccessError, SessionLifecycleState, SessionSecurityError,
    SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::{ssh_session, terminal, OrbitCoreError, CONNECTION_EVENT_CALLBACK};

pub(crate) struct OrbitBaseSession {
    pub(crate) id: u64,
    pub(crate) host: String,
    #[allow(dead_code)]
    pub(crate) username: String,
    pub(crate) key: BaseSessionKey,
    pub(crate) metadata: BaseSessionMetadata,
    pub(crate) ssh: tokio::sync::Mutex<OrbitSshHandle>,
    pub(crate) net_snapshot: tokio::sync::Mutex<Option<NetSnapshot>>,
    pub(crate) monitor_sample_generation: AtomicU64,
    pub(crate) channel_ref_count: AtomicU64,
    pub(crate) keepalive_watch_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

pub(crate) enum OrbitSshHandle {
    #[cfg(feature = "legacy-network-internal")]
    Legacy(client::Handle<InsecureLegacyAcceptAllHostKeyHandler>),
    Checked(client::Handle<CheckedHostKeyHandler>),
    CheckedViaJump {
        target: client::Handle<CheckedHostKeyHandler>,
        jump: client::Handle<CheckedHostKeyHandler>,
    },
    #[cfg(test)]
    Synthetic,
}

impl OrbitSshHandle {
    pub(crate) fn is_closed(&self) -> bool {
        match self {
            #[cfg(feature = "legacy-network-internal")]
            Self::Legacy(handle) => handle.is_closed(),
            Self::Checked(handle) => handle.is_closed(),
            Self::CheckedViaJump { target, jump } => target.is_closed() || jump.is_closed(),
            #[cfg(test)]
            Self::Synthetic => false,
        }
    }

    pub(crate) async fn channel_open_session(&self) -> Result<Channel<client::Msg>, russh::Error> {
        match self {
            #[cfg(feature = "legacy-network-internal")]
            Self::Legacy(handle) => handle.channel_open_session().await,
            Self::Checked(handle) => handle.channel_open_session().await,
            Self::CheckedViaJump { target, .. } => target.channel_open_session().await,
            #[cfg(test)]
            Self::Synthetic => panic!("synthetic session cannot open a real SSH channel"),
        }
    }

    pub(crate) async fn channel_open_direct_tcpip(
        &self,
        host_to_connect: String,
        port_to_connect: u32,
        originator_address: String,
        originator_port: u32,
    ) -> Result<Channel<client::Msg>, russh::Error> {
        match self {
            #[cfg(feature = "legacy-network-internal")]
            Self::Legacy(handle) => {
                handle
                    .channel_open_direct_tcpip(
                        host_to_connect,
                        port_to_connect,
                        originator_address,
                        originator_port,
                    )
                    .await
            }
            Self::Checked(handle) => {
                handle
                    .channel_open_direct_tcpip(
                        host_to_connect,
                        port_to_connect,
                        originator_address,
                        originator_port,
                    )
                    .await
            }
            Self::CheckedViaJump { target, .. } => {
                target
                    .channel_open_direct_tcpip(
                        host_to_connect,
                        port_to_connect,
                        originator_address,
                        originator_port,
                    )
                    .await
            }
            #[cfg(test)]
            Self::Synthetic => panic!("synthetic session cannot open a real SSH channel"),
        }
    }

    pub(crate) async fn disconnect(
        &self,
        reason: Disconnect,
        description: &str,
        language_tag: &str,
    ) -> Result<(), russh::Error> {
        match self {
            #[cfg(feature = "legacy-network-internal")]
            Self::Legacy(handle) => handle.disconnect(reason, description, language_tag).await,
            Self::Checked(handle) => handle.disconnect(reason, description, language_tag).await,
            Self::CheckedViaJump { target, jump } => {
                let target_result = target.disconnect(reason, description, language_tag).await;
                let jump_result = jump
                    .disconnect(Disconnect::ByApplication, description, language_tag)
                    .await;
                target_result.and(jump_result)
            }
            #[cfg(test)]
            Self::Synthetic => Ok(()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct BaseSessionKey {
    endpoint: String,
    username: String,
    security_generation: SessionSecurityGeneration,
    route_identity: Option<String>,
}

impl BaseSessionKey {
    #[cfg(any(test, feature = "legacy-network-internal"))]
    pub(crate) fn legacy(ip: &str, port: u16, username: &str) -> Self {
        Self {
            endpoint: ssh_session::normalize_host_port(ip, port),
            username: username.trim().to_string(),
            security_generation: SessionSecurityGeneration::LegacyUnverified,
            route_identity: None,
        }
    }

    pub(crate) fn checked(
        username: &str,
        security_generation: SessionSecurityGeneration,
    ) -> Result<Self, SessionSecurityError> {
        Self::checked_with_route(username, security_generation, None)
    }

    pub(crate) fn checked_with_route(
        username: &str,
        security_generation: SessionSecurityGeneration,
        route_identity: Option<String>,
    ) -> Result<Self, SessionSecurityError> {
        validate_checked_generation(&security_generation)?;
        let username = username.trim();
        if username.is_empty() || username.len() > 256 || username.chars().any(char::is_control) {
            return Err(SessionSecurityError::InvalidSessionIdentity);
        }
        let SessionSecurityGeneration::HostKeyVerified { host_identity, .. } = &security_generation
        else {
            return Err(SessionSecurityError::VerifiedSessionRequired);
        };
        Ok(Self {
            endpoint: ssh_session::normalize_host_port(
                &host_identity.normalized_host,
                host_identity.port,
            ),
            username: username.to_string(),
            security_generation,
            route_identity,
        })
    }

    pub(crate) fn security_generation(&self) -> &SessionSecurityGeneration {
        &self.security_generation
    }

    #[cfg(test)]
    pub(crate) fn endpoint(&self) -> &str {
        &self.endpoint
    }
}

#[derive(Debug, Default)]
pub(crate) struct SessionPoolSecurityIndex {
    entries: HashMap<BaseSessionKey, u64>,
}

impl SessionPoolSecurityIndex {
    pub(crate) fn get(&self, key: &BaseSessionKey) -> Option<u64> {
        self.entries.get(key).copied()
    }

    pub(crate) fn insert(&mut self, key: BaseSessionKey, session_id: u64) -> Option<u64> {
        self.entries.insert(key, session_id)
    }

    pub(crate) fn remove_if_matches(&mut self, key: &BaseSessionKey, session_id: u64) -> bool {
        if self.entries.get(key).copied() != Some(session_id) {
            return false;
        }
        self.entries.remove(key);
        true
    }
}

pub(crate) struct OrbitSftpSession {
    pub(crate) base: Arc<OrbitBaseSession>,
    pub(crate) sftp: SftpSession,
    #[allow(
        dead_code,
        reason = "checked SFTP metadata is consumed by the additive C ABI follow-up"
    )]
    pub(crate) metadata: SftpSessionMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SftpSessionSource {
    Legacy,
    Checked,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct SftpSessionMetadata {
    base_session_id: u64,
    security_generation: SessionSecurityGeneration,
    created_at: SystemTime,
    source: SftpSessionSource,
}

impl fmt::Debug for SftpSessionMetadata {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SftpSessionMetadata")
            .field("base_session_id", &self.base_session_id)
            .field("security_generation", &"[REDACTED]")
            .field("created_at", &self.created_at)
            .field("source", &self.source)
            .finish()
    }
}

impl SftpSessionMetadata {
    pub(crate) fn new(base: &OrbitBaseSession, source: SftpSessionSource) -> Self {
        Self {
            base_session_id: base.id,
            security_generation: base.metadata.security_generation().clone(),
            created_at: SystemTime::now(),
            source,
        }
    }

    pub(crate) fn checked(guard: &VerifiedBaseSessionGuard) -> Self {
        Self::new(guard.base(), SftpSessionSource::Checked)
    }

    #[allow(dead_code, reason = "reserved for the checked SFTP ABI adapter")]
    pub(crate) fn base_session_id(&self) -> u64 {
        self.base_session_id
    }

    #[allow(dead_code, reason = "reserved for checked SFTP operation revalidation")]
    pub(crate) fn security_generation(&self) -> &SessionSecurityGeneration {
        &self.security_generation
    }

    #[allow(dead_code, reason = "reserved for checked SFTP operation revalidation")]
    pub(crate) fn source(&self) -> SftpSessionSource {
        self.source
    }
}

pub(crate) struct VerifiedBaseSessionGuard {
    base: Arc<OrbitBaseSession>,
    security_generation: SessionSecurityGeneration,
}

impl fmt::Debug for VerifiedBaseSessionGuard {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifiedBaseSessionGuard")
            .field("base_session_id", &self.base.id)
            .field("security_generation", &"[HOST_KEY_VERIFIED]")
            .finish()
    }
}

impl VerifiedBaseSessionGuard {
    pub(crate) fn base(&self) -> &Arc<OrbitBaseSession> {
        &self.base
    }

    #[allow(dead_code, reason = "reserved for the checked SFTP ABI adapter")]
    pub(crate) fn base_session_id(&self) -> u64 {
        self.base.id
    }

    #[allow(dead_code, reason = "reserved for checked channel metadata")]
    pub(crate) fn security_generation(&self) -> &SessionSecurityGeneration {
        &self.security_generation
    }

    pub(crate) fn revalidate(&self) -> Result<(), CheckedChannelAccessError> {
        require_verified_metadata(&self.base.metadata, Some(&self.security_generation))
    }

    #[allow(
        dead_code,
        reason = "reserved for callers that pin an expected generation"
    )]
    pub(crate) fn require_security_generation(
        &self,
        expected: &SessionSecurityGeneration,
    ) -> Result<(), CheckedChannelAccessError> {
        require_verified_metadata(&self.base.metadata, Some(expected))
    }
}

static BASE_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitBaseSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static BASE_SESSION_KEY_INDEX: Lazy<Mutex<SessionPoolSecurityIndex>> =
    Lazy::new(|| Mutex::new(SessionPoolSecurityIndex::default()));
type CreationGate = tokio::sync::Mutex<()>;
static BASE_SESSION_CREATION_GATES: Lazy<Mutex<HashMap<BaseSessionKey, Weak<CreationGate>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static SFTP_SESSIONS: Lazy<Mutex<HashMap<u64, Arc<OrbitSftpSession>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
const SESSION_ID_NAMESPACE_SHIFT: u32 = 48;
const SESSION_ID_NAMESPACE_MASK: u64 = 0x0f_u64 << SESSION_ID_NAMESPACE_SHIFT;
const BASE_SESSION_ID_NAMESPACE: u64 = 0x01_u64 << SESSION_ID_NAMESPACE_SHIFT;
const SESSION_ID_COUNTER_MASK: u64 = (1_u64 << SESSION_ID_NAMESPACE_SHIFT) - 1;
static NEXT_BASE_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_SFTP_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) fn get_sftp_session(session_id: u64) -> Result<Arc<OrbitSftpSession>, OrbitCoreError> {
    let sessions = lock_sftp_sessions()?;
    let session = sessions
        .get(&session_id)
        .cloned()
        .ok_or_else(|| OrbitCoreError::SftpFailed("session not found".to_string()))?;
    require_sftp_operation_access(&session)?;
    Ok(session)
}

pub(crate) fn require_sftp_operation_access(
    session: &OrbitSftpSession,
) -> Result<(), OrbitCoreError> {
    require_sftp_operation_access_with_policy(session, LegacyNetworkPolicy::current())
}

pub(crate) fn require_sftp_operation_access_with_policy(
    session: &OrbitSftpSession,
    policy: LegacyNetworkPolicy,
) -> Result<(), OrbitCoreError> {
    require_sftp_operation_metadata_access_with_policy(&session.base, &session.metadata, policy)
}

pub(crate) fn require_sftp_operation_metadata_access_with_policy(
    base: &OrbitBaseSession,
    metadata: &SftpSessionMetadata,
    policy: LegacyNetworkPolicy,
) -> Result<(), OrbitCoreError> {
    if policy.allows_legacy_network() {
        return Ok(());
    }
    if metadata.source() != SftpSessionSource::Checked {
        return Err(OrbitCoreError::LegacyNetworkDisabled);
    }
    require_verified_metadata(&base.metadata, Some(metadata.security_generation()))
        .map_err(|error| OrbitCoreError::SshFailed(error.to_string()))
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
    let metadata = SftpSessionMetadata::new(&base, SftpSessionSource::Legacy);
    let wrapper = Arc::new(OrbitSftpSession {
        base,
        sftp,
        metadata,
    });
    lock_sftp_sessions()?.insert(channel_id, wrapper);
    Ok(channel_id)
}

pub(crate) fn insert_checked_sftp_session(
    guard: &VerifiedBaseSessionGuard,
    sftp: SftpSession,
) -> Result<u64, CheckedChannelAccessError> {
    guard.revalidate()?;
    let base = guard.base().clone();
    let metadata = SftpSessionMetadata::checked(guard);
    let mut sessions =
        lock_sftp_sessions().map_err(|_| CheckedChannelAccessError::SftpRegistrationFailed)?;
    base.channel_ref_count.fetch_add(1, Ordering::SeqCst);
    let channel_id = NEXT_SFTP_CHANNEL_ID.fetch_add(1, Ordering::SeqCst);
    let wrapper = Arc::new(OrbitSftpSession {
        base,
        sftp,
        metadata,
    });
    sessions.insert(channel_id, wrapper);
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
    LegacyNetworkGate::require_current()?;

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
        let key = BaseSessionKey::legacy(ip, port, username);

        if let Some(existing) = try_reuse_base_session(&key).await? {
            return Ok(existing);
        }

        let creation_gate = base_session_creation_gate(&key)?;
        let _creation_guard = creation_gate.lock().await;
        if let Some(existing) = try_reuse_base_session(&key).await? {
            return Ok(existing);
        }

        let config = ssh_session::new_client_config();
        let addr = ssh_session::normalize_host_port(ip, port);

        let mut ssh = client::connect(config, addr, InsecureLegacyAcceptAllHostKeyHandler)
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

        let base_id = next_base_session_id()?;
        let base = Arc::new(OrbitBaseSession {
            id: base_id,
            host: ip.to_string(),
            username: username.to_string(),
            key: key.clone(),
            metadata: BaseSessionMetadata::new_legacy(),
            ssh: tokio::sync::Mutex::new(OrbitSshHandle::Legacy(ssh)),
            net_snapshot: tokio::sync::Mutex::new(None),
            monitor_sample_generation: AtomicU64::new(0),
            channel_ref_count: AtomicU64::new(1),
            keepalive_watch_task: Mutex::new(None),
        });

        {
            let mut sessions = lock_base_sessions()?;
            let mut index = lock_base_key_index()?;
            sessions.insert(base_id, base.clone());
            index.insert(key, base_id);
        }
        spawn_keepalive_watch(base.clone());
        Ok(base)
    }
}

#[allow(
    dead_code,
    reason = "checked physical sessions are introduced by A2.3d after pool isolation"
)]
pub(crate) fn lookup_base_session_checked(
    username: &str,
    security_generation: SessionSecurityGeneration,
) -> Result<Option<Arc<OrbitBaseSession>>, SessionSecurityError> {
    let key = BaseSessionKey::checked(username, security_generation)?;
    let session_id = BASE_SESSION_KEY_INDEX
        .lock()
        .map_err(|_| SessionSecurityError::InternalInvariantViolation)?
        .get(&key);
    let Some(session_id) = session_id else {
        return Ok(None);
    };
    let session = BASE_SESSIONS
        .lock()
        .map_err(|_| SessionSecurityError::InternalInvariantViolation)?
        .get(&session_id)
        .cloned()
        .ok_or(SessionSecurityError::InternalInvariantViolation)?;
    session
        .metadata
        .assert_allows_new_channel(key.security_generation())?;
    if !try_acquire_session_reference(&session) {
        return Err(SessionSecurityError::SessionClosed);
    }
    Ok(Some(session))
}

pub(crate) async fn try_reuse_checked_base_session(
    username: &str,
    security_generation: SessionSecurityGeneration,
) -> Result<Option<Arc<OrbitBaseSession>>, OrbitCoreError> {
    let key = BaseSessionKey::checked(username, security_generation)
        .map_err(session_security_core_error)?;
    try_reuse_base_session(&key).await
}

pub(crate) async fn try_reuse_checked_base_session_with_route(
    username: &str,
    security_generation: SessionSecurityGeneration,
    route_identity: String,
) -> Result<Option<Arc<OrbitBaseSession>>, OrbitCoreError> {
    let key =
        BaseSessionKey::checked_with_route(username, security_generation, Some(route_identity))
            .map_err(session_security_core_error)?;
    try_reuse_base_session(&key).await
}

pub(crate) async fn lookup_verified_session_for_store(
    host_identity: &crate::security::HostIdentity,
    username: &str,
    trust_store_generation: &TrustStoreGeneration,
) -> Result<Option<Arc<OrbitBaseSession>>, OrbitCoreError> {
    let candidates: Vec<_> = lock_base_sessions()?.values().cloned().collect();
    for session in candidates {
        let SessionSecurityGeneration::HostKeyVerified {
            host_identity: stored_identity,
            trust_store_generation: stored_generation,
            ..
        } = session.metadata.security_generation()
        else {
            continue;
        };
        if stored_identity != host_identity
            || stored_generation != trust_store_generation
            || session.username != username
        {
            continue;
        }
        if session
            .metadata
            .assert_allows_new_channel(session.metadata.security_generation())
            .is_err()
        {
            continue;
        }
        if session.ssh.lock().await.is_closed() {
            let _ = session
                .metadata
                .transition_to(SessionLifecycleState::Closed);
            lock_base_key_index()?.remove_if_matches(&session.key, session.id);
            continue;
        }
        if try_acquire_session_reference(&session) {
            return Ok(Some(session));
        }
    }
    Ok(None)
}

pub(crate) fn insert_verified_base_session(
    ssh: client::Handle<CheckedHostKeyHandler>,
    username: &str,
    security_generation: SessionSecurityGeneration,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    insert_verified_base_session_with_route(
        OrbitSshHandle::Checked(ssh),
        username,
        security_generation,
        None,
    )
}

pub(crate) fn insert_verified_base_session_with_route(
    ssh: OrbitSshHandle,
    username: &str,
    security_generation: SessionSecurityGeneration,
    route_identity: Option<String>,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    let key =
        BaseSessionKey::checked_with_route(username, security_generation.clone(), route_identity)
            .map_err(session_security_core_error)?;
    let SessionSecurityGeneration::HostKeyVerified { host_identity, .. } = &security_generation
    else {
        return Err(session_security_core_error(
            SessionSecurityError::VerifiedSessionRequired,
        ));
    };
    let normalized_host = host_identity.normalized_host.clone();
    let metadata = BaseSessionMetadata::new_checked(security_generation)
        .map_err(session_security_core_error)?;
    let base_id = next_base_session_id()?;
    let base = Arc::new(OrbitBaseSession {
        id: base_id,
        host: normalized_host,
        username: username.to_string(),
        key: key.clone(),
        metadata,
        ssh: tokio::sync::Mutex::new(ssh),
        net_snapshot: tokio::sync::Mutex::new(None),
        monitor_sample_generation: AtomicU64::new(0),
        channel_ref_count: AtomicU64::new(1),
        keepalive_watch_task: Mutex::new(None),
    });
    {
        let mut sessions = lock_base_sessions()?;
        let mut index = lock_base_key_index()?;
        if index.get(&key).is_some() {
            return Err(OrbitCoreError::Internal(
                "verified session insertion requires an exclusive creation gate".to_string(),
            ));
        }
        sessions.insert(base_id, base.clone());
        index.insert(key, base_id);
    }
    spawn_keepalive_watch(base.clone());
    Ok(base)
}

fn session_security_core_error(error: SessionSecurityError) -> OrbitCoreError {
    OrbitCoreError::Internal(format!("session security error: {error}"))
}

fn next_base_session_id() -> Result<u64, OrbitCoreError> {
    let counter = NEXT_BASE_SESSION_ID.fetch_add(1, Ordering::SeqCst);
    if counter == 0 || counter > SESSION_ID_COUNTER_MASK {
        return Err(OrbitCoreError::Internal(
            "base session identifier space exhausted".to_string(),
        ));
    }
    Ok(BASE_SESSION_ID_NAMESPACE | counter)
}

pub(crate) const fn is_base_session_id(value: u64) -> bool {
    value & SESSION_ID_NAMESPACE_MASK == BASE_SESSION_ID_NAMESPACE
        && value & SESSION_ID_COUNTER_MASK != 0
}

pub(crate) fn resolve_base_session(
    session_or_channel_id: u64,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
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

pub(crate) fn resolve_base_session_by_base_id(
    base_session_id: u64,
) -> Result<Arc<OrbitBaseSession>, CheckedChannelAccessError> {
    if !is_base_session_id(base_session_id) {
        return Err(CheckedChannelAccessError::SessionNotFound);
    }
    BASE_SESSIONS
        .lock()
        .map_err(|_| CheckedChannelAccessError::InternalInvariantViolation)?
        .get(&base_session_id)
        .cloned()
        .ok_or(CheckedChannelAccessError::SessionNotFound)
}

pub(crate) fn require_active_verified_base_session(
    base_session_id: u64,
) -> Result<VerifiedBaseSessionGuard, CheckedChannelAccessError> {
    let base = resolve_base_session_by_base_id(base_session_id)?;
    require_verified_metadata(&base.metadata, None)?;
    let security_generation = base.metadata.security_generation().clone();
    Ok(VerifiedBaseSessionGuard {
        base,
        security_generation,
    })
}

fn require_verified_metadata(
    metadata: &BaseSessionMetadata,
    expected: Option<&SessionSecurityGeneration>,
) -> Result<(), CheckedChannelAccessError> {
    match metadata.state().map_err(CheckedChannelAccessError::from)? {
        SessionLifecycleState::Active => {}
        SessionLifecycleState::Draining => {
            return Err(CheckedChannelAccessError::SessionDraining);
        }
        SessionLifecycleState::Terminating => {
            return Err(CheckedChannelAccessError::SessionTerminating);
        }
        SessionLifecycleState::Closed => return Err(CheckedChannelAccessError::SessionClosed),
    }
    let generation = metadata.security_generation();
    match generation {
        SessionSecurityGeneration::LegacyUnverified => {
            return Err(CheckedChannelAccessError::LegacySessionNotAllowed);
        }
        SessionSecurityGeneration::HostKeyVerified { .. } => {
            validate_checked_generation(generation).map_err(CheckedChannelAccessError::from)?;
        }
    }
    if expected.is_some_and(|value| value != generation) {
        return Err(CheckedChannelAccessError::SecurityGenerationMismatch);
    }
    Ok(())
}

#[cfg(test)]
pub(crate) fn insert_synthetic_base_session_for_tests(
    host: &str,
    username: &str,
    security_generation: SessionSecurityGeneration,
) -> Result<Arc<OrbitBaseSession>, OrbitCoreError> {
    let key = match &security_generation {
        SessionSecurityGeneration::LegacyUnverified => BaseSessionKey::legacy(host, 22, username),
        SessionSecurityGeneration::HostKeyVerified { .. } => {
            BaseSessionKey::checked(username, security_generation.clone())
                .map_err(session_security_core_error)?
        }
    };
    let metadata = match security_generation {
        SessionSecurityGeneration::LegacyUnverified => BaseSessionMetadata::new_legacy(),
        verified @ SessionSecurityGeneration::HostKeyVerified { .. } => {
            BaseSessionMetadata::new_checked(verified).map_err(session_security_core_error)?
        }
    };
    let base_id = next_base_session_id()?;
    let base = Arc::new(OrbitBaseSession {
        id: base_id,
        host: host.to_string(),
        username: username.to_string(),
        key,
        metadata,
        ssh: tokio::sync::Mutex::new(OrbitSshHandle::Synthetic),
        net_snapshot: tokio::sync::Mutex::new(None),
        monitor_sample_generation: AtomicU64::new(0),
        channel_ref_count: AtomicU64::new(1),
        keepalive_watch_task: Mutex::new(None),
    });
    lock_base_sessions()?.insert(base_id, base.clone());
    Ok(base)
}

#[cfg(test)]
pub(crate) fn remove_synthetic_base_session_for_tests(base_session_id: u64) {
    if let Ok(mut sessions) = BASE_SESSIONS.lock() {
        sessions.remove(&base_session_id);
    }
}

pub(crate) async fn release_base_session(base_id: u64) -> Result<(), OrbitCoreError> {
    let maybe_base = lock_base_sessions()?.get(&base_id).cloned();
    let Some(base) = maybe_base else {
        return Ok(());
    };

    let prev = base
        .channel_ref_count
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |current| {
            current.checked_sub(1)
        })
        .map_err(|_| OrbitCoreError::Internal("base session reference underflow".to_string()))?;
    if prev > 1 {
        return Ok(());
    }

    let _ = base.metadata.transition_to(SessionLifecycleState::Closed);

    {
        let mut bases = lock_base_sessions()?;
        bases.remove(&base_id);
    }
    {
        let mut index = lock_base_key_index()?;
        index.remove_if_matches(&base.key, base_id);
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
) -> Result<std::sync::MutexGuard<'static, SessionPoolSecurityIndex>, OrbitCoreError> {
    BASE_SESSION_KEY_INDEX
        .lock()
        .map_err(|_| OrbitCoreError::Internal("base key index lock poisoned".to_string()))
}

fn lock_creation_gates() -> Result<
    std::sync::MutexGuard<'static, HashMap<BaseSessionKey, Weak<CreationGate>>>,
    OrbitCoreError,
> {
    BASE_SESSION_CREATION_GATES
        .lock()
        .map_err(|_| OrbitCoreError::Internal("base creation gate lock poisoned".to_string()))
}

pub(crate) fn base_session_creation_gate(
    key: &BaseSessionKey,
) -> Result<Arc<CreationGate>, OrbitCoreError> {
    let mut gates = lock_creation_gates()?;
    gates.retain(|_, gate| gate.strong_count() > 0);
    if let Some(gate) = gates.get(key).and_then(Weak::upgrade) {
        return Ok(gate);
    }
    let gate = Arc::new(CreationGate::new(()));
    gates.insert(key.clone(), Arc::downgrade(&gate));
    Ok(gate)
}

async fn try_reuse_base_session(
    key: &BaseSessionKey,
) -> Result<Option<Arc<OrbitBaseSession>>, OrbitCoreError> {
    let session_id = lock_base_key_index()?.get(key);
    let Some(session_id) = session_id else {
        return Ok(None);
    };
    let Some(session) = lock_base_sessions()?.get(&session_id).cloned() else {
        lock_base_key_index()?.remove_if_matches(key, session_id);
        return Ok(None);
    };

    if session
        .metadata
        .assert_allows_new_channel(key.security_generation())
        .is_err()
    {
        lock_base_key_index()?.remove_if_matches(key, session_id);
        return Ok(None);
    }
    let is_closed = {
        let ssh = session.ssh.lock().await;
        ssh.is_closed()
    };
    if is_closed {
        let _ = session
            .metadata
            .transition_to(SessionLifecycleState::Closed);
        lock_base_key_index()?.remove_if_matches(key, session_id);
        return Ok(None);
    }
    if !try_acquire_session_reference(&session) {
        return Ok(None);
    }
    Ok(Some(session))
}

fn try_acquire_session_reference(session: &OrbitBaseSession) -> bool {
    session
        .channel_ref_count
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |current| {
            (current > 0).then(|| current.checked_add(1)).flatten()
        })
        .is_ok()
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
                let _ = watch_base
                    .metadata
                    .transition_to(SessionLifecycleState::Closed);
                if let Ok(mut index) = lock_base_key_index() {
                    index.remove_if_matches(&watch_base.key, base_id);
                }
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
