use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::checked_terminal::{
    open_terminal_channel_checked_with_backend, CheckedPtySize, CheckedTerminalBackend,
    CheckedTerminalError, TerminalChannelId, MAX_PTY_DIMENSION, MIN_PTY_DIMENSION,
};
use crate::security::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, SessionLifecycleState,
    SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id, VerifiedBaseSessionGuard,
};
use crate::terminal::{
    insert_synthetic_terminal_channel_for_tests, remove_synthetic_terminal_channel_for_tests,
    terminal_channel_metadata_for_tests, TerminalChannelMetadata, TerminalChannelSource,
};

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-terminal-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-terminal-store"),
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
    error: Option<CheckedTerminalError>,
    reject_preferred_terminal: bool,
    calls: AtomicUsize,
    requested_terminal_types: std::sync::Mutex<Vec<&'static str>>,
    register_metadata: bool,
}

impl FakeBackend {
    fn successful() -> Self {
        Self {
            error: None,
            reject_preferred_terminal: false,
            calls: AtomicUsize::new(0),
            requested_terminal_types: std::sync::Mutex::new(Vec::new()),
            register_metadata: false,
        }
    }

    fn registering() -> Self {
        Self {
            register_metadata: true,
            ..Self::successful()
        }
    }

    fn failing(error: CheckedTerminalError) -> Self {
        Self {
            error: Some(error),
            ..Self::successful()
        }
    }

    fn rejects_preferred_terminal() -> Self {
        Self {
            reject_preferred_terminal: true,
            ..Self::successful()
        }
    }
}

impl CheckedTerminalBackend for FakeBackend {
    fn open<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
        size: CheckedPtySize,
        terminal_type: &'static str,
    ) -> Pin<Box<dyn Future<Output = Result<TerminalChannelId, CheckedTerminalError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.requested_terminal_types
                .lock()
                .unwrap()
                .push(terminal_type);
            if self.reject_preferred_terminal && terminal_type == "xterm-256color" {
                return Err(CheckedTerminalError::PtyRequestFailed);
            }
            if let Some(error) = self.error {
                return Err(error);
            }
            if self.register_metadata {
                let metadata = TerminalChannelMetadata::checked(guard, size.cols(), size.rows());
                return insert_synthetic_terminal_channel_for_tests(metadata)
                    .map(TerminalChannelId::new)
                    .map_err(|_| CheckedTerminalError::TerminalRegistrationFailed);
            }
            Ok(TerminalChannelId::new(77))
        })
    }
}

#[tokio::test]
async fn checked_terminal_retries_windows_compatible_terminal_type_after_pty_rejection() {
    let base = TestBase::new(verified_generation());
    let backend = FakeBackend::rejects_preferred_terminal();

    assert_eq!(
        open_terminal_channel_checked_with_backend(base.id, 120, 32, &backend)
            .await
            .unwrap()
            .get(),
        77
    );
    assert_eq!(backend.calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        *backend.requested_terminal_types.lock().unwrap(),
        vec!["xterm-256color", "xterm"]
    );
}

#[test]
fn checked_pty_size_accepts_boundaries_and_rejects_zero_or_oversized_values() {
    for (cols, rows) in [
        (MIN_PTY_DIMENSION, MIN_PTY_DIMENSION),
        (120, 32),
        (MAX_PTY_DIMENSION, MAX_PTY_DIMENSION),
    ] {
        let size = CheckedPtySize::new(cols, rows).unwrap();
        assert_eq!(size.cols(), cols);
        assert_eq!(size.rows(), rows);
    }

    for (cols, rows) in [
        (0, 1),
        (1, 0),
        (MAX_PTY_DIMENSION + 1, 1),
        (1, MAX_PTY_DIMENSION + 1),
    ] {
        assert_eq!(
            CheckedPtySize::new(cols, rows).unwrap_err(),
            CheckedTerminalError::InvalidPtySize
        );
    }
}

#[tokio::test]
async fn checked_terminal_gate_allows_active_verified_and_rejects_non_base_ids() {
    let base = TestBase::new(verified_generation());
    let backend = FakeBackend::successful();
    assert_eq!(
        open_terminal_channel_checked_with_backend(base.id, 120, 32, &backend)
            .await
            .unwrap()
            .get(),
        77
    );
    assert_eq!(backend.calls.load(Ordering::SeqCst), 1);

    for mixed_namespace_id in [1_u64, 2, 99_999] {
        assert_eq!(
            open_terminal_channel_checked_with_backend(mixed_namespace_id, 120, 32, &backend,)
                .await
                .unwrap_err(),
            CheckedTerminalError::ChannelAccess(CheckedChannelAccessError::SessionNotFound)
        );
    }
    assert_eq!(backend.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn checked_terminal_rejects_legacy_and_inactive_sessions_before_backend() {
    let backend = FakeBackend::successful();
    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    assert_eq!(
        open_terminal_channel_checked_with_backend(legacy.id, 120, 32, &backend)
            .await
            .unwrap_err(),
        CheckedTerminalError::ChannelAccess(CheckedChannelAccessError::LegacySessionNotAllowed)
    );

    for (state, error) in [
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
        let base = TestBase::new(verified_generation());
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        assert_eq!(
            open_terminal_channel_checked_with_backend(base.id, 120, 32, &backend)
                .await
                .unwrap_err(),
            CheckedTerminalError::ChannelAccess(error)
        );
    }
    assert_eq!(backend.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn checked_terminal_propagates_open_pty_shell_and_registration_failures() {
    let base = TestBase::new(verified_generation());
    for error in [
        CheckedTerminalError::ChannelAccess(CheckedChannelAccessError::ChannelOpenFailed),
        CheckedTerminalError::PtyRequestFailed,
        CheckedTerminalError::ShellStartFailed,
        CheckedTerminalError::TerminalRegistrationFailed,
    ] {
        let backend = FakeBackend::failing(error);
        assert_eq!(
            open_terminal_channel_checked_with_backend(base.id, 120, 32, &backend)
                .await
                .unwrap_err(),
            error
        );
        let expected_calls = if error == CheckedTerminalError::PtyRequestFailed {
            2
        } else {
            1
        };
        assert_eq!(backend.calls.load(Ordering::SeqCst), expected_calls);
    }
}

#[tokio::test]
async fn checked_terminal_registration_records_safe_verified_metadata() {
    let base = TestBase::new(verified_generation());
    let backend = FakeBackend::registering();
    let terminal_id = open_terminal_channel_checked_with_backend(base.id, 132, 41, &backend)
        .await
        .unwrap();
    let metadata = terminal_channel_metadata_for_tests(terminal_id.get()).unwrap();
    assert_eq!(metadata.base_session_id(), base.id);
    assert_eq!(metadata.security_generation(), &verified_generation());
    assert_eq!(metadata.source(), TerminalChannelSource::Checked);
    assert_eq!(metadata.cols(), 132);
    assert_eq!(metadata.rows(), 41);

    let debug = format!("{metadata:?}");
    for forbidden in [
        "password",
        "private_key",
        "token",
        "known_hosts",
        "BEGIN OPENSSH",
    ] {
        assert!(!debug.contains(forbidden));
    }
    remove_synthetic_terminal_channel_for_tests(terminal_id.get());
}

#[test]
fn checked_terminal_errors_are_structured_and_redacted() {
    for error in [
        CheckedTerminalError::ChannelAccess(CheckedChannelAccessError::SessionNotFound),
        CheckedTerminalError::InvalidPtySize,
        CheckedTerminalError::PtyRequestFailed,
        CheckedTerminalError::ShellStartFailed,
        CheckedTerminalError::TerminalRegistrationFailed,
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
