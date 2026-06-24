use std::collections::HashMap;
use std::fmt;
use std::time::{Duration, SystemTime};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::{rngs::OsRng, RngCore};
use thiserror::Error;

use super::host_key::{fingerprint_sha256_from_base64, HostIdentity, HostKeyState};
use super::host_key_verifier::{HostKeyChallengeDraft, HostKeyChallengeReason};
use super::known_hosts_store::{
    canonical_public_key, normalize_algorithm, KnownHostsStoreError, MAX_PUBLIC_KEY_BASE64_BYTES,
};
use super::trust_store_generation::TrustStoreGeneration;

const CHALLENGE_ID_BYTES: usize = 16;
const CHALLENGE_ID_ENCODED_LENGTH: usize = 22;
const MAX_ID_GENERATION_ATTEMPTS: usize = 8;
const MAX_CORRELATION_VALUE_BYTES: usize = 256;

pub const DEFAULT_CHALLENGE_TTL: Duration = Duration::from_secs(120);
pub const DEFAULT_TOMBSTONE_TTL: Duration = Duration::from_secs(120);
pub const DEFAULT_GLOBAL_PENDING_LIMIT: usize = 64;
pub const DEFAULT_PER_HOST_PENDING_LIMIT: usize = 4;
pub const DEFAULT_RESOLVED_TOMBSTONE_LIMIT: usize = 128;
pub const DEFAULT_RELATED_REQUEST_LIMIT: usize = 16;
pub const MAX_RELATED_REQUEST_LIMIT: usize = 256;

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ChallengeId(String);

impl ChallengeId {
    fn from_entropy(entropy: [u8; CHALLENGE_ID_BYTES]) -> Self {
        Self(URL_SAFE_NO_PAD.encode(entropy))
    }

    pub fn parse(value: &str) -> Result<Self, ChallengeRegistryError> {
        if value.len() != CHALLENGE_ID_ENCODED_LENGTH {
            return Err(ChallengeRegistryError::InvalidChallengeId);
        }
        let decoded = URL_SAFE_NO_PAD
            .decode(value)
            .map_err(|_| ChallengeRegistryError::InvalidChallengeId)?;
        if decoded.len() != CHALLENGE_ID_BYTES {
            return Err(ChallengeRegistryError::InvalidChallengeId);
        }
        Ok(Self(value.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ChallengeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("ChallengeId").field(&self.0).finish()
    }
}

impl fmt::Display for ChallengeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("secure challenge identifier generation failed")]
pub struct ChallengeIdGenerationError;

pub trait ChallengeIdGenerator: Send {
    fn fill_entropy(
        &mut self,
        destination: &mut [u8; CHALLENGE_ID_BYTES],
    ) -> Result<(), ChallengeIdGenerationError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SecureChallengeIdGenerator;

impl ChallengeIdGenerator for SecureChallengeIdGenerator {
    fn fill_entropy(
        &mut self,
        destination: &mut [u8; CHALLENGE_ID_BYTES],
    ) -> Result<(), ChallengeIdGenerationError> {
        OsRng
            .try_fill_bytes(destination)
            .map_err(|_| ChallengeIdGenerationError)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PendingChallengeRegistryConfig {
    pub challenge_ttl: Duration,
    pub tombstone_ttl: Duration,
    pub global_pending_limit: usize,
    pub per_host_pending_limit: usize,
    pub resolved_tombstone_limit: usize,
    pub related_request_limit: usize,
    pub public_key_max_len: usize,
}

impl Default for PendingChallengeRegistryConfig {
    fn default() -> Self {
        Self {
            challenge_ttl: DEFAULT_CHALLENGE_TTL,
            tombstone_ttl: DEFAULT_TOMBSTONE_TTL,
            global_pending_limit: DEFAULT_GLOBAL_PENDING_LIMIT,
            per_host_pending_limit: DEFAULT_PER_HOST_PENDING_LIMIT,
            resolved_tombstone_limit: DEFAULT_RESOLVED_TOMBSTONE_LIMIT,
            related_request_limit: DEFAULT_RELATED_REQUEST_LIMIT,
            public_key_max_len: MAX_PUBLIC_KEY_BASE64_BYTES,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingChallengeState {
    Pending,
    Accepted,
    Persisted,
    Rejected,
    Expired,
    InvalidatedByStoreChange,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ChallengeEquivalenceKey {
    host_identity: HostIdentity,
    key_algorithm: String,
    fingerprint_sha256: String,
    trust_store_generation: TrustStoreGeneration,
}

impl fmt::Debug for ChallengeEquivalenceKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ChallengeEquivalenceKey")
            .field("normalized_host", &self.host_identity.normalized_host)
            .field("port", &self.host_identity.port)
            .field("lookup_token", &self.host_identity.lookup_token)
            .field("key_algorithm", &self.key_algorithm)
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .field("trust_store_generation", &self.trust_store_generation)
            .finish()
    }
}

impl ChallengeEquivalenceKey {
    pub(crate) fn new(
        identity: &HostIdentity,
        key_algorithm: String,
        fingerprint_sha256: String,
        trust_store_generation: TrustStoreGeneration,
    ) -> Result<Self, ChallengeRegistryError> {
        let host_identity = HostIdentity::parse(&identity.normalized_host, identity.port)
            .map_err(|_| ChallengeRegistryError::InvalidHostIdentity)?;
        let key_algorithm = normalize_algorithm(&key_algorithm)
            .map_err(|_| ChallengeRegistryError::InvalidAlgorithm)?;
        if !fingerprint_sha256.starts_with("SHA256:")
            || fingerprint_sha256.len() <= "SHA256:".len()
            || fingerprint_sha256.chars().any(char::is_control)
        {
            return Err(ChallengeRegistryError::InvalidChallengeDraft);
        }
        Ok(Self {
            host_identity,
            key_algorithm,
            fingerprint_sha256,
            trust_store_generation,
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RelatedChallengeRequest {
    request_id: String,
    created_at: SystemTime,
}

impl fmt::Debug for RelatedChallengeRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelatedChallengeRequest")
            .field("request_id", &"[REDACTED]")
            .field("created_at", &self.created_at)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct PendingHostKeyChallenge {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub created_at: SystemTime,
    pub expires_at: SystemTime,
    pub state: PendingChallengeState,
    pub reason_code: HostKeyChallengeReason,
    pub store_generation_hint: Option<String>,
    equivalence_key: Option<ChallengeEquivalenceKey>,
    related_requests: Vec<RelatedChallengeRequest>,
    public_key_base64: String,
}

impl fmt::Debug for PendingHostKeyChallenge {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingHostKeyChallenge")
            .field("challenge_id", &self.challenge_id)
            .field("request_id", &self.request_id)
            .field("host_identity", &self.host_identity)
            .field("key_algorithm", &self.key_algorithm)
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .field("created_at", &self.created_at)
            .field("expires_at", &self.expires_at)
            .field("state", &self.state)
            .field("reason_code", &self.reason_code)
            .field("store_generation_hint", &self.store_generation_hint)
            .field("has_equivalence_key", &self.equivalence_key.is_some())
            .field("related_request_count", &self.related_requests.len())
            .field("public_key_base64", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegisteredHostKeyChallenge {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub created_at: SystemTime,
    pub expires_at: SystemTime,
    pub reason_code: HostKeyChallengeReason,
    pub store_generation_hint: Option<String>,
    pub reused_existing_challenge: bool,
    pub related_request_count: usize,
}

#[derive(Clone, PartialEq, Eq)]
pub struct AcceptedHostKeyChallenge {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub public_key_base64: String,
    pub created_at: SystemTime,
    pub accepted_at: SystemTime,
    pub store_generation_hint: Option<String>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct PendingHostKeyChallengeSnapshot {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub created_at: SystemTime,
    pub expires_at: SystemTime,
    pub store_generation_hint: Option<String>,
    pub(crate) public_key_base64: String,
}

impl fmt::Debug for PendingHostKeyChallengeSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingHostKeyChallengeSnapshot")
            .field("challenge_id", &self.challenge_id)
            .field("request_id", &self.request_id)
            .field("host_identity", &self.host_identity)
            .field("key_algorithm", &self.key_algorithm)
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .field("created_at", &self.created_at)
            .field("expires_at", &self.expires_at)
            .field("store_generation_hint", &self.store_generation_hint)
            .field("public_key_base64", &"[REDACTED]")
            .finish()
    }
}

impl PendingHostKeyChallengeSnapshot {
    pub(crate) fn public_key_base64(&self) -> &str {
        &self.public_key_base64
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedHostKeyChallenge {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub persisted_at: SystemTime,
}

impl fmt::Debug for AcceptedHostKeyChallenge {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AcceptedHostKeyChallenge")
            .field("challenge_id", &self.challenge_id)
            .field("request_id", &self.request_id)
            .field("host_identity", &self.host_identity)
            .field("key_algorithm", &self.key_algorithm)
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .field("public_key_base64", &"[REDACTED]")
            .field("created_at", &self.created_at)
            .field("accepted_at", &self.accepted_at)
            .field("store_generation_hint", &self.store_generation_hint)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RejectedHostKeyChallenge {
    pub challenge_id: ChallengeId,
    pub request_id: Option<String>,
    pub host_identity: HostIdentity,
    pub key_algorithm: String,
    pub fingerprint_sha256: String,
    pub rejected_at: SystemTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ChallengeRegistryError {
    #[error("challenge identifier generation failed")]
    IdGenerationFailed,
    #[error("challenge identifier generation repeatedly collided")]
    IdCollisionLimitReached,
    #[error("challenge identifier is invalid")]
    InvalidChallengeId,
    #[error("challenge was not found")]
    ChallengeNotFound,
    #[error("challenge has expired")]
    ChallengeExpired,
    #[error("challenge has already been resolved as {state:?}")]
    ChallengeAlreadyResolved { state: PendingChallengeState },
    #[error("global pending challenge limit reached")]
    PendingLimitReached,
    #[error("per-host pending challenge limit reached")]
    PerHostPendingLimitReached,
    #[error("related request limit reached for the pending challenge")]
    RelatedRequestLimitReached,
    #[error("host public key exceeds the configured size limit")]
    PublicKeyTooLarge { max_bytes: usize },
    #[error("host public key is invalid")]
    InvalidPublicKey,
    #[error("host key algorithm is invalid")]
    InvalidAlgorithm,
    #[error("host identity is invalid")]
    InvalidHostIdentity,
    #[error("host key challenge draft is invalid")]
    InvalidChallengeDraft,
    #[error("challenge correlation value is invalid")]
    InvalidCorrelationValue,
    #[error("challenge registry configuration is invalid")]
    InvalidConfiguration,
    #[error("known_hosts store generation no longer matches")]
    StoreGenerationMismatch,
    #[error("challenge binding no longer matches the pending entry")]
    ChallengeBindingMismatch,
    #[error("equivalent challenge index is inconsistent")]
    EquivalentChallengeIndexCorrupt,
    #[error("challenge registry invariant was violated")]
    InternalInvariantViolation,
}

#[derive(Debug, Clone)]
struct ResolvedChallengeTombstone {
    state: PendingChallengeState,
    resolved_at: SystemTime,
    discard_at: SystemTime,
}

pub struct PendingHostKeyChallengeRegistry<G = SecureChallengeIdGenerator> {
    config: PendingChallengeRegistryConfig,
    id_generator: G,
    pending: HashMap<ChallengeId, PendingHostKeyChallenge>,
    equivalence_index: HashMap<ChallengeEquivalenceKey, ChallengeId>,
    resolved: HashMap<ChallengeId, ResolvedChallengeTombstone>,
}

impl<G> fmt::Debug for PendingHostKeyChallengeRegistry<G> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingHostKeyChallengeRegistry")
            .field("config", &self.config)
            .field("pending_count", &self.pending.len())
            .field("equivalence_count", &self.equivalence_index.len())
            .field("resolved_count", &self.resolved.len())
            .finish()
    }
}

impl Default for PendingHostKeyChallengeRegistry<SecureChallengeIdGenerator> {
    fn default() -> Self {
        Self::new()
    }
}

impl PendingHostKeyChallengeRegistry<SecureChallengeIdGenerator> {
    pub fn new() -> Self {
        Self::with_id_generator(
            PendingChallengeRegistryConfig::default(),
            SecureChallengeIdGenerator,
        )
        .expect("default pending challenge registry configuration must be valid")
    }

    pub fn with_config(
        config: PendingChallengeRegistryConfig,
    ) -> Result<Self, ChallengeRegistryError> {
        Self::with_id_generator(config, SecureChallengeIdGenerator)
    }
}

impl<G: ChallengeIdGenerator> PendingHostKeyChallengeRegistry<G> {
    pub fn with_id_generator(
        config: PendingChallengeRegistryConfig,
        id_generator: G,
    ) -> Result<Self, ChallengeRegistryError> {
        validate_config(config)?;
        Ok(Self {
            config,
            id_generator,
            pending: HashMap::new(),
            equivalence_index: HashMap::new(),
            resolved: HashMap::new(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn register(
        &mut self,
        draft: HostKeyChallengeDraft,
        public_key_base64: &str,
        request_id: Option<&str>,
        store_generation_hint: Option<&str>,
        now: SystemTime,
    ) -> Result<RegisteredHostKeyChallenge, ChallengeRegistryError> {
        self.cleanup_expired(now)?;
        let prepared = prepare_registration(
            draft,
            public_key_base64,
            request_id,
            store_generation_hint,
            self.config.public_key_max_len,
        )?;
        self.insert_new_pending(prepared, None, now)
    }

    pub fn register_or_reuse_unknown_challenge(
        &mut self,
        draft: HostKeyChallengeDraft,
        public_key_base64: &str,
        request_id: Option<&str>,
        trust_store_generation: &TrustStoreGeneration,
        now: SystemTime,
    ) -> Result<RegisteredHostKeyChallenge, ChallengeRegistryError> {
        self.cleanup_expired(now)?;
        let prepared = prepare_registration(
            draft,
            public_key_base64,
            request_id,
            Some(trust_store_generation.as_hint()),
            self.config.public_key_max_len,
        )?;
        let equivalence_key = ChallengeEquivalenceKey::new(
            &prepared.host_identity,
            prepared.key_algorithm.clone(),
            prepared.fingerprint_sha256.clone(),
            trust_store_generation.clone(),
        )?;

        if let Some(challenge_id) = self.equivalence_index.get(&equivalence_key).cloned() {
            let pending = self
                .pending
                .get_mut(&challenge_id)
                .ok_or(ChallengeRegistryError::EquivalentChallengeIndexCorrupt)?;
            if pending.state != PendingChallengeState::Pending
                || pending.equivalence_key.as_ref() != Some(&equivalence_key)
                || pending.public_key_base64 != prepared.public_key_base64
            {
                return Err(ChallengeRegistryError::EquivalentChallengeIndexCorrupt);
            }
            add_related_request(
                pending,
                prepared.request_id.clone(),
                now,
                self.config.related_request_limit,
            )?;
            return Ok(registered_summary(pending, prepared.request_id, true));
        }

        self.insert_new_pending(prepared, Some(equivalence_key), now)
    }

    fn insert_new_pending(
        &mut self,
        prepared: PreparedChallengeRegistration,
        equivalence_key: Option<ChallengeEquivalenceKey>,
        now: SystemTime,
    ) -> Result<RegisteredHostKeyChallenge, ChallengeRegistryError> {
        if self.pending.len() >= self.config.global_pending_limit {
            return Err(ChallengeRegistryError::PendingLimitReached);
        }
        if self.pending_count_for(&prepared.host_identity) >= self.config.per_host_pending_limit {
            return Err(ChallengeRegistryError::PerHostPendingLimitReached);
        }

        let challenge_id = self.generate_unique_id()?;
        let expires_at = now
            .checked_add(self.config.challenge_ttl)
            .ok_or(ChallengeRegistryError::InternalInvariantViolation)?;
        let related_requests = prepared
            .request_id
            .as_ref()
            .map(|request_id| {
                vec![RelatedChallengeRequest {
                    request_id: request_id.clone(),
                    created_at: now,
                }]
            })
            .unwrap_or_default();
        let pending = PendingHostKeyChallenge {
            challenge_id: challenge_id.clone(),
            request_id: prepared.request_id.clone(),
            host_identity: prepared.host_identity,
            key_algorithm: prepared.key_algorithm,
            fingerprint_sha256: prepared.fingerprint_sha256,
            created_at: now,
            expires_at,
            state: PendingChallengeState::Pending,
            reason_code: prepared.reason_code,
            store_generation_hint: prepared.store_generation_hint,
            equivalence_key: equivalence_key.clone(),
            related_requests,
            public_key_base64: prepared.public_key_base64,
        };
        let registered = registered_summary(&pending, prepared.request_id, false);

        if let Some(key) = equivalence_key {
            if self.equivalence_index.contains_key(&key) {
                return Err(ChallengeRegistryError::EquivalentChallengeIndexCorrupt);
            }
            self.equivalence_index.insert(key, challenge_id.clone());
        }
        if self.pending.insert(challenge_id.clone(), pending).is_some() {
            self.equivalence_index
                .retain(|_, indexed_id| indexed_id != &challenge_id);
            return Err(ChallengeRegistryError::InternalInvariantViolation);
        }
        Ok(registered)
    }

    pub fn accept(
        &mut self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<AcceptedHostKeyChallenge, ChallengeRegistryError> {
        let challenge_id = ChallengeId::parse(challenge_id)?;
        self.cleanup_expired(now)?;
        self.ensure_not_resolved(&challenge_id)?;

        let pending = self.take_pending(&challenge_id)?;
        if let Err(error) =
            self.record_tombstone(challenge_id.clone(), PendingChallengeState::Accepted, now)
        {
            self.restore_pending(pending)?;
            return Err(error);
        }

        Ok(AcceptedHostKeyChallenge {
            challenge_id,
            request_id: pending.request_id,
            host_identity: pending.host_identity,
            key_algorithm: pending.key_algorithm,
            fingerprint_sha256: pending.fingerprint_sha256,
            public_key_base64: pending.public_key_base64,
            created_at: pending.created_at,
            accepted_at: now,
            store_generation_hint: pending.store_generation_hint,
        })
    }

    pub fn snapshot_pending(
        &mut self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<PendingHostKeyChallengeSnapshot, ChallengeRegistryError> {
        let challenge_id = ChallengeId::parse(challenge_id)?;
        self.cleanup_expired(now)?;
        self.ensure_not_resolved(&challenge_id)?;
        let pending = self
            .pending
            .get(&challenge_id)
            .ok_or(ChallengeRegistryError::ChallengeNotFound)?;
        if pending.state != PendingChallengeState::Pending {
            return Err(ChallengeRegistryError::InternalInvariantViolation);
        }
        Ok(PendingHostKeyChallengeSnapshot {
            challenge_id,
            request_id: pending.request_id.clone(),
            host_identity: pending.host_identity.clone(),
            key_algorithm: pending.key_algorithm.clone(),
            fingerprint_sha256: pending.fingerprint_sha256.clone(),
            created_at: pending.created_at,
            expires_at: pending.expires_at,
            store_generation_hint: pending.store_generation_hint.clone(),
            public_key_base64: pending.public_key_base64.clone(),
        })
    }

    pub fn mark_persisted_if_pending(
        &mut self,
        snapshot: &PendingHostKeyChallengeSnapshot,
        now: SystemTime,
    ) -> Result<PersistedHostKeyChallenge, ChallengeRegistryError> {
        self.cleanup_expired(now)?;
        self.ensure_not_resolved(&snapshot.challenge_id)?;
        let pending = self
            .pending
            .get(&snapshot.challenge_id)
            .ok_or(ChallengeRegistryError::ChallengeNotFound)?;
        if pending.state != PendingChallengeState::Pending {
            return Err(ChallengeRegistryError::InternalInvariantViolation);
        }
        if pending.host_identity != snapshot.host_identity
            || pending.request_id != snapshot.request_id
            || pending.key_algorithm != snapshot.key_algorithm
            || pending.fingerprint_sha256 != snapshot.fingerprint_sha256
            || pending.public_key_base64 != snapshot.public_key_base64
            || pending.created_at != snapshot.created_at
            || pending.expires_at != snapshot.expires_at
            || pending.store_generation_hint != snapshot.store_generation_hint
        {
            return Err(ChallengeRegistryError::ChallengeBindingMismatch);
        }

        let pending = self.take_pending(&snapshot.challenge_id)?;
        if let Err(error) = self.record_tombstone(
            snapshot.challenge_id.clone(),
            PendingChallengeState::Persisted,
            now,
        ) {
            self.restore_pending(pending)?;
            return Err(error);
        }

        Ok(PersistedHostKeyChallenge {
            challenge_id: snapshot.challenge_id.clone(),
            request_id: pending.request_id,
            host_identity: pending.host_identity,
            key_algorithm: pending.key_algorithm,
            fingerprint_sha256: pending.fingerprint_sha256,
            persisted_at: now,
        })
    }

    pub fn reject(
        &mut self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<RejectedHostKeyChallenge, ChallengeRegistryError> {
        let challenge_id = ChallengeId::parse(challenge_id)?;
        self.cleanup_expired(now)?;
        self.ensure_not_resolved(&challenge_id)?;

        let pending = self.take_pending(&challenge_id)?;
        if let Err(error) =
            self.record_tombstone(challenge_id.clone(), PendingChallengeState::Rejected, now)
        {
            self.restore_pending(pending)?;
            return Err(error);
        }

        Ok(RejectedHostKeyChallenge {
            challenge_id,
            request_id: pending.request_id,
            host_identity: pending.host_identity,
            key_algorithm: pending.key_algorithm,
            fingerprint_sha256: pending.fingerprint_sha256,
            rejected_at: now,
        })
    }

    pub fn cleanup_expired(&mut self, now: SystemTime) -> Result<usize, ChallengeRegistryError> {
        self.resolved.retain(|_, item| now < item.discard_at);
        let expired_ids = self
            .pending
            .iter()
            .filter_map(|(id, pending)| (now >= pending.expires_at).then_some(id.clone()))
            .collect::<Vec<_>>();
        for id in &expired_ids {
            let pending = self.take_pending(id)?;
            if let Err(error) =
                self.record_tombstone(id.clone(), PendingChallengeState::Expired, now)
            {
                self.restore_pending(pending)?;
                return Err(error);
            }
        }
        Ok(expired_ids.len())
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    pub fn pending_count_for(&self, identity: &HostIdentity) -> usize {
        self.pending
            .values()
            .filter(|pending| pending.host_identity.lookup_token == identity.lookup_token)
            .count()
    }

    pub fn resolved_count(&self) -> usize {
        self.resolved.len()
    }

    pub fn state(
        &mut self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<Option<PendingChallengeState>, ChallengeRegistryError> {
        let challenge_id = ChallengeId::parse(challenge_id)?;
        self.cleanup_expired(now)?;
        if self.pending.contains_key(&challenge_id) {
            return Ok(Some(PendingChallengeState::Pending));
        }
        Ok(self.resolved.get(&challenge_id).map(|item| item.state))
    }

    fn take_pending(
        &mut self,
        challenge_id: &ChallengeId,
    ) -> Result<PendingHostKeyChallenge, ChallengeRegistryError> {
        let pending = self
            .pending
            .get(challenge_id)
            .ok_or(ChallengeRegistryError::ChallengeNotFound)?;
        if pending.state != PendingChallengeState::Pending {
            return Err(ChallengeRegistryError::InternalInvariantViolation);
        }
        if let Some(key) = pending.equivalence_key.as_ref() {
            if self.equivalence_index.get(key) != Some(challenge_id) {
                return Err(ChallengeRegistryError::EquivalentChallengeIndexCorrupt);
            }
        }

        let pending = self
            .pending
            .remove(challenge_id)
            .ok_or(ChallengeRegistryError::InternalInvariantViolation)?;
        if let Some(key) = pending.equivalence_key.as_ref() {
            self.equivalence_index.remove(key);
        }
        Ok(pending)
    }

    fn restore_pending(
        &mut self,
        pending: PendingHostKeyChallenge,
    ) -> Result<(), ChallengeRegistryError> {
        if self.pending.contains_key(&pending.challenge_id) {
            return Err(ChallengeRegistryError::EquivalentChallengeIndexCorrupt);
        }
        if let Some(key) = pending.equivalence_key.as_ref() {
            if self.equivalence_index.contains_key(key) {
                return Err(ChallengeRegistryError::EquivalentChallengeIndexCorrupt);
            }
            self.equivalence_index
                .insert(key.clone(), pending.challenge_id.clone());
        }
        self.pending.insert(pending.challenge_id.clone(), pending);
        Ok(())
    }

    fn generate_unique_id(&mut self) -> Result<ChallengeId, ChallengeRegistryError> {
        for _ in 0..MAX_ID_GENERATION_ATTEMPTS {
            let mut entropy = [0_u8; CHALLENGE_ID_BYTES];
            self.id_generator
                .fill_entropy(&mut entropy)
                .map_err(|_| ChallengeRegistryError::IdGenerationFailed)?;
            let candidate = ChallengeId::from_entropy(entropy);
            if !self.pending.contains_key(&candidate) && !self.resolved.contains_key(&candidate) {
                return Ok(candidate);
            }
        }
        Err(ChallengeRegistryError::IdCollisionLimitReached)
    }

    fn ensure_not_resolved(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<(), ChallengeRegistryError> {
        match self.resolved.get(challenge_id).map(|item| item.state) {
            Some(PendingChallengeState::Expired) => Err(ChallengeRegistryError::ChallengeExpired),
            Some(state) => Err(ChallengeRegistryError::ChallengeAlreadyResolved { state }),
            None => Ok(()),
        }
    }

    fn record_tombstone(
        &mut self,
        challenge_id: ChallengeId,
        state: PendingChallengeState,
        now: SystemTime,
    ) -> Result<(), ChallengeRegistryError> {
        while self.resolved.len() >= self.config.resolved_tombstone_limit {
            let Some(oldest) = self
                .resolved
                .iter()
                .min_by_key(|(_, item)| item.resolved_at)
                .map(|(id, _)| id.clone())
            else {
                break;
            };
            self.resolved.remove(&oldest);
        }
        let discard_at = now
            .checked_add(self.config.tombstone_ttl)
            .ok_or(ChallengeRegistryError::InternalInvariantViolation)?;
        self.resolved.insert(
            challenge_id,
            ResolvedChallengeTombstone {
                state,
                resolved_at: now,
                discard_at,
            },
        );
        Ok(())
    }
}

struct PreparedChallengeRegistration {
    host_identity: HostIdentity,
    key_algorithm: String,
    fingerprint_sha256: String,
    public_key_base64: String,
    request_id: Option<String>,
    store_generation_hint: Option<String>,
    reason_code: HostKeyChallengeReason,
}

fn prepare_registration(
    draft: HostKeyChallengeDraft,
    public_key_base64: &str,
    request_id: Option<&str>,
    store_generation_hint: Option<&str>,
    public_key_max_len: usize,
) -> Result<PreparedChallengeRegistration, ChallengeRegistryError> {
    let host_identity = validate_draft(&draft)?;
    let key_algorithm = normalize_algorithm(&draft.key_algorithm).map_err(|error| match error {
        KnownHostsStoreError::InvalidAlgorithm => ChallengeRegistryError::InvalidAlgorithm,
        _ => ChallengeRegistryError::InternalInvariantViolation,
    })?;
    if public_key_base64.len() > public_key_max_len {
        return Err(ChallengeRegistryError::PublicKeyTooLarge {
            max_bytes: public_key_max_len,
        });
    }
    let public_key_base64 =
        canonical_public_key(public_key_base64).map_err(|error| match error {
            KnownHostsStoreError::InvalidPublicKey => ChallengeRegistryError::InvalidPublicKey,
            _ => ChallengeRegistryError::InternalInvariantViolation,
        })?;
    let fingerprint_sha256 = fingerprint_sha256_from_base64(&public_key_base64)
        .map_err(|_| ChallengeRegistryError::InvalidPublicKey)?;
    if fingerprint_sha256 != draft.fingerprint_sha256 || key_algorithm != draft.key_algorithm {
        return Err(ChallengeRegistryError::InvalidChallengeDraft);
    }

    Ok(PreparedChallengeRegistration {
        host_identity,
        key_algorithm,
        fingerprint_sha256,
        public_key_base64,
        request_id: validate_correlation_value(request_id)?,
        store_generation_hint: validate_correlation_value(store_generation_hint)?,
        reason_code: draft.reason_code,
    })
}

fn add_related_request(
    pending: &mut PendingHostKeyChallenge,
    request_id: Option<String>,
    now: SystemTime,
    limit: usize,
) -> Result<(), ChallengeRegistryError> {
    let Some(request_id) = request_id else {
        return Ok(());
    };
    if pending
        .related_requests
        .iter()
        .any(|request| request.request_id == request_id)
    {
        return Ok(());
    }
    if pending.related_requests.len() >= limit {
        return Err(ChallengeRegistryError::RelatedRequestLimitReached);
    }
    pending.related_requests.push(RelatedChallengeRequest {
        request_id,
        created_at: now,
    });
    Ok(())
}

fn registered_summary(
    pending: &PendingHostKeyChallenge,
    current_request_id: Option<String>,
    reused_existing_challenge: bool,
) -> RegisteredHostKeyChallenge {
    RegisteredHostKeyChallenge {
        challenge_id: pending.challenge_id.clone(),
        request_id: current_request_id,
        host_identity: pending.host_identity.clone(),
        key_algorithm: pending.key_algorithm.clone(),
        fingerprint_sha256: pending.fingerprint_sha256.clone(),
        created_at: pending.created_at,
        expires_at: pending.expires_at,
        reason_code: pending.reason_code,
        store_generation_hint: pending.store_generation_hint.clone(),
        reused_existing_challenge,
        related_request_count: pending.related_requests.len(),
    }
}

fn validate_config(config: PendingChallengeRegistryConfig) -> Result<(), ChallengeRegistryError> {
    if config.challenge_ttl.is_zero()
        || config.tombstone_ttl.is_zero()
        || config.global_pending_limit == 0
        || config.per_host_pending_limit == 0
        || config.per_host_pending_limit > config.global_pending_limit
        || config.resolved_tombstone_limit == 0
        || config.related_request_limit == 0
        || config.related_request_limit > MAX_RELATED_REQUEST_LIMIT
        || config.public_key_max_len == 0
        || config.public_key_max_len > MAX_PUBLIC_KEY_BASE64_BYTES
    {
        return Err(ChallengeRegistryError::InvalidConfiguration);
    }
    Ok(())
}

fn validate_draft(draft: &HostKeyChallengeDraft) -> Result<HostIdentity, ChallengeRegistryError> {
    if draft.known_state != HostKeyState::Unknown
        || draft.reason_code != HostKeyChallengeReason::UnknownHostKey
        || !draft.can_trust
        || draft.can_replace
    {
        return Err(ChallengeRegistryError::InvalidChallengeDraft);
    }
    let identity = HostIdentity::parse(&draft.host, draft.port)
        .map_err(|_| ChallengeRegistryError::InvalidHostIdentity)?;
    if identity.normalized_host != draft.normalized_host
        || identity.lookup_token != draft.lookup_token
        || identity.port != draft.port
    {
        return Err(ChallengeRegistryError::InvalidHostIdentity);
    }
    Ok(identity)
}

fn validate_correlation_value(
    value: Option<&str>,
) -> Result<Option<String>, ChallengeRegistryError> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.is_empty()
        || value.len() > MAX_CORRELATION_VALUE_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(ChallengeRegistryError::InvalidCorrelationValue);
    }
    Ok(Some(value.to_string()))
}
