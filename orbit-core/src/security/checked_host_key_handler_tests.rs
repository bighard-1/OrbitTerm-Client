use std::io;
use std::time::SystemTime;

use russh::keys::ssh_key::PublicKey;

use super::checked_host_key_handler::CheckedHostKeyHandler;
use super::connect_pre_auth_error::ConnectPreAuthError;
use super::host_key::{HostIdentity, HostKeyState};
use super::host_key_challenge_registry::{
    ChallengeRegistryError, PendingChallengeState, PendingHostKeyChallengeRegistry,
};
use super::host_key_challenge_service::{HostKeyChallengeService, HostKeyChallengeServiceError};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_verification_context::{
    HostKeyVerificationContext, HostKeyVerificationContextError,
};
use super::host_key_verifier::HostKeyBlockReason;
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::russh_host_key_adapter::RusshHostKeyAdapter;
use super::trust_store_generation::TrustStoreGeneration;
use super::verified_host_key_slot::VerifiedHostKeySlotError;

const REQUEST_ID: &str = "checked-attempt-1";

fn public_key(fill: u8) -> PublicKey {
    let algorithm = b"ssh-ed25519";
    let mut blob = Vec::new();
    blob.extend_from_slice(&(algorithm.len() as u32).to_be_bytes());
    blob.extend_from_slice(algorithm);
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[fill; 32]);
    PublicKey::from_bytes(&blob).expect("valid Ed25519 public key")
}

fn known_hosts_line(host: &str, key: &PublicKey, marker: Option<&str>) -> String {
    let presented = RusshHostKeyAdapter.adapt(key).expect("adapted key");
    format!(
        "{}{} {} {}",
        marker.map_or(String::new(), |value| format!("{value} ")),
        host,
        presented.key_algorithm(),
        presented.public_key_base64()
    )
}

fn handler_with_store(
    contents: &str,
) -> Result<(CheckedHostKeyHandler, HostKeyChallengeService), KnownHostsStoreError> {
    let store = KnownHostsStore::from_text(contents)?;
    let service = HostKeyChallengeService::new(PendingHostKeyChallengeRegistry::new());
    let context = HostKeyVerificationContext::new(
        HostIdentity::parse("example.com", 22).expect("identity"),
        Some(REQUEST_ID.to_string()),
        store,
        service.clone(),
    )
    .expect("context");
    Ok((CheckedHostKeyHandler::new(context), service))
}

#[test]
fn trust_store_generation_is_stable_opaque_and_content_sensitive() {
    let same_a = TrustStoreGeneration::from_contents(b"example contents");
    let same_b = TrustStoreGeneration::from_contents(b"example contents");
    let different = TrustStoreGeneration::from_contents(b"changed contents");

    assert_eq!(same_a, same_b);
    assert_ne!(same_a, different);
    let debug = format!("{same_a:?}");
    assert!(!debug.contains("example contents"));
    assert!(!debug.contains("known_hosts"));
    assert!(!debug.contains("/Users/"));
}

#[test]
fn context_is_credential_free_and_fails_closed_when_store_load_failed() {
    let service = HostKeyChallengeService::new(PendingHostKeyChallengeRegistry::new());
    let identity = HostIdentity::parse("example.com", 22).expect("identity");
    let context = HostKeyVerificationContext::new(
        identity.clone(),
        Some(REQUEST_ID.to_string()),
        KnownHostsStore::empty(),
        service.clone(),
    )
    .expect("context");
    let debug = format!("{context:?}").to_ascii_lowercase();
    for forbidden in [
        "password",
        "private_key",
        "passphrase",
        "access_token",
        "refresh_token",
    ] {
        assert!(!debug.contains(forbidden));
    }

    let error = HostKeyVerificationContext::from_loaded_store(
        identity,
        Some(REQUEST_ID.to_string()),
        Err(KnownHostsStoreError::ReadFailed {
            kind: io::ErrorKind::PermissionDenied,
        }),
        service,
    )
    .expect_err("unavailable store must fail closed");
    assert!(matches!(
        error,
        HostKeyVerificationContextError::StoreUnavailable(_)
    ));
}

#[test]
fn russh_adapter_uses_wire_blob_and_redacts_public_key() {
    let key = public_key(7);
    let presented = RusshHostKeyAdapter.adapt(&key).expect("adapted key");

    assert_eq!(presented.key_algorithm(), "ssh-ed25519");
    assert!(presented.fingerprint_sha256().starts_with("SHA256:"));
    let debug = format!("{presented:?}");
    assert!(!debug.contains(presented.public_key_base64()));
    assert!(debug.contains("[REDACTED]"));
}

#[test]
fn trusted_key_proceeds_and_records_per_connection_verification() {
    let key = public_key(1);
    let line = known_hosts_line("example.com", &key, None);
    let (mut handler, _) = handler_with_store(&line).expect("handler");

    assert!(handler
        .verify_presented_host_key(&key, SystemTime::UNIX_EPOCH)
        .expect("trusted"));
    let verified = handler
        .context()
        .verified_slot()
        .require_verified()
        .expect("verified result");
    assert_eq!(verified.host_identity.lookup_token, "example.com");
    assert_eq!(verified.key_algorithm, "ssh-ed25519");
}

#[test]
fn unknown_key_registers_challenge_and_never_populates_verified_slot() {
    let key = public_key(2);
    let presented = RusshHostKeyAdapter.adapt(&key).expect("adapted key");
    let (mut handler, service) = handler_with_store("").expect("handler");

    let error = handler
        .verify_presented_host_key(&key, SystemTime::UNIX_EPOCH)
        .expect_err("unknown host must challenge");
    assert!(!format!("{error:?}").contains(presented.public_key_base64()));
    let ConnectPreAuthError::HostKeyChallenge(challenge) = error else {
        panic!("challenge must retain its structured variant");
    };
    assert_eq!(challenge.request_id.as_deref(), Some(REQUEST_ID));
    assert_eq!(
        service
            .status(challenge.challenge_id.as_str(), SystemTime::UNIX_EPOCH)
            .expect("status"),
        Some(PendingChallengeState::Pending)
    );
    assert!(handler
        .context()
        .verified_slot()
        .is_empty()
        .expect("slot state"));
}

#[test]
fn changed_revoked_and_unsupported_keys_are_structurally_blocked() {
    let trusted = public_key(3);
    let changed = public_key(4);

    let changed_line = known_hosts_line("example.com", &trusted, None);
    let (mut changed_handler, _) = handler_with_store(&changed_line).expect("handler");
    let changed_error = changed_handler
        .verify_presented_host_key(&changed, SystemTime::UNIX_EPOCH)
        .expect_err("changed key must block");
    assert!(matches!(
        changed_error,
        ConnectPreAuthError::HostKeyBlocked(ref block)
            if block.reason_code == HostKeyBlockReason::Changed
    ));
    assert!(changed_handler
        .context()
        .verified_slot()
        .is_empty()
        .expect("slot state"));

    let revoked_line = known_hosts_line("example.com", &trusted, Some("@revoked"));
    let (mut revoked_handler, _) = handler_with_store(&revoked_line).expect("handler");
    assert!(matches!(
        revoked_handler.verify_presented_host_key(&trusted, SystemTime::UNIX_EPOCH),
        Err(ConnectPreAuthError::HostKeyBlocked(ref block))
            if block.reason_code == HostKeyBlockReason::Revoked
    ));

    let ca_line = known_hosts_line("example.com", &trusted, Some("@cert-authority"));
    let (mut ca_handler, _) = handler_with_store(&ca_line).expect("handler");
    assert!(matches!(
        ca_handler.verify_presented_host_key(&trusted, SystemTime::UNIX_EPOCH),
        Err(ConnectPreAuthError::HostKeyBlocked(ref block))
            if block.reason_code == HostKeyBlockReason::CertificateAuthorityUnsupported
    ));
}

#[test]
fn an_empty_verified_slot_is_an_explicit_fail_closed_error() {
    let (handler, _) = handler_with_store("").expect("handler");
    assert_eq!(
        handler.context().verified_slot().require_verified(),
        Err(VerifiedHostKeySlotError::MissingVerification)
    );
}

#[test]
fn challenge_service_wraps_registry_and_preserves_error_code_mapping() {
    let key = public_key(5);
    let presented = RusshHostKeyAdapter.adapt(&key).expect("adapted key");
    let (mut handler, service) = handler_with_store("").expect("handler");
    let error = handler
        .verify_presented_host_key(&key, SystemTime::UNIX_EPOCH)
        .expect_err("challenge");
    let ConnectPreAuthError::HostKeyChallenge(challenge) = error else {
        panic!("expected challenge");
    };
    let rejected = service
        .reject(challenge.challenge_id.as_str(), SystemTime::UNIX_EPOCH)
        .expect("reject");
    assert_eq!(rejected.fingerprint_sha256, presented.fingerprint_sha256());

    let duplicate = service
        .accept(challenge.challenge_id.as_str(), SystemTime::UNIX_EPOCH)
        .expect_err("resolved challenge");
    let HostKeyChallengeServiceError::Registry(registry_error) = duplicate else {
        panic!("expected structured registry error");
    };
    assert!(matches!(
        registry_error,
        ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Rejected
        }
    ));
    let payload = HostKeyFfiErrorPayload::from_registry_error(&registry_error, None, None);
    assert_eq!(payload.code, HostKeyFfiErrorCode::ChallengeAlreadyResolved);
}

#[test]
fn checked_handlers_share_service_dedup_but_keep_current_request_correlation() {
    let key = public_key(6);
    let service = HostKeyChallengeService::new(PendingHostKeyChallengeRegistry::new());
    let make_handler = |request_id: &str| {
        let context = HostKeyVerificationContext::new(
            HostIdentity::parse("example.com", 22).expect("identity"),
            Some(request_id.to_string()),
            KnownHostsStore::empty(),
            service.clone(),
        )
        .expect("context");
        CheckedHostKeyHandler::new(context)
    };
    let mut first_handler = make_handler("request-first");
    let mut second_handler = make_handler("request-second");

    let first = first_handler
        .verify_presented_host_key(&key, SystemTime::UNIX_EPOCH)
        .expect_err("unknown host");
    let second = second_handler
        .verify_presented_host_key(&key, SystemTime::UNIX_EPOCH)
        .expect_err("unknown host");
    let ConnectPreAuthError::HostKeyChallenge(first) = first else {
        panic!("first challenge");
    };
    let ConnectPreAuthError::HostKeyChallenge(second) = second else {
        panic!("second challenge");
    };
    assert_eq!(first.challenge_id, second.challenge_id);
    assert!(!first.reused_existing_challenge);
    assert!(second.reused_existing_challenge);
    assert_eq!(first.request_id.as_deref(), Some("request-first"));
    assert_eq!(second.request_id.as_deref(), Some("request-second"));
    assert_eq!(second.related_request_count, 2);
}

#[test]
fn checked_handler_implements_the_public_russh_handler_contract() {
    fn assert_handler<T: russh::client::Handler>() {}
    assert_handler::<CheckedHostKeyHandler>();
}

#[test]
fn host_key_state_model_remains_explicit_for_unknown_challenges() {
    assert_ne!(HostKeyState::Unknown, HostKeyState::Trusted);
}
