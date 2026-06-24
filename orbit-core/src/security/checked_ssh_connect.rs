use std::fmt;
use std::sync::Arc;

use thiserror::Error;
use tokio::time::timeout;

use super::checked_connect_coordinator::CheckedAuthenticationApproval;
use super::checked_test_connection::{
    authenticate_checked_session, best_effort_disconnect, load_checked_trust_store_generation,
    prepare_checked_connection, CheckedConnectionPreparationOutcome, CheckedTestConnectionError,
    CheckedTestConnectionRequest, CheckedTestTimeoutStage, CHECKED_AUTH_TIMEOUT,
};
use super::host_key_challenge_registry::RegisteredHostKeyChallenge;
use super::host_key_verifier::{HostKeyBlock, SessionSecurityGeneration};
use crate::session_pool::{self, BaseSessionKey, OrbitBaseSession};

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
