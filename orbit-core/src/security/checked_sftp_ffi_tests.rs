use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_sftp_ffi::{orbit_sftp_open_checked_v1, sftp_open_checked_response_for_tests};
use super::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, HostKeyFfiEnvelope,
    HostKeyFfiResultKind, SessionLifecycleState, SessionSecurityGeneration,
    SftpChannelOpenedPayload, TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_sftp::SftpSessionId;
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    require_active_verified_base_session, resolve_base_session_by_base_id, SftpSessionMetadata,
    SftpSessionSource,
};

const REQUEST_ID: &str = "checked-sftp-request";

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-sftp-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-sftp-store"),
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

fn call_exported(base_session_id: u64, request_id: *const c_char) -> (String, Value) {
    read_and_free(orbit_sftp_open_checked_v1(base_session_id, request_id))
}

#[test]
fn ffi_rejects_null_invalid_utf8_oversized_control_and_zero_inputs() {
    let (_, null_request) = call_exported(1, std::ptr::null());
    assert_eq!(null_request["error"]["code"], "invalid_request");
    assert_eq!(null_request["error"]["detail_code"], "null_request_id");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_utf8) = call_exported(1, invalid_utf8.as_ptr().cast());
    assert_eq!(invalid_utf8["error"]["code"], "invalid_utf8");

    for invalid in ["x".repeat(257), "line\nbreak".to_string()] {
        let invalid = CString::new(invalid).unwrap();
        let (_, response) = call_exported(1, invalid.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_request");
        assert_eq!(response["error"]["detail_code"], "invalid_request_id");
    }

    let request_id = CString::new(REQUEST_ID).unwrap();
    let (_, zero) = call_exported(0, request_id.as_ptr());
    assert_eq!(zero["request_id"], REQUEST_ID);
    assert_eq!(zero["error"]["code"], "invalid_request");
    assert_eq!(zero["error"]["detail_code"], "invalid_base_session_id");
}

#[test]
fn unknown_and_unsafe_base_sessions_fail_closed_before_channel_open() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let unknown_base_id = (1_u64 << 48) | 999_999;
    let (_, unknown) = call_exported(unknown_base_id, request_id.as_ptr());
    assert_eq!(unknown["error"]["code"], "session_not_found");

    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    let (_, legacy_error) = call_exported(legacy.id, request_id.as_ptr());
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
        let (_, response) = call_exported(base.id, request_id.as_ptr());
        assert_eq!(response["error"]["code"], expected);
    }
}

#[test]
fn active_verified_success_returns_versioned_string_ids_and_checked_metadata() {
    let base = TestBase::new(verified_generation());
    let request_id = CString::new(REQUEST_ID).unwrap();
    let pointer =
        sftp_open_checked_response_for_tests(base.id, request_id.as_ptr(), |base_id| async move {
            let guard = require_active_verified_base_session(base_id)?;
            let metadata = SftpSessionMetadata::checked(&guard);
            assert_eq!(metadata.source(), SftpSessionSource::Checked);
            assert_eq!(metadata.base_session_id(), base_id);
            assert_eq!(metadata.security_generation(), guard.security_generation());
            Ok(SftpSessionId(77))
        });
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "sftp_channel_opened");
    assert_eq!(value["data"]["base_session_id"], base.id.to_string());
    assert_eq!(value["data"]["sftp_session_id"], "77");
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["error"], Value::Null);
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::SftpChannelOpened
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
fn checked_channel_errors_keep_stable_json_codes() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    for (error, expected) in [
        (
            CheckedChannelAccessError::SecurityGenerationMismatch,
            "security_generation_mismatch",
        ),
        (
            CheckedChannelAccessError::ChannelOpenFailed,
            "channel_open_failed",
        ),
        (
            CheckedChannelAccessError::SubsystemRequestFailed,
            "subsystem_request_failed",
        ),
        (
            CheckedChannelAccessError::SftpRegistrationFailed,
            "sftp_registration_failed",
        ),
        (
            CheckedChannelAccessError::InternalInvariantViolation,
            "ffi_internal_error",
        ),
    ] {
        let pointer =
            sftp_open_checked_response_for_tests(1, request_id.as_ptr(), move |_| async move {
                Err(error)
            });
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        for forbidden in ["password", "private_key", "public_key", "known_hosts"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn sftp_payload_round_trips_decimal_strings_and_rejects_unsafe_ids() {
    let payload = SftpChannelOpenedPayload::new((1_u64 << 48) | 1, u64::MAX).unwrap();
    let json = serde_json::to_string(&payload).unwrap();
    assert!(json.contains(&format!("\"{}\"", u64::MAX)));
    assert!(!json.contains(&format!(":{}", u64::MAX)));

    for malformed in [
        r#"{"base_session_id":"0","sftp_session_id":"1","security_generation":"host_key_verified"}"#,
        r#"{"base_session_id":"01","sftp_session_id":"1","security_generation":"host_key_verified"}"#,
    ] {
        let decoded: SftpChannelOpenedPayload = serde_json::from_str(malformed).unwrap();
        let envelope = super::HostKeyFfiEnvelope::new(
            Some(REQUEST_ID.to_string()),
            super::HostKeyFfiResult::SftpChannelOpened(decoded),
        );
        assert!(envelope.is_err());
    }
}

#[test]
fn header_declares_additive_checked_sftp_and_preserves_legacy_signature() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_sftp_open_checked_v1"));
    assert!(header.contains("uint64_t base_session_id"));
    assert!(header.contains("const char *request_id"));
    assert!(header.contains("char *orbit_sftp_connect("));
    assert!(header.contains("const char *private_key_content"));
    assert!(header.contains("char *orbit_sftp_list_dir"));
    assert!(header.contains("char *orbit_sftp_upload_file"));
    assert!(header.contains("char *orbit_sftp_download_file"));
    assert!(header.contains("orbit_free_string"));
}
