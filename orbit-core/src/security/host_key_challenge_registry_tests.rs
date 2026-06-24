use std::collections::VecDeque;
use std::time::{Duration, SystemTime};

use super::{
    fingerprint_sha256_from_base64, ChallengeEquivalenceKey, ChallengeId,
    ChallengeIdGenerationError, ChallengeIdGenerator, ChallengeRegistryError, HostIdentity,
    HostKeyChallengeDraft, HostKeyVerificationDecision, HostKeyVerificationInput, HostKeyVerifier,
    KnownHostsStore, PendingChallengeRegistryConfig, PendingChallengeState,
    PendingHostKeyChallengeRegistry, SecureChallengeIdGenerator, TrustStoreGeneration,
    MAX_RELATED_REQUEST_LIMIT,
};

const KEY_A: &str = "AQIDBA==";
const KEY_B: &str = "BQYHCA==";
const NOW: SystemTime = SystemTime::UNIX_EPOCH;

#[derive(Debug)]
struct SequenceIdGenerator {
    values: VecDeque<Result<[u8; 16], ChallengeIdGenerationError>>,
}

impl SequenceIdGenerator {
    fn from_bytes(values: impl IntoIterator<Item = [u8; 16]>) -> Self {
        Self {
            values: values.into_iter().map(Ok).collect(),
        }
    }

    fn failing() -> Self {
        Self {
            values: VecDeque::from([Err(ChallengeIdGenerationError)]),
        }
    }
}

impl ChallengeIdGenerator for SequenceIdGenerator {
    fn fill_entropy(
        &mut self,
        destination: &mut [u8; 16],
    ) -> Result<(), ChallengeIdGenerationError> {
        let value = self
            .values
            .pop_front()
            .unwrap_or(Err(ChallengeIdGenerationError))?;
        *destination = value;
        Ok(())
    }
}

fn draft(host: &str, port: u16, algorithm: &str, public_key: &str) -> HostKeyChallengeDraft {
    let input = HostKeyVerificationInput {
        host_identity: HostIdentity::parse(host, port).unwrap(),
        key_algorithm: algorithm.to_string(),
        public_key_base64: public_key.to_string(),
    };
    let store = KnownHostsStore::empty();
    let HostKeyVerificationDecision::Challenge(draft) = HostKeyVerifier.verify(&store, &input)
    else {
        panic!("empty store must produce an unknown-host challenge");
    };
    draft
}

fn config(global: usize, per_host: usize) -> PendingChallengeRegistryConfig {
    PendingChallengeRegistryConfig {
        global_pending_limit: global,
        per_host_pending_limit: per_host,
        ..PendingChallengeRegistryConfig::default()
    }
}

fn deterministic_registry(
    values: impl IntoIterator<Item = [u8; 16]>,
) -> PendingHostKeyChallengeRegistry<SequenceIdGenerator> {
    PendingHostKeyChallengeRegistry::with_id_generator(
        PendingChallengeRegistryConfig::default(),
        SequenceIdGenerator::from_bytes(values),
    )
    .unwrap()
}

fn generation(value: &str) -> TrustStoreGeneration {
    TrustStoreGeneration::from_contents(value.as_bytes())
}

#[allow(
    clippy::too_many_arguments,
    reason = "test helper keeps every challenge equivalence dimension explicit"
)]
fn register_equivalent<G: ChallengeIdGenerator>(
    registry: &mut PendingHostKeyChallengeRegistry<G>,
    host: &str,
    port: u16,
    algorithm: &str,
    public_key: &str,
    request_id: &str,
    generation: &TrustStoreGeneration,
    now: SystemTime,
) -> Result<super::RegisteredHostKeyChallenge, ChallengeRegistryError> {
    registry.register_or_reuse_unknown_challenge(
        draft(host, port, algorithm, public_key),
        public_key,
        Some(request_id),
        generation,
        now,
    )
}

#[test]
fn equivalence_key_uses_normalized_identity_algorithm_fingerprint_and_generation() {
    let fingerprint_a = fingerprint_sha256_from_base64(KEY_A).unwrap();
    let fingerprint_b = fingerprint_sha256_from_base64(KEY_B).unwrap();
    let generation_a = generation("store-a");
    let generation_b = generation("store-b");
    let key = |host: &str,
               port: u16,
               algorithm: &str,
               fingerprint: &str,
               generation: &TrustStoreGeneration| {
        ChallengeEquivalenceKey::new(
            &HostIdentity::parse(host, port).unwrap(),
            algorithm.to_string(),
            fingerprint.to_string(),
            generation.clone(),
        )
        .unwrap()
    };

    assert_eq!(
        key(
            "Example.COM.",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "other.example",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "example.com",
            2222,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "server.example",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "203.0.113.10",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "192.0.2.10",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "2001:db8::10",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "example.com",
            22,
            "ecdsa-sha2-nistp256",
            &fingerprint_a,
            &generation_a
        )
    );
    assert_ne!(
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_a,
            &generation_a
        ),
        key(
            "example.com",
            22,
            "ssh-ed25519",
            &fingerprint_b,
            &generation_a
        )
    );
    let changed_generation = key(
        "example.com",
        22,
        "ssh-ed25519",
        &fingerprint_a,
        &generation_b,
    );
    let original = key(
        "example.com",
        22,
        "ssh-ed25519",
        &fingerprint_a,
        &generation_a,
    );
    assert_ne!(original, changed_generation);
    let debug = format!("{original:?}");
    assert!(!debug.contains(KEY_A));
    assert!(!debug.contains("known_hosts"));
    assert!(!debug.contains("password"));
    assert!(!debug.contains("/Users/"));
}

#[test]
fn equivalent_registration_reuses_id_tracks_current_request_and_is_idempotent() {
    let mut registry = deterministic_registry([[1; 16]]);
    let generation = generation("store-a");
    let first = register_equivalent(
        &mut registry,
        "Example.COM",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-1",
        &generation,
        NOW,
    )
    .unwrap();
    let reused = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-2",
        &generation,
        NOW,
    )
    .unwrap();
    let duplicate = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-2",
        &generation,
        NOW,
    )
    .unwrap();

    assert_eq!(first.challenge_id, reused.challenge_id);
    assert_eq!(reused.challenge_id, duplicate.challenge_id);
    assert!(!first.reused_existing_challenge);
    assert!(reused.reused_existing_challenge);
    assert_eq!(reused.request_id.as_deref(), Some("request-2"));
    assert_eq!(first.related_request_count, 1);
    assert_eq!(reused.related_request_count, 2);
    assert_eq!(duplicate.related_request_count, 2);
    assert_eq!(registry.pending_count(), 1);
}

#[test]
fn different_trust_store_generation_creates_a_distinct_pending_challenge() {
    let mut registry = deterministic_registry([[1; 16], [2; 16]]);
    let first = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-1",
        &generation("store-a"),
        NOW,
    )
    .unwrap();
    let second = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-2",
        &generation("store-b"),
        NOW,
    )
    .unwrap();

    assert_ne!(first.challenge_id, second.challenge_id);
    assert!(!second.reused_existing_challenge);
    assert_eq!(registry.pending_count(), 2);
}

#[test]
fn equivalent_reuse_precedes_capacity_checks_and_related_requests_are_bounded() {
    let config = PendingChallengeRegistryConfig {
        global_pending_limit: 1,
        per_host_pending_limit: 1,
        related_request_limit: 2,
        ..PendingChallengeRegistryConfig::default()
    };
    let mut registry = PendingHostKeyChallengeRegistry::with_config(config).unwrap();
    let generation = generation("store-a");
    register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-1",
        &generation,
        NOW,
    )
    .unwrap();
    assert!(
        register_equivalent(
            &mut registry,
            "example.com",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-2",
            &generation,
            NOW,
        )
        .unwrap()
        .reused_existing_challenge
    );
    assert_eq!(
        register_equivalent(
            &mut registry,
            "example.com",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-3",
            &generation,
            NOW,
        ),
        Err(ChallengeRegistryError::RelatedRequestLimitReached)
    );
    assert_eq!(
        register_equivalent(
            &mut registry,
            "example.com",
            22,
            "ssh-ed25519",
            KEY_B,
            "request-other-key",
            &generation,
            NOW,
        ),
        Err(ChallengeRegistryError::PendingLimitReached)
    );
    assert_eq!(
        register_equivalent(
            &mut registry,
            "other.example",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-other-host",
            &generation,
            NOW,
        ),
        Err(ChallengeRegistryError::PendingLimitReached)
    );
}

#[test]
fn equivalent_reuse_coexists_with_per_host_and_global_limits() {
    let config = PendingChallengeRegistryConfig {
        global_pending_limit: 2,
        per_host_pending_limit: 1,
        ..PendingChallengeRegistryConfig::default()
    };
    let mut registry = PendingHostKeyChallengeRegistry::with_config(config).unwrap();
    let generation = generation("store-a");
    register_equivalent(
        &mut registry,
        "one.example",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-1",
        &generation,
        NOW,
    )
    .unwrap();
    assert!(
        register_equivalent(
            &mut registry,
            "one.example",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-2",
            &generation,
            NOW,
        )
        .unwrap()
        .reused_existing_challenge
    );
    assert_eq!(
        register_equivalent(
            &mut registry,
            "one.example",
            22,
            "ssh-ed25519",
            KEY_B,
            "request-3",
            &generation,
            NOW,
        ),
        Err(ChallengeRegistryError::PerHostPendingLimitReached)
    );

    register_equivalent(
        &mut registry,
        "two.example",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-4",
        &generation,
        NOW,
    )
    .unwrap();
    assert!(
        register_equivalent(
            &mut registry,
            "two.example",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-5",
            &generation,
            NOW,
        )
        .unwrap()
        .reused_existing_challenge
    );
    assert_eq!(
        register_equivalent(
            &mut registry,
            "three.example",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-6",
            &generation,
            NOW,
        ),
        Err(ChallengeRegistryError::PendingLimitReached)
    );
}

#[test]
fn resolved_and_expired_challenges_release_the_equivalence_index() {
    enum Resolution {
        Accept,
        Reject,
        Persist,
        Expire,
    }

    for resolution in [
        Resolution::Accept,
        Resolution::Reject,
        Resolution::Persist,
        Resolution::Expire,
    ] {
        let config = PendingChallengeRegistryConfig {
            challenge_ttl: Duration::from_secs(1),
            ..PendingChallengeRegistryConfig::default()
        };
        let mut registry = PendingHostKeyChallengeRegistry::with_config(config).unwrap();
        let generation = generation("store-a");
        let first = register_equivalent(
            &mut registry,
            "example.com",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-1",
            &generation,
            NOW,
        )
        .unwrap();

        match resolution {
            Resolution::Accept => {
                registry.accept(first.challenge_id.as_str(), NOW).unwrap();
            }
            Resolution::Reject => {
                registry.reject(first.challenge_id.as_str(), NOW).unwrap();
            }
            Resolution::Persist => {
                let snapshot = registry
                    .snapshot_pending(first.challenge_id.as_str(), NOW)
                    .unwrap();
                registry.mark_persisted_if_pending(&snapshot, NOW).unwrap();
            }
            Resolution::Expire => {
                registry
                    .cleanup_expired(NOW + Duration::from_secs(1))
                    .unwrap();
            }
        }

        let second = register_equivalent(
            &mut registry,
            "example.com",
            22,
            "ssh-ed25519",
            KEY_A,
            "request-2",
            &generation,
            NOW + Duration::from_secs(2),
        )
        .unwrap();
        assert_ne!(first.challenge_id, second.challenge_id);
        assert!(!second.reused_existing_challenge);
        assert_eq!(registry.pending_count(), 1);
    }
}

#[test]
fn cas_mismatch_preserves_a_valid_equivalence_index() {
    let mut registry = PendingHostKeyChallengeRegistry::new();
    let generation = generation("store-a");
    let first = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-1",
        &generation,
        NOW,
    )
    .unwrap();
    let mut stale = registry
        .snapshot_pending(first.challenge_id.as_str(), NOW)
        .unwrap();
    stale.fingerprint_sha256 = fingerprint_sha256_from_base64(KEY_B).unwrap();
    assert_eq!(
        registry.mark_persisted_if_pending(&stale, NOW),
        Err(ChallengeRegistryError::ChallengeBindingMismatch)
    );

    let reused = register_equivalent(
        &mut registry,
        "example.com",
        22,
        "ssh-ed25519",
        KEY_A,
        "request-2",
        &generation,
        NOW,
    )
    .unwrap();
    assert_eq!(first.challenge_id, reused.challenge_id);
    assert!(reused.reused_existing_challenge);
}

#[test]
fn related_request_configuration_rejects_unbounded_values() {
    for related_request_limit in [0, MAX_RELATED_REQUEST_LIMIT + 1] {
        let config = PendingChallengeRegistryConfig {
            related_request_limit,
            ..PendingChallengeRegistryConfig::default()
        };
        assert!(matches!(
            PendingHostKeyChallengeRegistry::with_config(config),
            Err(ChallengeRegistryError::InvalidConfiguration)
        ));
    }
}

#[test]
fn secure_identifier_has_128_bits_of_encoded_entropy_and_no_host_text() {
    let mut registry = PendingHostKeyChallengeRegistry::<SecureChallengeIdGenerator>::new();
    let registered = registry
        .register(
            draft("secret-host.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            Some("request-1"),
            None,
            NOW,
        )
        .unwrap();

    assert_eq!(registered.challenge_id.as_str().len(), 22);
    assert!(ChallengeId::parse(registered.challenge_id.as_str()).is_ok());
    assert!(!registered.challenge_id.as_str().contains("secret-host"));
}

#[test]
fn deterministic_generator_produces_stable_identifier() {
    let mut registry = deterministic_registry([[7; 16]]);
    let registered = registry
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(registered.challenge_id.as_str(), "BwcHBwcHBwcHBwcHBwcHBw");
}

#[test]
fn id_generation_failure_and_repeated_collision_are_structured() {
    let mut failing = PendingHostKeyChallengeRegistry::with_id_generator(
        PendingChallengeRegistryConfig::default(),
        SequenceIdGenerator::failing(),
    )
    .unwrap();
    assert_eq!(
        failing.register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::IdGenerationFailed)
    );

    let repeated = std::iter::repeat_n([1; 16], 9);
    let mut colliding = deterministic_registry(repeated);
    colliding
        .register(
            draft("one.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(
        colliding.register(
            draft("two.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::IdCollisionLimitReached)
    );
}

#[test]
fn identifier_collision_is_retried_before_failing() {
    let mut registry = deterministic_registry([[1; 16], [1; 16], [2; 16]]);
    let first = registry
        .register(
            draft("one.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    let second = registry
        .register(
            draft("two.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_ne!(first.challenge_id, second.challenge_id);
}

#[test]
fn register_tracks_pending_count_and_binding_summary() {
    let mut registry = deterministic_registry([[1; 16]]);
    let registered = registry
        .register(
            draft("example.com", 2222, "ssh-ed25519", KEY_A),
            KEY_A,
            Some("request-42"),
            Some("store-v1"),
            NOW,
        )
        .unwrap();

    assert_eq!(registry.pending_count(), 1);
    assert_eq!(registry.pending_count_for(&registered.host_identity), 1);
    assert_eq!(registered.host_identity.lookup_token, "[example.com]:2222");
    assert_eq!(registered.key_algorithm, "ssh-ed25519");
    assert_eq!(registered.request_id.as_deref(), Some("request-42"));
    assert_eq!(
        registered.store_generation_hint.as_deref(),
        Some("store-v1")
    );
    assert_eq!(
        registry
            .state(registered.challenge_id.as_str(), NOW)
            .unwrap(),
        Some(PendingChallengeState::Pending)
    );
}

#[test]
fn global_and_per_host_limits_are_enforced() {
    let mut per_host = PendingHostKeyChallengeRegistry::with_id_generator(
        config(4, 1),
        SequenceIdGenerator::from_bytes([[1; 16], [2; 16]]),
    )
    .unwrap();
    per_host
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(
        per_host.register(
            draft("example.com", 22, "ssh-ed25519", KEY_B),
            KEY_B,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::PerHostPendingLimitReached)
    );

    let mut global = PendingHostKeyChallengeRegistry::with_id_generator(
        config(1, 1),
        SequenceIdGenerator::from_bytes([[3; 16], [4; 16]]),
    )
    .unwrap();
    global
        .register(
            draft("one.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(
        global.register(
            draft("two.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::PendingLimitReached)
    );
}

#[test]
fn host_port_dns_and_ip_have_independent_per_host_limits() {
    let mut registry = PendingHostKeyChallengeRegistry::with_id_generator(
        config(4, 1),
        SequenceIdGenerator::from_bytes([[1; 16], [2; 16], [3; 16], [4; 16]]),
    )
    .unwrap();
    for challenge in [
        draft("server.example", 22, "ssh-ed25519", KEY_A),
        draft("server.example", 2222, "ssh-ed25519", KEY_A),
        draft("203.0.113.7", 22, "ssh-ed25519", KEY_A),
        draft("203.0.113.7", 2222, "ssh-ed25519", KEY_A),
    ] {
        registry
            .register(challenge, KEY_A, None, None, NOW)
            .unwrap();
    }
    assert_eq!(registry.pending_count(), 4);
}

#[test]
fn normalized_hostname_aliases_share_the_same_per_host_limit() {
    let mut registry = PendingHostKeyChallengeRegistry::with_id_generator(
        config(2, 1),
        SequenceIdGenerator::from_bytes([[1; 16], [2; 16]]),
    )
    .unwrap();
    registry
        .register(
            draft("Example.COM.", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(
        registry.register(
            draft("example.com", 22, "ssh-ed25519", KEY_B),
            KEY_B,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::PerHostPendingLimitReached)
    );
}

#[test]
fn expired_entries_are_cleaned_before_capacity_checks() {
    let short = PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(5),
        global_pending_limit: 1,
        per_host_pending_limit: 1,
        ..PendingChallengeRegistryConfig::default()
    };
    let mut registry = PendingHostKeyChallengeRegistry::with_id_generator(
        short,
        SequenceIdGenerator::from_bytes([[1; 16], [2; 16]]),
    )
    .unwrap();
    registry
        .register(
            draft("one.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    registry
        .register(
            draft("two.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW + Duration::from_secs(5),
        )
        .unwrap();
    assert_eq!(registry.pending_count(), 1);
}

#[test]
fn public_key_algorithm_identity_and_draft_are_validated() {
    let small_key_config = PendingChallengeRegistryConfig {
        public_key_max_len: 4,
        ..PendingChallengeRegistryConfig::default()
    };
    let mut oversized = PendingHostKeyChallengeRegistry::with_id_generator(
        small_key_config,
        SequenceIdGenerator::from_bytes([[1; 16]]),
    )
    .unwrap();
    assert_eq!(
        oversized.register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::PublicKeyTooLarge { max_bytes: 4 })
    );

    let mut invalid = deterministic_registry([[2; 16], [3; 16], [4; 16], [5; 16]]);
    assert_eq!(
        invalid.register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            "%%%",
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::InvalidPublicKey)
    );

    let mut invalid_algorithm = draft("example.com", 22, "ssh-ed25519", KEY_A);
    invalid_algorithm.key_algorithm = "ssh ed25519".to_string();
    assert_eq!(
        invalid.register(invalid_algorithm, KEY_A, None, None, NOW),
        Err(ChallengeRegistryError::InvalidAlgorithm)
    );

    let mut invalid_identity = draft("example.com", 22, "ssh-ed25519", KEY_A);
    invalid_identity.lookup_token = "attacker.example".to_string();
    assert_eq!(
        invalid.register(invalid_identity, KEY_A, None, None, NOW),
        Err(ChallengeRegistryError::InvalidHostIdentity)
    );

    let mut replacement_draft = draft("example.com", 22, "ssh-ed25519", KEY_A);
    replacement_draft.can_replace = true;
    assert_eq!(
        invalid.register(replacement_draft, KEY_A, None, None, NOW),
        Err(ChallengeRegistryError::InvalidChallengeDraft)
    );
}

#[test]
fn fingerprint_mismatch_is_rejected_as_invalid_draft() {
    let mut registry = deterministic_registry([[1; 16]]);
    assert_eq!(
        registry.register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_B,
            None,
            None,
            NOW,
        ),
        Err(ChallengeRegistryError::InvalidChallengeDraft)
    );
}

#[test]
fn accept_atomically_consumes_and_returns_bound_public_key() {
    let mut registry = deterministic_registry([[1; 16]]);
    let registered = registry
        .register(
            draft("example.com", 2222, "ssh-ed25519", KEY_A),
            KEY_A,
            Some("request-a"),
            Some("generation-a"),
            NOW,
        )
        .unwrap();
    let accepted_at = NOW + Duration::from_secs(10);
    let accepted = registry
        .accept(registered.challenge_id.as_str(), accepted_at)
        .unwrap();

    assert_eq!(accepted.host_identity, registered.host_identity);
    assert_eq!(accepted.key_algorithm, "ssh-ed25519");
    assert_eq!(accepted.fingerprint_sha256, registered.fingerprint_sha256);
    assert_eq!(accepted.public_key_base64, KEY_A);
    assert_eq!(accepted.request_id.as_deref(), Some("request-a"));
    assert_eq!(
        accepted.store_generation_hint.as_deref(),
        Some("generation-a")
    );
    assert_eq!(accepted.accepted_at, accepted_at);
    assert_eq!(registry.pending_count(), 0);
    assert_eq!(
        registry.accept(registered.challenge_id.as_str(), accepted_at),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Accepted,
        })
    );
    assert_eq!(
        registry.reject(registered.challenge_id.as_str(), accepted_at),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Accepted,
        })
    );
}

#[test]
fn snapshot_does_not_consume_and_persisted_commit_is_atomic() {
    let mut registry = deterministic_registry([[1; 16]]);
    let registered = registry
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            Some("request-p"),
            None,
            NOW,
        )
        .unwrap();
    let snapshot = registry
        .snapshot_pending(registered.challenge_id.as_str(), NOW)
        .unwrap();

    assert_eq!(registry.pending_count(), 1);
    assert_eq!(snapshot.host_identity, registered.host_identity);
    assert!(!format!("{snapshot:?}").contains(KEY_A));

    let persisted = registry
        .mark_persisted_if_pending(&snapshot, NOW + Duration::from_secs(1))
        .unwrap();
    assert_eq!(persisted.request_id.as_deref(), Some("request-p"));
    assert_eq!(registry.pending_count(), 0);
    assert_eq!(
        registry.accept(registered.challenge_id.as_str(), NOW),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Persisted,
        })
    );
}

#[test]
fn persisted_commit_rejects_stale_rejected_expired_and_cross_host_snapshots() {
    let mut rejected_registry = deterministic_registry([[1; 16]]);
    let rejected_registered = rejected_registry
        .register(
            draft("rejected.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    let rejected_snapshot = rejected_registry
        .snapshot_pending(rejected_registered.challenge_id.as_str(), NOW)
        .unwrap();
    rejected_registry
        .reject(rejected_registered.challenge_id.as_str(), NOW)
        .unwrap();
    assert_eq!(
        rejected_registry.mark_persisted_if_pending(&rejected_snapshot, NOW),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Rejected,
        })
    );

    let short = PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(1),
        ..PendingChallengeRegistryConfig::default()
    };
    let mut expired_registry = PendingHostKeyChallengeRegistry::with_id_generator(
        short,
        SequenceIdGenerator::from_bytes([[2; 16]]),
    )
    .unwrap();
    let expired_registered = expired_registry
        .register(
            draft("expired.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    let expired_snapshot = expired_registry
        .snapshot_pending(expired_registered.challenge_id.as_str(), NOW)
        .unwrap();
    assert_eq!(
        expired_registry.mark_persisted_if_pending(&expired_snapshot, NOW + Duration::from_secs(1)),
        Err(ChallengeRegistryError::ChallengeExpired)
    );

    let mut mismatch_registry = deterministic_registry([[3; 16]]);
    let mismatch_registered = mismatch_registry
        .register(
            draft("host-a.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    let mut mismatch_snapshot = mismatch_registry
        .snapshot_pending(mismatch_registered.challenge_id.as_str(), NOW)
        .unwrap();
    mismatch_snapshot.host_identity = HostIdentity::parse("host-b.example", 22).unwrap();
    assert_eq!(
        mismatch_registry.mark_persisted_if_pending(&mismatch_snapshot, NOW),
        Err(ChallengeRegistryError::ChallengeBindingMismatch)
    );
    assert_eq!(mismatch_registry.pending_count(), 1);
}

#[test]
fn reject_consumes_without_returning_public_key_and_blocks_accept() {
    let mut registry = deterministic_registry([[1; 16]]);
    let registered = registry
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            Some("request-r"),
            None,
            NOW,
        )
        .unwrap();
    let rejected = registry
        .reject(registered.challenge_id.as_str(), NOW)
        .unwrap();

    assert_eq!(rejected.host_identity, registered.host_identity);
    assert_eq!(rejected.request_id.as_deref(), Some("request-r"));
    assert!(!format!("{rejected:?}").contains(KEY_A));
    assert_eq!(
        registry.accept(registered.challenge_id.as_str(), NOW),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Rejected,
        })
    );
    assert_eq!(
        registry.reject(registered.challenge_id.as_str(), NOW),
        Err(ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Rejected,
        })
    );
}

#[test]
fn unknown_and_invalid_ids_return_structured_errors() {
    let mut registry = deterministic_registry([]);
    assert_eq!(
        registry.accept("not-an-id", NOW),
        Err(ChallengeRegistryError::InvalidChallengeId)
    );
    let valid_unknown = ChallengeId::parse("AAAAAAAAAAAAAAAAAAAAAA").unwrap();
    assert_eq!(
        registry.reject(valid_unknown.as_str(), NOW),
        Err(ChallengeRegistryError::ChallengeNotFound)
    );
}

#[test]
fn expiry_is_deterministic_and_never_accepts_at_deadline() {
    let short = PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(5),
        ..PendingChallengeRegistryConfig::default()
    };
    let mut before_deadline = PendingHostKeyChallengeRegistry::with_id_generator(
        short,
        SequenceIdGenerator::from_bytes([[1; 16]]),
    )
    .unwrap();
    let before = before_deadline
        .register(
            draft("before.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert!(before_deadline
        .accept(before.challenge_id.as_str(), NOW + Duration::from_secs(4))
        .is_ok());

    let mut at_deadline = PendingHostKeyChallengeRegistry::with_id_generator(
        short,
        SequenceIdGenerator::from_bytes([[2; 16]]),
    )
    .unwrap();
    let expired = at_deadline
        .register(
            draft("expired.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert_eq!(
        at_deadline.accept(expired.challenge_id.as_str(), NOW + Duration::from_secs(5)),
        Err(ChallengeRegistryError::ChallengeExpired)
    );
    assert_eq!(
        at_deadline.reject(expired.challenge_id.as_str(), NOW + Duration::from_secs(5)),
        Err(ChallengeRegistryError::ChallengeExpired)
    );
}

#[test]
fn cleanup_marks_expired_then_eventually_discards_tombstone() {
    let short = PendingChallengeRegistryConfig {
        challenge_ttl: Duration::from_secs(5),
        tombstone_ttl: Duration::from_secs(10),
        ..PendingChallengeRegistryConfig::default()
    };
    let mut registry = PendingHostKeyChallengeRegistry::with_id_generator(
        short,
        SequenceIdGenerator::from_bytes([[1; 16]]),
    )
    .unwrap();
    let registered = registry
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();

    assert_eq!(
        registry
            .cleanup_expired(NOW + Duration::from_secs(5))
            .unwrap(),
        1
    );
    assert_eq!(registry.pending_count(), 0);
    assert_eq!(
        registry.accept(
            registered.challenge_id.as_str(),
            NOW + Duration::from_secs(6)
        ),
        Err(ChallengeRegistryError::ChallengeExpired)
    );
    registry
        .cleanup_expired(NOW + Duration::from_secs(16))
        .unwrap();
    assert_eq!(
        registry.accept(
            registered.challenge_id.as_str(),
            NOW + Duration::from_secs(16)
        ),
        Err(ChallengeRegistryError::ChallengeNotFound)
    );
}

#[test]
fn challenge_id_returns_only_the_bound_host_entry() {
    let mut registry = deterministic_registry([[1; 16], [2; 16]]);
    let host_a = registry
        .register(
            draft("a.example", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    registry
        .register(
            draft("b.example", 22, "ssh-ed25519", KEY_B),
            KEY_B,
            None,
            None,
            NOW,
        )
        .unwrap();

    let accepted = registry.accept(host_a.challenge_id.as_str(), NOW).unwrap();
    assert_eq!(accepted.host_identity.lookup_host, "a.example");
    assert_eq!(accepted.public_key_base64, KEY_A);
    assert_eq!(registry.pending_count(), 1);
}

#[test]
fn debug_and_errors_do_not_expose_public_key_or_credential_fields() {
    let mut registry = deterministic_registry([[1; 16]]);
    let registered = registry
        .register(
            draft("example.com", 22, "ssh-ed25519", KEY_A),
            KEY_A,
            None,
            None,
            NOW,
        )
        .unwrap();
    assert!(!format!("{registered:?}").contains(KEY_A));

    let accepted = registry
        .accept(registered.challenge_id.as_str(), NOW)
        .unwrap();
    let debug = format!("{accepted:?}");
    assert!(!debug.contains(KEY_A));
    assert!(!debug.contains("password:"));
    assert!(!debug.contains("private_key:"));
    assert!(!debug.contains("auth_token:"));

    let error = ChallengeRegistryError::PublicKeyTooLarge { max_bytes: 4 }.to_string();
    assert!(!error.contains(KEY_A));
}

#[test]
fn invalid_configuration_is_rejected() {
    let invalid = PendingChallengeRegistryConfig {
        global_pending_limit: 1,
        per_host_pending_limit: 2,
        ..PendingChallengeRegistryConfig::default()
    };
    assert!(matches!(
        PendingHostKeyChallengeRegistry::with_id_generator(
            invalid,
            SequenceIdGenerator::from_bytes([])
        ),
        Err(ChallengeRegistryError::InvalidConfiguration)
    ));
}
