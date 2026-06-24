use std::collections::VecDeque;
use std::io;
use std::time::SystemTime;

use russh::keys::ssh_key::PublicKey;

use super::checked_connect_coordinator::{
    CheckedConnectCoordinator, CheckedConnectPreAuthError, CheckedPreAuthDecision,
    KnownHostsStoreReloader, VerifiedSlotMismatchReason,
};
use super::checked_host_key_handler::CheckedHostKeyHandler;
use super::host_key::HostIdentity;
use super::host_key_challenge_registry::PendingHostKeyChallengeRegistry;
use super::host_key_challenge_service::HostKeyChallengeService;
use super::host_key_verifier::{
    HostKeyBlockReason, HostKeyVerificationDecision, HostKeyVerificationInput, HostKeyVerifier,
    SessionSecurityGeneration, VerifiedHostKey,
};
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::russh_host_key_adapter::RusshHostKeyAdapter;
use super::trust_store_generation::TrustStoreGeneration;

const REQUEST_ID: &str = "coordinator-request";

#[derive(Debug)]
struct FakeStoreReloader {
    results: VecDeque<Result<KnownHostsStore, KnownHostsStoreError>>,
}

impl FakeStoreReloader {
    fn new(
        results: impl IntoIterator<Item = Result<KnownHostsStore, KnownHostsStoreError>>,
    ) -> Self {
        Self {
            results: results.into_iter().collect(),
        }
    }
}

impl KnownHostsStoreReloader for FakeStoreReloader {
    fn reload(&mut self) -> Result<KnownHostsStore, KnownHostsStoreError> {
        self.results
            .pop_front()
            .unwrap_or(Err(KnownHostsStoreError::ReadFailed {
                kind: io::ErrorKind::UnexpectedEof,
            }))
    }
}

fn public_key(fill: u8) -> PublicKey {
    let algorithm = b"ssh-ed25519";
    let mut blob = Vec::new();
    blob.extend_from_slice(&(algorithm.len() as u32).to_be_bytes());
    blob.extend_from_slice(algorithm);
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[fill; 32]);
    PublicKey::from_bytes(&blob).expect("valid Ed25519 public key")
}

fn key_parts(key: &PublicKey) -> (String, String, String) {
    let presented = RusshHostKeyAdapter.adapt(key).expect("adapted key");
    (
        presented.key_algorithm().to_string(),
        presented.public_key_base64().to_string(),
        presented.fingerprint_sha256().to_string(),
    )
}

fn known_hosts_line(host: &str, key: &PublicKey, marker: Option<&str>) -> String {
    let (algorithm, public_key, _) = key_parts(key);
    format!(
        "{}{} {algorithm} {public_key}",
        marker.map_or(String::new(), |value| format!("{value} ")),
        host
    )
}

fn store(contents: &str) -> KnownHostsStore {
    KnownHostsStore::from_text(contents).expect("store")
}

fn service() -> HostKeyChallengeService {
    HostKeyChallengeService::new(PendingHostKeyChallengeRegistry::new())
}

fn coordinator(
    initial: KnownHostsStore,
    current: Result<KnownHostsStore, KnownHostsStoreError>,
) -> CheckedConnectCoordinator<FakeStoreReloader> {
    CheckedConnectCoordinator::new(
        HostIdentity::parse("example.com", 22).expect("identity"),
        Some(REQUEST_ID.to_string()),
        service(),
        FakeStoreReloader::new([Ok(initial), current]),
    )
    .expect("coordinator")
}

fn run_handler(coordinator: &CheckedConnectCoordinator<FakeStoreReloader>, key: &PublicKey) {
    let mut handler = CheckedHostKeyHandler::new(coordinator.verification_context());
    assert!(handler
        .verify_presented_host_key(key, SystemTime::UNIX_EPOCH)
        .expect("initial trusted key"));
}

fn verified_for(host: &str, key: &PublicKey) -> VerifiedHostKey {
    let (algorithm, public_key, _) = key_parts(key);
    let identity = HostIdentity::parse(host, 22).expect("identity");
    let store = store(&known_hosts_line(host, key, None));
    let decision = HostKeyVerifier.verify(
        &store,
        &HostKeyVerificationInput {
            host_identity: identity,
            key_algorithm: algorithm,
            public_key_base64: public_key,
        },
    );
    let HostKeyVerificationDecision::Proceed(verified) = decision else {
        panic!("trusted fixture");
    };
    verified
}

#[test]
fn coordinator_loads_initial_store_and_constructs_matching_context_generation() {
    let key = public_key(1);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let expected = TrustStoreGeneration::from_store(&initial);
    let coordinator = coordinator(initial.clone(), Ok(initial));

    assert_eq!(
        coordinator.verification_context().trust_store_generation(),
        &expected
    );
}

#[test]
fn initial_store_reload_failure_prevents_context_construction() {
    let result = CheckedConnectCoordinator::new(
        HostIdentity::parse("example.com", 22).unwrap(),
        Some(REQUEST_ID.to_string()),
        service(),
        FakeStoreReloader::new([Err(KnownHostsStoreError::ReadFailed {
            kind: io::ErrorKind::PermissionDenied,
        })]),
    );

    assert!(matches!(
        result,
        Err(CheckedConnectPreAuthError::StoreReloadFailed(
            KnownHostsStoreError::ReadFailed {
                kind: io::ErrorKind::PermissionDenied
            }
        ))
    ));
}

#[test]
fn empty_verified_slot_fails_closed_before_store_reload() {
    let mut coordinator = CheckedConnectCoordinator::new(
        HostIdentity::parse("example.com", 22).unwrap(),
        Some(REQUEST_ID.to_string()),
        service(),
        FakeStoreReloader::new([Ok(KnownHostsStore::empty())]),
    )
    .unwrap();

    assert!(matches!(
        coordinator.pre_authentication_check(),
        CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::VerifiedSlotEmpty)
    ));
}

#[test]
fn mismatched_slot_identity_algorithm_and_fingerprint_fail_closed() {
    let key = public_key(2);
    let initial = store(&known_hosts_line("example.com", &key, None));

    let mut identity_mismatch = coordinator(initial.clone(), Ok(initial.clone()));
    let (_, public_key, _) = key_parts(&key);
    identity_mismatch
        .verification_context()
        .verified_slot()
        .inject_unchecked_for_tests(verified_for("other.example", &key), public_key.clone())
        .unwrap();
    assert!(matches!(
        identity_mismatch.pre_authentication_check(),
        CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::VerifiedSlotMismatch {
            reason: VerifiedSlotMismatchReason::HostIdentity
        })
    ));

    for mutate in ["algorithm", "fingerprint"] {
        let mut coordinator = coordinator(initial.clone(), Ok(initial.clone()));
        let mut verified = verified_for("example.com", &key);
        if mutate == "algorithm" {
            verified.key_algorithm = "ecdsa-sha2-nistp256".to_string();
        } else {
            verified.fingerprint_sha256 = "SHA256:not-the-presented-key".to_string();
        }
        coordinator
            .verification_context()
            .verified_slot()
            .inject_unchecked_for_tests(verified, public_key.clone())
            .unwrap();
        let decision = coordinator.pre_authentication_check();
        assert!(
            matches!(
                decision,
                CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::VerifiedSlotMismatch {
                    reason: VerifiedSlotMismatchReason::KeyMaterial
                })
            ),
            "unexpected {mutate} mismatch decision: {decision:?}"
        );
    }
}

#[test]
fn unchanged_generation_allows_authentication_and_prepares_session_generation() {
    let key = public_key(3);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let expected_generation = TrustStoreGeneration::from_store(&initial);
    let (_, public_key, _) = key_parts(&key);
    let mut coordinator = coordinator(initial.clone(), Ok(initial));
    run_handler(&coordinator, &key);

    let CheckedPreAuthDecision::AllowAuthentication(approval) =
        coordinator.pre_authentication_check()
    else {
        panic!("unchanged trusted store must allow authentication");
    };
    assert_eq!(approval.trust_store_generation(), &expected_generation);
    assert_eq!(
        approval.verified_host_key().host_identity.lookup_token,
        "example.com"
    );
    assert_eq!(
        approval.session_security_generation(),
        SessionSecurityGeneration::HostKeyVerified {
            host_identity: approval.verified_host_key().host_identity.clone(),
            key_algorithm: approval.verified_host_key().key_algorithm.clone(),
            fingerprint_sha256: approval.verified_host_key().fingerprint_sha256.clone(),
            trust_store_generation: expected_generation,
        }
    );
    let debug = format!("{approval:?}");
    assert!(!debug.contains(&public_key));
}

#[test]
fn changed_generation_revalidates_and_allows_only_when_still_trusted() {
    let key = public_key(4);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let current = store(&format!(
        "# changed by another window\n{}",
        known_hosts_line("example.com", &key, None)
    ));
    assert_ne!(
        TrustStoreGeneration::from_store(&initial),
        TrustStoreGeneration::from_store(&current)
    );
    let expected_generation = TrustStoreGeneration::from_store(&current);
    let mut coordinator = coordinator(initial, Ok(current));
    run_handler(&coordinator, &key);

    let CheckedPreAuthDecision::AllowAuthentication(approval) =
        coordinator.pre_authentication_check()
    else {
        panic!("revalidated key must allow authentication");
    };
    assert_eq!(approval.trust_store_generation(), &expected_generation);
}

#[test]
fn changed_generation_unknown_fails_without_registering_a_new_challenge() {
    let key = public_key(5);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let challenge_service = service();
    let mut coordinator = CheckedConnectCoordinator::new(
        HostIdentity::parse("example.com", 22).unwrap(),
        Some(REQUEST_ID.to_string()),
        challenge_service.clone(),
        FakeStoreReloader::new([Ok(initial), Ok(KnownHostsStore::empty())]),
    )
    .unwrap();
    run_handler(&coordinator, &key);

    assert!(matches!(
        coordinator.pre_authentication_check(),
        CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::StoreGenerationChangedUnknown)
    ));
    assert_eq!(challenge_service.pending_count().unwrap(), 0);
}

#[test]
fn changed_generation_changed_revoked_and_unsupported_are_blocked() {
    let key = public_key(6);
    let other_key = public_key(7);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let cases = [
        (
            store(&known_hosts_line("example.com", &other_key, None)),
            HostKeyBlockReason::Changed,
        ),
        (
            store(&known_hosts_line("example.com", &key, Some("@revoked"))),
            HostKeyBlockReason::Revoked,
        ),
        (
            store(&known_hosts_line(
                "example.com",
                &key,
                Some("@cert-authority"),
            )),
            HostKeyBlockReason::CertificateAuthorityUnsupported,
        ),
        (
            store(&known_hosts_line(
                "example.com",
                &key,
                Some("@future-marker"),
            )),
            HostKeyBlockReason::UnsupportedRecord,
        ),
    ];

    for (current, expected_reason) in cases {
        let mut coordinator = coordinator(initial.clone(), Ok(current));
        run_handler(&coordinator, &key);
        assert!(matches!(
            coordinator.pre_authentication_check(),
            CheckedPreAuthDecision::Block(ref block) if block.reason_code == expected_reason
        ));
    }
}

#[test]
fn store_reload_permission_and_size_failures_are_fail_closed_and_path_free() {
    let key = public_key(8);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let failures = [
        KnownHostsStoreError::ReadFailed {
            kind: io::ErrorKind::PermissionDenied,
        },
        KnownHostsStoreError::FileTooLarge { max_bytes: 1024 },
    ];

    for failure in failures {
        let mut coordinator = coordinator(initial.clone(), Err(failure));
        run_handler(&coordinator, &key);
        let decision = coordinator.pre_authentication_check();
        assert!(matches!(
            decision,
            CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::StoreReloadFailed(_))
        ));
        let debug = format!("{decision:?}").to_ascii_lowercase();
        assert!(!debug.contains("known_hosts_path"));
        assert!(!debug.contains("/users/"));
        assert!(!debug.contains("password"));
        assert!(!debug.contains("private_key"));
        assert!(!debug.contains("token"));
    }
}

#[test]
fn coordinator_and_decision_debug_never_expose_public_key_material() {
    let key = public_key(9);
    let initial = store(&known_hosts_line("example.com", &key, None));
    let (_, public_key, _) = key_parts(&key);
    let mut coordinator = coordinator(initial.clone(), Ok(initial));
    run_handler(&coordinator, &key);
    assert!(!format!("{coordinator:?}").contains(&public_key));
    assert!(!format!("{:?}", coordinator.pre_authentication_check()).contains(&public_key));
}
