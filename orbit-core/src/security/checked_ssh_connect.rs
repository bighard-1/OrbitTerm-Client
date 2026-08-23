use std::fmt;
use std::sync::Arc;

use thiserror::Error;
use tokio::time::timeout;

use super::checked_connect_coordinator::CheckedAuthenticationApproval;
use super::checked_test_connection::{
    authenticate_checked_session, best_effort_disconnect, load_checked_trust_store_generation,
    prepare_checked_connection, prepare_checked_connection_over_stream,
    CheckedConnectionPreparationOutcome, CheckedTestConnectionError, CheckedTestConnectionRequest,
    CheckedTestTimeoutStage, CHECKED_AUTH_TIMEOUT,
};
use super::host_key_challenge_registry::RegisteredHostKeyChallenge;
use super::host_key_verifier::{HostKeyBlock, SessionSecurityGeneration};
use crate::session_pool::{self, BaseSessionKey, OrbitBaseSession, OrbitSshHandle};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CheckedSessionPoolStage {
    CandidateLookup,
    CreationGate,
    ExactLookup,
    Insert,
}

#[derive(Debug, Error)]
pub(crate) enum CheckedSshConnectError {
    #[error("checked SSH connection failed before session pooling")]
    Connection(#[source] CheckedTestConnectionError),
    #[error("checked SSH session pool operation failed")]
    SessionPool { stage: CheckedSessionPoolStage },
}

pub(crate) struct CheckedSshConnected {
    pub(crate) base: Arc<OrbitBaseSession>,
    pub(crate) security_generation: SessionSecurityGeneration,
}

impl fmt::Debug for CheckedSshConnected {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedSshConnected")
            .field("session_id", &self.base.id)
            .field("security_generation", &self.security_generation)
            .finish()
    }
}

pub(crate) enum CheckedSshConnectOutcome {
    Connected(CheckedSshConnected),
    Challenge(Box<RegisteredHostKeyChallenge>),
    Blocked(Box<HostKeyBlock>),
    Error(CheckedSshConnectError),
}

impl fmt::Debug for CheckedSshConnectOutcome {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connected(value) => formatter.debug_tuple("Connected").field(value).finish(),
            Self::Challenge(value) => formatter.debug_tuple("Challenge").field(value).finish(),
            Self::Blocked(value) => formatter.debug_tuple("Blocked").field(value).finish(),
            Self::Error(value) => formatter.debug_tuple("Error").field(value).finish(),
        }
    }
}

pub(crate) async fn run_checked_ssh_connect(
    request: CheckedTestConnectionRequest,
) -> CheckedSshConnectOutcome {
    if request.jump_host().is_some() {
        return run_checked_ssh_connect_via_jump(request).await;
    }
    let initial_generation = match load_checked_trust_store_generation(&request) {
        Ok(value) => value,
        Err(error) => return connection_error(error),
    };
    match session_pool::lookup_verified_session_for_store(
        request.host_identity(),
        request.username(),
        &initial_generation,
    )
    .await
    {
        Ok(Some(base)) => {
            return CheckedSshConnectOutcome::Connected(CheckedSshConnected {
                security_generation: base.metadata.security_generation().clone(),
                base,
            });
        }
        Ok(None) => {}
        Err(_) => return pool_error(CheckedSessionPoolStage::CandidateLookup),
    }

    let prepared = match prepare_checked_connection(&request).await {
        CheckedConnectionPreparationOutcome::Ready(value) => value,
        CheckedConnectionPreparationOutcome::Challenge(value) => {
            return CheckedSshConnectOutcome::Challenge(value);
        }
        CheckedConnectionPreparationOutcome::Blocked(value) => {
            return CheckedSshConnectOutcome::Blocked(value);
        }
        CheckedConnectionPreparationOutcome::Error(error) => return connection_error(error),
    };
    finish_prepared_connection(request, prepared.approval, prepared.session).await
}

async fn run_checked_ssh_connect_via_jump(
    request: CheckedTestConnectionRequest,
) -> CheckedSshConnectOutcome {
    let Some(jump) = request.jump_host() else {
        return connection_error(CheckedTestConnectionError::PreAuthentication(
            super::checked_connect_coordinator::CheckedConnectPreAuthError::VerifiedSlotUnavailable,
        ));
    };
    let jump_request =
        match jump.as_connection_request(
            request.known_hosts_path().to_path_buf(),
            request.request_id().to_string(),
        ) {
            Ok(value) => value,
            Err(_error) => return connection_error(CheckedTestConnectionError::PreAuthentication(
                super::checked_connect_coordinator::CheckedConnectPreAuthError::StoreReloadFailed(
                    super::known_hosts_store::KnownHostsStoreError::InvalidPath,
                ),
            )),
        };
    let prepared_jump = match prepare_checked_connection(&jump_request).await {
        CheckedConnectionPreparationOutcome::Ready(value) => value,
        CheckedConnectionPreparationOutcome::Challenge(value) => {
            return CheckedSshConnectOutcome::Challenge(value)
        }
        CheckedConnectionPreparationOutcome::Blocked(value) => {
            return CheckedSshConnectOutcome::Blocked(value)
        }
        CheckedConnectionPreparationOutcome::Error(value) => return connection_error(value),
    };
    let jump_route_identity = format!(
        "{}|{}|{}|{}",
        jump.route_identity(),
        prepared_jump.approval.verified_host_key().key_algorithm,
        prepared_jump
            .approval
            .verified_host_key()
            .fingerprint_sha256,
        prepared_jump.approval.trust_store_generation().as_hint(),
    );
    let mut jump_session = prepared_jump.session;
    match timeout(
        CHECKED_AUTH_TIMEOUT,
        authenticate_checked_session(&mut jump_session, &jump_request),
    )
    .await
    {
        Err(_) => {
            best_effort_disconnect(&jump_session, "jump host authentication timed out").await;
            return connection_error(CheckedTestConnectionError::Timeout {
                stage: CheckedTestTimeoutStage::Authentication,
            });
        }
        Ok(Err(error)) => {
            best_effort_disconnect(&jump_session, "jump host authentication failed").await;
            return connection_error(CheckedTestConnectionError::Authentication(error));
        }
        Ok(Ok(())) => {}
    }

    let stream = match timeout(
        super::checked_test_connection::CHECKED_CONNECT_TIMEOUT,
        jump_session.channel_open_direct_tcpip(
            request.host_identity().normalized_host.clone(),
            u32::from(request.host_identity().port),
            "127.0.0.1",
            0,
        ),
    )
    .await
    {
        Err(_) => {
            best_effort_disconnect(&jump_session, "jump tunnel timed out").await;
            return connection_error(CheckedTestConnectionError::Timeout {
                stage: CheckedTestTimeoutStage::Connect,
            });
        }
        Ok(Err(error)) => {
            best_effort_disconnect(&jump_session, "jump tunnel failed").await;
            return connection_error(CheckedTestConnectionError::Connect(
                super::connect_pre_auth_error::ConnectPreAuthError::Protocol(error),
            ));
        }
        Ok(Ok(channel)) => channel.into_stream(),
    };
    let prepared_target = match prepare_checked_connection_over_stream(&request, stream).await {
        CheckedConnectionPreparationOutcome::Ready(value) => value,
        CheckedConnectionPreparationOutcome::Challenge(value) => {
            best_effort_disconnect(&jump_session, "destination host key challenge").await;
            return CheckedSshConnectOutcome::Challenge(value);
        }
        CheckedConnectionPreparationOutcome::Blocked(value) => {
            best_effort_disconnect(&jump_session, "destination host key blocked").await;
            return CheckedSshConnectOutcome::Blocked(value);
        }
        CheckedConnectionPreparationOutcome::Error(value) => {
            best_effort_disconnect(&jump_session, "destination connection failed").await;
            return connection_error(value);
        }
    };
    finish_prepared_connection_via_jump(
        request,
        prepared_target.approval,
        prepared_target.session,
        jump_session,
        jump_route_identity,
    )
    .await
}

async fn finish_prepared_connection(
    request: CheckedTestConnectionRequest,
    approval: CheckedAuthenticationApproval,
    mut session: russh::client::Handle<super::checked_host_key_handler::CheckedHostKeyHandler>,
) -> CheckedSshConnectOutcome {
    let security_generation = approval.session_security_generation();
    let key = match BaseSessionKey::checked(request.username(), security_generation.clone()) {
        Ok(value) => value,
        Err(_) => {
            best_effort_disconnect(&session, "invalid verified session generation").await;
            return pool_error(CheckedSessionPoolStage::CreationGate);
        }
    };
    let gate = match session_pool::base_session_creation_gate(&key) {
        Ok(value) => value,
        Err(_) => {
            best_effort_disconnect(&session, "session pool unavailable").await;
            return pool_error(CheckedSessionPoolStage::CreationGate);
        }
    };
    let _guard = gate.lock().await;

    match session_pool::try_reuse_checked_base_session(
        request.username(),
        security_generation.clone(),
    )
    .await
    {
        Ok(Some(base)) => {
            best_effort_disconnect(&session, "verified session already pooled").await;
            return CheckedSshConnectOutcome::Connected(CheckedSshConnected {
                base,
                security_generation,
            });
        }
        Ok(None) => {}
        Err(_) => {
            best_effort_disconnect(&session, "session pool lookup failed").await;
            return pool_error(CheckedSessionPoolStage::ExactLookup);
        }
    }

    match timeout(
        CHECKED_AUTH_TIMEOUT,
        authenticate_checked_session(&mut session, &request),
    )
    .await
    {
        Err(_) => {
            best_effort_disconnect(&session, "authentication timed out").await;
            return connection_error(CheckedTestConnectionError::Timeout {
                stage: CheckedTestTimeoutStage::Authentication,
            });
        }
        Ok(Err(error)) => {
            best_effort_disconnect(&session, "authentication failed").await;
            return connection_error(CheckedTestConnectionError::Authentication(error));
        }
        Ok(Ok(())) => {}
    }

    match session_pool::insert_verified_base_session(
        session,
        request.username(),
        security_generation.clone(),
    ) {
        Ok(base) => CheckedSshConnectOutcome::Connected(CheckedSshConnected {
            base,
            security_generation,
        }),
        Err(_) => pool_error(CheckedSessionPoolStage::Insert),
    }
}

async fn finish_prepared_connection_via_jump(
    request: CheckedTestConnectionRequest,
    approval: CheckedAuthenticationApproval,
    mut target_session: russh::client::Handle<
        super::checked_host_key_handler::CheckedHostKeyHandler,
    >,
    jump_session: russh::client::Handle<super::checked_host_key_handler::CheckedHostKeyHandler>,
    route_identity: String,
) -> CheckedSshConnectOutcome {
    let security_generation = approval.session_security_generation();
    let key = match BaseSessionKey::checked_with_route(
        request.username(),
        security_generation.clone(),
        Some(route_identity.clone()),
    ) {
        Ok(value) => value,
        Err(_) => {
            best_effort_disconnect(&target_session, "invalid verified session generation").await;
            best_effort_disconnect(&jump_session, "invalid verified session generation").await;
            return pool_error(CheckedSessionPoolStage::CreationGate);
        }
    };
    let gate = match session_pool::base_session_creation_gate(&key) {
        Ok(value) => value,
        Err(_) => {
            best_effort_disconnect(&target_session, "session pool unavailable").await;
            best_effort_disconnect(&jump_session, "session pool unavailable").await;
            return pool_error(CheckedSessionPoolStage::CreationGate);
        }
    };
    let _guard = gate.lock().await;
    match session_pool::try_reuse_checked_base_session_with_route(
        request.username(),
        security_generation.clone(),
        route_identity.clone(),
    )
    .await
    {
        Ok(Some(base)) => {
            best_effort_disconnect(&target_session, "verified jump session already pooled").await;
            best_effort_disconnect(&jump_session, "verified jump session already pooled").await;
            return CheckedSshConnectOutcome::Connected(CheckedSshConnected {
                base,
                security_generation,
            });
        }
        Ok(None) => {}
        Err(_) => {
            best_effort_disconnect(&target_session, "session pool lookup failed").await;
            best_effort_disconnect(&jump_session, "session pool lookup failed").await;
            return pool_error(CheckedSessionPoolStage::ExactLookup);
        }
    }
    match timeout(
        CHECKED_AUTH_TIMEOUT,
        authenticate_checked_session(&mut target_session, &request),
    )
    .await
    {
        Err(_) => {
            best_effort_disconnect(&target_session, "destination authentication timed out").await;
            best_effort_disconnect(&jump_session, "destination authentication timed out").await;
            return connection_error(CheckedTestConnectionError::Timeout {
                stage: CheckedTestTimeoutStage::Authentication,
            });
        }
        Ok(Err(error)) => {
            best_effort_disconnect(&target_session, "destination authentication failed").await;
            best_effort_disconnect(&jump_session, "destination authentication failed").await;
            return connection_error(CheckedTestConnectionError::Authentication(error));
        }
        Ok(Ok(())) => {}
    }
    match session_pool::insert_verified_base_session_with_route(
        OrbitSshHandle::CheckedViaJump {
            target: target_session,
            jump: jump_session,
        },
        request.username(),
        security_generation.clone(),
        Some(route_identity),
    ) {
        Ok(base) => CheckedSshConnectOutcome::Connected(CheckedSshConnected {
            base,
            security_generation,
        }),
        Err(_) => pool_error(CheckedSessionPoolStage::Insert),
    }
}

fn connection_error(error: CheckedTestConnectionError) -> CheckedSshConnectOutcome {
    CheckedSshConnectOutcome::Error(CheckedSshConnectError::Connection(error))
}

fn pool_error(stage: CheckedSessionPoolStage) -> CheckedSshConnectOutcome {
    CheckedSshConnectOutcome::Error(CheckedSshConnectError::SessionPool { stage })
}

#[cfg(test)]
pub(crate) fn authentication_error_for_tests() -> CheckedSshConnectError {
    CheckedSshConnectError::Connection(CheckedTestConnectionError::Authentication(
        super::checked_test_connection::CheckedAuthenticationError::Failed,
    ))
}
