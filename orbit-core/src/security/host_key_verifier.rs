use thiserror::Error;

use super::host_key::{
    fingerprint_sha256_from_base64, FingerprintError, HostIdentity, HostKeyState,
};
use super::known_hosts::{patterns_apply_to_identity, KnownHostMarker, KnownHostRecord};
use super::known_hosts_store::{
    canonical_public_key, normalize_algorithm, KnownHostsStore, KnownHostsStoreError,
};
use super::trust_store_generation::TrustStoreGeneration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyVerificationInput {
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub public_key_base64: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyVerificationDecision {
    Proceed(VerifiedHostKey),
    Challenge(HostKeyChallengeDraft),
    Block(HostKeyBlock),
    Fail(HostKeyVerificationError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedHostKey {
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub matched_record: KnownHostRecordSummary,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostRecordSummary {
    pub line_number: usize,
    pub marker: KnownHostMarker,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyChallengeReason {
    UnknownHostKey,
}

impl HostKeyChallengeReason {
    pub const fn message_key(self) -> &'static str {
        match self {
            Self::UnknownHostKey => "host_key.unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyChallengeDraft {
    pub host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_token: String,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub reason_code: HostKeyChallengeReason,
    pub known_state: HostKeyState,
    pub can_trust: bool,
    pub can_replace: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyBlockReason {
    Changed,
    Revoked,
    UnsupportedRecord,
    CertificateAuthorityUnsupported,
}

impl HostKeyBlockReason {
    pub const fn message_key(self) -> &'static str {
        match self {
            Self::Changed => "host_key.changed",
            Self::Revoked => "host_key.revoked",
            Self::UnsupportedRecord => "host_key.unsupported_record",
            Self::CertificateAuthorityUnsupported => "host_key.cert_authority_unsupported",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyBlock {
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub presented_fingerprint_sha256: String,
    pub reason_code: HostKeyBlockReason,
    pub previous_fingerprint_sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HostKeyVerificationError {
    #[error("host identity is invalid")]
    InvalidHostIdentity,
    #[error("host key algorithm is invalid")]
    InvalidAlgorithm,
    #[error("host public key is invalid")]
    InvalidPublicKey,
    #[error("host key fingerprint could not be generated")]
    Fingerprint(#[source] FingerprintError),
    #[error("known_hosts store is unavailable")]
    StoreUnavailable(#[source] KnownHostsStoreError),
    #[error("host key matcher returned an inconsistent result")]
    MatcherInvariant,
}

/// Security generation metadata reserved for the A2.3 SessionPool integration.
///
/// Defining the type here does not change pool behavior. It prevents a checked
/// connection from later treating a legacy accept-all session as equivalent to
/// a host-key-verified session.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SessionSecurityGeneration {
    LegacyUnverified,
    HostKeyVerified {
        host_identity: HostIdentity,
        key_algorithm: String,
        fingerprint_sha256: String,
        trust_store_generation: TrustStoreGeneration,
    },
}

impl SessionSecurityGeneration {
    pub fn from_verified(
        value: &VerifiedHostKey,
        trust_store_generation: TrustStoreGeneration,
    ) -> Self {
        Self::HostKeyVerified {
            host_identity: value.host_identity.clone(),
            key_algorithm: value.key_algorithm.clone(),
            fingerprint_sha256: value.fingerprint_sha256.clone(),
            trust_store_generation,
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct HostKeyVerifier;

impl HostKeyVerifier {
    pub fn verify_loaded(
        &self,
        store: Result<&KnownHostsStore, KnownHostsStoreError>,
        input: &HostKeyVerificationInput,
    ) -> HostKeyVerificationDecision {
        match store {
            Ok(store) => self.verify(store, input),
            Err(error) => {
                HostKeyVerificationDecision::Fail(HostKeyVerificationError::StoreUnavailable(error))
            }
        }
    }

    pub fn verify(
        &self,
        store: &KnownHostsStore,
        input: &HostKeyVerificationInput,
    ) -> HostKeyVerificationDecision {
        let identity = match validated_identity(&input.host_identity) {
            Ok(identity) => identity,
            Err(error) => return HostKeyVerificationDecision::Fail(error),
        };
        let key_algorithm = match normalize_algorithm(&input.key_algorithm) {
            Ok(algorithm) => algorithm,
            Err(KnownHostsStoreError::InvalidAlgorithm) => {
                return HostKeyVerificationDecision::Fail(
                    HostKeyVerificationError::InvalidAlgorithm,
                );
            }
            Err(_) => {
                return HostKeyVerificationDecision::Fail(
                    HostKeyVerificationError::MatcherInvariant,
                );
            }
        };
        let public_key_base64 = match canonical_public_key(&input.public_key_base64) {
            Ok(public_key) => public_key,
            Err(KnownHostsStoreError::InvalidPublicKey) => {
                return HostKeyVerificationDecision::Fail(
                    HostKeyVerificationError::InvalidPublicKey,
                );
            }
            Err(_) => {
                return HostKeyVerificationDecision::Fail(
                    HostKeyVerificationError::MatcherInvariant,
                );
            }
        };
        let fingerprint = match fingerprint_sha256_from_base64(&public_key_base64) {
            Ok(fingerprint) => fingerprint,
            Err(error) => {
                return HostKeyVerificationDecision::Fail(HostKeyVerificationError::Fingerprint(
                    error,
                ));
            }
        };

        let matched = store.query(identity, &key_algorithm, &public_key_base64);
        match matched.state {
            HostKeyState::Trusted => matched
                .matched_line
                .and_then(|line_number| record_summary(store, line_number))
                .map(|matched_record| {
                    HostKeyVerificationDecision::Proceed(VerifiedHostKey {
                        host_identity: identity.clone(),
                        key_algorithm,
                        fingerprint_sha256: fingerprint,
                        matched_record,
                    })
                })
                .unwrap_or_else(|| {
                    HostKeyVerificationDecision::Fail(HostKeyVerificationError::MatcherInvariant)
                }),
            HostKeyState::Unknown => {
                HostKeyVerificationDecision::Challenge(HostKeyChallengeDraft {
                    host: identity.original_host.clone(),
                    normalized_host: identity.normalized_host.clone(),
                    port: identity.port,
                    lookup_token: identity.lookup_token.clone(),
                    key_algorithm,
                    fingerprint_sha256: fingerprint,
                    reason_code: HostKeyChallengeReason::UnknownHostKey,
                    known_state: HostKeyState::Unknown,
                    can_trust: true,
                    can_replace: false,
                })
            }
            HostKeyState::Changed => HostKeyVerificationDecision::Block(HostKeyBlock {
                host_identity: identity.clone(),
                key_algorithm: key_algorithm.clone(),
                presented_fingerprint_sha256: fingerprint,
                reason_code: HostKeyBlockReason::Changed,
                previous_fingerprint_sha256: previous_trusted_fingerprint(
                    store,
                    identity,
                    &key_algorithm,
                ),
            }),
            HostKeyState::Revoked => HostKeyVerificationDecision::Block(HostKeyBlock {
                host_identity: identity.clone(),
                key_algorithm,
                presented_fingerprint_sha256: fingerprint,
                reason_code: HostKeyBlockReason::Revoked,
                previous_fingerprint_sha256: None,
            }),
            HostKeyState::Unsupported => {
                let reason_code = matched
                    .matched_line
                    .and_then(|line_number| record_at_line(store, line_number))
                    .map(|record| match record.marker {
                        KnownHostMarker::CertAuthority => {
                            HostKeyBlockReason::CertificateAuthorityUnsupported
                        }
                        _ => HostKeyBlockReason::UnsupportedRecord,
                    })
                    .unwrap_or(HostKeyBlockReason::UnsupportedRecord);
                HostKeyVerificationDecision::Block(HostKeyBlock {
                    host_identity: identity.clone(),
                    key_algorithm,
                    presented_fingerprint_sha256: fingerprint,
                    reason_code,
                    previous_fingerprint_sha256: None,
                })
            }
            HostKeyState::Invalid => {
                HostKeyVerificationDecision::Fail(HostKeyVerificationError::InvalidPublicKey)
            }
            HostKeyState::Error => {
                HostKeyVerificationDecision::Fail(HostKeyVerificationError::MatcherInvariant)
            }
        }
    }
}

fn validated_identity(identity: &HostIdentity) -> Result<&HostIdentity, HostKeyVerificationError> {
    let reparsed = HostIdentity::parse(&identity.original_host, identity.port)
        .map_err(|_| HostKeyVerificationError::InvalidHostIdentity)?;
    if reparsed.normalized_host != identity.normalized_host
        || reparsed.lookup_host != identity.lookup_host
        || reparsed.lookup_token != identity.lookup_token
        || reparsed.port != identity.port
    {
        return Err(HostKeyVerificationError::InvalidHostIdentity);
    }
    Ok(identity)
}

fn record_at_line(store: &KnownHostsStore, line_number: usize) -> Option<&KnownHostRecord> {
    store
        .records()
        .find(|record| record.line_number == line_number)
}

fn record_summary(store: &KnownHostsStore, line_number: usize) -> Option<KnownHostRecordSummary> {
    record_at_line(store, line_number).map(|record| KnownHostRecordSummary {
        line_number,
        marker: record.marker.clone(),
    })
}

fn previous_trusted_fingerprint(
    store: &KnownHostsStore,
    identity: &HostIdentity,
    key_algorithm: &str,
) -> Option<String> {
    store
        .records()
        .find(|record| {
            record.marker == KnownHostMarker::None
                && record.key_algorithm.eq_ignore_ascii_case(key_algorithm)
                && patterns_apply_to_identity(&record.patterns, identity)
        })
        .and_then(|record| fingerprint_sha256_from_base64(&record.public_key_base64).ok())
}
