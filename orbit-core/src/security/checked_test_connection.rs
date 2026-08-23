use std::fmt;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::Duration;

use russh::client;
use russh::Disconnect;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::time::timeout;

use super::checked_connect_coordinator::{
    CheckedAuthenticationApproval, CheckedConnectCoordinator, CheckedConnectPreAuthError,
    CheckedPreAuthDecision, KnownHostsStoreReloader,
};
use super::checked_host_key_handler::CheckedHostKeyHandler;
use super::connect_pre_auth_error::ConnectPreAuthError;
use super::host_key::HostIdentity;
use super::host_key_challenge_registry::RegisteredHostKeyChallenge;
use super::host_key_challenge_service::{
    shared_host_key_challenge_service, HostKeyChallengeService,
};
use super::host_key_trust_persistence::validate_orbitterm_known_hosts_path;
use super::host_key_verifier::HostKeyBlock;
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::trust_store_generation::TrustStoreGeneration;
use crate::ssh_session;

pub(crate) const CHECKED_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const CHECKED_AUTH_TIMEOUT: Duration = Duration::from_secs(15);
const CHECKED_DISCONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_USERNAME_BYTES: usize = 256;
const MAX_REQUEST_ID_BYTES: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedTestInputError {
    #[error("checked SSH test host is invalid")]
    InvalidHost,
    #[error("checked SSH test username is invalid")]
    InvalidUsername,
    #[error("checked SSH test request identifier is invalid")]
    InvalidRequestId,
    #[error("checked SSH test requires a password or private key")]
    MissingCredentials,
    #[error("checked SSH test known_hosts path is invalid")]
    InvalidKnownHostsPath,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CheckedTestTimeoutStage {
    Connect,
    Authentication,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedAuthenticationError {
    #[error("SSH authentication was not successful")]
    Failed,
}

#[derive(Debug, Error)]
pub(crate) enum CheckedTestConnectionError {
    #[error("checked SSH test connection timed out")]
    Timeout { stage: CheckedTestTimeoutStage },
    #[error("checked SSH test failed during KEX")]
    Connect(#[source] ConnectPreAuthError),
    #[error("checked SSH test failed at the authentication gate")]
    PreAuthentication(#[source] CheckedConnectPreAuthError),
    #[error("checked SSH test authentication failed")]
    Authentication(#[source] CheckedAuthenticationError),
}

pub(crate) enum CheckedTestConnectionOutcome {
    Succeeded(CheckedAuthenticationApproval),
    Challenge(Box<RegisteredHostKeyChallenge>),
    Blocked(Box<HostKeyBlock>),
    Error(CheckedTestConnectionError),
}

pub(crate) struct CheckedPreparedConnection {
    pub(crate) session: client::Handle<CheckedHostKeyHandler>,
    pub(crate) approval: CheckedAuthenticationApproval,
}

impl fmt::Debug for CheckedPreparedConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedPreparedConnection")
            .field("approval", &self.approval)
            .finish_non_exhaustive()
    }
}

pub(crate) enum CheckedConnectionPreparationOutcome {
    Ready(CheckedPreparedConnection),
    Challenge(Box<RegisteredHostKeyChallenge>),
    Blocked(Box<HostKeyBlock>),
    Error(CheckedTestConnectionError),
}

impl fmt::Debug for CheckedTestConnectionOutcome {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Succeeded(approval) => {
                formatter.debug_tuple("Succeeded").field(approval).finish()
            }
            Self::Challenge(challenge) => {
                formatter.debug_tuple("Challenge").field(challenge).finish()
            }
            Self::Blocked(block) => formatter.debug_tuple("Blocked").field(block).finish(),
            Self::Error(error) => formatter.debug_tuple("Error").field(error).finish(),
        }
    }
}

pub(crate) struct CheckedTestConnectionRequest {
    host_identity: HostIdentity,
    username: String,
    password: String,
    private_key: String,
    private_key_passphrase: String,
    allow_password_fallback: bool,
    known_hosts_path: PathBuf,
    request_id: String,
    jump_host: Option<CheckedJumpHostRequest>,
}

/// A one-hop ProxyJump endpoint. This is intentionally separate from the
/// destination request: credentials and host identity must never be reused
/// between the two SSH servers.
#[derive(Clone)]
pub(crate) struct CheckedJumpHostRequest {
    host_identity: HostIdentity,
    username: String,
    password: String,
    private_key: String,
    private_key_passphrase: String,
    allow_password_fallback: bool,
}

impl fmt::Debug for CheckedJumpHostRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedJumpHostRequest")
            .field("host_identity", &self.host_identity)
            .field("username", &self.username)
            .field("password", &"[REDACTED]")
            .field("private_key", &"[REDACTED]")
            .field("private_key_passphrase", &"[REDACTED]")
            .field("allow_password_fallback", &self.allow_password_fallback)
            .finish()
    }
}

impl CheckedJumpHostRequest {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        host: String,
        port: u16,
        username: String,
        password: String,
        private_key: String,
        private_key_passphrase: String,
        allow_password_fallback: bool,
    ) -> Result<Self, CheckedTestInputError> {
        let host_identity =
            HostIdentity::parse(&host, port).map_err(|_| CheckedTestInputError::InvalidHost)?;
        if port == 0 || host_identity.port != port {
            return Err(CheckedTestInputError::InvalidHost);
        }
        let username = username.trim().to_string();
        if username.is_empty()
            || username.len() > MAX_USERNAME_BYTES
            || username.chars().any(char::is_control)
        {
            return Err(CheckedTestInputError::InvalidUsername);
        }
        if password.is_empty() && private_key.trim().is_empty() {
            return Err(CheckedTestInputError::MissingCredentials);
        }
        Ok(Self {
            host_identity,
            username,
            password,
            private_key,
            private_key_passphrase,
            allow_password_fallback,
        })
    }

    pub(crate) fn as_connection_request(
        &self,
        known_hosts_path: PathBuf,
        request_id: String,
    ) -> Result<CheckedTestConnectionRequest, CheckedTestInputError> {
        CheckedTestConnectionRequest::new(
            self.host_identity.normalized_host.clone(),
            self.host_identity.port,
            self.username.clone(),
            self.password.clone(),
            self.private_key.clone(),
            self.private_key_passphrase.clone(),
            self.allow_password_fallback,
            known_hosts_path,
            request_id,
        )
    }

    pub(crate) fn route_identity(&self) -> String {
        format!(
            "{}@{}:{}",
            self.username, self.host_identity.normalized_host, self.host_identity.port
        )
    }
}

impl fmt::Debug for CheckedTestConnectionRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedTestConnectionRequest")
            .field("host_identity", &self.host_identity)
            .field("username", &self.username)
            .field("password", &"[REDACTED]")
            .field("private_key", &"[REDACTED]")
            .field("private_key_passphrase", &"[REDACTED]")
            .field("allow_password_fallback", &self.allow_password_fallback)
            .field("known_hosts_path", &"[REDACTED]")
            .field("request_id", &self.request_id)
            .finish()
    }
}

impl CheckedTestConnectionRequest {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        host: String,
        port: u16,
        username: String,
        password: String,
        private_key: String,
        private_key_passphrase: String,
        allow_password_fallback: bool,
        known_hosts_path: PathBuf,
        request_id: String,
    ) -> Result<Self, CheckedTestInputError> {
        let host_identity =
            HostIdentity::parse(&host, port).map_err(|_| CheckedTestInputError::InvalidHost)?;
        if port == 0 || host_identity.port != port {
            return Err(CheckedTestInputError::InvalidHost);
        }
        let username = username.trim().to_string();
        if username.is_empty()
            || username.len() > MAX_USERNAME_BYTES
            || username.chars().any(char::is_control)
        {
            return Err(CheckedTestInputError::InvalidUsername);
        }
        if request_id.is_empty()
            || request_id.len() > MAX_REQUEST_ID_BYTES
            || request_id.chars().any(char::is_control)
        {
            return Err(CheckedTestInputError::InvalidRequestId);
        }
        if password.is_empty() && private_key.trim().is_empty() {
            return Err(CheckedTestInputError::MissingCredentials);
        }
        validate_checked_known_hosts_path(&known_hosts_path)?;

        Ok(Self {
            host_identity,
            username,
            password,
            private_key,
            private_key_passphrase,
            allow_password_fallback,
            known_hosts_path,
            request_id,
            jump_host: None,
        })
    }

    pub(crate) fn request_id(&self) -> &str {
        &self.request_id
    }

    pub(crate) fn host_identity(&self) -> &HostIdentity {
        &self.host_identity
    }

    pub(crate) fn with_jump_host(mut self, jump_host: CheckedJumpHostRequest) -> Self {
        self.jump_host = Some(jump_host);
        self
    }

    pub(crate) fn jump_host(&self) -> Option<&CheckedJumpHostRequest> {
        self.jump_host.as_ref()
    }

    pub(crate) fn known_hosts_path(&self) -> &Path {
        &self.known_hosts_path
    }

    pub(crate) fn username(&self) -> &str {
        &self.username
    }
}

pub(crate) fn load_checked_trust_store_generation(
    request: &CheckedTestConnectionRequest,
) -> Result<TrustStoreGeneration, CheckedTestConnectionError> {
    validate_checked_known_hosts_path(&request.known_hosts_path).map_err(|_| {
        CheckedTestConnectionError::PreAuthentication(
            CheckedConnectPreAuthError::StoreReloadFailed(KnownHostsStoreError::InvalidPath),
        )
    })?;
    let store = KnownHostsStore::load(&request.known_hosts_path).map_err(|error| {
        CheckedTestConnectionError::PreAuthentication(
            CheckedConnectPreAuthError::StoreReloadFailed(error),
        )
    })?;
    Ok(TrustStoreGeneration::from_store(&store))
}

fn validate_checked_known_hosts_path(path: &Path) -> Result<(), CheckedTestInputError> {
    validate_orbitterm_known_hosts_path(path)
        .map_err(|_| CheckedTestInputError::InvalidKnownHostsPath)?;

    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CheckedTestInputError::InvalidKnownHostsPath);
        }
    }
    if let Some(parent) = path.parent() {
        if let Ok(metadata) = fs::symlink_metadata(parent) {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(CheckedTestInputError::InvalidKnownHostsPath);
            }
            if let (Ok(canonical_parent), Some(file_name)) =
                (parent.canonicalize(), path.file_name())
            {
                validate_orbitterm_known_hosts_path(&canonical_parent.join(file_name))
                    .map_err(|_| CheckedTestInputError::InvalidKnownHostsPath)?;
            }
        }
    }
    Ok(())
}

struct FileKnownHostsStoreReloader {
    path: PathBuf,
}

impl fmt::Debug for FileKnownHostsStoreReloader {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FileKnownHostsStoreReloader")
            .field("path", &"[REDACTED]")
            .finish()
    }
}

impl KnownHostsStoreReloader for FileKnownHostsStoreReloader {
    fn reload(&mut self) -> Result<KnownHostsStore, KnownHostsStoreError> {
        validate_checked_known_hosts_path(&self.path)
            .map_err(|_| KnownHostsStoreError::InvalidPath)?;
        KnownHostsStore::load(&self.path)
    }
}

pub(crate) async fn run_checked_test_connection(
    request: CheckedTestConnectionRequest,
) -> CheckedTestConnectionOutcome {
    run_checked_test_connection_with_service(request, shared_host_key_challenge_service().clone())
        .await
}

async fn run_checked_test_connection_with_service(
    request: CheckedTestConnectionRequest,
    challenge_service: HostKeyChallengeService,
) -> CheckedTestConnectionOutcome {
    let prepared = prepare_checked_connection_with_service(&request, challenge_service).await;
    let CheckedConnectionPreparationOutcome::Ready(mut prepared) = prepared else {
        return preparation_outcome_to_test_outcome(prepared);
    };

    let outcome = match timeout(
        CHECKED_AUTH_TIMEOUT,
        authenticate_checked_session(&mut prepared.session, &request),
    )
    .await
    {
        Err(_) => CheckedTestConnectionOutcome::Error(CheckedTestConnectionError::Timeout {
            stage: CheckedTestTimeoutStage::Authentication,
        }),
        Ok(Err(error)) => {
            CheckedTestConnectionOutcome::Error(CheckedTestConnectionError::Authentication(error))
        }
        Ok(Ok(())) => CheckedTestConnectionOutcome::Succeeded(prepared.approval),
    };
    best_effort_disconnect(&prepared.session, "connection test complete").await;
    outcome
}

pub(crate) async fn prepare_checked_connection(
    request: &CheckedTestConnectionRequest,
) -> CheckedConnectionPreparationOutcome {
    prepare_checked_connection_with_service(request, shared_host_key_challenge_service().clone())
        .await
}

/// The same checked host-key preparation used for a direct socket, but over a
/// stream that was opened with SSH `direct-tcpip` on a verified jump host.
/// This keeps destination verification fully independent from the jump host.
pub(crate) async fn prepare_checked_connection_over_stream<R>(
    request: &CheckedTestConnectionRequest,
    stream: R,
) -> CheckedConnectionPreparationOutcome
where
    R: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    prepare_checked_connection_over_stream_with_service(
        request,
        stream,
        shared_host_key_challenge_service().clone(),
    )
    .await
}

async fn prepare_checked_connection_with_service(
    request: &CheckedTestConnectionRequest,
    challenge_service: HostKeyChallengeService,
) -> CheckedConnectionPreparationOutcome {
    let reloader = FileKnownHostsStoreReloader {
        path: request.known_hosts_path.clone(),
    };
    let mut coordinator = match CheckedConnectCoordinator::new(
        request.host_identity.clone(),
        Some(request.request_id.clone()),
        challenge_service,
        reloader,
    ) {
        Ok(value) => value,
        Err(error) => {
            return CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::PreAuthentication(error),
            );
        }
    };

    let address = ssh_session::normalize_host_port(
        &request.host_identity.normalized_host,
        request.host_identity.port,
    );
    let handler = CheckedHostKeyHandler::new(coordinator.verification_context());
    let session = match timeout(
        CHECKED_CONNECT_TIMEOUT,
        client::connect(ssh_session::new_client_config(), address, handler),
    )
    .await
    {
        Err(_) => {
            return CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::Timeout {
                    stage: CheckedTestTimeoutStage::Connect,
                },
            );
        }
        Ok(Err(error)) => return preparation_outcome_from_connect_error(error),
        Ok(Ok(session)) => session,
    };

    match coordinator.pre_authentication_check() {
        CheckedPreAuthDecision::AllowAuthentication(approval) => {
            CheckedConnectionPreparationOutcome::Ready(CheckedPreparedConnection {
                session,
                approval,
            })
        }
        CheckedPreAuthDecision::Block(block) => {
            best_effort_disconnect(&session, "host key blocked").await;
            CheckedConnectionPreparationOutcome::Blocked(block)
        }
        CheckedPreAuthDecision::Fail(error) => {
            best_effort_disconnect(&session, "pre-authentication check failed").await;
            CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::PreAuthentication(error),
            )
        }
    }
}

async fn prepare_checked_connection_over_stream_with_service<R>(
    request: &CheckedTestConnectionRequest,
    stream: R,
    challenge_service: HostKeyChallengeService,
) -> CheckedConnectionPreparationOutcome
where
    R: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let reloader = FileKnownHostsStoreReloader {
        path: request.known_hosts_path.clone(),
    };
    let mut coordinator = match CheckedConnectCoordinator::new(
        request.host_identity.clone(),
        Some(request.request_id.clone()),
        challenge_service,
        reloader,
    ) {
        Ok(value) => value,
        Err(error) => {
            return CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::PreAuthentication(error),
            );
        }
    };
    let handler = CheckedHostKeyHandler::new(coordinator.verification_context());
    let session = match timeout(
        CHECKED_CONNECT_TIMEOUT,
        client::connect_stream(ssh_session::new_client_config(), stream, handler),
    )
    .await
    {
        Err(_) => {
            return CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::Timeout {
                    stage: CheckedTestTimeoutStage::Connect,
                },
            );
        }
        Ok(Err(error)) => return preparation_outcome_from_connect_error(error),
        Ok(Ok(session)) => session,
    };

    match coordinator.pre_authentication_check() {
        CheckedPreAuthDecision::AllowAuthentication(approval) => {
            CheckedConnectionPreparationOutcome::Ready(CheckedPreparedConnection {
                session,
                approval,
            })
        }
        CheckedPreAuthDecision::Block(block) => {
            best_effort_disconnect(&session, "host key blocked").await;
            CheckedConnectionPreparationOutcome::Blocked(block)
        }
        CheckedPreAuthDecision::Fail(error) => {
            best_effort_disconnect(&session, "pre-authentication check failed").await;
            CheckedConnectionPreparationOutcome::Error(
                CheckedTestConnectionError::PreAuthentication(error),
            )
        }
    }
}

pub(crate) async fn run_authentication_gate<F, Fut>(
    decision: CheckedPreAuthDecision,
    authenticate: F,
) -> CheckedTestConnectionOutcome
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<(), CheckedAuthenticationError>>,
{
    let approval = match decision {
        CheckedPreAuthDecision::AllowAuthentication(approval) => approval,
        CheckedPreAuthDecision::Block(block) => {
            return CheckedTestConnectionOutcome::Blocked(block);
        }
        CheckedPreAuthDecision::Fail(error) => {
            return CheckedTestConnectionOutcome::Error(
                CheckedTestConnectionError::PreAuthentication(error),
            );
        }
    };

    match timeout(CHECKED_AUTH_TIMEOUT, authenticate()).await {
        Err(_) => CheckedTestConnectionOutcome::Error(CheckedTestConnectionError::Timeout {
            stage: CheckedTestTimeoutStage::Authentication,
        }),
        Ok(Err(error)) => {
            CheckedTestConnectionOutcome::Error(CheckedTestConnectionError::Authentication(error))
        }
        Ok(Ok(())) => CheckedTestConnectionOutcome::Succeeded(approval),
    }
}

pub(crate) async fn authenticate_checked_session(
    session: &mut client::Handle<CheckedHostKeyHandler>,
    request: &CheckedTestConnectionRequest,
) -> Result<(), CheckedAuthenticationError> {
    ssh_session::authenticate_ssh(
        session,
        &request.username,
        &request.password,
        &request.private_key,
        &request.private_key_passphrase,
        request.allow_password_fallback,
    )
    .await
    .map_err(|_| CheckedAuthenticationError::Failed)
}

fn preparation_outcome_from_connect_error(
    error: ConnectPreAuthError,
) -> CheckedConnectionPreparationOutcome {
    match error {
        ConnectPreAuthError::HostKeyChallenge(challenge) => {
            CheckedConnectionPreparationOutcome::Challenge(challenge)
        }
        ConnectPreAuthError::HostKeyBlocked(block) => {
            CheckedConnectionPreparationOutcome::Blocked(block)
        }
        other => {
            CheckedConnectionPreparationOutcome::Error(CheckedTestConnectionError::Connect(other))
        }
    }
}

fn preparation_outcome_to_test_outcome(
    outcome: CheckedConnectionPreparationOutcome,
) -> CheckedTestConnectionOutcome {
    match outcome {
        CheckedConnectionPreparationOutcome::Ready(_) => {
            unreachable!("ready preparation is handled before conversion")
        }
        CheckedConnectionPreparationOutcome::Challenge(challenge) => {
            CheckedTestConnectionOutcome::Challenge(challenge)
        }
        CheckedConnectionPreparationOutcome::Blocked(block) => {
            CheckedTestConnectionOutcome::Blocked(block)
        }
        CheckedConnectionPreparationOutcome::Error(error) => {
            CheckedTestConnectionOutcome::Error(error)
        }
    }
}

pub(crate) async fn best_effort_disconnect(
    session: &client::Handle<CheckedHostKeyHandler>,
    reason: &'static str,
) {
    let _ = timeout(
        CHECKED_DISCONNECT_TIMEOUT,
        session.disconnect(Disconnect::ByApplication, reason, "en"),
    )
    .await;
}
