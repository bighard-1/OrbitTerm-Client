use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::Value;

use super::checked_ssh_connect::{
    authentication_error_for_tests, CheckedSessionPoolStage, CheckedSshConnectError,
    CheckedSshConnectOutcome,
};
use super::checked_ssh_connect_ffi::{
    error_payload_for_tests, orbit_ssh_connect_checked_v1, outcome_json_for_tests,
};
use super::host_key::HostIdentity;
use super::host_key_challenge_registry::PendingHostKeyChallengeRegistry;
use super::host_key_ffi_error::HostKeyFfiErrorCode;
use super::host_key_ffi_protocol::{
    HostKeyConnectedPayload, HostKeyFfiEnvelope, HostKeyFfiResultKind,
};
use super::host_key_verifier::{
    HostKeyBlockReason, HostKeyVerificationDecision, HostKeyVerificationInput, HostKeyVerifier,
    SessionSecurityGeneration,
};
use super::known_hosts_store::KnownHostsStore;
use super::trust_store_generation::TrustStoreGeneration;
use crate::c_ffi::orbit_free_string;

const REQUEST_ID: &str = "checked-connect-request";
const ALGORITHM: &str = "ssh-ed25519";

#[tokio::test]
async fn timed_out_pool_waiter_is_dropped_without_late_acquisition() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    for stage in [
        CheckedSessionPoolStage::CreationGate,
        CheckedSessionPoolStage::ExactLookup,
    ] {
        let gate = tokio::sync::Mutex::new(());
        let guard = gate.lock().await;
        let acquired = AtomicBool::new(false);
        let result = super::checked_ssh_connect::wait_for_session_pool(
            async {
                let _guard = gate.lock().await;
                acquired.store(true, Ordering::SeqCst);
            },
            stage,
            Duration::from_millis(20),
        )
        .await;
        assert!(matches!(
            result,
            Err(CheckedSshConnectError::SessionPoolTimeout { .. })
        ));
        drop(guard);
        // A fresh caller can proceed; the expired operation never runs later.
        assert!(gate.try_lock().is_ok());
        tokio::task::yield_now().await;
        assert!(!acquired.load(Ordering::SeqCst));
    }
}

#[test]
fn pool_timeout_payload_preserves_a_closed_stage_without_session_data() {
    for (stage, detail) in [
        (
            CheckedSessionPoolStage::CandidateLookup,
            "session_pool_lookup_timeout",
        ),
        (
            CheckedSessionPoolStage::CreationGate,
            "session_pool_creation_timeout",
        ),
        (
            CheckedSessionPoolStage::ExactLookup,
            "session_pool_exact_lookup_timeout",
        ),
    ] {
        let json = outcome_json_for_tests(
            CheckedSshConnectOutcome::Error(CheckedSshConnectError::SessionPoolTimeout { stage }),
            REQUEST_ID,
        );
        let value: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["error"]["code"], "ssh_timeout");
        assert_eq!(value["error"]["detail_code"], detail);
        assert_eq!(value["request_id"], REQUEST_ID);
        assert!(!json.contains("password"));
        assert!(!json.contains("session_id"));
        assert!(!json.contains("127.0.0.1"));
    }
}

#[tokio::test]
async fn contended_keyed_gate_and_exact_lookup_preserve_the_reusable_session() {
    use std::sync::atomic::Ordering;
    use std::time::{Duration, SystemTime};

    let username = format!(
        "exact-pool-wait-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    let generation = verified_generation();
    let base = crate::session_pool::insert_synthetic_base_session_for_tests(
        "example.com",
        &username,
        generation.clone(),
    )
    .unwrap();
    crate::session_pool::index_synthetic_base_session_for_tests(&base);
    let gate = crate::session_pool::base_session_creation_gate(&base.key).unwrap();
    let guard = gate.lock().await;
    let gate_result = super::checked_ssh_connect::wait_for_session_pool(
        gate.lock(),
        CheckedSessionPoolStage::CreationGate,
        Duration::from_millis(20),
    )
    .await;
    drop(guard);
    assert!(matches!(
        gate_result,
        Err(CheckedSshConnectError::SessionPoolTimeout {
            stage: CheckedSessionPoolStage::CreationGate
        })
    ));
    assert!(gate.try_lock().is_ok());

    let guard = base.ssh.lock().await;
    let reuse_result = super::checked_ssh_connect::wait_for_session_pool(
        crate::session_pool::try_reuse_checked_base_session(&username, generation.clone()),
        CheckedSessionPoolStage::ExactLookup,
        Duration::from_millis(20),
    )
    .await;
    drop(guard);
    let references_after_timeout = base.channel_ref_count.load(Ordering::SeqCst);
    let retry = crate::session_pool::try_reuse_checked_base_session(&username, generation)
        .await
        .unwrap();
    crate::session_pool::remove_synthetic_base_session_for_tests(base.id);

    assert!(matches!(
        reuse_result,
        Err(CheckedSshConnectError::SessionPoolTimeout {
            stage: CheckedSessionPoolStage::ExactLookup
        })
    ));
    assert_eq!(references_after_timeout, 1);
    assert_eq!(retry.unwrap().id, base.id);
    assert_eq!(base.channel_ref_count.load(Ordering::SeqCst), 2);
    assert_eq!(
        base.metadata.state().unwrap(),
        super::SessionLifecycleState::Active
    );
}

#[tokio::test]
async fn busy_verified_session_lookup_returns_a_bounded_error_without_replacing_the_session() {
    use std::sync::atomic::Ordering;
    use std::time::{Duration, SystemTime};

    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::env::temp_dir().join(format!("OrbitTerm-checked-pool-wait-{unique}"));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("known_hosts");
    let public_key = public_key_base64(4);
    std::fs::write(&path, format!("[127.0.0.1]:2222 {ALGORITHM} {public_key}")).unwrap();
    let store = KnownHostsStore::load(&path).unwrap();
    let identity = HostIdentity::parse("127.0.0.1", 2222).unwrap();
    let HostKeyVerificationDecision::Proceed(verified) = HostKeyVerifier.verify(
        &store,
        &HostKeyVerificationInput {
            host_identity: identity,
            key_algorithm: ALGORITHM.into(),
            public_key_base64: public_key,
        },
    ) else {
        panic!("trusted local fixture")
    };
    let generation = SessionSecurityGeneration::from_verified(
        &verified,
        TrustStoreGeneration::from_store(&store),
    );
    let username = format!("pool-wait-{unique}");
    let base = crate::session_pool::insert_synthetic_base_session_for_tests(
        "127.0.0.1",
        &username,
        generation,
    )
    .unwrap();
    let request = super::checked_test_connection::CheckedTestConnectionRequest::new(
        "127.0.0.1".into(),
        2222,
        username,
        "test-only".into(),
        String::new(),
        String::new(),
        false,
        path,
        REQUEST_ID.into(),
    )
    .unwrap();
    let initial = crate::session_pool::lookup_verified_session_for_store(
        request.host_identity(),
        request.username(),
        &super::checked_test_connection::load_checked_trust_store_generation(&request).unwrap(),
    )
    .await
    .unwrap()
    .expect("fixture must hit the existing verified session before testing contention");
    assert_eq!(initial.id, base.id);
    crate::session_pool::release_base_session(initial.id)
        .await
        .unwrap();
    let guard = base.ssh.lock().await;
    let result = tokio::time::timeout(
        Duration::from_secs(20),
        super::checked_ssh_connect::run_checked_ssh_connect(request),
    )
    .await;
    drop(guard);
    crate::session_pool::remove_synthetic_base_session_for_tests(base.id);
    std::fs::remove_dir_all(directory).unwrap();

    let outcome =
        result.expect("a busy pooled SSH handle must not hold a new connection indefinitely");
    let CheckedSshConnectOutcome::Error(error) = outcome else {
        panic!("busy session must not be reused")
    };
    let payload = error_payload_for_tests(&error, REQUEST_ID);
    assert_eq!(payload.code, HostKeyFfiErrorCode::SshTimeout);
    assert_eq!(
        payload.detail_code.as_deref(),
        Some("session_pool_lookup_timeout")
    );
    assert_eq!(base.channel_ref_count.load(Ordering::SeqCst), 1);
    assert_eq!(
        base.metadata.state().unwrap(),
        super::SessionLifecycleState::Active
    );
}

fn public_key_base64(fill: u8) -> String {
    let mut blob = Vec::new();
    blob.extend_from_slice(&(ALGORITHM.len() as u32).to_be_bytes());
    blob.extend_from_slice(ALGORITHM.as_bytes());
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[fill; 32]);
    STANDARD.encode(blob)
}

fn verified_generation() -> SessionSecurityGeneration {
    let identity = HostIdentity::parse("Example.com", 2222).unwrap();
    let public_key = public_key_base64(4);
    let store = KnownHostsStore::from_text(&format!("[example.com]:2222 {ALGORITHM} {public_key}"))
        .unwrap();
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
    SessionSecurityGeneration::from_verified(&verified, TrustStoreGeneration::from_store(&store))
}

fn challenge_outcome() -> (CheckedSshConnectOutcome, String) {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let public_key = public_key_base64(5);
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
        CheckedSshConnectOutcome::Challenge(Box::new(registered)),
        public_key,
    )
}

fn blocked_outcome(reason: HostKeyBlockReason) -> CheckedSshConnectOutcome {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let trusted_key = public_key_base64(6);
    let presented_key = if reason == HostKeyBlockReason::Changed {
        public_key_base64(7)
    } else {
        trusted_key.clone()
    };
    let marker = match reason {
        HostKeyBlockReason::Changed => "",
        HostKeyBlockReason::Revoked => "@revoked ",
        HostKeyBlockReason::UnsupportedRecord => "@unsupported ",
        HostKeyBlockReason::CertificateAuthorityUnsupported => "@cert-authority ",
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
    CheckedSshConnectOutcome::Blocked(Box::new(block))
}

fn call_checked(
    host: *const c_char,
    port: i32,
    username: *const c_char,
    path: *const c_char,
    request_id: *const c_char,
) -> Value {
    let password = CString::new("credential-secret").unwrap();
    let empty = CString::new("").unwrap();
    let pointer = orbit_ssh_connect_checked_v1(
        host,
        port,
        username,
        password.as_ptr(),
        empty.as_ptr(),
        empty.as_ptr(),
        0,
        path,
        request_id,
    );
    assert!(!pointer.is_null());
    // SAFETY: The checked C ABI returns a Rust-owned NUL-terminated string.
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap()
        .to_string();
    orbit_free_string(pointer);
    serde_json::from_str(&json).unwrap()
}

#[test]
fn connected_payload_uses_verified_generation_without_sensitive_material() {
    let payload = HostKeyConnectedPayload::from_security_generation(42, &verified_generation())
        .expect("valid connected payload");
    let json = serde_json::to_string(&payload).unwrap();
    assert_eq!(payload.session_id, 42);
    assert_eq!(payload.normalized_host, "example.com");
    assert_eq!(payload.port, 2222);
    assert!(json.contains("host_key_verified"));
    for excluded in [
        "public_key_base64",
        "known_hosts_path",
        "\"password\"",
        "\"private_key\"",
        "\"token\"",
    ] {
        assert!(!json.contains(excluded));
    }
}

#[test]
fn challenge_and_blocked_outcomes_keep_host_key_semantics() {
    let (challenge, public_key) = challenge_outcome();
    let challenge_json = outcome_json_for_tests(challenge, REQUEST_ID);
    let envelope = HostKeyFfiEnvelope::from_json(&challenge_json).unwrap();
    assert_eq!(envelope.kind(), HostKeyFfiResultKind::HostKeyChallenge);
    assert!(!challenge_json.contains(&public_key));

    for reason in [HostKeyBlockReason::Changed, HostKeyBlockReason::Revoked] {
        let json = outcome_json_for_tests(blocked_outcome(reason), REQUEST_ID);
        let envelope = HostKeyFfiEnvelope::from_json(&json).unwrap();
        assert_eq!(envelope.kind(), HostKeyFfiResultKind::HostKeyBlocked);
    }
}

#[test]
fn authentication_and_session_pool_errors_have_distinct_codes() {
    let auth = error_payload_for_tests(&authentication_error_for_tests(), REQUEST_ID);
    assert_eq!(auth.code, HostKeyFfiErrorCode::SshAuthFailed);

    let pool = CheckedSshConnectError::SessionPool {
        stage: CheckedSessionPoolStage::Insert,
    };
    let pool = error_payload_for_tests(&pool, REQUEST_ID);
    assert_eq!(pool.code, HostKeyFfiErrorCode::SessionPoolFailed);
    assert_eq!(
        pool.detail_code.as_deref(),
        Some("verified_session_insert_failed")
    );
}

#[test]
fn ffi_rejects_null_and_invalid_inputs_with_json_errors() {
    let host = CString::new("example.com").unwrap();
    let username = CString::new("root").unwrap();
    let path = CString::new(
        PathBuf::from("/tmp/not-orbitterm/known_hosts")
            .to_string_lossy()
            .as_bytes(),
    )
    .unwrap();
    let request_id = CString::new(REQUEST_ID).unwrap();

    let null_host = call_checked(
        std::ptr::null(),
        22,
        username.as_ptr(),
        path.as_ptr(),
        request_id.as_ptr(),
    );
    assert_eq!(null_host["error"]["code"], "invalid_request");
    assert_eq!(null_host["request_id"], REQUEST_ID);

    let invalid_port = call_checked(
        host.as_ptr(),
        0,
        username.as_ptr(),
        path.as_ptr(),
        request_id.as_ptr(),
    );
    assert_eq!(invalid_port["error"]["detail_code"], "invalid_port");

    let null_path = call_checked(
        host.as_ptr(),
        22,
        username.as_ptr(),
        std::ptr::null(),
        request_id.as_ptr(),
    );
    assert_eq!(null_path["error"]["detail_code"], "null_known_hosts_path");
}

#[test]
fn ffi_rejects_invalid_utf8_without_leaking_credentials() {
    let invalid = [0xff_u8, 0_u8];
    let username = CString::new("root").unwrap();
    let path = CString::new("/tmp/not-orbitterm/known_hosts").unwrap();
    let request_id = CString::new(REQUEST_ID).unwrap();
    let value = call_checked(
        invalid.as_ptr().cast(),
        22,
        username.as_ptr(),
        path.as_ptr(),
        request_id.as_ptr(),
    );
    let json = value.to_string();
    assert_eq!(value["error"]["code"], "invalid_utf8");
    assert!(!json.contains("credential-secret"));
}

#[test]
fn header_declares_checked_connect_without_removing_legacy_connect() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_ssh_connect_checked_v1"));
    assert!(header.contains("char *orbit_ssh_connect("));
}
