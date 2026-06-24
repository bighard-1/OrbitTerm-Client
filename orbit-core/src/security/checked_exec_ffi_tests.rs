use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_exec_ffi::{exec_response_for_tests, orbit_exec_checked_v1};
use super::{
    fingerprint_sha256, CheckedChannelAccessError, ExecResultPayload, HostIdentity,
    HostKeyFfiEnvelope, HostKeyFfiResultKind, SessionLifecycleState, SessionSecurityGeneration,
    TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_exec::{
    CheckedExecError, CheckedExecOutput, DEFAULT_BATCH_STDERR_BYTES, DEFAULT_BATCH_STDOUT_BYTES,
    DEFAULT_BATCH_TIMEOUT_SECONDS, MAX_COMMAND_BYTES,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

const REQUEST_ID: &str = "checked-exec-request";

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-exec-ffi-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-exec-ffi-store"),
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

fn read_and_free(pointer: *mut c_char) -> (String, Value) {
    assert!(!pointer.is_null());
    // SAFETY: Checked FFI responses are Rust-owned NUL-terminated strings.
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap()
        .to_string();
    orbit_free_string(pointer);
    let value = serde_json::from_str(&json).unwrap();
    (json, value)
}

fn call_exported(
    base_session_id: u64,
    command: *const c_char,
    timeout_seconds: u32,
    max_stdout_bytes: u32,
    max_stderr_bytes: u32,
    request_id: *const c_char,
) -> (String, Value) {
    read_and_free(orbit_exec_checked_v1(
        base_session_id,
        command,
        timeout_seconds,
        max_stdout_bytes,
        max_stderr_bytes,
        request_id,
    ))
}

#[test]
fn ffi_rejects_null_invalid_utf8_zero_and_invalid_command_inputs() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("printf safe").unwrap();

    let (_, null_request) = call_exported(1, command.as_ptr(), 30, 1024, 1024, std::ptr::null());
    assert_eq!(null_request["error"]["code"], "invalid_request");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_request) = call_exported(
        1,
        command.as_ptr(),
        30,
        1024,
        1024,
        invalid_utf8.as_ptr().cast(),
    );
    assert_eq!(invalid_request["error"]["code"], "invalid_utf8");

    for invalid_request_id in ["x".repeat(257), "line\nbreak".to_string()] {
        let invalid_request_id = CString::new(invalid_request_id).unwrap();
        let (_, response) = call_exported(
            1,
            command.as_ptr(),
            30,
            1024,
            1024,
            invalid_request_id.as_ptr(),
        );
        assert_eq!(response["error"]["code"], "invalid_request");
    }

    let (_, null_command) = call_exported(1, std::ptr::null(), 30, 1024, 1024, request_id.as_ptr());
    assert_eq!(null_command["error"]["code"], "invalid_request");

    let (_, invalid_command_utf8) = call_exported(
        1,
        invalid_utf8.as_ptr().cast(),
        30,
        1024,
        1024,
        request_id.as_ptr(),
    );
    assert_eq!(invalid_command_utf8["error"]["code"], "invalid_utf8");

    let (_, zero_base) = call_exported(0, command.as_ptr(), 30, 1024, 1024, request_id.as_ptr());
    assert_eq!(zero_base["request_id"], REQUEST_ID);
    assert_eq!(zero_base["error"]["code"], "invalid_request");

    for invalid in ["", "   ", "echo first\necho second", "echo\tunsafe"] {
        let invalid = CString::new(invalid).unwrap();
        let (_, response) = call_exported(1, invalid.as_ptr(), 30, 1024, 1024, request_id.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_command");
    }

    let oversized = CString::new("x".repeat(MAX_COMMAND_BYTES + 1)).unwrap();
    let (_, oversized) = call_exported(1, oversized.as_ptr(), 30, 1024, 1024, request_id.as_ptr());
    assert_eq!(oversized["error"]["code"], "command_too_large");
}

#[test]
fn options_use_safe_defaults_and_reject_values_above_batch_maxima() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("printf safe").unwrap();
    let pointer = exec_response_for_tests(
        7,
        command.as_ptr(),
        0,
        0,
        0,
        request_id.as_ptr(),
        |_, _, options| async move {
            assert_eq!(
                options.batch_values_for_tests(),
                (
                    u64::from(DEFAULT_BATCH_TIMEOUT_SECONDS),
                    DEFAULT_BATCH_STDOUT_BYTES as usize,
                    DEFAULT_BATCH_STDERR_BYTES as usize,
                )
            );
            Ok(CheckedExecOutput::new(String::new(), String::new(), 0))
        },
    );
    assert_eq!(read_and_free(pointer).1["kind"], "exec_result");

    for (timeout, stdout, stderr) in [
        (301, 1024, 1024),
        (30, 1024 * 1024 + 1, 1024),
        (30, 1024, 256 * 1024 + 1),
    ] {
        let (_, response) = call_exported(
            1,
            command.as_ptr(),
            timeout,
            stdout,
            stderr,
            request_id.as_ptr(),
        );
        assert_eq!(response["error"]["code"], "invalid_exec_options");
    }
}

#[test]
fn success_returns_bounded_exec_result_and_owned_string() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("printf safe").unwrap();
    let pointer = exec_response_for_tests(
        7,
        command.as_ptr(),
        30,
        4096,
        2048,
        request_id.as_ptr(),
        |base_session_id, command, _| async move {
            assert_eq!(base_session_id, 7);
            assert_eq!(command, "printf safe");
            Ok(CheckedExecOutput::new(
                "bounded stdout".to_string(),
                "bounded stderr".to_string(),
                0,
            ))
        },
    );
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "exec_result");
    assert_eq!(value["data"]["base_session_id"], "7");
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["data"]["exit_status"], 0);
    assert_eq!(value["data"]["stdout"], "bounded stdout");
    assert_eq!(value["data"]["stderr"], "bounded stderr");
    assert_eq!(value["data"]["timed_out"], false);
    assert_eq!(value["data"]["stdout_truncated"], false);
    assert_eq!(value["data"]["stderr_truncated"], false);
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::ExecResult
    );
}

#[test]
fn gate_rejects_unknown_legacy_non_active_and_untyped_ids() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("true").unwrap();
    let unknown_base_id = (1_u64 << 48) | 888_889;
    let (_, unknown) = call_exported(
        unknown_base_id,
        command.as_ptr(),
        30,
        1024,
        1024,
        request_id.as_ptr(),
    );
    assert_eq!(unknown["error"]["code"], "session_not_found");

    for non_base_id in [1_u64, 2, 9_000_000_000] {
        let (_, response) = call_exported(
            non_base_id,
            command.as_ptr(),
            30,
            1024,
            1024,
            request_id.as_ptr(),
        );
        assert_eq!(response["error"]["code"], "session_not_found");
    }

    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    let (_, legacy) = call_exported(
        legacy.id,
        command.as_ptr(),
        30,
        1024,
        1024,
        request_id.as_ptr(),
    );
    assert_eq!(legacy["error"]["code"], "legacy_session_not_allowed");

    for (state, expected) in [
        (SessionLifecycleState::Draining, "session_draining"),
        (SessionLifecycleState::Terminating, "session_terminating"),
        (SessionLifecycleState::Closed, "session_closed"),
    ] {
        let base = TestBase::new(verified_generation());
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        let (_, response) = call_exported(
            base.id,
            command.as_ptr(),
            30,
            1024,
            1024,
            request_id.as_ptr(),
        );
        assert_eq!(response["error"]["code"], expected);
    }
}

#[test]
fn active_verified_export_reaches_checked_backend_only() {
    let base = TestBase::new(verified_generation());
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("true").unwrap();
    let (_, response) = call_exported(
        base.id,
        command.as_ptr(),
        30,
        1024,
        1024,
        request_id.as_ptr(),
    );
    // Synthetic sessions intentionally panic if real channel I/O is reached.
    // The internal error proves the verified gate admitted this base while the
    // FFI catch boundary still prevented unwinding across C.
    assert_eq!(response["error"]["code"], "ffi_internal_error");
}

#[test]
fn checked_exec_errors_map_to_stable_redacted_codes() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let secret_command = "printf secret-command-payload";
    let command = CString::new(secret_command).unwrap();
    let cases = [
        (
            CheckedExecError::ChannelAccess(CheckedChannelAccessError::ChannelOpenFailed),
            "channel_open_failed",
        ),
        (CheckedExecError::ExecRequestFailed, "exec_request_failed"),
        (CheckedExecError::ExecOutputFailed, "exec_output_failed"),
        (
            CheckedExecError::OutputLimitExceeded,
            "exec_output_limit_exceeded",
        ),
        (CheckedExecError::Timeout, "exec_timeout"),
        (
            CheckedExecError::CommandFailed { exit_status: 17 },
            "exec_command_failed",
        ),
    ];
    for (error, expected) in cases {
        let error_copy = error;
        let pointer = exec_response_for_tests(
            7,
            command.as_ptr(),
            30,
            4096,
            2048,
            request_id.as_ptr(),
            move |_, _, _| async move { Err(error_copy) },
        );
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        assert!(!json.contains(secret_command));
        for forbidden in ["password", "private_key", "public_key", "known_hosts"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn panic_is_caught_as_json_internal_error() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let command = CString::new("true").unwrap();
    let pointer = exec_response_for_tests(
        7,
        command.as_ptr(),
        30,
        1024,
        1024,
        request_id.as_ptr(),
        |_, _, _| async move { panic!("test panic must not cross FFI") },
    );
    let (_, response) = read_and_free(pointer);
    assert_eq!(response["error"]["code"], "ffi_internal_error");
}

#[test]
fn payload_debug_redacts_stdout_and_stderr() {
    let payload = ExecResultPayload::new(
        7,
        0,
        "stdout-secret-token".to_string(),
        "stderr-private-key".to_string(),
    )
    .unwrap();
    let debug = format!("{payload:?}");
    assert!(!debug.contains("stdout-secret-token"));
    assert!(!debug.contains("stderr-private-key"));
}

#[test]
fn header_declares_checked_exec_and_preserves_existing_abis() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_exec_checked_v1"));
    assert!(header.contains("uint32_t timeout_seconds"));
    assert!(header.contains("uint32_t max_stdout_bytes"));
    assert!(header.contains("uint32_t max_stderr_bytes"));
    assert!(header.contains("char *orbit_exec_command(uint64_t session_id, const char *command);"));
    for existing in [
        "orbit_terminal_open_checked_v1",
        "orbit_sftp_open_checked_v1",
        "orbit_monitor_snapshot_checked_v1",
        "orbit_docker_list_checked_v1",
    ] {
        assert!(header.contains(existing));
    }
}
