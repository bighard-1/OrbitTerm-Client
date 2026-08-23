//! Pure security primitives that do not perform network or platform I/O.
//!
//! Epic A1 through A2.3e-4 expose Host Key, Known Hosts, pure verification,
//! bounded/deduplicated challenge lifecycle, a checked handler, its
//! pre-authentication store-generation gate, a checked test connection, and an
//! additive checked reusable connection. Checked SFTP channels additionally
//! require an active verified base session and have an additive JSON C ABI.
//! Checked one-shot Monitor snapshots, typed Docker operations, bounded Batch
//! exec, and terminal PTY channels use the same verified base-session gate.
//! The insecure legacy host-key handler is compiled only for the explicit
//! `legacy-network-internal` migration feature.

#[cfg(feature = "legacy-network-internal")]
pub(crate) mod insecure_legacy_host_key_handler;

#[allow(
    dead_code,
    reason = "A2.3b-pre2 coordinator is intentionally production-unwired"
)]
pub(crate) mod checked_connect_coordinator;
#[cfg(test)]
mod checked_connect_coordinator_tests;
pub(crate) mod checked_docker_ffi;
#[cfg(test)]
mod checked_docker_ffi_tests;
pub(crate) mod checked_exec_ffi;
#[cfg(test)]
mod checked_exec_ffi_tests;
#[allow(
    dead_code,
    reason = "A2.3a checked handler skeleton is intentionally production-unwired"
)]
pub(crate) mod checked_host_key_handler;
#[cfg(test)]
mod checked_host_key_handler_tests;
pub(crate) mod checked_monitor_ffi;
#[cfg(test)]
mod checked_monitor_ffi_tests;
pub(crate) mod checked_port_forward_ffi;
pub(crate) mod checked_sftp_ffi;
#[cfg(test)]
mod checked_sftp_ffi_tests;
pub(crate) mod checked_ssh_connect;
pub(crate) mod checked_ssh_connect_ffi;
#[cfg(test)]
mod checked_ssh_connect_tests;
pub(crate) mod checked_terminal_ffi;
#[cfg(test)]
mod checked_terminal_ffi_tests;
#[allow(
    dead_code,
    reason = "A2.3b checked test connection is exposed only through its additive C ABI"
)]
pub(crate) mod checked_test_connection;
mod checked_test_connection_ffi;
#[cfg(test)]
mod checked_test_connection_tests;
#[allow(
    dead_code,
    reason = "A2.3a structured errors are consumed by the next checked-connect patch"
)]
pub(crate) mod connect_pre_auth_error;
mod host_key;
mod host_key_challenge_registry;
#[cfg(test)]
mod host_key_challenge_registry_tests;
#[allow(
    dead_code,
    reason = "A2.3a registration is consumed only by the production-unwired checked handler"
)]
pub(crate) mod host_key_challenge_service;
pub(crate) mod host_key_ffi_api;
#[cfg(test)]
mod host_key_ffi_api_tests;
mod host_key_ffi_error;
mod host_key_ffi_lifecycle;
mod host_key_ffi_protocol;
#[cfg(test)]
mod host_key_ffi_protocol_tests;
mod host_key_trust_persistence;
#[cfg(test)]
mod host_key_trust_persistence_tests;
#[allow(
    dead_code,
    reason = "A2.3a context is intentionally not attached to production connections"
)]
pub(crate) mod host_key_verification_context;
mod host_key_verifier;
#[cfg(test)]
mod host_key_verifier_tests;
mod known_hosts;
mod known_hosts_format;
mod known_hosts_persistence;
mod known_hosts_store;
#[cfg(test)]
mod known_hosts_store_tests;
#[cfg(test)]
mod openssh_integration_tests;
#[allow(
    dead_code,
    reason = "A2.3a adapter is intentionally not attached to the production handler"
)]
pub(crate) mod russh_host_key_adapter;
pub(crate) mod session_security;
#[cfg(test)]
mod session_security_tests;
#[allow(
    dead_code,
    reason = "A2.3a generation is reserved for pre-auth and SessionPool checks"
)]
pub(crate) mod trust_store_generation;
#[allow(
    dead_code,
    reason = "A2.3a verified slot is consumed by the next checked-connect coordinator"
)]
pub(crate) mod verified_host_key_slot;

pub use host_key::{
    fingerprint_sha256, fingerprint_sha256_from_base64, FingerprintError, HostIdentity,
    HostIdentityError, HostKeyState,
};
pub use host_key_challenge_registry::{
    AcceptedHostKeyChallenge, ChallengeEquivalenceKey, ChallengeId, ChallengeIdGenerationError,
    ChallengeIdGenerator, ChallengeRegistryError, PendingChallengeRegistryConfig,
    PendingChallengeState, PendingHostKeyChallenge, PendingHostKeyChallengeRegistry,
    PendingHostKeyChallengeSnapshot, PersistedHostKeyChallenge, RegisteredHostKeyChallenge,
    RejectedHostKeyChallenge, SecureChallengeIdGenerator, DEFAULT_CHALLENGE_TTL,
    DEFAULT_GLOBAL_PENDING_LIMIT, DEFAULT_PER_HOST_PENDING_LIMIT, DEFAULT_RELATED_REQUEST_LIMIT,
    DEFAULT_RESOLVED_TOMBSTONE_LIMIT, DEFAULT_TOMBSTONE_TTL, MAX_RELATED_REQUEST_LIMIT,
};
pub use host_key_ffi_error::{
    HostKeyFfiErrorCode, HostKeyFfiErrorPayload, HostKeyFfiProtocolError,
};
pub use host_key_ffi_lifecycle::{
    HostKeyChallengeAcceptanceStatus, HostKeyChallengeAcceptedPayload, HostKeyChallengeStatus,
    HostKeyChallengeStatusPayload, HostKeyCleanupCompletedPayload, HostKeyProtocolVersionPayload,
};
pub use host_key_ffi_protocol::{
    DockerActionResultPayload, DockerContainerPayload, DockerContainersPayload, DockerLogsPayload,
    DockerOperationStatus, DockerStatsItemPayload, DockerStatsPayload, ExecResultPayload,
    HostKeyBlockedPayload, HostKeyChallengePayload, HostKeyConnectedPayload,
    HostKeyConnectionTestSucceededPayload, HostKeyFfiBlockReasonCode,
    HostKeyFfiChallengeReasonCode, HostKeyFfiEnvelope, HostKeyFfiKnownState, HostKeyFfiResult,
    HostKeyFfiResultKind, HostKeyFfiSecurityGeneration, HostKeyRejectedPayload,
    HostKeyRejectionStatus, HostKeyTrustPersistedPayload, HostKeyTrustStatus,
    LocalTunnelStartedPayload, LocalTunnelStoppedPayload, MonitorSnapshotDiagnostic,
    MonitorSnapshotPayload, MonitorSnapshotStatsPayload, MonitorSystemInfoPayload,
    SftpChannelOpenedPayload, SftpDirectoryEntryPayload, SftpDirectoryListPayload,
    SftpDownloadPayload, SftpMutationOperation, SftpMutationPayload, SftpTextFilePayload,
    SftpUploadPayload, TerminalChannelOpenedPayload, HOST_KEY_FFI_SCHEMA_VERSION,
};
pub use host_key_trust_persistence::{
    persist_snapshot_to_known_hosts, HostKeyTrustPersistenceError,
};
pub use host_key_verifier::{
    HostKeyBlock, HostKeyBlockReason, HostKeyChallengeDraft, HostKeyChallengeReason,
    HostKeyVerificationDecision, HostKeyVerificationError, HostKeyVerificationInput,
    HostKeyVerifier, KnownHostRecordSummary, SessionSecurityGeneration, VerifiedHostKey,
};
pub use known_hosts::{
    KnownHostMarker, KnownHostPattern, KnownHostRecord, KnownHostsError, KnownHostsFile,
    KnownHostsMatch, KnownHostsMatcher, KnownHostsWarning, UnparsedKnownHostsLine,
};
pub use known_hosts_store::{
    AddRevokedKeyOutcome, AddTrustedKeyOutcome, KnownHostsStore, KnownHostsStoreError,
    KnownHostsStoreWarning, ReplaceTrustedKeyOutcome, DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE,
};
pub use session_security::{
    BaseSessionMetadata, CheckedChannelAccessError, SessionLifecycleState, SessionSecurityError,
};
pub use trust_store_generation::TrustStoreGeneration;
