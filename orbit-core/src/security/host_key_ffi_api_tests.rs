use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::time::{Duration, SystemTime};

use serde_json::Value;

use super::host_key_ffi_api::{
    challenge_service_for_tests, orbit_hostkey_challenge_accept_v1,
    orbit_hostkey_challenge_cleanup_expired_v1, orbit_hostkey_challenge_reject_v1,
    orbit_hostkey_challenge_status_v1, orbit_hostkey_protocol_version_v1, reset_registry_for_tests,
    HOST_KEY_FFI_TEST_SERIAL,
};
use super::{
    fingerprint_sha256_from_base64, HostIdentity, HostKeyChallengeDraft, HostKeyChallengeReason,
    HostKeyState, PendingChallengeRegistryConfig, PendingHostKeyChallengeRegistry,
    TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;

const PUBLIC_KEY: &str = "AQIDBA==";
const REQUEST_ID: &str = "ffi-request-1";

fn draft() -> HostKeyChallengeDraft {
    let identity = HostIdentity::parse("example.com", 22).expect("identity");
    HostKeyChallengeDraft {
        host: identity.original_host,
        normalized_host: identity.normalized_host,
        port: identity.port,
        lookup_token: identity.lookup_token,
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256_from_base64(PUBLIC_KEY).expect("fingerprint"),
        reason_code: HostKeyChallengeReason::UnknownHostKey,
        known_state: HostKeyState::Unknown,
        can_trust: true,
        can_replace: false,
    }
}

fn reset(config: PendingChallengeRegistryConfig) {
    let registry = PendingHostKeyChallengeRegistry::with_config(config).expect("registry");
    reset_registry_for_tests(registry).expect("reset registry");
}

fn register(now: SystemTime) -> String {
    let generation = TrustStoreGeneration::from_contents(b"ffi-test-store");
    challenge_service_for_tests()
        .register_unknown_challenge(draft(), PUBLIC_KEY, Some(REQUEST_ID), &generation, now)
        .expect("register")
        .challenge_id
        .to_string()
}

fn call_with_id(function: extern "C" fn(*const c_char) -> *mut c_char, id: &str) -> Value {
    let id = CString::new(id).expect("C challenge ID");
    take_json(function(id.as_ptr()))
}

fn take_json(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null());
    // SAFETY: Every tested function returns a valid owned NUL-terminated C string.
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .expect("UTF-8 JSON")
        .to_string();
    orbit_free_string(pointer);
    super::HostKeyFfiEnvelope::from_json(&value).expect("protocol envelope");
    serde_json::from_str(&value).expect("JSON envelope")
}

fn assert_no_sensitive_material(value: &Value) {
    let text = value.to_string();
    assert!(!text.contains(PUBLIC_KEY));
    assert!(!text.contains("/Users/"));
    assert_no_forbidden_keys(value);
}

fn assert_no_forbidden_keys(value: &Value) {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                assert!(
                    !matches!(
                        key.as_str(),
                        "password"
                            | "private_key"
                            | "private_key_content"
                            | "access_token"
                            | "refresh_token"
                            | "known_hosts_path"
                    ),
                    "leaked sensitive field {key}"
                );
                assert_no_forbidden_keys(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                assert_no_forbidden_keys(item);
            }
        }
        _ => {}
    }
}

#[test]
fn protocol_version_returns_versioned_json_and_supported_symbols() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    let value = take_json(orbit_hostkey_protocol_version_v1());

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["kind"], "protocol_version");
    assert_eq!(value["data"]["schema_version"], 1);
    assert!(value["data"]["supported_kinds"]
        .as_array()
        .expect("kinds")
        .contains(&Value::String("host_key_challenge_accepted".to_string())));
    assert!(value["data"]["supported_kinds"]
        .as_array()
        .expect("kinds")
        .contains(&Value::String("terminal_channel_opened".to_string())));
    assert!(value["data"]["supported_error_codes"]
        .as_array()
        .expect("codes")
        .contains(&Value::String("challenge_expired".to_string())));
    assert!(value["data"]["supported_error_codes"]
        .as_array()
        .expect("codes")
        .contains(&Value::String("pty_request_failed".to_string())));
}

#[test]
fn null_and_invalid_utf8_inputs_return_json_errors() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());

    for function in [
        orbit_hostkey_challenge_accept_v1,
        orbit_hostkey_challenge_reject_v1,
        orbit_hostkey_challenge_status_v1,
    ] {
        let value = take_json(function(ptr::null()));
        assert_eq!(value["kind"], "error");
        assert_eq!(value["error"]["code"], "invalid_request");
    }

    let invalid_utf8 = [0xff_u8, 0];
    let value = take_json(orbit_hostkey_challenge_accept_v1(
        invalid_utf8.as_ptr().cast(),
    ));
    assert_eq!(value["error"]["code"], "invalid_utf8");
}

#[test]
fn malformed_and_unknown_ids_have_distinct_error_codes() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());

    let malformed = call_with_id(orbit_hostkey_challenge_status_v1, "not-an-id");
    assert_eq!(malformed["error"]["code"], "invalid_request");

    let unknown = call_with_id(orbit_hostkey_challenge_accept_v1, "AAAAAAAAAAAAAAAAAAAAAA");
    assert_eq!(unknown["error"]["code"], "challenge_not_found");
}

#[test]
fn accept_consumes_without_claiming_persistence_or_exposing_public_key() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let challenge_id = register(SystemTime::now());

    let pending = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(pending["data"]["state"], "pending");

    let accepted = call_with_id(orbit_hostkey_challenge_accept_v1, &challenge_id);
    assert_eq!(accepted["request_id"], REQUEST_ID);
    assert_eq!(accepted["kind"], "host_key_challenge_accepted");
    assert_eq!(accepted["data"]["status"], "accepted_not_persisted");
    assert_no_sensitive_material(&accepted);

    let duplicate = call_with_id(orbit_hostkey_challenge_accept_v1, &challenge_id);
    assert_eq!(duplicate["error"]["code"], "challenge_already_resolved");
    assert_eq!(duplicate["error"]["detail_code"], "accepted");
    assert_eq!(duplicate["error"]["challenge_id"], challenge_id);

    let status = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(status["data"]["state"], "accepted");
}

#[test]
fn reject_consumes_and_returns_no_public_key() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let challenge_id = register(SystemTime::now());

    let rejected = call_with_id(orbit_hostkey_challenge_reject_v1, &challenge_id);
    assert_eq!(rejected["kind"], "host_key_rejected");
    assert_eq!(rejected["data"]["status"], "rejected");
    assert_no_sensitive_material(&rejected);

    let accept = call_with_id(orbit_hostkey_challenge_accept_v1, &challenge_id);
    assert_eq!(accept["error"]["code"], "challenge_already_resolved");
    assert_eq!(accept["error"]["detail_code"], "rejected");

    let status = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(status["data"]["state"], "rejected");
}

#[test]
fn expired_status_and_cleanup_have_stable_semantics() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    let config = PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(1),
        ..PendingChallengeRegistryConfig::default()
    };
    reset(config);
    let challenge_id = register(SystemTime::UNIX_EPOCH);

    let cleanup = take_json(orbit_hostkey_challenge_cleanup_expired_v1());
    assert_eq!(cleanup["kind"], "host_key_cleanup_completed");
    assert_eq!(cleanup["data"]["expired_count"], 1);

    let status = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(status["data"]["state"], "expired");

    let accept = call_with_id(orbit_hostkey_challenge_accept_v1, &challenge_id);
    assert_eq!(accept["error"]["code"], "challenge_expired");
    assert_no_sensitive_material(&accept);
}

#[test]
fn cleanup_empty_registry_returns_valid_summary_and_owned_string() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let value = take_json(orbit_hostkey_challenge_cleanup_expired_v1());

    assert_eq!(value["kind"], "host_key_cleanup_completed");
    assert_eq!(value["data"]["expired_count"], 0);
}

#[test]
fn header_declares_additive_v1_functions_and_preserves_legacy_abi() {
    let header = include_str!("../../include/orbit_core.h");
    for symbol in [
        "orbit_hostkey_challenge_accept_v1",
        "orbit_hostkey_challenge_accept_and_persist_v1",
        "orbit_hostkey_challenge_reject_v1",
        "orbit_hostkey_challenge_status_v1",
        "orbit_hostkey_challenge_cleanup_expired_v1",
        "orbit_hostkey_protocol_version_v1",
    ] {
        assert!(header.contains(symbol), "missing {symbol}");
    }
    assert!(header.contains("orbit_ssh_connect"));
    assert!(header.contains("orbit_free_string"));
}
