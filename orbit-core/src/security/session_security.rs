use std::fmt;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::SystemTime;

use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};
use thiserror::Error;

use super::host_key::HostIdentity;
use super::host_key_verifier::SessionSecurityGeneration;
use super::known_hosts_store::normalize_algorithm;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SessionLifecycleState {
    Active = 0,
    Draining = 1,
    Terminating = 2,
    Closed = 3,
}

impl SessionLifecycleState {
    fn from_byte(value: u8) -> Result<Self, SessionSecurityError> {
        match value {
            0 => Ok(Self::Active),
            1 => Ok(Self::Draining),
            2 => Ok(Self::Terminating),
            3 => Ok(Self::Closed),
            _ => Err(SessionSecurityError::InternalInvariantViolation),
        }
    }

    fn can_transition_to(self, target: Self) -> bool {
        self == target
            || matches!(
                (self, target),
                (
                    Self::Active,
                    Self::Draining | Self::Terminating | Self::Closed
                ) | (Self::Draining, Self::Terminating | Self::Closed)
                    | (Self::Terminating, Self::Closed)
            )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SessionSecurityError {
    #[error("legacy unverified session cannot satisfy a checked request")]
    LegacySessionNotAllowed,
    #[error("checked session lookup requires a verified security generation")]
    VerifiedSessionRequired,
    #[error("session security generation does not match the request")]
    SecurityGenerationMismatch,
    #[error("session is draining and cannot open new channels")]
    SessionDraining,
    #[error("session is terminating and cannot open new channels")]
    SessionTerminating,
    #[error("session is closed and cannot open new channels")]
    SessionClosed,
    #[error("checked session generation is invalid")]
    InvalidCheckedGeneration,
    #[error("session identity is invalid")]
    InvalidSessionIdentity,
    #[error("session lifecycle transition is invalid")]
    InvalidStateTransition,
    #[error("session security invariant failed")]
    InternalInvariantViolation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CheckedChannelAccessError {
    #[error("base session was not found")]
    SessionNotFound,
    #[error("legacy unverified session cannot open a checked channel")]
    LegacySessionNotAllowed,
    #[error("checked channel requires a host-key-verified session")]
    VerifiedSessionRequired,
    #[error("session security generation does not match the checked channel")]
    SecurityGenerationMismatch,
    #[error("session is draining and cannot open a checked channel")]
    SessionDraining,
    #[error("session is terminating and cannot open a checked channel")]
    SessionTerminating,
    #[error("session is closed and cannot open a checked channel")]
    SessionClosed,
    #[error("SSH channel could not be opened")]
    ChannelOpenFailed,
    #[error("SFTP subsystem request failed")]
    SubsystemRequestFailed,
    #[error("SFTP session registration failed")]
    SftpRegistrationFailed,
    #[error("checked channel security invariant failed")]
    InternalInvariantViolation,
}

impl From<SessionSecurityError> for CheckedChannelAccessError {
    fn from(value: SessionSecurityError) -> Self {
        match value {
            SessionSecurityError::LegacySessionNotAllowed => Self::LegacySessionNotAllowed,
            SessionSecurityError::VerifiedSessionRequired => Self::VerifiedSessionRequired,
            SessionSecurityError::SecurityGenerationMismatch
            | SessionSecurityError::InvalidCheckedGeneration
            | SessionSecurityError::InvalidSessionIdentity => Self::SecurityGenerationMismatch,
            SessionSecurityError::SessionDraining => Self::SessionDraining,
            SessionSecurityError::SessionTerminating => Self::SessionTerminating,
            SessionSecurityError::SessionClosed => Self::SessionClosed,
            SessionSecurityError::InvalidStateTransition
            | SessionSecurityError::InternalInvariantViolation => Self::InternalInvariantViolation,
        }
    }
}

pub struct BaseSessionMetadata {
    security_generation: SessionSecurityGeneration,
    created_at: SystemTime,
    state: AtomicU8,
}

impl fmt::Debug for BaseSessionMetadata {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BaseSessionMetadata")
            .field("security_generation", &self.security_generation)
            .field("created_at", &self.created_at)
            .field("state", &self.state())
            .finish()
    }
}

impl BaseSessionMetadata {
    pub fn new_legacy() -> Self {
        Self::new(SessionSecurityGeneration::LegacyUnverified)
    }

    pub fn new_checked(
        security_generation: SessionSecurityGeneration,
    ) -> Result<Self, SessionSecurityError> {
        validate_checked_generation(&security_generation)?;
        Ok(Self::new(security_generation))
    }

    fn new(security_generation: SessionSecurityGeneration) -> Self {
        Self {
            security_generation,
            created_at: SystemTime::now(),
            state: AtomicU8::new(SessionLifecycleState::Active as u8),
        }
    }

    pub fn security_generation(&self) -> &SessionSecurityGeneration {
        &self.security_generation
    }

    pub fn created_at(&self) -> SystemTime {
        self.created_at
    }

    pub fn state(&self) -> Result<SessionLifecycleState, SessionSecurityError> {
        SessionLifecycleState::from_byte(self.state.load(Ordering::Acquire))
    }

    pub fn transition_to(
        &self,
        target: SessionLifecycleState,
    ) -> Result<SessionLifecycleState, SessionSecurityError> {
        loop {
            let current_raw = self.state.load(Ordering::Acquire);
            let current = SessionLifecycleState::from_byte(current_raw)?;
            if !current.can_transition_to(target) {
                return Err(SessionSecurityError::InvalidStateTransition);
            }
            if current == target {
                return Ok(current);
            }
            match self.state.compare_exchange(
                current_raw,
                target as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Ok(target),
                Err(_) => continue,
            }
        }
    }

    pub fn assert_allows_new_channel(
        &self,
        required: &SessionSecurityGeneration,
    ) -> Result<(), SessionSecurityError> {
        match self.state()? {
            SessionLifecycleState::Active => {}
            SessionLifecycleState::Draining => {
                return Err(SessionSecurityError::SessionDraining);
            }
            SessionLifecycleState::Terminating => {
                return Err(SessionSecurityError::SessionTerminating);
            }
            SessionLifecycleState::Closed => return Err(SessionSecurityError::SessionClosed),
        }

        match (required, &self.security_generation) {
            (
                SessionSecurityGeneration::HostKeyVerified { .. },
                SessionSecurityGeneration::LegacyUnverified,
            ) => Err(SessionSecurityError::LegacySessionNotAllowed),
            (expected, actual) if expected == actual => Ok(()),
            _ => Err(SessionSecurityError::SecurityGenerationMismatch),
        }
    }
}

pub fn validate_checked_generation(
    generation: &SessionSecurityGeneration,
) -> Result<(), SessionSecurityError> {
    match generation {
        SessionSecurityGeneration::LegacyUnverified => {
            Err(SessionSecurityError::VerifiedSessionRequired)
        }
        SessionSecurityGeneration::HostKeyVerified {
            host_identity,
            key_algorithm,
            fingerprint_sha256,
            ..
        } => {
            let reparsed = HostIdentity::parse(&host_identity.original_host, host_identity.port)
                .map_err(|_| SessionSecurityError::InvalidCheckedGeneration)?;
            if &reparsed != host_identity
                || normalize_algorithm(key_algorithm).as_deref() != Ok(key_algorithm.as_str())
                || !valid_sha256_fingerprint(fingerprint_sha256)
            {
                return Err(SessionSecurityError::InvalidCheckedGeneration);
            }
            Ok(())
        }
    }
}

fn valid_sha256_fingerprint(value: &str) -> bool {
    value
        .strip_prefix("SHA256:")
        .and_then(|encoded| STANDARD_NO_PAD.decode(encoded).ok())
        .is_some_and(|digest| digest.len() == 32)
}
