use std::ffi::{CStr, CString};
use std::io;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::UNIX_EPOCH;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::Value;

use super::checked_connect_coordinator::{
    CheckedAuthenticationApproval, CheckedConnectPreAuthError, CheckedPreAuthDecision,
};
use super::checked_test_connection::{
    run_authentication_gate, CheckedAuthenticationError, CheckedTestConnectionError,
    CheckedTestConnectionOutcome, CheckedTestConnectionRequest, CheckedTestInputError,
    CheckedTestTimeoutStage,
};
use super::checked_test_connection_ffi::{
    error_payload_for_tests, orbit_test_ssh_connection_checked_v1, outcome_json_for_tests,
    parse_checked_connection_request_with_jump,
};
use super::connect_pre_auth_error::ConnectPreAuthError;
use super::host_key::HostIdentity;
use super::host_key_challenge_registry::PendingHostKeyChallengeRegistry;
use super::host_key_ffi_error::HostKeyFfiErrorCode;
use super::host_key_ffi_protocol::{HostKeyFfiEnvelope, HostKeyFfiResultKind};
use super::host_key_verifier::{
    HostKeyBlockReason, HostKeyVerificationDecision, HostKeyVerificationInput, HostKeyVerifier,
};
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::trust_store_generation::TrustStoreGeneration;
use crate::c_ffi::orbit_free_string;
use crate::ORBIT_RUNTIME;

const REQUEST_ID: &str = "checked-test-request";
const ALGORITHM: &str = "ssh-ed25519";

fn public_key_base64(fill: u8) -> String {
    let mut blob = Vec::new();
    blob.extend_from_slice(&(ALGORITHM.len() as u32).to_be_bytes());
    blob.extend_from_slice(ALGORITHM.as_bytes());
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[fill; 32]);
    STANDARD.encode(blob)
}

fn known_hosts_path(label: &str) -> PathBuf {
    std::env::temp_dir()
        .join(format!(
            "OrbitTerm-checked-test-{label}-{}",
            std::process::id()
        ))
        .join("known_hosts")
}

fn verified_approval() -> CheckedAuthenticationApproval {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let public_key = public_key_base64(7);
    let store =
        KnownHostsStore::from_text(&format!("example.com {ALGORITHM} {public_key}")).unwrap();
    let HostKeyVerificationDecision::Proceed(verified) = HostKeyVerifier.verify(
        &store,
        &HostKeyVerificationInput {
            host_identity: identity,
            key_algorithm: ALGORITHM.to_string(),
            public_key_base64: public_key,
        },
    ) else {
        panic!("trusted fixture");
    };
    let generation = TrustStoreGeneration::from_store(&store);
    CheckedAuthenticationApproval::new(verified, generation)
}

fn blocked_outcome(reason: HostKeyBlockReason) -> CheckedTestConnectionOutcome {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let trusted_key = public_key_base64(8);
    let presented_key = if reason == HostKeyBlockReason::Changed {
        public_key_base64(9)
    } else {
        trusted_key.clone()
    };
    let marker = match reason {
        HostKeyBlockReason::Revoked => "@revoked ",
        HostKeyBlockReason::CertificateAuthorityUnsupported => "@cert-authority ",
        HostKeyBlockReason::UnsupportedRecord => "@future-marker ",
        HostKeyBlockReason::Changed => "",
    };
    let store =
        KnownHostsStore::from_text(&format!("{marker}example.com {ALGORITHM} {trusted_key}"))
            .unwrap();
    let HostKeyVerificationDecision::Block(block) = HostKeyVerifier.verify(
        &store,
        &HostKeyVerificationInput {
            host_identity: identity,
            key_algorithm: ALGORITHM.to_string(),
            public_key_base64: presented_key,
        },
    ) else {
        panic!("blocked fixture");
    };
    CheckedTestConnectionOutcome::Blocked(Box::new(block))
}

fn challenge_outcome() -> (CheckedTestConnectionOutcome, String) {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let public_key = public_key_base64(10);
    let HostKeyVerificationDecision::Challenge(draft) = HostKeyVerifier.verify(
        &KnownHostsStore::empty(),
        &HostKeyVerificationInput {
            host_identity: identity,
            key_algorithm: ALGORITHM.to_string(),
            public_key_base64: public_key.clone(),
        },
    ) else {
        panic!("unknown fixture");
    };
    let registered = PendingHostKeyChallengeRegistry::new()
        .register_or_reuse_unknown_challenge(
            draft,
            &public_key,
            Some(REQUEST_ID),
            &TrustStoreGeneration::from_contents(b"empty"),
            UNIX_EPOCH,
        )
        .unwrap();
    (
        CheckedTestConnectionOutcome::Challenge(Box::new(registered)),
        public_key,
    )
}

#[allow(clippy::too_many_arguments)]
fn call_checked(
    host: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key: *const c_char,
    passphrase: *const c_char,
    path: *const c_char,
    request_id: *const c_char,
) -> Value {
    let pointer = orbit_test_ssh_connection_checked_v1(
        host,
        port,
        username,
        password,
        private_key,
        passphrase,
        1,
        path,
        request_id,
    );
    assert!(!pointer.is_null());
    // SAFETY: The checked C ABI returns a NUL-terminated Rust-owned string.
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap()
        .to_string();
    orbit_free_string(pointer);
    serde_json::from_str(&json).unwrap()
}

fn c_string(value: &str) -> CString {
    CString::new(value).unwrap()
}

#[test]
fn request_validation_and_debug_exclude_credentials_and_path() {
    let path = known_hosts_path("redaction");
    let path_text = path.to_string_lossy().to_string();
    let request = CheckedTestConnectionRequest::new(
        "example.com".to_string(),
        22,
        "root".to_string(),
        "password-secret".to_string(),
        "private-key-secret".to_string(),
        "passphrase-secret".to_string(),
        true,
        path,
        REQUEST_ID.to_string(),
    )
    .unwrap();
    assert_eq!(request.request_id(), REQUEST_ID);
    let debug = format!("{request:?}");
    for secret in [
        "password-secret",
        "private-key-secret",
        "passphrase-secret",
        &path_text,
    ] {
        assert!(!debug.contains(secret));
    }

    assert!(matches!(
        CheckedTestConnectionRequest::new(
            "example.com".to_string(),
            22,
            "root".to_string(),
            String::new(),
            String::new(),
            String::new(),
            false,
            known_hosts_path("missing-credentials"),
            REQUEST_ID.to_string(),
        ),
        Err(CheckedTestInputError::MissingCredentials)
    ));
    assert!(matches!(
        CheckedTestConnectionRequest::new(
            "example.com".to_string(),
            22,
            "root".to_string(),
            "secret".to_string(),
            String::new(),
            String::new(),
            false,
            PathBuf::from("/tmp/known_hosts"),
            REQUEST_ID.to_string(),
        ),
        Err(CheckedTestInputError::InvalidKnownHostsPath)
    ));
}

#[test]
fn jump_ffi_request_keeps_hop_credentials_redacted_and_separate() {
    let target_host = c_string("target.example.com");
    let target_username = c_string("target-user");
    let target_password = c_string("target-password-secret");
    let jump_host = c_string("bastion.example.com");
    let jump_username = c_string("jump-user");
    let jump_password = c_string("jump-password-secret");
    let known_hosts = c_string(known_hosts_path("jump-ffi").to_str().unwrap());
    let request_id = c_string(REQUEST_ID);

    let request = parse_checked_connection_request_with_jump(
        target_host.as_ptr(),
        22,
        target_username.as_ptr(),
        target_password.as_ptr(),
        ptr::null(),
        ptr::null(),
        0,
        1,
        jump_host.as_ptr(),
        2222,
        jump_username.as_ptr(),
        jump_password.as_ptr(),
        ptr::null(),
        ptr::null(),
        0,
        known_hosts.as_ptr(),
        request_id.as_ptr(),
    )
    .expect("valid one-hop request");

    let jump = request.jump_host().expect("jump host is preserved");
    assert_eq!(jump.route_identity(), "jump-user@bastion.example.com:2222");

    let debug = format!("{request:?} {jump:?}");
    for secret in ["target-password-secret", "jump-password-secret"] {
        assert!(!debug.contains(secret));
    }
}

#[cfg(unix)]
#[test]
fn request_rejects_symlinked_known_hosts_file() {
    use std::os::unix::fs::symlink;

    let parent = known_hosts_path("symlink").parent().unwrap().to_path_buf();
    let _ = std::fs::remove_dir_all(&parent);
    std::fs::create_dir_all(&parent).unwrap();
    let target = parent.join("target_known_hosts");
    let linked = parent.join("known_hosts");
    std::fs::write(&target, "").unwrap();
    symlink(&target, &linked).unwrap();

    let result = CheckedTestConnectionRequest::new(
        "example.com".to_string(),
        22,
        "root".to_string(),
        "secret".to_string(),
        String::new(),
        String::new(),
        false,
        linked,
        REQUEST_ID.to_string(),
    );
    assert!(matches!(
        result,
        Err(CheckedTestInputError::InvalidKnownHostsPath)
    ));
    std::fs::remove_dir_all(parent).unwrap();
}

#[test]
fn ffi_null_invalid_utf8_port_and_missing_credential_inputs_return_json_errors() {
    let host = c_string("example.com");
    let username = c_string("root");
    let password = c_string("secret");
    let path = c_string(known_hosts_path("ffi-input").to_str().unwrap());
    let request_id = c_string(REQUEST_ID);

    let missing_request_id = call_checked(
        host.as_ptr(),
        22,
        username.as_ptr(),
        password.as_ptr(),
        ptr::null(),
        ptr::null(),
        path.as_ptr(),
        ptr::null(),
    );
    assert_eq!(missing_request_id["error"]["code"], "invalid_request");
    assert!(missing_request_id["request_id"].is_null());

    for (host_ptr, user_ptr, path_ptr) in [
        (ptr::null(), username.as_ptr(), path.as_ptr()),
        (host.as_ptr(), ptr::null(), path.as_ptr()),
        (host.as_ptr(), username.as_ptr(), ptr::null()),
    ] {
        let value = call_checked(
            host_ptr,
            22,
            user_ptr,
            password.as_ptr(),
            ptr::null(),
            ptr::null(),
            path_ptr,
            request_id.as_ptr(),
        );
        assert_eq!(value["kind"], "error");
        assert_eq!(value["error"]["code"], "invalid_request");
        assert_eq!(value["request_id"], REQUEST_ID);
    }

    let invalid_utf8 = CString::new(vec![0xff]).unwrap();
    for (host_ptr, path_ptr) in [
        (invalid_utf8.as_ptr(), path.as_ptr()),
        (host.as_ptr(), invalid_utf8.as_ptr()),
    ] {
        let value = call_checked(
            host_ptr,
            22,
            username.as_ptr(),
            password.as_ptr(),
            ptr::null(),
            ptr::null(),
            path_ptr,
            request_id.as_ptr(),
        );
        assert_eq!(value["error"]["code"], "invalid_utf8");
    }

    let invalid_port = call_checked(
        host.as_ptr(),
        70_000,
        username.as_ptr(),
        password.as_ptr(),
        ptr::null(),
        ptr::null(),
        path.as_ptr(),
        request_id.as_ptr(),
    );
    assert_eq!(invalid_port["error"]["detail_code"], "invalid_port");

    let missing_credentials = call_checked(
        host.as_ptr(),
        22,
        username.as_ptr(),
        ptr::null(),
        ptr::null(),
        ptr::null(),
        path.as_ptr(),
        request_id.as_ptr(),
    );
    assert_eq!(
        missing_credentials["error"]["detail_code"],
        "missing_credentials"
    );
}

#[test]
fn challenge_blocked_success_and_error_json_keep_stable_distinct_semantics() {
    let (challenge, full_public_key) = challenge_outcome();
    let challenge_json = outcome_json_for_tests(challenge, REQUEST_ID);
    let challenge_envelope = HostKeyFfiEnvelope::from_json(&challenge_json).unwrap();
    assert_eq!(
        challenge_envelope.kind(),
        HostKeyFfiResultKind::HostKeyChallenge
    );
    assert!(!challenge_json.contains(&full_public_key));

    for reason in [
        HostKeyBlockReason::Changed,
        HostKeyBlockReason::Revoked,
        HostKeyBlockReason::UnsupportedRecord,
    ] {
        let json = outcome_json_for_tests(blocked_outcome(reason), REQUEST_ID);
        assert_eq!(
            HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
            HostKeyFfiResultKind::HostKeyBlocked
        );
    }

    let success = outcome_json_for_tests(
        CheckedTestConnectionOutcome::Succeeded(verified_approval()),
        REQUEST_ID,
    );
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&success).unwrap().kind(),
        HostKeyFfiResultKind::ConnectionTestSucceeded
    );

    let cases = [
        (
            CheckedTestConnectionError::Authentication(CheckedAuthenticationError::Failed),
            HostKeyFfiErrorCode::SshAuthFailed,
        ),
        (
            CheckedTestConnectionError::Connect(ConnectPreAuthError::Protocol(
                russh::Error::Disconnect,
            )),
            HostKeyFfiErrorCode::SshConnectFailed,
        ),
        (
            CheckedTestConnectionError::Timeout {
                stage: CheckedTestTimeoutStage::Connect,
            },
            HostKeyFfiErrorCode::SshTimeout,
        ),
        (
            CheckedTestConnectionError::PreAuthentication(
                CheckedConnectPreAuthError::VerifiedSlotEmpty,
            ),
            HostKeyFfiErrorCode::FfiInternalError,
        ),
        (
            CheckedTestConnectionError::PreAuthentication(
                CheckedConnectPreAuthError::StoreReloadFailed(KnownHostsStoreError::ReadFailed {
                    kind: io::ErrorKind::PermissionDenied,
                }),
            ),
            HostKeyFfiErrorCode::KnownHostsPermissionDenied,
        ),
    ];
    for (error, expected) in cases {
        assert_eq!(error_payload_for_tests(&error, REQUEST_ID).code, expected);
    }
}

#[test]
fn authentication_gate_invokes_runner_only_for_allow_decision() {
    let calls = AtomicUsize::new(0);
    let blocked = match blocked_outcome(HostKeyBlockReason::Revoked) {
        CheckedTestConnectionOutcome::Blocked(block) => block,
        _ => unreachable!(),
    };
    let outcome = ORBIT_RUNTIME.block_on(run_authentication_gate(
        CheckedPreAuthDecision::Block(blocked),
        || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        },
    ));
    assert!(matches!(outcome, CheckedTestConnectionOutcome::Blocked(_)));
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let outcome = ORBIT_RUNTIME.block_on(run_authentication_gate(
        CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::StoreGenerationChangedUnknown),
        || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        },
    ));
    assert!(matches!(outcome, CheckedTestConnectionOutcome::Error(_)));
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let outcome = ORBIT_RUNTIME.block_on(run_authentication_gate(
        CheckedPreAuthDecision::AllowAuthentication(verified_approval()),
        || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        },
    ));
    assert!(matches!(
        outcome,
        CheckedTestConnectionOutcome::Succeeded(_)
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn json_outputs_exclude_credentials_public_key_and_known_hosts_path() {
    let (challenge, full_public_key) = challenge_outcome();
    let outputs = [
        outcome_json_for_tests(challenge, REQUEST_ID),
        outcome_json_for_tests(
            CheckedTestConnectionOutcome::Error(CheckedTestConnectionError::Authentication(
                CheckedAuthenticationError::Failed,
            )),
            REQUEST_ID,
        ),
    ];
    for output in outputs {
        assert!(!output.contains(&full_public_key));
        for forbidden in [
            "\"password\":",
            "\"private_key\":",
            "\"private_key_passphrase\":",
            "\"known_hosts_path\":",
            "\"token\":",
        ] {
            assert!(!output.contains(forbidden));
        }
    }
}

#[test]
fn header_declares_checked_test_symbol_without_removing_legacy_entries() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_test_ssh_connection_checked_v1"));
    assert!(header.contains("char *orbit_test_ssh_connection("));
    assert!(header.contains("char *orbit_ssh_connect("));
    assert!(header.contains("orbit_free_string"));
}
