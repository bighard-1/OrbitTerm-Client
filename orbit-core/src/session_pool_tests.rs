use std::sync::Arc;

use crate::security::{
    fingerprint_sha256, HostIdentity, SessionSecurityError, SessionSecurityGeneration,
    TrustStoreGeneration,
};
use crate::session_pool::{
    base_session_creation_gate, lookup_base_session_checked, BaseSessionKey,
    SessionPoolSecurityIndex,
};

fn verified_generation(
    host: &str,
    fingerprint_seed: &[u8],
    store: &[u8],
) -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse(host, 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(fingerprint_seed),
        trust_store_generation: TrustStoreGeneration::from_contents(store),
    }
}

#[test]
fn legacy_and_checked_keys_are_isolated_and_checked_hosts_are_normalized() {
    let verified = verified_generation("Example.COM", b"key", b"store");
    let legacy = BaseSessionKey::legacy("Example.COM", 22, " root ");
    let checked = BaseSessionKey::checked(" root ", verified).unwrap();

    assert_ne!(legacy, checked);
    assert_eq!(legacy.endpoint(), "Example.COM:22");
    assert_eq!(checked.endpoint(), "example.com:22");
    assert_eq!(
        legacy.security_generation(),
        &SessionSecurityGeneration::LegacyUnverified
    );
}

#[test]
fn pool_index_reuses_only_an_exact_security_generation() {
    let generation_a = verified_generation("example.com", b"key-a", b"store-a");
    let same = generation_a.clone();
    let different_fingerprint = verified_generation("example.com", b"key-b", b"store-a");
    let different_store = verified_generation("example.com", b"key-a", b"store-b");
    let checked_a = BaseSessionKey::checked("root", generation_a).unwrap();
    let checked_same = BaseSessionKey::checked("root", same).unwrap();
    let checked_fingerprint = BaseSessionKey::checked("root", different_fingerprint).unwrap();
    let checked_store = BaseSessionKey::checked("root", different_store).unwrap();
    let legacy = BaseSessionKey::legacy("example.com", 22, "root");
    let mut index = SessionPoolSecurityIndex::default();

    index.insert(legacy.clone(), 1);
    index.insert(checked_a.clone(), 2);
    assert_eq!(index.get(&legacy), Some(1));
    assert_eq!(index.get(&checked_same), Some(2));
    assert_eq!(index.get(&checked_fingerprint), None);
    assert_eq!(index.get(&checked_store), None);
    assert!(index.remove_if_matches(&checked_a, 2));
    assert!(!index.remove_if_matches(&legacy, 99));
}

#[test]
fn checked_lookup_rejects_legacy_before_consulting_global_pool() {
    assert!(matches!(
        lookup_base_session_checked("root", SessionSecurityGeneration::LegacyUnverified),
        Err(SessionSecurityError::VerifiedSessionRequired)
    ));

    let verified = verified_generation("example.com", b"key", b"store");
    assert!(lookup_base_session_checked("root", verified)
        .unwrap()
        .is_none());
}

#[test]
fn keyed_creation_gate_is_shared_per_generation_and_distinct_across_keys() {
    let legacy = BaseSessionKey::legacy("example.com", 22, "root");
    let same = BaseSessionKey::legacy("example.com", 22, "root");
    let checked =
        BaseSessionKey::checked("root", verified_generation("example.com", b"key", b"store"))
            .unwrap();

    let first = base_session_creation_gate(&legacy).unwrap();
    let second = base_session_creation_gate(&same).unwrap();
    let checked_gate = base_session_creation_gate(&checked).unwrap();
    assert!(Arc::ptr_eq(&first, &second));
    assert!(!Arc::ptr_eq(&first, &checked_gate));

    let old_gate = Arc::downgrade(&first);
    drop(first);
    drop(second);
    assert!(old_gate.upgrade().is_none());
    assert!(base_session_creation_gate(&legacy).is_ok());
}

#[test]
fn key_debug_contains_no_credentials_public_keys_or_store_paths() {
    let key = BaseSessionKey::checked("root", verified_generation("example.com", b"key", b"store"))
        .unwrap();
    let debug = format!("{key:?}");
    for forbidden in [
        "password",
        "private_key",
        "known_hosts_path",
        "BEGIN OPENSSH",
    ] {
        assert!(!debug.contains(forbidden));
    }
}
