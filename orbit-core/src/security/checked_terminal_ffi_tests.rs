use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_terminal_ffi::{
    orbit_terminal_open_checked_v1, terminal_open_checked_response_for_tests,
};
use super::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, HostKeyFfiEnvelope,
    HostKeyFfiResult, HostKeyFfiResultKind, SessionLifecycleState, SessionSecurityGeneration,
    TerminalChannelOpenedPayload, TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_terminal::{CheckedTerminalError, TerminalChannelId};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

const REQUEST_ID: &str = "checked-terminal-request";

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
    cols: u32,
    rows: u32,
    request_id: *const c_char,
) -> (String, Value) {
    read_and_free(orbit_terminal_open_checked_v1(
        base_session_id,
        cols,
        rows,
        request_id,
    ))
}

#[test]
fn ffi_rejects_null_invalid_utf8_oversized_control_zero_and_invalid_sizes() {
    let (_, null_request) = call_exported(1, 120, 32, std::ptr::null());
    assert_eq!(null_request["error"]["code"], "invalid_request");
    assert_eq!(null_request["error"]["detail_code"], "null_request_id");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_utf8) = call_exported(1, 120, 32, invalid_utf8.as_ptr().cast());
    assert_eq!(invalid_utf8["error"]["code"], "invalid_utf8");

    for invalid in ["x".repeat(257), "line\nbreak".to_string()] {
        let invalid = CString::new(invalid).unwrap();
        let (_, response) = call_exported(1, 120, 32, invalid.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_request");
        assert_eq!(response["error"]["detail_code"], "invalid_request_id");
    }

    let request_id = CString::new(REQUEST_ID).unwrap();
    let (_, zero) = call_exported(0, 120, 32, request_id.as_ptr());
    assert_eq!(zero["request_id"], REQUEST_ID);
    assert_eq!(zero["error"]["code"], "invalid_request");
    assert_eq!(zero["error"]["detail_code"], "invalid_base_session_id");

    for (cols, rows) in [(0, 32), (120, 0), (1_001, 32), (120, 1_001)] {
        let (_, response) = call_exported(1, cols, rows, request_id.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_pty_size");
        assert_eq!(response["error"]["detail_code"], "invalid_pty_size");
    }
}

#[test]
fn unknown_legacy_and_inactive_base_sessions_fail_closed() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let unknown_base_id = (1_u64 << 48) | 999_999;
    let (_, unknown) = call_exported(unknown_base_id, 120, 32, request_id.as_ptr());
    assert_eq!(unknown["error"]["code"], "session_not_found");

    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    let (_, legacy_error) = call_exported(legacy.id, 120, 32, request_id.as_ptr());
    assert_eq!(legacy_error["error"]["code"], "legacy_session_not_allowed");

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
        let (_, response) = call_exported(base.id, 120, 32, request_id.as_ptr());
        assert_eq!(response["error"]["code"], expected);
    }
}

#[test]
fn successful_response_round_trips_request_and_decimal_string_ids() {
    let base = TestBase::new(verified_generation());
    let request_id = CString::new(REQUEST_ID).unwrap();
    let pointer = terminal_open_checked_response_for_tests(
        base.id,
        132,
        41,
        request_id.as_ptr(),
        |base_id, cols, rows| async move {
            assert_eq!(base_id, base.id);
            assert_eq!((cols, rows), (132, 41));
            Ok(TerminalChannelId::new(88))
        },
    );
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "terminal_channel_opened");
    assert_eq!(value["data"]["base_session_id"], base.id.to_string());
    assert_eq!(value["data"]["terminal_channel_id"], "88");
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["data"]["cols"], 132);
    assert_eq!(value["data"]["rows"], 41);
    assert_eq!(value["error"], Value::Null);
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::TerminalChannelOpened
    );
    for forbidden in [
        "password",
        "private_key",
        "passphrase",
        "token",
        "public_key",
        "known_hosts",
    ] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn terminal_errors_keep_stable_json_codes_without_sensitive_context() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    for (error, expected) in [
        (
            CheckedTerminalError::ChannelAccess(
                CheckedChannelAccessError::SecurityGenerationMismatch,
            ),
            "security_generation_mismatch",
        ),
        (
            CheckedTerminalError::ChannelAccess(CheckedChannelAccessError::ChannelOpenFailed),
            "channel_open_failed",
        ),
        (CheckedTerminalError::PtyRequestFailed, "pty_request_failed"),
        (CheckedTerminalError::ShellStartFailed, "shell_start_failed"),
        (
            CheckedTerminalError::TerminalRegistrationFailed,
            "ffi_internal_error",
        ),
    ] {
        let pointer = terminal_open_checked_response_for_tests(
            1,
            120,
            32,
            request_id.as_ptr(),
            move |_, _, _| async move { Err(error) },
        );
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        for forbidden in ["password", "private_key", "public_key", "known_hosts"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn terminal_payload_rejects_unsafe_ids_sizes_and_generation() {
    let payload = TerminalChannelOpenedPayload::new((1_u64 << 48) | 1, u64::MAX, 120, 32).unwrap();
    let json = serde_json::to_string(&payload).unwrap();
    assert!(json.contains(&format!("\"{}\"", u64::MAX)));
    assert!(!json.contains(&format!(":{}", u64::MAX)));

    for malformed in [
        r#"{"base_session_id":"0","terminal_channel_id":"1","security_generation":"host_key_verified","cols":120,"rows":32}"#,
        r#"{"base_session_id":"1","terminal_channel_id":"01","security_generation":"host_key_verified","cols":120,"rows":32}"#,
        r#"{"base_session_id":"1","terminal_channel_id":"2","security_generation":"host_key_verified","cols":0,"rows":32}"#,
    ] {
        let decoded: TerminalChannelOpenedPayload = serde_json::from_str(malformed).unwrap();
        let envelope = HostKeyFfiEnvelope::new(
            Some(REQUEST_ID.to_string()),
            HostKeyFfiResult::TerminalChannelOpened(decoded),
        );
        assert!(envelope.is_err());
    }
}

#[test]
fn header_declares_checked_terminal_and_preserves_legacy_terminal_abi() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_terminal_open_checked_v1"));
    assert!(header.contains("uint64_t base_session_id"));
    assert!(header.contains("uint32_t cols"));
    assert!(header.contains("uint32_t rows"));
    assert!(header.contains("const char *request_id"));
    assert!(header.contains("char *orbit_request_channel("));
    assert!(header.contains("char *orbit_terminal_write("));
    assert!(header.contains("char *orbit_terminal_resize("));
    assert!(header.contains("char *orbit_terminal_close("));
    assert!(header.contains("orbit_free_string"));
}
