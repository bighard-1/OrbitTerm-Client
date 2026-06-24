use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, SystemTime};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use rand::random;
use serde_json::Value;

use super::host_key_ffi_api::{
    challenge_service_for_tests, orbit_hostkey_challenge_accept_and_persist_v1,
    orbit_hostkey_challenge_accept_v1, orbit_hostkey_challenge_reject_v1,
    orbit_hostkey_challenge_status_v1, reset_registry_for_tests, HOST_KEY_FFI_TEST_SERIAL,
};
use super::{
    fingerprint_sha256_from_base64, HostIdentity, HostKeyChallengeDraft, HostKeyChallengeReason,
    HostKeyState, KnownHostsStore, PendingChallengeRegistryConfig, PendingHostKeyChallengeRegistry,
    TrustStoreGeneration, DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE,
};
use crate::c_ffi::orbit_free_string;

const KEY_A: &str = "AQIDBA==";
const KEY_B: &str = "BQYHCA==";

fn draft(host: &str, port: u16, key: &str) -> HostKeyChallengeDraft {
    let identity = HostIdentity::parse(host, port).expect("identity");
    HostKeyChallengeDraft {
        host: identity.original_host,
        normalized_host: identity.normalized_host,
        port: identity.port,
        lookup_token: identity.lookup_token,
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256_from_base64(key).expect("fingerprint"),
        reason_code: HostKeyChallengeReason::UnknownHostKey,
        known_state: HostKeyState::Unknown,
        can_trust: true,
        can_replace: false,
    }
}

fn reset(config: PendingChallengeRegistryConfig) {
    reset_registry_for_tests(
        PendingHostKeyChallengeRegistry::with_config(config).expect("registry"),
    )
    .expect("reset registry");
}

fn register(host: &str, port: u16, key: &str, now: SystemTime) -> String {
    let generation = TrustStoreGeneration::from_contents(b"persistence-test-store");
    challenge_service_for_tests()
        .register_unknown_challenge(
            draft(host, port, key),
            key,
            Some("persist-request"),
            &generation,
            now,
        )
        .expect("register")
        .challenge_id
        .to_string()
}

fn persist(challenge_id: &str, path: &Path, comment: Option<&str>) -> Value {
    let challenge_id = CString::new(challenge_id).expect("challenge ID");
    let path = CString::new(path.to_string_lossy().as_bytes()).expect("path");
    let comment = comment.map(|value| CString::new(value).expect("comment"));
    take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        challenge_id.as_ptr(),
        path.as_ptr(),
        comment.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
    ))
}

fn call_with_id(function: extern "C" fn(*const c_char) -> *mut c_char, id: &str) -> Value {
    let id = CString::new(id).expect("challenge ID");
    take_json(function(id.as_ptr()))
}

fn take_json(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null());
    // SAFETY: The ABI returns an owned, valid, NUL-terminated C string.
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .expect("UTF-8 JSON")
        .to_string();
    orbit_free_string(pointer);
    super::HostKeyFfiEnvelope::from_json(&json).expect("protocol envelope");
    serde_json::from_str(&json).expect("JSON")
}

fn assert_pending(challenge_id: &str) {
    let status = call_with_id(orbit_hostkey_challenge_status_v1, challenge_id);
    assert_eq!(status["data"]["state"], "pending");
}

fn assert_redacted(value: &Value, path: &Path) {
    let json = value.to_string();
    assert!(!json.contains(KEY_A));
    assert!(!json.contains(&path.to_string_lossy().to_string()));
    for key in [
        "password",
        "private_key",
        "private_key_content",
        "access_token",
        "refresh_token",
        "known_hosts_path",
    ] {
        assert!(!value_has_key(value, key), "leaked key {key}");
    }
}

fn value_has_key(value: &Value, key: &str) -> bool {
    match value {
        Value::Object(object) => {
            object.contains_key(key) || object.values().any(|child| value_has_key(child, key))
        }
        Value::Array(items) => items.iter().any(|item| value_has_key(item, key)),
        _ => false,
    }
}

#[test]
fn ffi_rejects_null_and_invalid_utf8_inputs() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let valid_id = CString::new("AAAAAAAAAAAAAAAAAAAAAA").unwrap();
    let valid_path = CString::new("/tmp/OrbitTerm/known_hosts").unwrap();

    let null_id = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        ptr::null(),
        valid_path.as_ptr(),
        ptr::null(),
    ));
    assert_eq!(null_id["error"]["code"], "invalid_request");

    let null_path = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        valid_id.as_ptr(),
        ptr::null(),
        ptr::null(),
    ));
    assert_eq!(null_path["error"]["code"], "invalid_request");

    let invalid_utf8 = [0xff_u8, 0];
    let invalid_id = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        invalid_utf8.as_ptr().cast(),
        valid_path.as_ptr(),
        ptr::null(),
    ));
    assert_eq!(invalid_id["error"]["code"], "invalid_utf8");

    let invalid_path = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        valid_id.as_ptr(),
        invalid_utf8.as_ptr().cast(),
        ptr::null(),
    ));
    assert_eq!(invalid_path["error"]["code"], "invalid_utf8");

    let invalid_comment = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        valid_id.as_ptr(),
        valid_path.as_ptr(),
        invalid_utf8.as_ptr().cast(),
    ));
    assert_eq!(invalid_comment["error"]["code"], "invalid_utf8");

    let malformed_id = CString::new("not-an-id").unwrap();
    let malformed = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        malformed_id.as_ptr(),
        valid_path.as_ptr(),
        ptr::null(),
    ));
    assert_eq!(malformed["error"]["code"], "invalid_request");

    let unknown = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        valid_id.as_ptr(),
        valid_path.as_ptr(),
        ptr::null(),
    ));
    assert_eq!(unknown["error"]["code"], "challenge_not_found");
}

#[test]
fn unknown_host_is_atomically_saved_then_marked_persisted() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let directory = TestDirectory::new();
    let path = directory.path().join("nested/OrbitTerm/known_hosts");
    let challenge_id = register("Example.COM", 22, KEY_A, SystemTime::now());

    let response = persist(&challenge_id, &path, Some("ops\n managed"));
    assert_eq!(response["kind"], "host_key_trust_persisted");
    assert_eq!(response["data"]["status"], "trusted_added");
    assert_redacted(&response, &path);

    let store = KnownHostsStore::load(&path).expect("reload");
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    assert_eq!(
        store.query(&identity, "ssh-ed25519", KEY_A).state,
        HostKeyState::Trusted
    );
    assert!(fs::read_to_string(&path)
        .expect("known_hosts")
        .contains("ops managed"));
    #[cfg(unix)]
    {
        let file_mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        let parent_mode = fs::metadata(path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(file_mode, 0o600);
        assert_eq!(parent_mode, 0o700);
    }
    let status = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(status["data"]["state"], "persisted");

    let duplicate = persist(&challenge_id, &path, None);
    assert_eq!(duplicate["error"]["code"], "challenge_already_resolved");
}

#[test]
fn already_trusted_is_idempotent_and_consumes_challenge() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let directory = TestDirectory::new();
    let path = directory.path().join("OrbitTerm/known_hosts");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, Some("existing"))
        .unwrap();
    store.save(&path).unwrap();
    let before = fs::read(&path).unwrap();
    let challenge_id = register("example.com", 22, KEY_A, SystemTime::now());

    let response = persist(&challenge_id, &path, None);
    assert_eq!(response["data"]["status"], "already_trusted");
    assert_eq!(fs::read(&path).unwrap(), before);
    let status = call_with_id(orbit_hostkey_challenge_status_v1, &challenge_id);
    assert_eq!(status["data"]["state"], "persisted");
}

#[test]
fn custom_port_ipv6_and_dns_ip_isolation_are_preserved() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let directory = TestDirectory::new();
    let path = directory.path().join("OrbitTerm/known_hosts");

    let custom_id = register("example.com", 2222, KEY_A, SystemTime::now());
    assert_eq!(
        persist(&custom_id, &path, None)["data"]["status"],
        "trusted_added"
    );
    let ipv6_id = register("2001:db8::1", 2222, KEY_A, SystemTime::now());
    assert_eq!(
        persist(&ipv6_id, &path, None)["data"]["status"],
        "trusted_added"
    );

    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("[example.com]:2222"));
    assert!(text.contains("[2001:db8::1]:2222"));
    assert!(text.contains("OrbitTerm"));
    let store = KnownHostsStore::load(&path).unwrap();
    assert_eq!(
        store
            .query(
                &HostIdentity::parse("192.0.2.10", 2222).unwrap(),
                "ssh-ed25519",
                KEY_A
            )
            .state,
        HostKeyState::Unknown
    );
}

#[test]
fn changed_revoked_and_cert_authority_records_fail_closed_without_consuming() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    let cases = [
        (
            format!("example.com ssh-ed25519 {KEY_B}\n"),
            "host_key_changed",
        ),
        (
            format!("@revoked example.com ssh-ed25519 {KEY_A}\n"),
            "host_key_revoked",
        ),
        (
            format!("@cert-authority example.com ssh-ed25519 {KEY_A}\n"),
            "host_key_unsupported",
        ),
    ];

    for (index, (contents, expected_code)) in cases.into_iter().enumerate() {
        reset(PendingChallengeRegistryConfig::default());
        let directory = TestDirectory::new();
        let path = directory
            .path()
            .join(format!("OrbitTerm-{index}/known_hosts"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, contents).unwrap();
        let before = fs::read(&path).unwrap();
        let challenge_id = register("example.com", 22, KEY_A, SystemTime::now());

        let response = persist(&challenge_id, &path, None);
        assert_eq!(response["error"]["code"], expected_code);
        assert_redacted(&response, &path);
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_pending(&challenge_id);
    }
}

#[test]
fn oversized_file_invalid_comment_and_non_orbitterm_path_do_not_consume() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let directory = TestDirectory::new();
    let oversized_path = directory.path().join("OrbitTerm/known_hosts");
    fs::create_dir_all(oversized_path.parent().unwrap()).unwrap();
    fs::write(
        &oversized_path,
        vec![b'x'; DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE + 1],
    )
    .unwrap();
    let oversized_id = register("large.example", 22, KEY_A, SystemTime::now());
    let oversized = persist(&oversized_id, &oversized_path, None);
    assert_eq!(oversized["error"]["code"], "known_hosts_file_too_large");
    assert_redacted(&oversized, &oversized_path);
    assert_pending(&oversized_id);

    let comment_path = directory.path().join("OrbitTerm-comment/known_hosts");
    let comment_id = register("comment.example", 22, KEY_A, SystemTime::now());
    let long_comment = "x".repeat(513);
    let comment = persist(&comment_id, &comment_path, Some(&long_comment));
    assert_eq!(comment["error"]["code"], "invalid_request");
    assert_pending(&comment_id);

    let invalid_path = directory.path().join(".ssh/known_hosts");
    let invalid_id = register("path.example", 22, KEY_A, SystemTime::now());
    let invalid = persist(&invalid_id, &invalid_path, None);
    assert_eq!(invalid["error"]["code"], "invalid_request");
    assert!(!invalid_path.exists());
    assert_pending(&invalid_id);
}

#[test]
fn expired_rejected_and_plain_accepted_challenges_never_write() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    let directory = TestDirectory::new();
    let path = directory.path().join("OrbitTerm/known_hosts");

    reset(PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(1),
        ..PendingChallengeRegistryConfig::default()
    });
    let expired_id = register("expired.example", 22, KEY_A, SystemTime::UNIX_EPOCH);
    let expired = persist(&expired_id, &path, None);
    assert_eq!(expired["error"]["code"], "challenge_expired");
    assert!(!path.exists());

    reset(PendingChallengeRegistryConfig::default());
    let rejected_id = register("rejected.example", 22, KEY_A, SystemTime::now());
    call_with_id(orbit_hostkey_challenge_reject_v1, &rejected_id);
    let rejected = persist(&rejected_id, &path, None);
    assert_eq!(rejected["error"]["code"], "challenge_already_resolved");
    assert!(!path.exists());

    reset(PendingChallengeRegistryConfig::default());
    let accepted_id = register("accepted.example", 22, KEY_A, SystemTime::now());
    call_with_id(orbit_hostkey_challenge_accept_v1, &accepted_id);
    let accepted = persist(&accepted_id, &path, None);
    assert_eq!(accepted["error"]["code"], "challenge_already_resolved");
    assert!(!path.exists());
}

#[cfg(unix)]
#[test]
fn permission_failure_does_not_consume_challenge() {
    let _serial = HOST_KEY_FFI_TEST_SERIAL.lock().expect("test serial");
    reset(PendingChallengeRegistryConfig::default());
    let directory = TestDirectory::new();
    let parent = directory.path().join("OrbitTerm-readonly");
    fs::create_dir_all(&parent).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o500)).unwrap();
    let path = parent.join("known_hosts");
    let challenge_id = register("permission.example", 22, KEY_A, SystemTime::now());

    let response = persist(&challenge_id, &path, None);
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(response["error"]["code"], "known_hosts_permission_denied");
    assert_redacted(&response, &path);
    assert!(!path.exists());
    assert_pending(&challenge_id);
}

struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "orbitterm-trust-persistence-test-{}-{:016x}",
            std::process::id(),
            random::<u64>()
        ));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
