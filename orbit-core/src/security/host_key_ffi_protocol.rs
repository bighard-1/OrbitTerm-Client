use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Number, Value};

use super::host_key::HostIdentity;
use super::host_key_challenge_registry::{
    ChallengeId, PersistedHostKeyChallenge, RegisteredHostKeyChallenge, RejectedHostKeyChallenge,
};
use super::host_key_ffi_error::{HostKeyFfiErrorPayload, HostKeyFfiProtocolError};
use super::host_key_ffi_lifecycle::{
    HostKeyChallengeAcceptedPayload, HostKeyChallengeStatusPayload, HostKeyCleanupCompletedPayload,
    HostKeyProtocolVersionPayload,
};
use super::host_key_verifier::{
    HostKeyBlock, HostKeyBlockReason, HostKeyChallengeReason, SessionSecurityGeneration,
    VerifiedHostKey,
};
use super::known_hosts_store::AddTrustedKeyOutcome;

pub const HOST_KEY_FFI_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiResultKind {
    Connected,
    ConnectionTestSucceeded,
    SftpChannelOpened,
    TerminalChannelOpened,
    ExecResult,
    MonitorSnapshot,
    DockerContainers,
    DockerStats,
    DockerLogs,
    DockerActionResult,
    HostKeyChallenge,
    HostKeyChallengeAccepted,
    HostKeyChallengeStatus,
    HostKeyCleanupCompleted,
    HostKeyBlocked,
    HostKeyTrustPersisted,
    HostKeyRejected,
    ProtocolVersion,
    Error,
}

impl HostKeyFfiResultKind {
    pub const ALL: &'static [Self] = &[
        Self::Connected,
        Self::ConnectionTestSucceeded,
        Self::SftpChannelOpened,
        Self::TerminalChannelOpened,
        Self::ExecResult,
        Self::MonitorSnapshot,
        Self::DockerContainers,
        Self::DockerStats,
        Self::DockerLogs,
        Self::DockerActionResult,
        Self::HostKeyChallenge,
        Self::HostKeyChallengeAccepted,
        Self::HostKeyChallengeStatus,
        Self::HostKeyCleanupCompleted,
        Self::HostKeyBlocked,
        Self::HostKeyTrustPersisted,
        Self::HostKeyRejected,
        Self::ProtocolVersion,
        Self::Error,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyFfiResult {
    Connected(HostKeyConnectedPayload),
    ConnectionTestSucceeded(HostKeyConnectionTestSucceededPayload),
    SftpChannelOpened(SftpChannelOpenedPayload),
    TerminalChannelOpened(TerminalChannelOpenedPayload),
    ExecResult(ExecResultPayload),
    MonitorSnapshot(MonitorSnapshotPayload),
    DockerContainers(DockerContainersPayload),
    DockerStats(DockerStatsPayload),
    DockerLogs(DockerLogsPayload),
    DockerActionResult(DockerActionResultPayload),
    HostKeyChallenge(HostKeyChallengePayload),
    HostKeyChallengeAccepted(HostKeyChallengeAcceptedPayload),
    HostKeyChallengeStatus(HostKeyChallengeStatusPayload),
    HostKeyCleanupCompleted(HostKeyCleanupCompletedPayload),
    HostKeyBlocked(HostKeyBlockedPayload),
    HostKeyTrustPersisted(HostKeyTrustPersistedPayload),
    HostKeyRejected(HostKeyRejectedPayload),
    ProtocolVersion(HostKeyProtocolVersionPayload),
    Error(HostKeyFfiErrorPayload),
}

impl HostKeyFfiResult {
    pub const fn kind(&self) -> HostKeyFfiResultKind {
        match self {
            Self::Connected(_) => HostKeyFfiResultKind::Connected,
            Self::ConnectionTestSucceeded(_) => HostKeyFfiResultKind::ConnectionTestSucceeded,
            Self::SftpChannelOpened(_) => HostKeyFfiResultKind::SftpChannelOpened,
            Self::TerminalChannelOpened(_) => HostKeyFfiResultKind::TerminalChannelOpened,
            Self::ExecResult(_) => HostKeyFfiResultKind::ExecResult,
            Self::MonitorSnapshot(_) => HostKeyFfiResultKind::MonitorSnapshot,
            Self::DockerContainers(_) => HostKeyFfiResultKind::DockerContainers,
            Self::DockerStats(_) => HostKeyFfiResultKind::DockerStats,
            Self::DockerLogs(_) => HostKeyFfiResultKind::DockerLogs,
            Self::DockerActionResult(_) => HostKeyFfiResultKind::DockerActionResult,
            Self::HostKeyChallenge(_) => HostKeyFfiResultKind::HostKeyChallenge,
            Self::HostKeyChallengeAccepted(_) => HostKeyFfiResultKind::HostKeyChallengeAccepted,
            Self::HostKeyChallengeStatus(_) => HostKeyFfiResultKind::HostKeyChallengeStatus,
            Self::HostKeyCleanupCompleted(_) => HostKeyFfiResultKind::HostKeyCleanupCompleted,
            Self::HostKeyBlocked(_) => HostKeyFfiResultKind::HostKeyBlocked,
            Self::HostKeyTrustPersisted(_) => HostKeyFfiResultKind::HostKeyTrustPersisted,
            Self::HostKeyRejected(_) => HostKeyFfiResultKind::HostKeyRejected,
            Self::ProtocolVersion(_) => HostKeyFfiResultKind::ProtocolVersion,
            Self::Error(_) => HostKeyFfiResultKind::Error,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyFfiEnvelope {
    pub schema_version: u32,
    pub request_id: Option<String>,
    pub result: HostKeyFfiResult,
}

impl HostKeyFfiEnvelope {
    pub fn new(
        request_id: Option<String>,
        result: HostKeyFfiResult,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let envelope = Self {
            schema_version: HOST_KEY_FFI_SCHEMA_VERSION,
            request_id,
            result,
        };
        envelope.validate()?;
        Ok(envelope)
    }

    pub const fn kind(&self) -> HostKeyFfiResultKind {
        self.result.kind()
    }

    pub fn to_json(&self) -> Result<String, HostKeyFfiProtocolError> {
        serde_json::to_string(self).map_err(|_| HostKeyFfiProtocolError::SerializationFailed)
    }

    pub fn from_json(json: &str) -> Result<Self, HostKeyFfiProtocolError> {
        let wire: WireEnvelope =
            serde_json::from_str(json).map_err(|_| HostKeyFfiProtocolError::InvalidJson)?;
        Self::try_from_wire(wire)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.schema_version != HOST_KEY_FFI_SCHEMA_VERSION {
            return Err(HostKeyFfiProtocolError::UnsupportedSchemaVersion {
                received: self.schema_version,
            });
        }
        validate_correlation_id(self.request_id.as_deref())?;
        match &self.result {
            HostKeyFfiResult::HostKeyChallenge(payload) => {
                if payload.request_id != self.request_id {
                    return Err(HostKeyFfiProtocolError::RequestIdMismatch);
                }
                payload.validate()?;
            }
            HostKeyFfiResult::HostKeyChallengeAccepted(payload) => payload.validate()?,
            HostKeyFfiResult::HostKeyChallengeStatus(payload) => payload.validate()?,
            HostKeyFfiResult::HostKeyCleanupCompleted(payload) => payload.validate()?,
            HostKeyFfiResult::HostKeyBlocked(payload) => payload.validate()?,
            HostKeyFfiResult::Connected(payload) => payload.validate()?,
            HostKeyFfiResult::ConnectionTestSucceeded(payload) => payload.validate()?,
            HostKeyFfiResult::SftpChannelOpened(payload) => payload.validate()?,
            HostKeyFfiResult::TerminalChannelOpened(payload) => payload.validate()?,
            HostKeyFfiResult::ExecResult(payload) => payload.validate()?,
            HostKeyFfiResult::MonitorSnapshot(payload) => payload.validate()?,
            HostKeyFfiResult::DockerContainers(payload) => payload.validate()?,
            HostKeyFfiResult::DockerStats(payload) => payload.validate()?,
            HostKeyFfiResult::DockerLogs(payload) => payload.validate()?,
            HostKeyFfiResult::DockerActionResult(payload) => payload.validate()?,
            HostKeyFfiResult::HostKeyTrustPersisted(payload) => payload.validate()?,
            HostKeyFfiResult::HostKeyRejected(payload) => payload.validate()?,
            HostKeyFfiResult::ProtocolVersion(payload) => payload.validate()?,
            HostKeyFfiResult::Error(payload) => {
                if payload.request_id != self.request_id {
                    return Err(HostKeyFfiProtocolError::RequestIdMismatch);
                }
                payload.validate()?;
            }
        }
        Ok(())
    }

    fn to_wire(&self) -> Result<WireEnvelope, HostKeyFfiProtocolError> {
        self.validate()?;
        let (data, error) = match &self.result {
            HostKeyFfiResult::Connected(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::ConnectionTestSucceeded(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::SftpChannelOpened(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::TerminalChannelOpened(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::ExecResult(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::MonitorSnapshot(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::DockerContainers(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::DockerStats(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::DockerLogs(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::DockerActionResult(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyChallenge(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyChallengeAccepted(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyChallengeStatus(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyCleanupCompleted(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyBlocked(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyTrustPersisted(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::HostKeyRejected(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::ProtocolVersion(payload) => (Some(to_value(payload)?), None),
            HostKeyFfiResult::Error(payload) => (None, Some(payload.clone())),
        };
        Ok(WireEnvelope {
            schema_version: self.schema_version,
            request_id: self.request_id.clone(),
            kind: self.kind(),
            data,
            error,
        })
    }

    fn try_from_wire(wire: WireEnvelope) -> Result<Self, HostKeyFfiProtocolError> {
        if wire.schema_version != HOST_KEY_FFI_SCHEMA_VERSION {
            return Err(HostKeyFfiProtocolError::UnsupportedSchemaVersion {
                received: wire.schema_version,
            });
        }

        let result = match wire.kind {
            HostKeyFfiResultKind::Error => {
                if wire.data.is_some() {
                    return Err(HostKeyFfiProtocolError::InvalidEnvelope);
                }
                HostKeyFfiResult::Error(
                    wire.error
                        .ok_or(HostKeyFfiProtocolError::MissingErrorPayload)?,
                )
            }
            kind => {
                if wire.error.is_some() {
                    return Err(HostKeyFfiProtocolError::InvalidEnvelope);
                }
                let data = wire
                    .data
                    .ok_or(HostKeyFfiProtocolError::MissingDataPayload)?;
                match kind {
                    HostKeyFfiResultKind::Connected => {
                        HostKeyFfiResult::Connected(from_value(data)?)
                    }
                    HostKeyFfiResultKind::ConnectionTestSucceeded => {
                        HostKeyFfiResult::ConnectionTestSucceeded(from_value(data)?)
                    }
                    HostKeyFfiResultKind::SftpChannelOpened => {
                        HostKeyFfiResult::SftpChannelOpened(from_value(data)?)
                    }
                    HostKeyFfiResultKind::TerminalChannelOpened => {
                        HostKeyFfiResult::TerminalChannelOpened(from_value(data)?)
                    }
                    HostKeyFfiResultKind::ExecResult => {
                        HostKeyFfiResult::ExecResult(from_value(data)?)
                    }
                    HostKeyFfiResultKind::MonitorSnapshot => {
                        HostKeyFfiResult::MonitorSnapshot(from_value(data)?)
                    }
                    HostKeyFfiResultKind::DockerContainers => {
                        HostKeyFfiResult::DockerContainers(from_value(data)?)
                    }
                    HostKeyFfiResultKind::DockerStats => {
                        HostKeyFfiResult::DockerStats(from_value(data)?)
                    }
                    HostKeyFfiResultKind::DockerLogs => {
                        HostKeyFfiResult::DockerLogs(from_value(data)?)
                    }
                    HostKeyFfiResultKind::DockerActionResult => {
                        HostKeyFfiResult::DockerActionResult(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyChallenge => {
                        HostKeyFfiResult::HostKeyChallenge(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyChallengeAccepted => {
                        HostKeyFfiResult::HostKeyChallengeAccepted(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyChallengeStatus => {
                        HostKeyFfiResult::HostKeyChallengeStatus(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyCleanupCompleted => {
                        HostKeyFfiResult::HostKeyCleanupCompleted(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyBlocked => {
                        HostKeyFfiResult::HostKeyBlocked(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyTrustPersisted => {
                        HostKeyFfiResult::HostKeyTrustPersisted(from_value(data)?)
                    }
                    HostKeyFfiResultKind::HostKeyRejected => {
                        HostKeyFfiResult::HostKeyRejected(from_value(data)?)
                    }
                    HostKeyFfiResultKind::ProtocolVersion => {
                        HostKeyFfiResult::ProtocolVersion(from_value(data)?)
                    }
                    HostKeyFfiResultKind::Error => unreachable!("error kind handled above"),
                }
            }
        };

        let envelope = Self {
            schema_version: wire.schema_version,
            request_id: wire.request_id,
            result,
        };
        envelope.validate()?;
        Ok(envelope)
    }
}

impl Serialize for HostKeyFfiEnvelope {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_wire()
            .map_err(serde::ser::Error::custom)?
            .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for HostKeyFfiEnvelope {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = WireEnvelope::deserialize(deserializer)?;
        Self::try_from_wire(wire).map_err(D::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyChallengePayload {
    pub challenge_id: String,
    pub request_id: Option<String>,
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub reason_code: HostKeyFfiChallengeReasonCode,
    pub known_state: HostKeyFfiKnownState,
    pub can_trust: bool,
    pub can_replace: bool,
    pub expires_at_unix: u64,
    #[serde(default)]
    pub reused_existing_challenge: bool,
    #[serde(default)]
    pub related_request_count: u32,
}

impl HostKeyChallengePayload {
    pub fn from_registered(
        challenge: &RegisteredHostKeyChallenge,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        Ok(Self {
            challenge_id: challenge.challenge_id.as_str().to_string(),
            request_id: challenge.request_id.clone(),
            host: challenge.host_identity.original_host.clone(),
            normalized_host: challenge.host_identity.normalized_host.clone(),
            port: challenge.host_identity.port,
            lookup_token: challenge.host_identity.lookup_token.clone(),
            key_algorithm: challenge.key_algorithm.clone(),
            fingerprint_sha256: challenge.fingerprint_sha256.clone(),
            reason_code: challenge.reason_code.into(),
            known_state: HostKeyFfiKnownState::Unknown,
            can_trust: true,
            can_replace: false,
            expires_at_unix: unix_seconds(challenge.expires_at)?,
            reused_existing_challenge: challenge.reused_existing_challenge,
            related_request_count: u32::try_from(challenge.related_request_count)
                .map_err(|_| HostKeyFfiProtocolError::InvalidPayload)?,
        })
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_challenge_id(&self.challenge_id)?;
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )?;
        if self.reason_code != HostKeyFfiChallengeReasonCode::UnknownHost
            || self.known_state != HostKeyFfiKnownState::Unknown
            || !self.can_trust
            || self.can_replace
            || (self.reused_existing_challenge && self.related_request_count == 0)
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyBlockedPayload {
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub presented_fingerprint_sha256: String,
    pub previous_fingerprint_sha256: Option<String>,
    pub reason_code: HostKeyFfiBlockReasonCode,
    pub known_state: HostKeyFfiKnownState,
    pub can_trust: bool,
    pub can_replace: bool,
    pub message_key: String,
}

impl From<&HostKeyBlock> for HostKeyBlockedPayload {
    fn from(block: &HostKeyBlock) -> Self {
        let reason_code = HostKeyFfiBlockReasonCode::from(block.reason_code);
        Self {
            host: block.host_identity.original_host.clone(),
            normalized_host: block.host_identity.normalized_host.clone(),
            port: block.host_identity.port,
            lookup_token: block.host_identity.lookup_token.clone(),
            key_algorithm: block.key_algorithm.clone(),
            presented_fingerprint_sha256: block.presented_fingerprint_sha256.clone(),
            previous_fingerprint_sha256: block.previous_fingerprint_sha256.clone(),
            reason_code,
            known_state: reason_code.known_state(),
            can_trust: false,
            can_replace: reason_code == HostKeyFfiBlockReasonCode::Changed
                && block.previous_fingerprint_sha256.is_some(),
            message_key: block.reason_code.message_key().to_string(),
        }
    }
}

impl HostKeyBlockedPayload {
    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.presented_fingerprint_sha256,
        )?;
        if self.can_trust
            || self.known_state != self.reason_code.known_state()
            || self.can_replace
                != (self.reason_code == HostKeyFfiBlockReasonCode::Changed
                    && self.previous_fingerprint_sha256.is_some())
            || self.message_key != self.reason_code.message_key()
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        if let Some(previous) = &self.previous_fingerprint_sha256 {
            validate_fingerprint(previous)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyConnectedPayload {
    pub session_id: u64,
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
}

impl HostKeyConnectedPayload {
    pub fn from_verified(
        session_id: u64,
        verified: &VerifiedHostKey,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        if session_id == 0 {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(Self {
            session_id,
            host: verified.host_identity.original_host.clone(),
            normalized_host: verified.host_identity.normalized_host.clone(),
            port: verified.host_identity.port,
            lookup_token: verified.host_identity.lookup_token.clone(),
            key_algorithm: verified.key_algorithm.clone(),
            fingerprint_sha256: verified.fingerprint_sha256.clone(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
        })
    }

    pub fn from_security_generation(
        session_id: u64,
        generation: &SessionSecurityGeneration,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let SessionSecurityGeneration::HostKeyVerified {
            host_identity,
            key_algorithm,
            fingerprint_sha256,
            ..
        } = generation
        else {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        };
        let payload = Self {
            session_id,
            host: host_identity.original_host.clone(),
            normalized_host: host_identity.normalized_host.clone(),
            port: host_identity.port,
            lookup_token: host_identity.lookup_token.clone(),
            key_algorithm: key_algorithm.clone(),
            fingerprint_sha256: fingerprint_sha256.clone(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.session_id == 0
            || self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyConnectionTestSucceededPayload {
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SftpChannelOpenedPayload {
    pub base_session_id: String,
    pub sftp_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
}

impl SftpChannelOpenedPayload {
    pub fn new(
        base_session_id: u64,
        sftp_session_id: u64,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            sftp_session_id: sftp_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_decimal_session_id(&self.base_session_id)?;
        validate_decimal_session_id(&self.sftp_session_id)?;
        if self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalChannelOpenedPayload {
    pub base_session_id: String,
    pub terminal_channel_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub cols: u32,
    pub rows: u32,
}

impl TerminalChannelOpenedPayload {
    pub fn new(
        base_session_id: u64,
        terminal_channel_id: u64,
        cols: u32,
        rows: u32,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            terminal_channel_id: terminal_channel_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            cols,
            rows,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_decimal_session_id(&self.base_session_id)?;
        validate_decimal_session_id(&self.terminal_channel_id)?;
        if self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified
            || !(1..=1_000).contains(&self.cols)
            || !(1..=1_000).contains(&self.rows)
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

const MAX_EXEC_STDOUT_PAYLOAD_BYTES: usize = 1024 * 1024;
const MAX_EXEC_STDERR_PAYLOAD_BYTES: usize = 256 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecResultPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub exit_status: u32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
}

impl fmt::Debug for ExecResultPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExecResultPayload")
            .field("base_session_id", &self.base_session_id)
            .field("security_generation", &self.security_generation)
            .field("exit_status", &self.exit_status)
            .field("stdout", &"[REDACTED]")
            .field("stderr", &"[REDACTED]")
            .field("timed_out", &self.timed_out)
            .field("stdout_truncated", &self.stdout_truncated)
            .field("stderr_truncated", &self.stderr_truncated)
            .finish()
    }
}

impl ExecResultPayload {
    pub fn new(
        base_session_id: u64,
        exit_status: u32,
        stdout: String,
        stderr: String,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            exit_status,
            stdout,
            stderr,
            timed_out: false,
            stdout_truncated: false,
            stderr_truncated: false,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_decimal_session_id(&self.base_session_id)?;
        if self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified
            || self.exit_status != 0
            || self.timed_out
            || self.stdout_truncated
            || self.stderr_truncated
            || self.stdout.len() > MAX_EXEC_STDOUT_PAYLOAD_BYTES
            || self.stderr.len() > MAX_EXEC_STDERR_PAYLOAD_BYTES
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MonitorSnapshotPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub stats: MonitorSnapshotStatsPayload,
    pub diagnostics: Vec<MonitorSnapshotDiagnostic>,
}

impl MonitorSnapshotPayload {
    pub fn new(
        base_session_id: u64,
        stats: MonitorSnapshotStatsPayload,
        diagnostics: Vec<MonitorSnapshotDiagnostic>,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            stats,
            diagnostics,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_decimal_session_id(&self.base_session_id)?;
        if self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        self.stats.validate()?;
        if self.diagnostics.len() > 8 {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MonitorSnapshotStatsPayload {
    pub sampled_at_unix: u64,
    pub cpu_usage_percent: Number,
    pub mem_available_mb: u64,
    pub mem_used_percent: Number,
    pub disk_used_percent: Number,
    pub ping_latency_ms: Option<Number>,
    pub rx_rate_kbps: Number,
    pub tx_rate_kbps: Number,
}

impl MonitorSnapshotStatsPayload {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        sampled_at_unix: u64,
        cpu_usage_percent: f64,
        mem_available_mb: u64,
        mem_used_percent: f64,
        disk_used_percent: f64,
        ping_latency_ms: Option<f64>,
        rx_rate_kbps: f64,
        tx_rate_kbps: f64,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            sampled_at_unix,
            cpu_usage_percent: finite_number(cpu_usage_percent)?,
            mem_available_mb,
            mem_used_percent: finite_number(mem_used_percent)?,
            disk_used_percent: finite_number(disk_used_percent)?,
            ping_latency_ms: ping_latency_ms.map(finite_number).transpose()?,
            rx_rate_kbps: finite_number(rx_rate_kbps)?,
            tx_rate_kbps: finite_number(tx_rate_kbps)?,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.sampled_at_unix == 0
            || !valid_percent(&self.cpu_usage_percent)
            || !valid_percent(&self.mem_used_percent)
            || !valid_percent(&self.disk_used_percent)
            || self
                .ping_latency_ms
                .as_ref()
                .is_some_and(number_is_negative)
            || number_is_negative(&self.rx_rate_kbps)
            || number_is_negative(&self.tx_rate_kbps)
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MonitorSnapshotDiagnostic {
    PingUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerContainerPayload {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub running_for: String,
}

impl DockerContainerPayload {
    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_container_id(&self.id)?;
        for value in [
            &self.name,
            &self.image,
            &self.state,
            &self.status,
            &self.running_for,
        ] {
            validate_bounded_docker_text(value)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerContainersPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub containers: Vec<DockerContainerPayload>,
}

impl DockerContainersPayload {
    pub fn new(
        base_session_id: u64,
        containers: Vec<DockerContainerPayload>,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            containers,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_common(&self.base_session_id, self.security_generation)?;
        if self.containers.len() > 10_000 {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        self.containers.iter().try_for_each(|item| item.validate())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerStatsItemPayload {
    pub id: String,
    pub name: String,
    pub cpu_percent: Number,
    pub mem_percent: Number,
    pub mem_usage: String,
    pub net_io: String,
    pub block_io: String,
    pub pids: u32,
}

impl DockerStatsItemPayload {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        name: String,
        cpu_percent: f64,
        mem_percent: f64,
        mem_usage: String,
        net_io: String,
        block_io: String,
        pids: u32,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            id,
            name,
            cpu_percent: finite_number(cpu_percent)?,
            mem_percent: finite_number(mem_percent)?,
            mem_usage,
            net_io,
            block_io,
            pids,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_container_id(&self.id)?;
        for value in [&self.name, &self.mem_usage, &self.net_io, &self.block_io] {
            validate_bounded_docker_text(value)?;
        }
        if number_is_negative(&self.cpu_percent) || !valid_percent(&self.mem_percent) {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerStatsPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub stats: Vec<DockerStatsItemPayload>,
}

impl DockerStatsPayload {
    pub fn new(
        base_session_id: u64,
        stats: Vec<DockerStatsItemPayload>,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            stats,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_common(&self.base_session_id, self.security_generation)?;
        if self.stats.len() > 10_000 {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        self.stats.iter().try_for_each(|item| item.validate())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerLogsPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub container_id: String,
    pub logs: String,
}

impl DockerLogsPayload {
    pub fn new(
        base_session_id: u64,
        container_id: String,
        logs: String,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            container_id,
            logs,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_common(&self.base_session_id, self.security_generation)?;
        validate_docker_container_id(&self.container_id)?;
        if self.logs.len() > 1024 * 1024 || self.logs.contains('\0') {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DockerOperationStatus {
    Completed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerActionResultPayload {
    pub base_session_id: String,
    pub security_generation: HostKeyFfiSecurityGeneration,
    pub container_id: String,
    pub action: String,
    pub status: DockerOperationStatus,
}

impl DockerActionResultPayload {
    pub fn new(
        base_session_id: u64,
        container_id: String,
        action: String,
    ) -> Result<Self, HostKeyFfiProtocolError> {
        let payload = Self {
            base_session_id: base_session_id.to_string(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
            container_id,
            action,
            status: DockerOperationStatus::Completed,
        };
        payload.validate()?;
        Ok(payload)
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_docker_common(&self.base_session_id, self.security_generation)?;
        validate_docker_container_id(&self.container_id)?;
        if !matches!(
            self.action.as_str(),
            "start" | "stop" | "restart" | "kill" | "pause" | "unpause" | "remove"
        ) || self.status != DockerOperationStatus::Completed
        {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

impl HostKeyConnectionTestSucceededPayload {
    pub fn from_verified(verified: &VerifiedHostKey) -> Self {
        Self {
            host: verified.host_identity.original_host.clone(),
            normalized_host: verified.host_identity.normalized_host.clone(),
            port: verified.host_identity.port,
            lookup_token: verified.host_identity.lookup_token.clone(),
            key_algorithm: verified.key_algorithm.clone(),
            fingerprint_sha256: verified.fingerprint_sha256.clone(),
            security_generation: HostKeyFfiSecurityGeneration::HostKeyVerified,
        }
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        if self.security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyTrustPersistedPayload {
    pub challenge_id: String,
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub status: HostKeyTrustStatus,
}

impl HostKeyTrustPersistedPayload {
    pub fn from_persisted(
        challenge: &PersistedHostKeyChallenge,
        outcome: AddTrustedKeyOutcome,
    ) -> Self {
        Self {
            challenge_id: challenge.challenge_id.as_str().to_string(),
            host: challenge.host_identity.original_host.clone(),
            normalized_host: challenge.host_identity.normalized_host.clone(),
            port: challenge.host_identity.port,
            lookup_token: challenge.host_identity.lookup_token.clone(),
            key_algorithm: challenge.key_algorithm.clone(),
            fingerprint_sha256: challenge.fingerprint_sha256.clone(),
            status: outcome.into(),
        }
    }

    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_challenge_id(&self.challenge_id)?;
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyRejectedPayload {
    pub challenge_id: String,
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub status: HostKeyRejectionStatus,
}

impl From<&RejectedHostKeyChallenge> for HostKeyRejectedPayload {
    fn from(challenge: &RejectedHostKeyChallenge) -> Self {
        Self {
            challenge_id: challenge.challenge_id.as_str().to_string(),
            host: challenge.host_identity.original_host.clone(),
            normalized_host: challenge.host_identity.normalized_host.clone(),
            port: challenge.host_identity.port,
            lookup_token: challenge.host_identity.lookup_token.clone(),
            key_algorithm: challenge.key_algorithm.clone(),
            fingerprint_sha256: challenge.fingerprint_sha256.clone(),
            status: HostKeyRejectionStatus::Rejected,
        }
    }
}

impl HostKeyRejectedPayload {
    fn validate(&self) -> Result<(), HostKeyFfiProtocolError> {
        validate_challenge_id(&self.challenge_id)?;
        validate_host_fields(
            &self.host,
            &self.normalized_host,
            self.port,
            &self.lookup_token,
            &self.key_algorithm,
            &self.fingerprint_sha256,
        )?;
        if self.status != HostKeyRejectionStatus::Rejected {
            return Err(HostKeyFfiProtocolError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiChallengeReasonCode {
    UnknownHost,
}

impl From<HostKeyChallengeReason> for HostKeyFfiChallengeReasonCode {
    fn from(value: HostKeyChallengeReason) -> Self {
        match value {
            HostKeyChallengeReason::UnknownHostKey => Self::UnknownHost,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiBlockReasonCode {
    Changed,
    Revoked,
    Unsupported,
    CertAuthorityUnsupported,
}

impl HostKeyFfiBlockReasonCode {
    const fn known_state(self) -> HostKeyFfiKnownState {
        match self {
            Self::Changed => HostKeyFfiKnownState::Changed,
            Self::Revoked => HostKeyFfiKnownState::Revoked,
            Self::Unsupported | Self::CertAuthorityUnsupported => HostKeyFfiKnownState::Unsupported,
        }
    }

    const fn message_key(self) -> &'static str {
        match self {
            Self::Changed => "host_key.changed",
            Self::Revoked => "host_key.revoked",
            Self::Unsupported => "host_key.unsupported_record",
            Self::CertAuthorityUnsupported => "host_key.cert_authority_unsupported",
        }
    }
}

impl From<HostKeyBlockReason> for HostKeyFfiBlockReasonCode {
    fn from(value: HostKeyBlockReason) -> Self {
        match value {
            HostKeyBlockReason::Changed => Self::Changed,
            HostKeyBlockReason::Revoked => Self::Revoked,
            HostKeyBlockReason::UnsupportedRecord => Self::Unsupported,
            HostKeyBlockReason::CertificateAuthorityUnsupported => Self::CertAuthorityUnsupported,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiKnownState {
    Unknown,
    Trusted,
    Changed,
    Revoked,
    Unsupported,
    Invalid,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyFfiSecurityGeneration {
    HostKeyVerified,
}

impl TryFrom<&SessionSecurityGeneration> for HostKeyFfiSecurityGeneration {
    type Error = HostKeyFfiProtocolError;

    fn try_from(value: &SessionSecurityGeneration) -> Result<Self, Self::Error> {
        match value {
            SessionSecurityGeneration::HostKeyVerified { .. } => Ok(Self::HostKeyVerified),
            SessionSecurityGeneration::LegacyUnverified => {
                Err(HostKeyFfiProtocolError::LegacySessionNotAllowed)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyTrustStatus {
    TrustedAdded,
    AlreadyTrusted,
}

impl From<AddTrustedKeyOutcome> for HostKeyTrustStatus {
    fn from(outcome: AddTrustedKeyOutcome) -> Self {
        match outcome {
            AddTrustedKeyOutcome::Added => Self::TrustedAdded,
            AddTrustedKeyOutcome::AlreadyTrusted => Self::AlreadyTrusted,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKeyRejectionStatus {
    Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WireEnvelope {
    schema_version: u32,
    request_id: Option<String>,
    kind: HostKeyFfiResultKind,
    data: Option<Value>,
    error: Option<HostKeyFfiErrorPayload>,
}

fn to_value<T: Serialize>(value: &T) -> Result<Value, HostKeyFfiProtocolError> {
    serde_json::to_value(value).map_err(|_| HostKeyFfiProtocolError::SerializationFailed)
}

fn from_value<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T, HostKeyFfiProtocolError> {
    serde_json::from_value(value).map_err(|_| HostKeyFfiProtocolError::InvalidPayload)
}

fn unix_seconds(value: SystemTime) -> Result<u64, HostKeyFfiProtocolError> {
    value
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| HostKeyFfiProtocolError::InvalidTimestamp)
}

pub(super) fn validate_challenge_id(value: &str) -> Result<(), HostKeyFfiProtocolError> {
    ChallengeId::parse(value)
        .map(|_| ())
        .map_err(|_| HostKeyFfiProtocolError::InvalidPayload)
}

pub(super) fn validate_host_fields(
    host: &str,
    normalized_host: &str,
    port: u16,
    lookup_token: &str,
    key_algorithm: &str,
    fingerprint: &str,
) -> Result<(), HostKeyFfiProtocolError> {
    let identity =
        HostIdentity::parse(host, port).map_err(|_| HostKeyFfiProtocolError::InvalidPayload)?;
    if identity.normalized_host != normalized_host
        || identity.lookup_token != lookup_token
        || identity.port != port
        || key_algorithm.is_empty()
    {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    validate_fingerprint(fingerprint)
}

fn validate_fingerprint(value: &str) -> Result<(), HostKeyFfiProtocolError> {
    let Some(encoded) = value.strip_prefix("SHA256:") else {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    };
    let digest = STANDARD_NO_PAD
        .decode(encoded)
        .map_err(|_| HostKeyFfiProtocolError::InvalidPayload)?;
    if digest.len() != 32 {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn validate_correlation_id(value: Option<&str>) -> Result<(), HostKeyFfiProtocolError> {
    let Some(value) = value else {
        return Ok(());
    };
    if value.is_empty()
        || value.len() > 256
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn validate_decimal_session_id(value: &str) -> Result<(), HostKeyFfiProtocolError> {
    if value.is_empty()
        || value.len() > 20
        || value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value.parse::<u64>().ok().filter(|id| *id != 0).is_none()
    {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn validate_docker_common(
    base_session_id: &str,
    security_generation: HostKeyFfiSecurityGeneration,
) -> Result<(), HostKeyFfiProtocolError> {
    validate_decimal_session_id(base_session_id)?;
    if security_generation != HostKeyFfiSecurityGeneration::HostKeyVerified {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn validate_docker_container_id(value: &str) -> Result<(), HostKeyFfiProtocolError> {
    if !(12..=64).contains(&value.len()) || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn validate_bounded_docker_text(value: &str) -> Result<(), HostKeyFfiProtocolError> {
    if value.len() > 64 * 1024 || value.contains('\0') {
        return Err(HostKeyFfiProtocolError::InvalidPayload);
    }
    Ok(())
}

fn finite_number(value: f64) -> Result<Number, HostKeyFfiProtocolError> {
    Number::from_f64(value).ok_or(HostKeyFfiProtocolError::InvalidPayload)
}

fn number_is_negative(value: &Number) -> bool {
    value.as_f64().is_none_or(|value| value < 0.0)
}

fn valid_percent(value: &Number) -> bool {
    value
        .as_f64()
        .is_some_and(|value| (0.0..=100.0).contains(&value))
}
