use serde::{Deserialize, Serialize};

use super::host_key_challenge_registry::{AcceptedHostKeyChallenge, PendingChallengeState};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiProtocolError};
use super::host_key_ffi_protocol::{
    validate_challenge_id, validate_host_fields, HostKeyFfiResultKind, HOST_KEY_FFI_SCHEMA_VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyChallengeAcceptedPayload {
    pub challenge_id: String,
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub status: HostKeyChallengeAcceptanceStatus,
}

impl From<&AcceptedHostKeyChallenge> for HostKeyChallengeAcceptedPayload {
    fn from(challenge: &AcceptedHostKeyChallenge) -> Self {
        Self {
            challenge_id: challenge.challenge_id.as_str().to_string(),
            host: challenge.host_identity.original_host.clone(),
            normalized_host: challenge.host_identity.normalized_host.clone(),
            port: challenge.host_identity.port,
            lookup_token: challenge.host_identity.lookup_token.clone(),
            key_algorithm: challenge.key_algorithm.clone(),
            fingerprint_sha256: challenge.fingerprint_sha256.clone(),
            status: HostKeyChallengeAcceptanceStatus::AcceptedNotPersisted,
        }
    }
}

impl HostKeyChallengeAcceptedPayload {
    pub(super) fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_challenge_id(&self.challenge_id)?;
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )?;
        if self.status != HostKeyChallengeAcceptanceStatus::AcceptedNotPersisted {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyChallengeAcceptanceStatus {
    AcceptedNotPersisted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyChallengeStatusPayload {
    pub challenge_id: String,
    pub state: HostKeyChallengeStatus,
}

impl HostKeyChallengeStatusPayload {
    pub fn new(challenge_id: String, state: PendingChallengeState) -> Self {
        Self {
            challenge_id,
            state: state.into(),
        }
    }

    pub(super) fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_challenge_id(&self.challenge_id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyChallengeStatus {
    Pending,
    Accepted,
    Persisted,
    Rejected,
    Expired,
    InvalidatedByStoreChange,
}

impl From<PendingChallengeState> for HostKeyChallengeStatus {
    fn from(state: PendingChallengeState) -> Self {
        match state {
            PendingChallengeState::Pending => Self::Pending,
            PendingChallengeState::Accepted => Self::Accepted,
            PendingChallengeState::Persisted => Self::Persisted,
            PendingChallengeState::Rejected => Self::Rejected,
            PendingChallengeState::Expired => Self::Expired,
            PendingChallengeState::InvalidatedByStoreChange => Self::InvalidatedByStoreChange,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyCleanupCompletedPayload {
    pub expired_count: u64,
}

impl HostKeyCleanupCompletedPayload {
    pub(super) const fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyProtocolVersionPayload {
    pub schema_version: u32,
    pub supported_kinds: Vec<HostKeyFfiResultKind>,
    pub supported_error_codes: Vec<HostKeyFfiErrorCode>,
}

impl HostKeyProtocolVersionPayload {
    pub fn current() -> Self {
        Self {
            schema_version: HOST_KEY_FFI_SCHEMA_VERSION,
            supported_kinds: HostKeyFfiResultKind::ALL.to_vec(),
            supported_error_codes: HostKeyFfiErrorCode::ALL.to_vec(),
        }
    }

    pub(super) fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.schema_version != HOST_KEY_FFI_SCHEMA_VERSION
            || self.supported_kinds.as_slice() != HostKeyFfiResultKind::ALL
            || self.supported_error_codes.as_slice() != HostKeyFfiErrorCode::ALL
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}
