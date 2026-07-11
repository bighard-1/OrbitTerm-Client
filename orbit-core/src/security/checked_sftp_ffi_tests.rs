use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_sftp_ffi::{
    orbit_sftp_chmod_checked_v1, orbit_sftp_create_file_checked_v1, orbit_sftp_list_checked_v1,
    orbit_sftp_mkdir_checked_v1, orbit_sftp_open_checked_v1, orbit_sftp_remove_checked_v1,
    orbit_sftp_rename_checked_v1, sftp_chmod_checked_response_for_tests,
    sftp_create_file_checked_response_for_tests, sftp_download_checked_response_for_tests,
    sftp_list_checked_response_for_tests, sftp_mkdir_checked_response_for_tests,
    sftp_open_checked_response_for_tests, sftp_read_text_checked_response_for_tests,
    sftp_remove_checked_response_for_tests, sftp_rename_checked_response_for_tests,
    sftp_upload_checked_response_for_tests, sftp_write_text_checked_response_for_tests,
};
use super::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, HostKeyFfiEnvelope,
    HostKeyFfiResultKind, SessionLifecycleState, SessionSecurityGeneration,
    SftpChannelOpenedPayload, SftpDirectoryEntryPayload, SftpDirectoryListPayload,
    SftpTextFilePayload, TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_sftp::SftpSessionId;
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    require_active_verified_base_session, resolve_base_session_by_base_id, SftpSessionMetadata,
    SftpSessionSource,
};
use crate::sftp::{SftpEntrySnapshot, SftpMutationError};
use crate::OrbitCoreError;

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

fn call_exported_list(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> (String, Value) {
    read_and_free(orbit_sftp_list_checked_v1(
        sftp_session_id,
        remote_path,
        request_id,
    ))
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
fn list_ffi_rejects_null_invalid_utf8_unsafe_path_and_zero_inputs() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/var/log").unwrap();

    let (_, null_request) = call_exported_list(1, path.as_ptr(), std::ptr::null());
    assert_eq!(null_request["error"]["code"], "invalid_request");
    assert_eq!(null_request["error"]["detail_code"], "null_request_id");

    let (_, zero) = call_exported_list(0, path.as_ptr(), request_id.as_ptr());
    assert_eq!(zero["request_id"], REQUEST_ID);
    assert_eq!(zero["error"]["code"], "invalid_request");
    assert_eq!(zero["error"]["detail_code"], "invalid_sftp_session_id");

    let (_, null_path) = call_exported_list(1, std::ptr::null(), request_id.as_ptr());
    assert_eq!(null_path["error"]["code"], "invalid_request");
    assert_eq!(null_path["error"]["detail_code"], "null_remote_path");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_utf8) =
        call_exported_list(1, invalid_utf8.as_ptr().cast(), request_id.as_ptr());
    assert_eq!(invalid_utf8["error"]["code"], "invalid_utf8");

    for invalid in ["relative", "/var/../etc", "C:\\Users"] {
        let invalid = CString::new(invalid).unwrap();
        let (_, response) = call_exported_list(1, invalid.as_ptr(), request_id.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_request");
        assert_eq!(response["error"]["detail_code"], "invalid_remote_path");
    }
}

#[test]
fn list_success_returns_checked_directory_payload_without_sensitive_fields() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/var/log").unwrap();
    let pointer = sftp_list_checked_response_for_tests(
        77,
        path.as_ptr(),
        request_id.as_ptr(),
        |session_id, remote_path| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/var/log");
            Ok(r#"[{"name":"syslog","size":42,"permissions":"-rw-r--r--","permissions_octal":420,"modified_at_unix":1700000000}]"#.to_string())
        },
    );
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "sftp_directory_list");
    assert_eq!(value["data"]["sftp_session_id"], "77");
    assert_eq!(value["data"]["path"], "/var/log");
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["data"]["entries"][0]["name"], "syslog");
    assert_eq!(value["data"]["entries"][0]["size"], 42);
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::SftpDirectoryList
    );
    for forbidden in [
        "password",
        "private_key",
        "passphrase",
        "public_key",
        "known_hosts",
    ] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn list_payload_rejects_unsafe_entries_and_round_trips() {
    let entry = SftpDirectoryEntryPayload::new(
        "app.log".to_string(),
        128,
        "-rw-r--r--".to_string(),
        0o644,
        1_700_000_000,
    )
    .unwrap();
    let payload = SftpDirectoryListPayload::new(77, "/opt/app".to_string(), vec![entry]).unwrap();
    let envelope = super::HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        super::HostKeyFfiResult::SftpDirectoryList(payload),
    )
    .unwrap();
    assert_eq!(envelope.kind(), HostKeyFfiResultKind::SftpDirectoryList);

    assert!(SftpDirectoryEntryPayload::new(
        "bad/name".to_string(),
        0,
        "-rw-r--r--".to_string(),
        0o644,
        0,
    )
    .is_err());
    assert!(SftpDirectoryListPayload::new(77, "/opt/../etc".to_string(), vec![]).is_err());
}

#[test]
fn list_errors_map_to_stable_redacted_codes() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/var/log").unwrap();
    for (error, expected) in [
        (OrbitCoreError::InvalidInput, "invalid_request"),
        (
            OrbitCoreError::LegacyNetworkDisabled,
            "legacy_session_not_allowed",
        ),
        (
            OrbitCoreError::SshFailed("session_closed password known_hosts".to_string()),
            "security_generation_mismatch",
        ),
        (
            OrbitCoreError::SftpFailed("permission denied /secret".to_string()),
            "sftp_list_failed",
        ),
        (
            OrbitCoreError::Internal("json includes private_key".to_string()),
            "ffi_internal_error",
        ),
    ] {
        let pointer = sftp_list_checked_response_for_tests(
            77,
            path.as_ptr(),
            request_id.as_ptr(),
            move |_, _| async move { Err(error) },
        );
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        for forbidden in ["password", "private_key", "known_hosts", "/secret"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn read_text_success_returns_checked_bounded_payload_without_sensitive_fields() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/var/log/syslog").unwrap();
    let pointer = sftp_read_text_checked_response_for_tests(
        77,
        path.as_ptr(),
        request_id.as_ptr(),
        |session_id, remote_path| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/var/log/syslog");
            Ok("hello\nworld\n".to_string())
        },
    );
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "sftp_text_file");
    assert_eq!(value["data"]["sftp_session_id"], "77");
    assert_eq!(value["data"]["path"], "/var/log/syslog");
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["data"]["byte_length"], 12);
    assert_eq!(value["data"]["content"], "hello\nworld\n");
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::SftpTextFile
    );
    for forbidden in [
        "password",
        "private_key",
        "passphrase",
        "public_key",
        "known_hosts",
    ] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn read_text_payload_rejects_unsafe_path_and_oversized_content() {
    assert!(SftpTextFilePayload::new(77, "/opt/app.log".to_string(), "ok".to_string()).is_ok());
    assert!(SftpTextFilePayload::new(77, "/opt/../secret".to_string(), "ok".to_string()).is_err());
    assert!(SftpTextFilePayload::new(
        77,
        "/opt/large.log".to_string(),
        "x".repeat(2 * 1024 * 1024 + 1)
    )
    .is_err());
}

#[test]
fn read_text_errors_map_to_stable_redacted_codes() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/var/log/syslog").unwrap();
    for (error, expected) in [
        (OrbitCoreError::InvalidInput, "invalid_request"),
        (
            OrbitCoreError::LegacyNetworkDisabled,
            "legacy_session_not_allowed",
        ),
        (
            OrbitCoreError::SshFailed("session_closed password known_hosts".to_string()),
            "security_generation_mismatch",
        ),
        (
            OrbitCoreError::SftpFailed("not utf8 /secret".to_string()),
            "sftp_read_failed",
        ),
        (
            OrbitCoreError::Internal("json includes private_key".to_string()),
            "ffi_internal_error",
        ),
    ] {
        let pointer = sftp_read_text_checked_response_for_tests(
            77,
            path.as_ptr(),
            request_id.as_ptr(),
            move |_, _| async move { Err(error) },
        );
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        for forbidden in ["password", "private_key", "known_hosts", "/secret"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn header_declares_additive_checked_sftp_and_preserves_legacy_signature() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_sftp_open_checked_v1"));
    assert!(header.contains("orbit_sftp_list_checked_v1"));
    assert!(header.contains("orbit_sftp_read_text_checked_v1"));
    assert!(header.contains("orbit_sftp_download_checked_v1"));
    assert!(header.contains("orbit_sftp_upload_checked_v1"));
    assert!(header.contains("orbit_sftp_mkdir_checked_v1"));
    assert!(header.contains("orbit_sftp_create_file_checked_v1"));
    assert!(header.contains("orbit_sftp_rename_checked_v1"));
    assert!(header.contains("orbit_sftp_remove_checked_v1"));
    assert!(header.contains("orbit_sftp_chmod_checked_v1"));
    assert!(header.contains("orbit_sftp_write_text_checked_v1"));
    assert!(header.contains("uint64_t sftp_session_id"));
    assert!(header.contains("const char *remote_path"));
    assert!(header.contains("uint64_t base_session_id"));
    assert!(header.contains("const char *request_id"));
    assert!(header.contains("char *orbit_sftp_connect("));
    assert!(header.contains("const char *private_key_content"));
    assert!(header.contains("char *orbit_sftp_list_dir"));
    assert!(header.contains("char *orbit_sftp_upload_file"));
    assert!(header.contains("char *orbit_sftp_download_file"));
    assert!(header.contains("orbit_free_string"));
}

#[test]
fn download_requires_absolute_local_path_and_returns_redacted_checked_payload() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let remote_path = CString::new("/var/log/syslog").unwrap();
    let relative_path = CString::new("syslog").unwrap();
    let pointer = sftp_download_checked_response_for_tests(
        77,
        remote_path.as_ptr(),
        relative_path.as_ptr(),
        request_id.as_ptr(),
        |_, _, _| async move { Ok(r#"{"bytes":1}"#.to_string()) },
    );
    let (_, relative) = read_and_free(pointer);
    assert_eq!(relative["error"]["code"], "invalid_request");
    assert_eq!(
        relative["error"]["detail_code"],
        "invalid_local_download_path"
    );

    let local_path = CString::new("/tmp/orbitterm-syslog").unwrap();
    let pointer = sftp_download_checked_response_for_tests(
        77,
        remote_path.as_ptr(),
        local_path.as_ptr(),
        request_id.as_ptr(),
        |session_id, remote, local| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote, "/var/log/syslog");
            assert_eq!(local, "/tmp/orbitterm-syslog");
            Ok(r#"{"bytes":42}"#.to_string())
        },
    );
    let (json, success) = read_and_free(pointer);
    assert_eq!(success["kind"], "sftp_download_completed");
    assert_eq!(success["data"]["sftp_session_id"], "77");
    assert_eq!(success["data"]["path"], "/var/log/syslog");
    assert_eq!(success["data"]["byte_length"], 42);
    assert!(!json.contains("orbitterm-syslog"));
}

#[test]
fn download_errors_are_stable_and_redacted() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let remote_path = CString::new("/var/log/syslog").unwrap();
    let local_path = CString::new("/tmp/orbitterm-syslog").unwrap();
    let pointer = sftp_download_checked_response_for_tests(
        77,
        remote_path.as_ptr(),
        local_path.as_ptr(),
        request_id.as_ptr(),
        |_, _, _| async move {
            Err(OrbitCoreError::SftpFailed(
                "permission denied /secret private_key".to_string(),
            ))
        },
    );
    let (json, error) = read_and_free(pointer);
    assert_eq!(error["error"]["code"], "sftp_download_failed");
    for forbidden in ["/secret", "private_key", "orbitterm-syslog"] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn upload_requires_absolute_local_path_and_returns_redacted_checked_payload() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let local_path = CString::new("upload.txt").unwrap();
    let remote_path = CString::new("/srv/upload.txt").unwrap();
    let pointer = sftp_upload_checked_response_for_tests(
        77,
        local_path.as_ptr(),
        remote_path.as_ptr(),
        request_id.as_ptr(),
        |_, _, _| async move { Ok(r#"{"bytes":1}"#.to_string()) },
    );
    let (_, relative) = read_and_free(pointer);
    assert_eq!(relative["error"]["code"], "invalid_request");
    assert_eq!(
        relative["error"]["detail_code"],
        "invalid_local_upload_path"
    );

    let local_path = CString::new("/tmp/orbitterm-upload.txt").unwrap();
    let pointer = sftp_upload_checked_response_for_tests(
        77,
        local_path.as_ptr(),
        remote_path.as_ptr(),
        request_id.as_ptr(),
        |session_id, local, remote| async move {
            assert_eq!(session_id, 77);
            assert_eq!(local, "/tmp/orbitterm-upload.txt");
            assert_eq!(remote, "/srv/upload.txt");
            Ok(r#"{"bytes":42}"#.to_string())
        },
    );
    let (json, success) = read_and_free(pointer);
    assert_eq!(success["kind"], "sftp_upload_completed");
    assert_eq!(success["data"]["path"], "/srv/upload.txt");
    assert_eq!(success["data"]["byte_length"], 42);
    assert!(!json.contains("orbitterm-upload.txt"));
}

#[test]
fn upload_errors_are_stable_and_redacted() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let local_path = CString::new("/tmp/orbitterm-upload.txt").unwrap();
    let remote_path = CString::new("/srv/upload.txt").unwrap();
    let pointer = sftp_upload_checked_response_for_tests(
        77,
        local_path.as_ptr(),
        remote_path.as_ptr(),
        request_id.as_ptr(),
        |_, _, _| async move {
            Err(OrbitCoreError::SftpFailed(
                "exists /secret private_key".to_string(),
            ))
        },
    );
    let (json, error) = read_and_free(pointer);
    assert_eq!(error["error"]["code"], "sftp_upload_failed");
    for forbidden in ["/secret", "private_key", "orbitterm-upload.txt"] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn mkdir_checked_rejects_root_and_returns_typed_payload() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let root = CString::new("/").unwrap();
    let pointer = sftp_mkdir_checked_response_for_tests(
        77,
        root.as_ptr(),
        request_id.as_ptr(),
        |_, _| async move { Ok(()) },
    );
    let (_, rejected) = read_and_free(pointer);
    assert_eq!(rejected["error"]["code"], "invalid_request");
    assert_eq!(
        rejected["error"]["detail_code"],
        "invalid_sftp_mutation_path"
    );

    for root_alias in ["//", "/./", "/srv//folder", "/srv/folder/"] {
        let root_alias = CString::new(root_alias).unwrap();
        let pointer = sftp_mkdir_checked_response_for_tests(
            77,
            root_alias.as_ptr(),
            request_id.as_ptr(),
            |_, _| async move { Ok(()) },
        );
        let (_, rejected) = read_and_free(pointer);
        assert_eq!(rejected["error"]["code"], "invalid_request");
        assert_eq!(
            rejected["error"]["detail_code"],
            "invalid_sftp_mutation_path"
        );
    }

    let path = CString::new("/srv/new-folder").unwrap();
    let pointer = sftp_mkdir_checked_response_for_tests(
        77,
        path.as_ptr(),
        request_id.as_ptr(),
        |session_id, remote_path| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/srv/new-folder");
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["kind"], "sftp_mutation_completed");
    assert_eq!(success["data"]["operation"], "mkdir");
    assert_eq!(success["data"]["path"], "/srv/new-folder");
    assert!(success["data"]["destination_path"].is_null());
}

#[test]
fn create_file_checked_returns_typed_create_file_payload() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/empty.txt").unwrap();
    let pointer = sftp_create_file_checked_response_for_tests(
        77,
        path.as_ptr(),
        request_id.as_ptr(),
        |session_id, remote_path| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/srv/empty.txt");
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["kind"], "sftp_mutation_completed");
    assert_eq!(success["data"]["operation"], "create_file");
    assert_eq!(success["data"]["path"], "/srv/empty.txt");
    assert!(success["data"]["destination_path"].is_null());
}

#[test]
fn chmod_checked_passes_mode_and_snapshot_and_rejects_out_of_range_mode() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/report.txt").unwrap();
    let pointer = sftp_chmod_checked_response_for_tests(
        77,
        path.as_ptr(),
        0o640,
        42,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |session_id, remote_path, mode, snapshot| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/srv/report.txt");
            assert_eq!(mode, 0o640);
            assert_eq!(snapshot.permissions_octal, 0o100_644);
            assert!(!snapshot.is_directory);
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["data"]["operation"], "chmod");
    assert_eq!(success["data"]["path"], "/srv/report.txt");

    let pointer = sftp_chmod_checked_response_for_tests(
        77,
        path.as_ptr(),
        0o10_000,
        42,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |_, _, _, _| async move { Ok(()) },
    );
    let (_, rejected) = read_and_free(pointer);
    assert_eq!(rejected["error"]["code"], "invalid_request");
    assert_eq!(rejected["error"]["detail_code"], "invalid_sftp_permissions");
}

#[test]
fn write_text_checked_copies_utf8_bytes_and_rejects_invalid_content() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/report.txt").unwrap();
    let content = "hello 世界\n".as_bytes();
    let pointer = sftp_write_text_checked_response_for_tests(
        77,
        path.as_ptr(),
        content.as_ptr(),
        content.len(),
        12,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |session_id, remote_path, copied, snapshot| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/srv/report.txt");
            assert_eq!(copied, "hello 世界\n".as_bytes());
            assert_eq!(snapshot.permissions_octal, 0o100_644);
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["data"]["operation"], "write_text");

    let invalid = [0xff_u8];
    let pointer = sftp_write_text_checked_response_for_tests(
        77,
        path.as_ptr(),
        invalid.as_ptr(),
        invalid.len(),
        12,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |_, _, _, _| async move { Ok(()) },
    );
    let (_, rejected) = read_and_free(pointer);
    assert_eq!(
        rejected["error"]["detail_code"],
        "invalid_sftp_text_content"
    );
}

#[test]
fn rename_checked_passes_exact_snapshot_and_rejects_matching_paths() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let old_path = CString::new("/srv/report.txt").unwrap();
    let new_path = CString::new("/srv/report-final.txt").unwrap();
    let pointer = sftp_rename_checked_response_for_tests(
        77,
        old_path.as_ptr(),
        new_path.as_ptr(),
        42,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |session_id, old, new, snapshot| async move {
            assert_eq!(session_id, 77);
            assert_eq!(old, "/srv/report.txt");
            assert_eq!(new, "/srv/report-final.txt");
            assert_eq!(
                snapshot,
                SftpEntrySnapshot {
                    size: 42,
                    permissions_octal: 0o100_644,
                    modified_at_unix: 1_700_000_000,
                    is_directory: false,
                }
            );
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["data"]["operation"], "rename");
    assert_eq!(success["data"]["path"], "/srv/report.txt");
    assert_eq!(success["data"]["destination_path"], "/srv/report-final.txt");

    let pointer = sftp_rename_checked_response_for_tests(
        77,
        old_path.as_ptr(),
        old_path.as_ptr(),
        42,
        0o100_644,
        1_700_000_000,
        0,
        request_id.as_ptr(),
        |_, _, _, _| async move { Ok(()) },
    );
    let (_, rejected) = read_and_free(pointer);
    assert_eq!(rejected["error"]["detail_code"], "sftp_rename_paths_match");
}

#[test]
fn remove_checked_validates_snapshot_shape_and_returns_remove_payload() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/empty").unwrap();
    let pointer = sftp_remove_checked_response_for_tests(
        77,
        path.as_ptr(),
        0,
        0o040_755,
        1_700_000_000,
        2,
        request_id.as_ptr(),
        |_, _, _| async move { Ok(()) },
    );
    let (_, rejected) = read_and_free(pointer);
    assert_eq!(
        rejected["error"]["detail_code"],
        "invalid_sftp_entry_snapshot"
    );

    let pointer = sftp_remove_checked_response_for_tests(
        77,
        path.as_ptr(),
        0,
        0o040_755,
        1_700_000_000,
        1,
        request_id.as_ptr(),
        |session_id, remote_path, snapshot| async move {
            assert_eq!(session_id, 77);
            assert_eq!(remote_path, "/srv/empty");
            assert!(snapshot.is_directory);
            Ok(())
        },
    );
    let (_, success) = read_and_free(pointer);
    assert_eq!(success["data"]["operation"], "remove");
    assert_eq!(success["data"]["path"], "/srv/empty");
}

#[test]
fn mutation_errors_are_stable_and_redacted() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/private").unwrap();
    for (error, expected_code) in [
        (SftpMutationError::SessionUnavailable, "session_not_found"),
        (SftpMutationError::TargetExists, "sftp_target_exists"),
        (SftpMutationError::EntryChanged, "sftp_entry_changed"),
        (SftpMutationError::BackendFailed, "sftp_mutation_failed"),
    ] {
        let pointer = sftp_mkdir_checked_response_for_tests(
            77,
            path.as_ptr(),
            request_id.as_ptr(),
            move |_, _| async move { Err(error) },
        );
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected_code);
        assert!(!json.contains("password"));
        assert!(!json.contains("private_key"));
    }
}

#[test]
fn exported_mutations_reject_unknown_checked_session_without_path_disclosure() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let path = CString::new("/srv/private").unwrap();
    let destination = CString::new("/srv/private-renamed").unwrap();
    let pointers = [
        orbit_sftp_mkdir_checked_v1(u64::MAX, path.as_ptr(), request_id.as_ptr()),
        orbit_sftp_create_file_checked_v1(u64::MAX, path.as_ptr(), request_id.as_ptr()),
        orbit_sftp_rename_checked_v1(
            u64::MAX,
            path.as_ptr(),
            destination.as_ptr(),
            42,
            0o100_600,
            1_700_000_000,
            0,
            request_id.as_ptr(),
        ),
        orbit_sftp_remove_checked_v1(
            u64::MAX,
            path.as_ptr(),
            42,
            0o100_600,
            1_700_000_000,
            0,
            request_id.as_ptr(),
        ),
        orbit_sftp_chmod_checked_v1(
            u64::MAX,
            path.as_ptr(),
            0o600,
            42,
            0o100_600,
            1_700_000_000,
            0,
            request_id.as_ptr(),
        ),
    ];
    for pointer in pointers {
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], "session_not_found");
        assert!(!json.contains("/srv/private"));
    }
}
