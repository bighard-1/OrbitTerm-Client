use std::io;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use hmac::{Hmac, Mac};
use sha1::Sha1;

use super::{
    fingerprint_sha256_from_base64, HostIdentity, HostKeyBlockReason, HostKeyChallengeReason,
    HostKeyState, HostKeyVerificationDecision, HostKeyVerificationError, HostKeyVerificationInput,
    HostKeyVerifier, KnownHostsStore, KnownHostsStoreError, SessionSecurityGeneration,
    TrustStoreGeneration,
};

type HmacSha1 = Hmac<Sha1>;

const KEY_A: &str = "AQIDBA==";
const KEY_B: &str = "BQYHCA==";

fn input(host: &str, port: u16, algorithm: &str, public_key: &str) -> HostKeyVerificationInput {
    HostKeyVerificationInput {
        host_identity: HostIdentity::parse(host, port).unwrap(),
        key_algorithm: algorithm.to_string(),
        public_key_base64: public_key.to_string(),
    }
}

fn verify(contents: &str, input: &HostKeyVerificationInput) -> HostKeyVerificationDecision {
    let store = KnownHostsStore::from_text(contents).unwrap();
    HostKeyVerifier.verify(&store, input)
}

#[test]
fn trusted_key_proceeds_with_verified_summary() {
    let decision = verify(
        &format!("example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ssh-ed25519", KEY_A),
    );

    let HostKeyVerificationDecision::Proceed(verified) = decision else {
        panic!("trusted key must proceed");
    };
    assert_eq!(verified.host_identity.lookup_token, "example.com");
    assert_eq!(verified.key_algorithm, "ssh-ed25519");
    assert_eq!(verified.matched_record.line_number, 1);
    assert_eq!(
        verified.fingerprint_sha256,
        fingerprint_sha256_from_base64(KEY_A).unwrap()
    );
}

#[test]
fn unknown_host_produces_non_replacing_challenge() {
    let decision = verify("", &input("unknown.example", 22, "ssh-ed25519", KEY_A));

    let HostKeyVerificationDecision::Challenge(challenge) = decision else {
        panic!("unknown host must challenge");
    };
    assert_eq!(challenge.known_state, HostKeyState::Unknown);
    assert_eq!(
        challenge.reason_code,
        HostKeyChallengeReason::UnknownHostKey
    );
    assert_eq!(challenge.reason_code.message_key(), "host_key.unknown");
    assert!(challenge.can_trust);
    assert!(!challenge.can_replace);
    assert_eq!(challenge.lookup_token, "unknown.example");
}

#[test]
fn new_algorithm_for_known_host_still_challenges() {
    let decision = verify(
        &format!("example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ecdsa-sha2-nistp256", KEY_B),
    );
    assert!(matches!(
        decision,
        HostKeyVerificationDecision::Challenge(_)
    ));
}

#[test]
fn changed_key_blocks_and_reports_previous_fingerprint() {
    let decision = verify(
        &format!("example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ssh-ed25519", KEY_B),
    );

    let HostKeyVerificationDecision::Block(block) = decision else {
        panic!("changed key must block");
    };
    assert_eq!(block.reason_code, HostKeyBlockReason::Changed);
    assert_eq!(block.reason_code.message_key(), "host_key.changed");
    assert_eq!(
        block.previous_fingerprint_sha256,
        Some(fingerprint_sha256_from_base64(KEY_A).unwrap())
    );
    assert_eq!(
        block.presented_fingerprint_sha256,
        fingerprint_sha256_from_base64(KEY_B).unwrap()
    );
}

#[test]
fn revoked_key_blocks_and_takes_priority_over_trusted() {
    let contents =
        format!("example.com ssh-ed25519 {KEY_A}\n@revoked example.com ssh-ed25519 {KEY_A}");
    let decision = verify(&contents, &input("example.com", 22, "ssh-ed25519", KEY_A));

    let HostKeyVerificationDecision::Block(block) = decision else {
        panic!("revoked key must block");
    };
    assert_eq!(block.reason_code, HostKeyBlockReason::Revoked);
}

#[test]
fn certificate_authority_record_is_blocked_as_unsupported() {
    let decision = verify(
        &format!("@cert-authority example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ssh-ed25519", KEY_A),
    );

    let HostKeyVerificationDecision::Block(block) = decision else {
        panic!("certificate authority support is not enabled");
    };
    assert_eq!(
        block.reason_code,
        HostKeyBlockReason::CertificateAuthorityUnsupported
    );
    assert_eq!(
        block.reason_code.message_key(),
        "host_key.cert_authority_unsupported"
    );
}

#[test]
fn invalid_public_key_fails_without_exposing_material() {
    let secret_like_key = "%%%private-key-material%%%";
    let decision = verify(
        "",
        &input("example.com", 22, "ssh-ed25519", secret_like_key),
    );

    assert_eq!(
        decision,
        HostKeyVerificationDecision::Fail(HostKeyVerificationError::InvalidPublicKey)
    );
    assert!(!format!("{decision:?}").contains(secret_like_key));
}

#[test]
fn invalid_algorithm_fails_before_matching() {
    let decision = verify("", &input("example.com", 22, "ssh ed25519", KEY_A));
    assert_eq!(
        decision,
        HostKeyVerificationDecision::Fail(HostKeyVerificationError::InvalidAlgorithm)
    );
}

#[test]
fn inconsistent_host_identity_fails() {
    let mut request = input("example.com", 22, "ssh-ed25519", KEY_A);
    request.host_identity.lookup_token = "attacker.example".to_string();
    let decision = verify("", &request);
    assert_eq!(
        decision,
        HostKeyVerificationDecision::Fail(HostKeyVerificationError::InvalidHostIdentity)
    );
}

#[test]
fn store_error_fails_closed() {
    let request = input("example.com", 22, "ssh-ed25519", KEY_A);
    let decision = HostKeyVerifier.verify_loaded(
        Err(KnownHostsStoreError::ReadFailed {
            kind: io::ErrorKind::PermissionDenied,
        }),
        &request,
    );
    assert!(matches!(
        decision,
        HostKeyVerificationDecision::Fail(HostKeyVerificationError::StoreUnavailable(_))
    ));
}

#[test]
fn malformed_warning_does_not_hide_a_valid_trusted_record() {
    let contents = format!("malformed line\nexample.com ssh-ed25519 {KEY_A}");
    let store = KnownHostsStore::from_text(&contents).unwrap();
    assert_eq!(store.warnings().len(), 1);
    let decision = HostKeyVerifier.verify(&store, &input("example.com", 22, "ssh-ed25519", KEY_A));
    assert!(matches!(decision, HostKeyVerificationDecision::Proceed(_)));
}

#[test]
fn dns_and_ip_identities_do_not_cross_trust() {
    let contents = format!("server.example ssh-ed25519 {KEY_A}");
    assert!(matches!(
        verify(&contents, &input("203.0.113.7", 22, "ssh-ed25519", KEY_A)),
        HostKeyVerificationDecision::Challenge(_)
    ));

    let ip_contents = format!("203.0.113.7 ssh-ed25519 {KEY_A}");
    assert!(matches!(
        verify(
            &ip_contents,
            &input("server.example", 22, "ssh-ed25519", KEY_A)
        ),
        HostKeyVerificationDecision::Challenge(_)
    ));
}

#[test]
fn default_and_custom_ports_do_not_cross_trust() {
    let default_contents = format!("example.com ssh-ed25519 {KEY_A}");
    assert!(matches!(
        verify(
            &default_contents,
            &input("example.com", 2222, "ssh-ed25519", KEY_A)
        ),
        HostKeyVerificationDecision::Challenge(_)
    ));

    let custom_contents = format!("[example.com]:2222 ssh-ed25519 {KEY_A}");
    assert!(matches!(
        verify(
            &custom_contents,
            &input("example.com", 22, "ssh-ed25519", KEY_A)
        ),
        HostKeyVerificationDecision::Challenge(_)
    ));
}

#[test]
fn ipv6_and_hashed_hosts_can_proceed() {
    let ipv6 = format!("[2001:db8::1]:2222 ssh-ed25519 {KEY_A}");
    assert!(matches!(
        verify(&ipv6, &input("2001:db8::1", 2222, "ssh-ed25519", KEY_A)),
        HostKeyVerificationDecision::Proceed(_)
    ));

    let token = "[hashed.example]:2222";
    let hashed = hashed_pattern(token, b"01234567890123456789");
    assert!(matches!(
        verify(
            &format!("{hashed} ssh-ed25519 {KEY_A}"),
            &input("hashed.example", 2222, "ssh-ed25519", KEY_A)
        ),
        HostKeyVerificationDecision::Proceed(_)
    ));
}

#[test]
fn challenge_and_block_outputs_contain_no_full_public_key_or_credentials() {
    let challenge = verify("", &input("example.com", 22, "ssh-ed25519", KEY_A));
    let block = verify(
        &format!("example.com ssh-ed25519 {KEY_B}"),
        &input("example.com", 22, "ssh-ed25519", KEY_A),
    );

    for rendered in [format!("{challenge:?}"), format!("{block:?}")] {
        assert!(!rendered.contains(KEY_A));
        assert!(!rendered.contains("password:"));
        assert!(!rendered.contains("private_key:"));
        assert!(!rendered.contains("auth_token:"));
    }
}

#[test]
fn unsupported_record_never_proceeds() {
    let decision = verify(
        &format!("@future-marker example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ssh-ed25519", KEY_A),
    );
    let HostKeyVerificationDecision::Block(block) = decision else {
        panic!("unsupported record must block");
    };
    assert_eq!(block.reason_code, HostKeyBlockReason::UnsupportedRecord);
}

#[test]
fn session_security_generations_are_strictly_distinct() {
    let trusted = verify(
        &format!("example.com ssh-ed25519 {KEY_A}"),
        &input("example.com", 22, "ssh-ed25519", KEY_A),
    );
    let HostKeyVerificationDecision::Proceed(verified) = trusted else {
        panic!("fixture must be trusted");
    };
    let trust_generation = TrustStoreGeneration::from_contents(b"store-a");
    let generation = SessionSecurityGeneration::from_verified(&verified, trust_generation.clone());

    assert_ne!(generation, SessionSecurityGeneration::LegacyUnverified);
    assert_ne!(
        generation,
        SessionSecurityGeneration::HostKeyVerified {
            host_identity: HostIdentity::parse("other.example", 22).unwrap(),
            key_algorithm: verified.key_algorithm.clone(),
            fingerprint_sha256: verified.fingerprint_sha256.clone(),
            trust_store_generation: trust_generation.clone(),
        }
    );
    assert_ne!(
        generation,
        SessionSecurityGeneration::HostKeyVerified {
            host_identity: verified.host_identity.clone(),
            key_algorithm: "ecdsa-sha2-nistp256".to_string(),
            fingerprint_sha256: verified.fingerprint_sha256.clone(),
            trust_store_generation: trust_generation.clone(),
        }
    );
    assert_ne!(
        generation,
        SessionSecurityGeneration::HostKeyVerified {
            host_identity: verified.host_identity.clone(),
            key_algorithm: verified.key_algorithm.clone(),
            fingerprint_sha256: fingerprint_sha256_from_base64(KEY_B).unwrap(),
            trust_store_generation: trust_generation.clone(),
        }
    );
    assert_ne!(
        generation,
        SessionSecurityGeneration::HostKeyVerified {
            host_identity: verified.host_identity,
            key_algorithm: verified.key_algorithm,
            fingerprint_sha256: verified.fingerprint_sha256,
            trust_store_generation: TrustStoreGeneration::from_contents(b"store-b"),
        }
    );
}

fn hashed_pattern(token: &str, salt: &[u8]) -> String {
    let mut mac = HmacSha1::new_from_slice(salt).unwrap();
    mac.update(token.as_bytes());
    let hash = mac.finalize().into_bytes();
    format!("|1|{}|{}", STANDARD.encode(salt), STANDARD.encode(hash))
}
