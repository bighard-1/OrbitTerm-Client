use super::host_key::{fingerprint_sha256, HostIdentity};
use super::host_key_verifier::SessionSecurityGeneration;
use super::session_security::{
    validate_checked_generation, BaseSessionMetadata, SessionLifecycleState, SessionSecurityError,
};
use super::trust_store_generation::TrustStoreGeneration;

fn verified_generation(
    host: &str,
    algorithm: &str,
    fingerprint_seed: &[u8],
    store: &[u8],
) -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse(host, 22).unwrap(),
        key_algorithm: algorithm.to_string(),
        fingerprint_sha256: fingerprint_sha256(fingerprint_seed),
        trust_store_generation: TrustStoreGeneration::from_contents(store),
    }
}

#[test]
fn generation_identity_algorithm_fingerprint_and_store_are_strictly_distinct() {
    let base = verified_generation("Example.COM", "ssh-ed25519", b"key-a", b"store-a");
    assert_ne!(base, SessionSecurityGeneration::LegacyUnverified);
    assert_ne!(
        base,
        verified_generation("other.example", "ssh-ed25519", b"key-a", b"store-a")
    );
    assert_ne!(
        base,
        verified_generation("example.com", "ecdsa-sha2-nistp256", b"key-a", b"store-a")
    );
    assert_ne!(
        base,
        verified_generation("example.com", "ssh-ed25519", b"key-b", b"store-a")
    );
    assert_ne!(
        base,
        verified_generation("example.com", "ssh-ed25519", b"key-a", b"store-b")
    );
}

#[test]
fn checked_generation_validation_rejects_legacy_and_malformed_summaries() {
    assert_eq!(
        validate_checked_generation(&SessionSecurityGeneration::LegacyUnverified),
        Err(SessionSecurityError::VerifiedSessionRequired)
    );
    let valid = verified_generation("example.com", "ssh-ed25519", b"key", b"store");
    assert_eq!(validate_checked_generation(&valid), Ok(()));

    let SessionSecurityGeneration::HostKeyVerified {
        host_identity,
        trust_store_generation,
        ..
    } = valid
    else {
        unreachable!();
    };
    let malformed = SessionSecurityGeneration::HostKeyVerified {
        host_identity,
        key_algorithm: "SSH ED25519".to_string(),
        fingerprint_sha256: "SHA256:not-a-digest".to_string(),
        trust_store_generation,
    };
    assert_eq!(
        validate_checked_generation(&malformed),
        Err(SessionSecurityError::InvalidCheckedGeneration)
    );
}

#[test]
fn active_channel_gate_requires_an_exact_security_generation() {
    let verified = verified_generation("example.com", "ssh-ed25519", b"key-a", b"store-a");
    let different = verified_generation("example.com", "ssh-ed25519", b"key-b", b"store-a");
    let metadata = BaseSessionMetadata::new_checked(verified.clone()).unwrap();
    let legacy = BaseSessionMetadata::new_legacy();

    assert_eq!(metadata.state(), Ok(SessionLifecycleState::Active));
    assert_eq!(legacy.state(), Ok(SessionLifecycleState::Active));
    assert_eq!(
        legacy.security_generation(),
        &SessionSecurityGeneration::LegacyUnverified
    );
    assert_eq!(metadata.assert_allows_new_channel(&verified), Ok(()));
    assert_eq!(
        metadata.assert_allows_new_channel(&different),
        Err(SessionSecurityError::SecurityGenerationMismatch)
    );
    assert_eq!(
        legacy.assert_allows_new_channel(&verified),
        Err(SessionSecurityError::LegacySessionNotAllowed)
    );
    assert_eq!(
        metadata.assert_allows_new_channel(&SessionSecurityGeneration::LegacyUnverified),
        Err(SessionSecurityError::SecurityGenerationMismatch)
    );
}

#[test]
fn draining_terminating_and_closed_states_block_new_channels() {
    let verified = verified_generation("example.com", "ssh-ed25519", b"key", b"store");

    let draining = BaseSessionMetadata::new_checked(verified.clone()).unwrap();
    assert_eq!(
        draining.transition_to(SessionLifecycleState::Draining),
        Ok(SessionLifecycleState::Draining)
    );
    assert_eq!(
        draining.assert_allows_new_channel(&verified),
        Err(SessionSecurityError::SessionDraining)
    );
    assert_eq!(
        draining.transition_to(SessionLifecycleState::Active),
        Err(SessionSecurityError::InvalidStateTransition)
    );

    let terminating = BaseSessionMetadata::new_checked(verified.clone()).unwrap();
    terminating
        .transition_to(SessionLifecycleState::Terminating)
        .unwrap();
    assert_eq!(
        terminating.assert_allows_new_channel(&verified),
        Err(SessionSecurityError::SessionTerminating)
    );

    let closed = BaseSessionMetadata::new_checked(verified.clone()).unwrap();
    closed.transition_to(SessionLifecycleState::Closed).unwrap();
    assert_eq!(
        closed.assert_allows_new_channel(&verified),
        Err(SessionSecurityError::SessionClosed)
    );
}

#[test]
fn metadata_and_errors_do_not_expose_credentials_paths_or_public_keys() {
    let verified = verified_generation("example.com", "ssh-ed25519", b"key", b"store");
    let metadata = BaseSessionMetadata::new_checked(verified).unwrap();
    let output = format!(
        "{metadata:?} {:?}",
        SessionSecurityError::LegacySessionNotAllowed
    );
    for forbidden in [
        "password",
        "private_key",
        "known_hosts_path",
        "BEGIN OPENSSH",
        "secret-public-key",
    ] {
        assert!(!output.contains(forbidden));
    }
    assert!(metadata.created_at() <= std::time::SystemTime::now());
}
