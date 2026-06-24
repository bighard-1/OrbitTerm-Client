use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::checked_sftp::{
    open_sftp_channel_checked_with_backend, CheckedSftpBackend, SftpSessionId,
};
use crate::security::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, HostKeyFfiErrorCode,
    HostKeyFfiErrorPayload, SessionLifecycleState, SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, is_base_session_id,
    remove_synthetic_base_session_for_tests, require_active_verified_base_session,
    resolve_base_session_by_base_id, SftpSessionMetadata, SftpSessionSource,
    VerifiedBaseSessionGuard,
};

fn verified_generation(seed: &[u8], store: &[u8]) -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(seed),
        trust_store_generation: TrustStoreGeneration::from_contents(store),
    }
}

struct TestBase {
    id: u64,
}

impl TestBase {
    fn new(generation: SessionSecurityGeneration) -> Self {
        let base = insert_synthetic_base_session_for_tests("example.com", "root", generation)
            .expect("insert synthetic base");
        Self { id: base.id }
    }
}

impl Drop for TestBase {
    fn drop(&mut self) {
        remove_synthetic_base_session_for_tests(self.id);
    }
}

struct FakeBackend {
    open_error: Option<CheckedChannelAccessError>,
    registration_error: Option<CheckedChannelAccessError>,
    open_calls: AtomicUsize,
    registration_calls: AtomicUsize,
}

impl FakeBackend {
    fn successful() -> Self {
        Self {
            open_error: None,
            registration_error: None,
            open_calls: AtomicUsize::new(0),
            registration_calls: AtomicUsize::new(0),
        }
    }

    fn with_open_error(error: CheckedChannelAccessError) -> Self {
        Self {
            open_error: Some(error),
            ..Self::successful()
        }
    }

    fn with_registration_error(error: CheckedChannelAccessError) -> Self {
        Self {
            registration_error: Some(error),
            ..Self::successful()
        }
    }
}

impl CheckedSftpBackend for FakeBackend {
    type Session = ();

    fn open<'a>(
        &'a self,
        _guard: &'a VerifiedBaseSessionGuard,
    ) -> Pin<Box<dyn Future<Output = Result<Self::Session, CheckedChannelAccessError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.open_calls.fetch_add(1, Ordering::SeqCst);
            self.open_error.map_or(Ok(()), Err)
        })
    }

    fn register(
        &self,
        _guard: &VerifiedBaseSessionGuard,
        _session: Self::Session,
    ) -> Result<SftpSessionId, CheckedChannelAccessError> {
        self.registration_calls.fetch_add(1, Ordering::SeqCst);
        self.registration_error.map_or(Ok(SftpSessionId(9)), Err)
    }
}

#[test]
fn base_only_resolver_accepts_only_tagged_base_namespace() {
    let base = TestBase::new(verified_generation(b"key", b"store"));
    assert!(is_base_session_id(base.id));
    assert_eq!(
        resolve_base_session_by_base_id(base.id).unwrap().id,
        base.id
    );

    for non_base_id in [1_u64, 2, 9_000_000_000] {
        assert!(!is_base_session_id(non_base_id));
        assert!(matches!(
            resolve_base_session_by_base_id(non_base_id),
            Err(CheckedChannelAccessError::SessionNotFound)
        ));
    }
    assert!(matches!(
        resolve_base_session_by_base_id(base.id + 1_000_000),
        Err(CheckedChannelAccessError::SessionNotFound)
    ));
}

#[test]
fn verified_gate_allows_only_active_host_key_verified_base() {
    let verified = TestBase::new(verified_generation(b"key", b"store"));
    let guard = require_active_verified_base_session(verified.id).unwrap();
    assert_eq!(guard.base_session_id(), verified.id);

    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    assert!(matches!(
        require_active_verified_base_session(legacy.id),
        Err(CheckedChannelAccessError::LegacySessionNotAllowed)
    ));
}

#[test]
fn verified_gate_rejects_draining_terminating_and_closed_sessions() {
    for (state, expected) in [
        (
            SessionLifecycleState::Draining,
            CheckedChannelAccessError::SessionDraining,
        ),
        (
            SessionLifecycleState::Terminating,
            CheckedChannelAccessError::SessionTerminating,
        ),
        (
            SessionLifecycleState::Closed,
            CheckedChannelAccessError::SessionClosed,
        ),
    ] {
        let base = TestBase::new(verified_generation(b"key", b"store"));
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        assert_eq!(
            require_active_verified_base_session(base.id).unwrap_err(),
            expected
        );
    }
}

#[test]
fn verified_guard_rejects_generation_mismatch() {
    let base = TestBase::new(verified_generation(b"key-a", b"store"));
    let guard = require_active_verified_base_session(base.id).unwrap();
    assert_eq!(
        guard
            .require_security_generation(&verified_generation(b"key-b", b"store"))
            .unwrap_err(),
        CheckedChannelAccessError::SecurityGenerationMismatch
    );
}

#[tokio::test]
async fn checked_sftp_gate_runs_before_backend_and_success_registers() {
    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    let backend = FakeBackend::successful();
    assert_eq!(
        open_sftp_channel_checked_with_backend(legacy.id, &backend)
            .await
            .unwrap_err(),
        CheckedChannelAccessError::LegacySessionNotAllowed
    );
    assert_eq!(backend.open_calls.load(Ordering::SeqCst), 0);
    assert_eq!(backend.registration_calls.load(Ordering::SeqCst), 0);

    for state in [
        SessionLifecycleState::Draining,
        SessionLifecycleState::Terminating,
        SessionLifecycleState::Closed,
    ] {
        let blocked = TestBase::new(verified_generation(b"blocked-key", b"store"));
        resolve_base_session_by_base_id(blocked.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        assert!(open_sftp_channel_checked_with_backend(blocked.id, &backend)
            .await
            .is_err());
        assert_eq!(backend.open_calls.load(Ordering::SeqCst), 0);
        assert_eq!(backend.registration_calls.load(Ordering::SeqCst), 0);
    }

    let verified = TestBase::new(verified_generation(b"key", b"store"));
    let session_id = open_sftp_channel_checked_with_backend(verified.id, &backend)
        .await
        .unwrap();
    assert_eq!(session_id.get(), 9);
    assert_eq!(backend.open_calls.load(Ordering::SeqCst), 1);
    assert_eq!(backend.registration_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn checked_sftp_propagates_open_subsystem_and_registration_errors() {
    let base = TestBase::new(verified_generation(b"key", b"store"));
    for error in [
        CheckedChannelAccessError::ChannelOpenFailed,
        CheckedChannelAccessError::SubsystemRequestFailed,
    ] {
        let backend = FakeBackend::with_open_error(error);
        assert_eq!(
            open_sftp_channel_checked_with_backend(base.id, &backend)
                .await
                .unwrap_err(),
            error
        );
        assert_eq!(backend.registration_calls.load(Ordering::SeqCst), 0);
    }

    let backend =
        FakeBackend::with_registration_error(CheckedChannelAccessError::SftpRegistrationFailed);
    assert_eq!(
        open_sftp_channel_checked_with_backend(base.id, &backend)
            .await
            .unwrap_err(),
        CheckedChannelAccessError::SftpRegistrationFailed
    );
}

#[test]
fn checked_sftp_metadata_binds_base_and_verified_generation_without_secrets() {
    let base = TestBase::new(verified_generation(b"key", b"store"));
    let guard = require_active_verified_base_session(base.id).unwrap();
    let metadata = SftpSessionMetadata::checked(&guard);
    assert_eq!(metadata.base_session_id(), base.id);
    assert_eq!(metadata.security_generation(), guard.security_generation());
    assert_eq!(metadata.source(), SftpSessionSource::Checked);

    let debug = format!("{metadata:?}");
    for forbidden in [
        "password",
        "private_key",
        "token",
        "known_hosts_path",
        "BEGIN OPENSSH PRIVATE KEY",
    ] {
        assert!(!debug.contains(forbidden));
    }
}

#[test]
fn checked_channel_errors_are_redacted_and_structured() {
    for error in [
        CheckedChannelAccessError::SessionNotFound,
        CheckedChannelAccessError::LegacySessionNotAllowed,
        CheckedChannelAccessError::VerifiedSessionRequired,
        CheckedChannelAccessError::SecurityGenerationMismatch,
        CheckedChannelAccessError::SessionDraining,
        CheckedChannelAccessError::SessionTerminating,
        CheckedChannelAccessError::SessionClosed,
        CheckedChannelAccessError::ChannelOpenFailed,
        CheckedChannelAccessError::SubsystemRequestFailed,
        CheckedChannelAccessError::SftpRegistrationFailed,
        CheckedChannelAccessError::InternalInvariantViolation,
    ] {
        let output = format!("{error:?} {error}");
        for forbidden in [
            "password",
            "private_key",
            "token",
            "known_hosts",
            "BEGIN OPENSSH",
        ] {
            assert!(!output.contains(forbidden));
        }
    }
}

#[test]
fn checked_channel_errors_map_to_stable_future_ffi_codes() {
    let cases = [
        (
            CheckedChannelAccessError::SessionNotFound,
            HostKeyFfiErrorCode::SessionNotFound,
        ),
        (
            CheckedChannelAccessError::LegacySessionNotAllowed,
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
        ),
        (
            CheckedChannelAccessError::SessionDraining,
            HostKeyFfiErrorCode::SessionDraining,
        ),
        (
            CheckedChannelAccessError::SessionTerminating,
            HostKeyFfiErrorCode::SessionTerminating,
        ),
        (
            CheckedChannelAccessError::SessionClosed,
            HostKeyFfiErrorCode::SessionClosed,
        ),
        (
            CheckedChannelAccessError::ChannelOpenFailed,
            HostKeyFfiErrorCode::ChannelOpenFailed,
        ),
        (
            CheckedChannelAccessError::SubsystemRequestFailed,
            HostKeyFfiErrorCode::SubsystemRequestFailed,
        ),
    ];
    for (error, expected) in cases {
        let payload = HostKeyFfiErrorPayload::from_checked_channel_error(
            error,
            Some("request-checked-sftp".to_string()),
        );
        assert_eq!(payload.code, expected);
        assert_eq!(payload.request_id.as_deref(), Some("request-checked-sftp"));
        let json = serde_json::to_string(&payload).unwrap();
        assert!(!json.contains("public_key"));
        assert!(!json.contains("known_hosts_path"));
    }
}
