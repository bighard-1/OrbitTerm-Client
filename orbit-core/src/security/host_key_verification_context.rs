use std::fmt;
use std::sync::Arc;

use thiserror::Error;

use super::host_key::HostIdentity;
use super::host_key_challenge_service::HostKeyChallengeService;
use super::host_key_verifier::HostKeyVerifier;
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::trust_store_generation::TrustStoreGeneration;
use super::verified_host_key_slot::VerifiedHostKeySlot;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub(crate) enum HostKeyVerificationContextError {
    #[error("host key verification request identifier is invalid")]
    InvalidRequestId,
    #[error("known_hosts store is unavailable")]
    StoreUnavailable(#[source] KnownHostsStoreError),
}

/// Immutable trust inputs and per-attempt output state for checked KEX.
#[derive(Clone)]
pub(crate) struct HostKeyVerificationContext {
    host_identity: HostIdentity,
    request_id: Option<String>,
    trust_store: Arc<KnownHostsStore>,
    trust_store_generation: TrustStoreGeneration,
    verifier: HostKeyVerifier,
    challenge_service: HostKeyChallengeService,
    verified_slot: VerifiedHostKeySlot,
}

impl fmt::Debug for HostKeyVerificationContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostKeyVerificationContext")
            .field("host_identity", &self.host_identity)
            .field("request_id", &self.request_id)
            .field("trust_store_generation", &self.trust_store_generation)
            .field("verified_slot", &self.verified_slot)
            .finish_non_exhaustive()
    }
}

impl HostKeyVerificationContext {
    pub(crate) fn new(
        host_identity: HostIdentity,
        request_id: Option<String>,
        trust_store: KnownHostsStore,
        challenge_service: HostKeyChallengeService,
    ) -> Result<Self, HostKeyVerificationContextError> {
        Self::from_loaded_store(
            host_identity,
            request_id,
            Ok(trust_store),
            challenge_service,
        )
    }

    pub(crate) fn from_loaded_store(
        host_identity: HostIdentity,
        request_id: Option<String>,
        trust_store: Result<KnownHostsStore, KnownHostsStoreError>,
        challenge_service: HostKeyChallengeService,
    ) -> Result<Self, HostKeyVerificationContextError> {
        if let Some(value) = request_id.as_deref() {
            if value.is_empty()
                || value.len() > MAX_REQUEST_ID_BYTES
                || value.chars().any(char::is_control)
            {
                return Err(HostKeyVerificationContextError::InvalidRequestId);
            }
        }
        let trust_store = trust_store.map_err(HostKeyVerificationContextError::StoreUnavailable)?;
        let trust_store_generation = TrustStoreGeneration::from_store(&trust_store);
        Ok(Self {
            host_identity,
            request_id,
            trust_store: Arc::new(trust_store),
            trust_store_generation,
            verifier: HostKeyVerifier,
            challenge_service,
            verified_slot: VerifiedHostKeySlot::default(),
        })
    }

    pub(crate) fn host_identity(&self) -> &HostIdentity {
        &self.host_identity
    }

    pub(crate) fn request_id(&self) -> Option<&str> {
        self.request_id.as_deref()
    }

    pub(crate) fn trust_store(&self) -> &KnownHostsStore {
        self.trust_store.as_ref()
    }

    pub(crate) fn trust_store_generation(&self) -> &TrustStoreGeneration {
        &self.trust_store_generation
    }

    pub(crate) fn verifier(&self) -> HostKeyVerifier {
        self.verifier
    }

    pub(crate) fn challenge_service(&self) -> &HostKeyChallengeService {
        &self.challenge_service
    }

    pub(crate) fn verified_slot(&self) -> &VerifiedHostKeySlot {
        &self.verified_slot
    }
}
