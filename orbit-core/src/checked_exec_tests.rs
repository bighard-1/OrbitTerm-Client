use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::checked_exec::{
    append_bounded_for_tests, run_remote_command_checked_with_backend, validate_command,
    CheckedExecBackend, CheckedExecError, CheckedExecOptions, CheckedExecOutput,
    DEFAULT_BATCH_STDERR_BYTES, DEFAULT_BATCH_STDOUT_BYTES, DEFAULT_BATCH_TIMEOUT_SECONDS,
    MAX_BATCH_STDERR_BYTES, MAX_BATCH_STDOUT_BYTES, MAX_BATCH_TIMEOUT_SECONDS, MAX_COMMAND_BYTES,
};
use crate::security::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, SessionLifecycleState,
    SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id, VerifiedBaseSessionGuard,
};

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-exec-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-exec-store"),
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

struct FakeExecBackend {
    result: Result<CheckedExecOutput, CheckedExecError>,
    calls: AtomicUsize,
}

impl FakeExecBackend {
    fn success() -> Self {
        Self {
            result: Ok(CheckedExecOutput::new(
                "output".to_string(),
                String::new(),
                0,
            )),
            calls: AtomicUsize::new(0),
        }
    }

    fn failure(error: CheckedExecError) -> Self {
        Self {
            result: Err(error),
            calls: AtomicUsize::new(0),
        }
    }
}

impl CheckedExecBackend for FakeExecBackend {
    fn execute<'a>(
        &'a self,
        _guard: &'a VerifiedBaseSessionGuard,
        _command: &'a str,
        _options: CheckedExecOptions,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.result.clone()
        })
    }
}

#[tokio::test]
async fn active_verified_base_allows_checked_exec() {
    let base = TestBase::new(verified_generation());
    let backend = FakeExecBackend::success();
    let output = run_remote_command_checked_with_backend(
        base.id,
        "printf safe",
        CheckedExecOptions::monitor_snapshot(),
        &backend,
    )
    .await
    .unwrap();
    assert_eq!(output.stdout(), "output");
    assert_eq!(backend.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn legacy_and_non_active_sessions_fail_before_backend() {
    let backend = FakeExecBackend::success();
    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    assert!(matches!(
        run_remote_command_checked_with_backend(
            legacy.id,
            "true",
            CheckedExecOptions::monitor_snapshot(),
            &backend,
        )
        .await,
        Err(CheckedExecError::ChannelAccess(
            CheckedChannelAccessError::LegacySessionNotAllowed
        ))
    ));

    for state in [
        SessionLifecycleState::Draining,
        SessionLifecycleState::Terminating,
        SessionLifecycleState::Closed,
    ] {
        let base = TestBase::new(verified_generation());
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        assert!(run_remote_command_checked_with_backend(
            base.id,
            "true",
            CheckedExecOptions::monitor_snapshot(),
            &backend,
        )
        .await
        .is_err());
    }
    assert_eq!(backend.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn untyped_sftp_and_terminal_like_ids_are_never_base_sessions() {
    let backend = FakeExecBackend::success();
    for non_base_id in [1_u64, 2, 9_000_000_000] {
        assert_eq!(
            run_remote_command_checked_with_backend(
                non_base_id,
                "true",
                CheckedExecOptions::monitor_snapshot(),
                &backend,
            )
            .await
            .unwrap_err(),
            CheckedExecError::ChannelAccess(CheckedChannelAccessError::SessionNotFound)
        );
    }
    assert_eq!(backend.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn channel_exec_and_output_failures_remain_structured() {
    let base = TestBase::new(verified_generation());
    for error in [
        CheckedExecError::ChannelAccess(CheckedChannelAccessError::ChannelOpenFailed),
        CheckedExecError::ExecRequestFailed,
        CheckedExecError::ExecOutputFailed,
        CheckedExecError::OutputLimitExceeded,
        CheckedExecError::Timeout,
        CheckedExecError::CommandFailed { exit_status: 17 },
    ] {
        let backend = FakeExecBackend::failure(error);
        assert_eq!(
            run_remote_command_checked_with_backend(
                base.id,
                "true",
                CheckedExecOptions::monitor_snapshot(),
                &backend,
            )
            .await
            .unwrap_err(),
            error
        );
    }
}

#[test]
fn checked_exec_debug_output_never_exposes_command_or_remote_output() {
    let output = CheckedExecOutput::new(
        "stdout-secret-token".to_string(),
        "stderr-private-key".to_string(),
        0,
    );
    let debug = format!("{output:?}");
    assert!(!debug.contains("stdout-secret-token"));
    assert!(!debug.contains("stderr-private-key"));

    for error in [
        CheckedExecError::ExecRequestFailed,
        CheckedExecError::ExecOutputFailed,
        CheckedExecError::CommandFailed { exit_status: 1 },
    ] {
        let debug = format!("{error:?} {error}");
        for forbidden in ["password", "private_key", "token", "known_hosts"] {
            assert!(!debug.contains(forbidden));
        }
    }
}

#[test]
fn checked_output_limit_fails_without_partially_appending_data() {
    let mut output = b"abc".to_vec();
    assert_eq!(
        append_bounded_for_tests(&mut output, b"de", 4).unwrap_err(),
        CheckedExecError::OutputLimitExceeded
    );
    assert_eq!(output, b"abc");
}

#[test]
fn batch_command_validation_allows_shell_syntax_but_rejects_controls_and_size() {
    for valid in ["printf safe", "echo $HOME | sed 's/x/y/'", "false || true"] {
        validate_command(valid).unwrap();
    }
    for invalid in ["", "   ", "echo first\necho second", "echo\tunsafe", "a\0b"] {
        assert_eq!(
            validate_command(invalid).unwrap_err(),
            CheckedExecError::InvalidCommand
        );
    }
    assert_eq!(
        validate_command(&"x".repeat(MAX_COMMAND_BYTES + 1)).unwrap_err(),
        CheckedExecError::CommandTooLarge
    );
}

#[test]
fn batch_options_apply_defaults_accept_maxima_and_reject_oversized_values() {
    assert_eq!(
        CheckedExecOptions::batch(0, 0, 0)
            .unwrap()
            .batch_values_for_tests(),
        (
            u64::from(DEFAULT_BATCH_TIMEOUT_SECONDS),
            DEFAULT_BATCH_STDOUT_BYTES as usize,
            DEFAULT_BATCH_STDERR_BYTES as usize,
        )
    );
    assert_eq!(
        CheckedExecOptions::batch(
            MAX_BATCH_TIMEOUT_SECONDS,
            MAX_BATCH_STDOUT_BYTES,
            MAX_BATCH_STDERR_BYTES,
        )
        .unwrap()
        .batch_values_for_tests(),
        (
            u64::from(MAX_BATCH_TIMEOUT_SECONDS),
            MAX_BATCH_STDOUT_BYTES as usize,
            MAX_BATCH_STDERR_BYTES as usize,
        )
    );
    for invalid in [
        (MAX_BATCH_TIMEOUT_SECONDS + 1, 1, 1),
        (1, MAX_BATCH_STDOUT_BYTES + 1, 1),
        (1, 1, MAX_BATCH_STDERR_BYTES + 1),
    ] {
        assert_eq!(
            CheckedExecOptions::batch(invalid.0, invalid.1, invalid.2).unwrap_err(),
            CheckedExecError::InvalidOptions
        );
    }
}
