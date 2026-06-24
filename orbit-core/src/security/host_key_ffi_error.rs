use std::io;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::host_key_challenge_registry::{
    ChallengeId, ChallengeRegistryError, PendingChallengeState,
};
use super::host_key_verifier::HostKeyVerificationError;
use super::known_hosts_store::KnownHostsStoreError;
use super::session_security::CheckedChannelAccessError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiErrorCode {
    HostKeyUnknown,
    HostKeyChanged,
    HostKeyRevoked,
    HostKeyUnsupported,
    HostKeyInvalid,
    KnownHostsReadFailed,
    KnownHostsSaveFailed,
    KnownHostsPermissionDenied,
    KnownHostsFileTooLarge,
    ChallengeNotFound,
    ChallengeExpired,
    ChallengeAlreadyResolved,
    ChallengeMismatch,
    PendingLimitReached,
    PerHostPendingLimitReached,
    RelatedRequestLimitReached,
    InvalidRequest,
    InvalidJson,
    InvalidUtf8,
    FfiInternalError,
    SshConnectFailed,
    SshAuthFailed,
    SshTimeout,
    SessionPoolFailed,
    SessionNotFound,
    LegacySessionNotAllowed,
    VerifiedSessionRequired,
    SecurityGenerationMismatch,
    SessionDraining,
    SessionTerminating,
    SessionClosed,
    ChannelOpenFailed,
    InvalidPtySize,
    PtyRequestFailed,
    ShellStartFailed,
    SubsystemRequestFailed,
    SftpRegistrationFailed,
    InvalidCommand,
    CommandTooLarge,
    InvalidExecOptions,
    ExecRequestFailed,
    ExecOutputFailed,
    ExecOutputLimitExceeded,
    ExecTimeout,
    ExecCommandFailed,
    MonitorSnapshotFailed,
    DockerInvalidContainerId,
    DockerInvalidContainerName,
    DockerInvalidAction,
    DockerInvalidLogsTail,
    DockerInvalidUpdateOption,
    DockerCommandFailed,
    DockerParseFailed,
}

impl HostKeyFfiErrorCode {
    pub const ALL: &'static [Self] = &[
        Self::HostKeyUnknown,
        Self::HostKeyChanged,
        Self::HostKeyRevoked,
        Self::HostKeyUnsupported,
        Self::HostKeyInvalid,
        Self::KnownHostsReadFailed,
        Self::KnownHostsSaveFailed,
        Self::KnownHostsPermissionDenied,
        Self::KnownHostsFileTooLarge,
        Self::ChallengeNotFound,
        Self::ChallengeExpired,
        Self::ChallengeAlreadyResolved,
        Self::ChallengeMismatch,
        Self::PendingLimitReached,
        Self::PerHostPendingLimitReached,
        Self::RelatedRequestLimitReached,
        Self::InvalidRequest,
        Self::InvalidJson,
        Self::InvalidUtf8,
        Self::FfiInternalError,
        Self::SshConnectFailed,
        Self::SshAuthFailed,
        Self::SshTimeout,
        Self::SessionPoolFailed,
        Self::SessionNotFound,
        Self::LegacySessionNotAllowed,
        Self::VerifiedSessionRequired,
        Self::SecurityGenerationMismatch,
        Self::SessionDraining,
        Self::SessionTerminating,
        Self::SessionClosed,
        Self::ChannelOpenFailed,
        Self::InvalidPtySize,
        Self::PtyRequestFailed,
        Self::ShellStartFailed,
        Self::SubsystemRequestFailed,
        Self::SftpRegistrationFailed,
        Self::InvalidCommand,
        Self::CommandTooLarge,
        Self::InvalidExecOptions,
        Self::ExecRequestFailed,
        Self::ExecOutputFailed,
        Self::ExecOutputLimitExceeded,
        Self::ExecTimeout,
        Self::ExecCommandFailed,
        Self::MonitorSnapshotFailed,
        Self::DockerInvalidContainerId,
        Self::DockerInvalidContainerName,
        Self::DockerInvalidAction,
        Self::DockerInvalidLogsTail,
        Self::DockerInvalidUpdateOption,
        Self::DockerCommandFailed,
        Self::DockerParseFailed,
    ];

    pub const fn message_key(self) -> &'static str {
        match self {
            Self::HostKeyUnknown => "error.host_key.unknown",
            Self::HostKeyChanged => "error.host_key.changed",
            Self::HostKeyRevoked => "error.host_key.revoked",
            Self::HostKeyUnsupported => "error.host_key.unsupported",
            Self::HostKeyInvalid => "error.host_key.invalid",
            Self::KnownHostsReadFailed => "error.known_hosts.read_failed",
            Self::KnownHostsSaveFailed => "error.known_hosts.save_failed",
            Self::KnownHostsPermissionDenied => "error.known_hosts.permission_denied",
            Self::KnownHostsFileTooLarge => "error.known_hosts.file_too_large",
            Self::ChallengeNotFound => "error.host_key.challenge_not_found",
            Self::ChallengeExpired => "error.host_key.challenge_expired",
            Self::ChallengeAlreadyResolved => "error.host_key.challenge_already_resolved",
            Self::ChallengeMismatch => "error.host_key.challenge_mismatch",
            Self::PendingLimitReached => "error.host_key.pending_limit_reached",
            Self::PerHostPendingLimitReached => "error.host_key.per_host_pending_limit_reached",
            Self::RelatedRequestLimitReached => "error.host_key.related_request_limit_reached",
            Self::InvalidRequest => "error.request.invalid",
            Self::InvalidJson => "error.json.invalid",
            Self::InvalidUtf8 => "error.utf8.invalid",
            Self::FfiInternalError => "error.ffi.internal",
            Self::SshConnectFailed => "error.ssh.connect_failed",
            Self::SshAuthFailed => "error.ssh.auth_failed",
            Self::SshTimeout => "error.ssh.timeout",
            Self::SessionPoolFailed => "error.session_pool.failed",
            Self::SessionNotFound => "error.session.not_found",
            Self::LegacySessionNotAllowed => "error.session.legacy_not_allowed",
            Self::VerifiedSessionRequired => "error.session.verified_required",
            Self::SecurityGenerationMismatch => "error.session.security_generation_mismatch",
            Self::SessionDraining => "error.session.draining",
            Self::SessionTerminating => "error.session.terminating",
            Self::SessionClosed => "error.session.closed",
            Self::ChannelOpenFailed => "error.channel.open_failed",
            Self::InvalidPtySize => "error.terminal.invalid_pty_size",
            Self::PtyRequestFailed => "error.terminal.pty_request_failed",
            Self::ShellStartFailed => "error.terminal.shell_start_failed",
            Self::SubsystemRequestFailed => "error.sftp.subsystem_request_failed",
            Self::SftpRegistrationFailed => "error.sftp.registration_failed",
            Self::InvalidCommand => "error.exec.invalid_command",
            Self::CommandTooLarge => "error.exec.command_too_large",
            Self::InvalidExecOptions => "error.exec.invalid_options",
            Self::ExecRequestFailed => "error.exec.request_failed",
            Self::ExecOutputFailed => "error.exec.output_failed",
            Self::ExecOutputLimitExceeded => "error.exec.output_limit_exceeded",
            Self::ExecTimeout => "error.exec.timeout",
            Self::ExecCommandFailed => "error.exec.command_failed",
            Self::MonitorSnapshotFailed => "error.monitor.snapshot_failed",
            Self::DockerInvalidContainerId => "error.docker.invalid_container_id",
            Self::DockerInvalidContainerName => "error.docker.invalid_container_name",
            Self::DockerInvalidAction => "error.docker.invalid_action",
            Self::DockerInvalidLogsTail => "error.docker.invalid_logs_tail",
            Self::DockerInvalidUpdateOption => "error.docker.invalid_update_option",
            Self::DockerCommandFailed => "error.docker.command_failed",
            Self::DockerParseFailed => "error.docker.parse_failed",
        }
    }

    pub const fn retryable(self) -> bool {
        matches!(
            self,
            Self::KnownHostsReadFailed
                | Self::KnownHostsSaveFailed
                | Self::ChallengeNotFound
                | Self::ChallengeExpired
                | Self::PendingLimitReached
                | Self::PerHostPendingLimitReached
                | Self::RelatedRequestLimitReached
                | Self::SshConnectFailed
                | Self::SshTimeout
                | Self::ExecTimeout
                | Self::SessionNotFound
                | Self::SessionDraining
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyFfiErrorPayload {
    pub code: HostKeyFfiErrorCode,
    pub message_key: String,
    pub detail_code: Option<String>,
    pub retryable: bool,
    pub request_id: Option<String>,
    pub challenge_id: Option<String>,
}

impl HostKeyFfiErrorPayload {
    pub fn new(
        code: HostKeyFfiErrorCode,
        detail_code: Option<&str>,
        request_id: Option<String>,
        challenge_id: Option<String>,
    ) -> Self {
        Self {
            code,
            message_key: code.message_key().to_string(),
            detail_code: detail_code.map(str::to_string),
            retryable: code.retryable(),
            request_id,
            challenge_id,
        }
    }

    pub fn from_verification_error(
        error: &HostKeyVerificationError,
        request_id: Option<String>,
    ) -> Self {
        match error {
            HostKeyVerificationError::InvalidHostIdentity => Self::new(
                HostKeyFfiErrorCode::HostKeyInvalid,
                Some("invalid_host_identity"),
                request_id,
                None,
            ),
            HostKeyVerificationError::InvalidAlgorithm => Self::new(
                HostKeyFfiErrorCode::HostKeyInvalid,
                Some("invalid_algorithm"),
                request_id,
                None,
            ),
            HostKeyVerificationError::InvalidPublicKey
            | HostKeyVerificationError::Fingerprint(_) => Self::new(
                HostKeyFfiErrorCode::HostKeyInvalid,
                Some("invalid_public_key"),
                request_id,
                None,
            ),
            HostKeyVerificationError::StoreUnavailable(store_error) => {
                Self::from_store_error(store_error, request_id, None)
            }
            HostKeyVerificationError::MatcherInvariant => Self::new(
                HostKeyFfiErrorCode::FfiInternalError,
                Some("matcher_invariant"),
                request_id,
                None,
            ),
        }
    }

    pub fn from_checked_channel_error(
        error: CheckedChannelAccessError,
        request_id: Option<String>,
    ) -> Self {
        let (code, detail) = match error {
            CheckedChannelAccessError::SessionNotFound => {
                (HostKeyFfiErrorCode::SessionNotFound, "session_not_found")
            }
            CheckedChannelAccessError::LegacySessionNotAllowed => (
                HostKeyFfiErrorCode::LegacySessionNotAllowed,
                "legacy_session_not_allowed",
            ),
            CheckedChannelAccessError::VerifiedSessionRequired => (
                HostKeyFfiErrorCode::VerifiedSessionRequired,
                "verified_session_required",
            ),
            CheckedChannelAccessError::SecurityGenerationMismatch => (
                HostKeyFfiErrorCode::SecurityGenerationMismatch,
                "security_generation_mismatch",
            ),
            CheckedChannelAccessError::SessionDraining => {
                (HostKeyFfiErrorCode::SessionDraining, "session_draining")
            }
            CheckedChannelAccessError::SessionTerminating => (
                HostKeyFfiErrorCode::SessionTerminating,
                "session_terminating",
            ),
            CheckedChannelAccessError::SessionClosed => {
                (HostKeyFfiErrorCode::SessionClosed, "session_closed")
            }
            CheckedChannelAccessError::ChannelOpenFailed => (
                HostKeyFfiErrorCode::ChannelOpenFailed,
                "channel_open_failed",
            ),
            CheckedChannelAccessError::SubsystemRequestFailed => (
                HostKeyFfiErrorCode::SubsystemRequestFailed,
                "subsystem_request_failed",
            ),
            CheckedChannelAccessError::SftpRegistrationFailed => (
                HostKeyFfiErrorCode::SftpRegistrationFailed,
                "sftp_registration_failed",
            ),
            CheckedChannelAccessError::InternalInvariantViolation => (
                HostKeyFfiErrorCode::FfiInternalError,
                "checked_channel_invariant",
            ),
        };
        Self::new(code, Some(detail), request_id, None)
    }

    pub fn from_registry_error(
        error: &ChallengeRegistryError,
        request_id: Option<String>,
        challenge_id: Option<String>,
    ) -> Self {
        let (code, detail) = match error {
            ChallengeRegistryError::InvalidChallengeId
            | ChallengeRegistryError::InvalidCorrelationValue
            | ChallengeRegistryError::InvalidConfiguration => {
                (HostKeyFfiErrorCode::InvalidRequest, "invalid_request")
            }
            ChallengeRegistryError::ChallengeNotFound => (
                HostKeyFfiErrorCode::ChallengeNotFound,
                "challenge_not_found",
            ),
            ChallengeRegistryError::ChallengeExpired => {
                (HostKeyFfiErrorCode::ChallengeExpired, "challenge_expired")
            }
            ChallengeRegistryError::ChallengeAlreadyResolved { state } => (
                HostKeyFfiErrorCode::ChallengeAlreadyResolved,
                resolved_state_detail(*state),
            ),
            ChallengeRegistryError::PendingLimitReached => (
                HostKeyFfiErrorCode::PendingLimitReached,
                "global_pending_limit",
            ),
            ChallengeRegistryError::PerHostPendingLimitReached => (
                HostKeyFfiErrorCode::PerHostPendingLimitReached,
                "per_host_pending_limit",
            ),
            ChallengeRegistryError::RelatedRequestLimitReached => (
                HostKeyFfiErrorCode::RelatedRequestLimitReached,
                "related_request_limit",
            ),
            ChallengeRegistryError::PublicKeyTooLarge { .. }
            | ChallengeRegistryError::InvalidPublicKey
            | ChallengeRegistryError::InvalidAlgorithm
            | ChallengeRegistryError::InvalidHostIdentity
            | ChallengeRegistryError::InvalidChallengeDraft => (
                HostKeyFfiErrorCode::HostKeyInvalid,
                "invalid_host_key_input",
            ),
            ChallengeRegistryError::StoreGenerationMismatch => (
                HostKeyFfiErrorCode::ChallengeMismatch,
                "store_generation_mismatch",
            ),
            ChallengeRegistryError::ChallengeBindingMismatch => (
                HostKeyFfiErrorCode::ChallengeMismatch,
                "challenge_binding_mismatch",
            ),
            ChallengeRegistryError::IdGenerationFailed
            | ChallengeRegistryError::IdCollisionLimitReached
            | ChallengeRegistryError::EquivalentChallengeIndexCorrupt
            | ChallengeRegistryError::InternalInvariantViolation => {
                (HostKeyFfiErrorCode::FfiInternalError, "registry_internal")
            }
        };
        Self::new(code, Some(detail), request_id, challenge_id)
    }

    pub fn from_store_error(
        error: &KnownHostsStoreError,
        request_id: Option<String>,
        challenge_id: Option<String>,
    ) -> Self {
        let (code, detail) = match error {
            KnownHostsStoreError::ReadFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::TemporaryFileCreateFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::WriteFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::FlushFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::SyncFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::AtomicReplaceFailed {
                kind: io::ErrorKind::PermissionDenied,
            }
            | KnownHostsStoreError::PermissionFailed {
                kind: io::ErrorKind::PermissionDenied,
            } => (
                HostKeyFfiErrorCode::KnownHostsPermissionDenied,
                "permission_denied",
            ),
            KnownHostsStoreError::ReadFailed { .. } | KnownHostsStoreError::InvalidPath => {
                (HostKeyFfiErrorCode::KnownHostsReadFailed, "read_failed")
            }
            KnownHostsStoreError::FileTooLarge { .. } => (
                HostKeyFfiErrorCode::KnownHostsFileTooLarge,
                "file_too_large",
            ),
            KnownHostsStoreError::InvalidUtf8 => {
                (HostKeyFfiErrorCode::InvalidUtf8, "known_hosts_invalid_utf8")
            }
            KnownHostsStoreError::TemporaryFileCreateFailed { .. }
            | KnownHostsStoreError::WriteFailed { .. }
            | KnownHostsStoreError::FlushFailed { .. }
            | KnownHostsStoreError::SyncFailed { .. }
            | KnownHostsStoreError::AtomicReplaceFailed { .. }
            | KnownHostsStoreError::PermissionFailed { .. } => {
                (HostKeyFfiErrorCode::KnownHostsSaveFailed, "save_failed")
            }
            KnownHostsStoreError::InvalidPublicKey | KnownHostsStoreError::InvalidAlgorithm => {
                (HostKeyFfiErrorCode::HostKeyInvalid, "invalid_store_input")
            }
            KnownHostsStoreError::InvalidComment => {
                (HostKeyFfiErrorCode::InvalidRequest, "invalid_comment")
            }
            KnownHostsStoreError::ChangedKeyConflict => {
                (HostKeyFfiErrorCode::HostKeyChanged, "changed_key_conflict")
            }
            KnownHostsStoreError::RevokedConflict => {
                (HostKeyFfiErrorCode::HostKeyRevoked, "revoked_key_conflict")
            }
            KnownHostsStoreError::UnsupportedMarker => (
                HostKeyFfiErrorCode::HostKeyUnsupported,
                "unsupported_marker",
            ),
            KnownHostsStoreError::TrustedRecordNotFound
            | KnownHostsStoreError::AmbiguousHostPattern => (
                HostKeyFfiErrorCode::ChallengeMismatch,
                "store_record_mismatch",
            ),
        };
        Self::new(code, Some(detail), request_id, challenge_id)
    }

    pub(crate) fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.message_key != self.code.message_key()
            || self.retryable != self.code.retryable()
            || self.message_key.is_empty()
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        if let Some(detail) = &self.detail_code {
            if detail.is_empty()
                || detail.len() > 128
                || !detail
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
            {
                return Err(HostKeyFfiProtocolError::InvalidPayload);
            }
        }
        if let Some(challenge_id) = &self.challenge_id {
            ChallengeId::parse(challenge_id)
                .map_err(|_| HostKeyFfiProtocolError::InvalidPayload)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HostKeyFfiProtocolError {
    #[error("host key FFI JSON is invalid")]
    InvalidJson,
    #[error("host key FFI schema version {received} is unsupported")]
    UnsupportedSchemaVersion { received: u32 },
    #[error("host key FFI envelope is invalid")]
    InvalidEnvelope,
    #[error("host key FFI data payload is missing")]
    MissingDataPayload,
    #[error("host key FFI error payload is missing")]
    MissingErrorPayload,
    #[error("host key FFI payload is invalid")]
    InvalidPayload,
    #[error("host key FFI request identifiers do not match")]
    RequestIdMismatch,
    #[error("host key FFI timestamp is invalid")]
    InvalidTimestamp,
    #[error("host key FFI serialization failed")]
    SerializationFailed,
    #[error("legacy unverified session cannot be represented as checked")]
    LegacySessionNotAllowed,
}

impl HostKeyFfiProtocolError {
    pub fn to_error_payload(&self, request_id: Option<String>) -> HostKeyFfiErrorPayload {
        let (code, detail) = match self {
            Self::InvalidJson => (HostKeyFfiErrorCode::InvalidJson, "invalid_json"),
            Self::UnsupportedSchemaVersion { .. } => (
                HostKeyFfiErrorCode::InvalidRequest,
                "unsupported_schema_version",
            ),
            Self::InvalidEnvelope
            | Self::MissingDataPayload
            | Self::MissingErrorPayload
            | Self::InvalidPayload
            | Self::RequestIdMismatch
            | Self::InvalidTimestamp
            | Self::LegacySessionNotAllowed => (
                HostKeyFfiErrorCode::InvalidRequest,
                "invalid_protocol_payload",
            ),
            Self::SerializationFailed => (
                HostKeyFfiErrorCode::FfiInternalError,
                "serialization_failed",
            ),
        };
        HostKeyFfiErrorPayload::new(code, Some(detail), request_id, None)
    }
}

fn resolved_state_detail(state: PendingChallengeState) -> &'static str {
    match state {
        PendingChallengeState::Pending => "pending",
        PendingChallengeState::Accepted => "accepted",
        PendingChallengeState::Persisted => "persisted",
        PendingChallengeState::Rejected => "rejected",
        PendingChallengeState::Expired => "expired",
        PendingChallengeState::InvalidatedByStoreChange => "invalidated_by_store_change",
    }
}
