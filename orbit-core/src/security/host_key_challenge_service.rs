use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

use thiserror::Error;

use super::host_key_challenge_registry::{
    AcceptedHostKeyChallenge, ChallengeRegistryError, PendingChallengeState,
    PendingHostKeyChallengeRegistry, PendingHostKeyChallengeSnapshot, PersistedHostKeyChallenge,
    RegisteredHostKeyChallenge, RejectedHostKeyChallenge,
};
use super::host_key_verifier::HostKeyChallengeDraft;
use super::trust_store_generation::TrustStoreGeneration;

type Registry = PendingHostKeyChallengeRegistry;

static SHARED_CHALLENGE_SERVICE: OnceLock<HostKeyChallengeService> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub(crate) enum HostKeyChallengeServiceError {
    #[error("host key challenge registry operation failed")]
    Registry(#[source] ChallengeRegistryError),
    #[error("host key challenge service is unavailable")]
    Unavailable,
}

impl From<ChallengeRegistryError> for HostKeyChallengeServiceError {
    fn from(error: ChallengeRegistryError) -> Self {
        Self::Registry(error)
    }
}

/// Short-lived, injectable access to the bounded pending challenge registry.
///
/// The mutex stays private so callers cannot hold its guard across file, UI,
/// or network operations. Clones share the same registry instance.
#[derive(Clone)]
pub(crate) struct HostKeyChallengeService {
    registry: Arc<Mutex<Registry>>,
}

impl std::fmt::Debug for HostKeyChallengeService {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("HostKeyChallengeService")
            .finish_non_exhaustive()
    }
}

impl Default for HostKeyChallengeService {
    fn default() -> Self {
        Self::new(Registry::new())
    }
}

impl HostKeyChallengeService {
    pub(crate) fn new(registry: Registry) -> Self {
        Self {
            registry: Arc::new(Mutex::new(registry)),
        }
    }

    pub(crate) fn register_unknown_challenge(
        &self,
        draft: HostKeyChallengeDraft,
        public_key_base64: &str,
        request_id: Option<&str>,
        trust_store_generation: &TrustStoreGeneration,
        now: SystemTime,
    ) -> Result<RegisteredHostKeyChallenge, HostKeyChallengeServiceError> {
        self.with_registry(|registry| {
            registry.register_or_reuse_unknown_challenge(
                draft,
                public_key_base64,
                request_id,
                trust_store_generation,
                now,
            )
        })
    }

    pub(crate) fn accept(
        &self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<AcceptedHostKeyChallenge, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.accept(challenge_id, now))
    }

    pub(crate) fn reject(
        &self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<RejectedHostKeyChallenge, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.reject(challenge_id, now))
    }

    pub(crate) fn status(
        &self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<Option<PendingChallengeState>, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.state(challenge_id, now))
    }

    pub(crate) fn cleanup_expired(
        &self,
        now: SystemTime,
    ) -> Result<usize, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.cleanup_expired(now))
    }

    pub(crate) fn snapshot_pending(
        &self,
        challenge_id: &str,
        now: SystemTime,
    ) -> Result<PendingHostKeyChallengeSnapshot, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.snapshot_pending(challenge_id, now))
    }

    pub(crate) fn mark_persisted_if_pending(
        &self,
        snapshot: &PendingHostKeyChallengeSnapshot,
        now: SystemTime,
    ) -> Result<PersistedHostKeyChallenge, HostKeyChallengeServiceError> {
        self.with_registry(|registry| registry.mark_persisted_if_pending(snapshot, now))
    }

    fn with_registry<T>(
        &self,
        operation: impl FnOnce(&mut Registry) -> Result<T, ChallengeRegistryError>,
    ) -> Result<T, HostKeyChallengeServiceError> {
        let mut guard = self
            .registry
            .lock()
            .map_err(|_| HostKeyChallengeServiceError::Unavailable)?;
        operation(&mut guard).map_err(HostKeyChallengeServiceError::Registry)
    }

    #[cfg(test)]
    pub(crate) fn replace_registry(
        &self,
        replacement: Registry,
    ) -> Result<(), HostKeyChallengeServiceError> {
        let mut guard = self
            .registry
            .lock()
            .map_err(|_| HostKeyChallengeServiceError::Unavailable)?;
        *guard = replacement;
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn pending_count(&self) -> Result<usize, HostKeyChallengeServiceError> {
        self.registry
            .lock()
            .map(|registry| registry.pending_count())
            .map_err(|_| HostKeyChallengeServiceError::Unavailable)
    }
}

pub(crate) fn shared_host_key_challenge_service() -> &'static HostKeyChallengeService {
    SHARED_CHALLENGE_SERVICE.get_or_init(HostKeyChallengeService::default)
}
