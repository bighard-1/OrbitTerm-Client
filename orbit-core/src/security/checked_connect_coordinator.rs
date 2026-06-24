use thiserror::Error;

use super::host_key::HostIdentity;
use super::host_key_challenge_service::HostKeyChallengeService;
use super::host_key_verification_context::{
    HostKeyVerificationContext, HostKeyVerificationContextError,
};
use super::host_key_verifier::{
    HostKeyBlock, HostKeyVerificationDecision, HostKeyVerificationError, HostKeyVerificationInput,
    SessionSecurityGeneration, VerifiedHostKey,
};
use super::known_hosts_store::{KnownHostsStore, KnownHostsStoreError};
use super::trust_store_generation::TrustStoreGeneration;
use super::verified_host_key_slot::{VerifiedHostKeyForRecheck, VerifiedHostKeySlotError};

pub(crate) trait KnownHostsStoreReloader {
    fn reload(&mut self) -> Result<KnownHostsStore, KnownHostsStoreError>;
}

#[derive(Debug, Clone)]
pub(crate) struct CheckedConnectStoreReload {
    store: KnownHostsStore,
    generation: TrustStoreGeneration,
}

impl CheckedConnectStoreReload {
    fn new(store: KnownHostsStore) -> Self {
        let generation = TrustStoreGeneration::from_store(&store);
        Self { store, generation }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VerifiedSlotMismatchReason {
    HostIdentity,
    KeyMaterial,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub(crate) enum CheckedConnectPreAuthError {
    #[error("verified host key slot is empty")]
    VerifiedSlotEmpty,
    #[error("verified host key slot is unavailable")]
    VerifiedSlotUnavailable,
    #[error("verified host key slot does not match the checked connection context")]
    VerifiedSlotMismatch { reason: VerifiedSlotMismatchReason },
    #[error("known_hosts store could not be reloaded")]
    StoreReloadFailed(#[source] KnownHostsStoreError),
    #[error("known_hosts changed and the previously verified key is no longer trusted")]
    StoreGenerationChangedUnknown,
    #[error("host key verification failed during the authentication gate")]
    HostKeyVerificationFailed(#[source] HostKeyVerificationError),
    #[error("checked connection context could not be created")]
    ContextCreationFailed(#[source] HostKeyVerificationContextError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CheckedAuthenticationApproval {
    verified_host_key: VerifiedHostKey,
    trust_store_generation: TrustStoreGeneration,
}

impl CheckedAuthenticationApproval {
    pub(crate) fn new(
        verified_host_key: VerifiedHostKey,
        trust_store_generation: TrustStoreGeneration,
    ) -> Self {
        Self {
            verified_host_key,
            trust_store_generation,
        }
    }

    pub(crate) fn verified_host_key(&self) -> &VerifiedHostKey {
        &self.verified_host_key
    }

    pub(crate) fn trust_store_generation(&self) -> &TrustStoreGeneration {
        &self.trust_store_generation
    }

    pub(crate) fn session_security_generation(&self) -> SessionSecurityGeneration {
        SessionSecurityGeneration::from_verified(
            &self.verified_host_key,
            self.trust_store_generation.clone(),
        )
    }
}

#[derive(Debug)]
pub(crate) enum CheckedPreAuthDecision {
    AllowAuthentication(CheckedAuthenticationApproval),
    Block(Box<HostKeyBlock>),
    Fail(CheckedConnectPreAuthError),
}

pub(crate) struct CheckedConnectCoordinator<R> {
    context: HostKeyVerificationContext,
    reloader: R,
}

impl<R> std::fmt::Debug for CheckedConnectCoordinator<R> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CheckedConnectCoordinator")
            .field("context", &self.context)
            .finish_non_exhaustive()
    }
}

impl<R: KnownHostsStoreReloader> CheckedConnectCoordinator<R> {
    pub(crate) fn new(
        host_identity: HostIdentity,
        request_id: Option<String>,
        challenge_service: HostKeyChallengeService,
        mut reloader: R,
    ) -> Result<Self, CheckedConnectPreAuthError> {
        let initial = reload_store(&mut reloader)?;
        let context = HostKeyVerificationContext::new(
            host_identity,
            request_id,
            initial.store,
            challenge_service,
        )
        .map_err(CheckedConnectPreAuthError::ContextCreationFailed)?;
        debug_assert_eq!(
            context.trust_store_generation(),
            &initial.generation,
            "context must derive generation from the loaded store"
        );
        Ok(Self { context, reloader })
    }

    pub(crate) fn verification_context(&self) -> HostKeyVerificationContext {
        self.context.clone()
    }

    pub(crate) fn pre_authentication_check(&mut self) -> CheckedPreAuthDecision {
        let recheck = match self.context.verified_slot().require_for_recheck() {
            Ok(value) => value,
            Err(VerifiedHostKeySlotError::MissingVerification) => {
                return CheckedPreAuthDecision::Fail(CheckedConnectPreAuthError::VerifiedSlotEmpty);
            }
            Err(VerifiedHostKeySlotError::Unavailable) => {
                return CheckedPreAuthDecision::Fail(
                    CheckedConnectPreAuthError::VerifiedSlotUnavailable,
                );
            }
            Err(_) => {
                return CheckedPreAuthDecision::Fail(
                    CheckedConnectPreAuthError::VerifiedSlotMismatch {
                        reason: VerifiedSlotMismatchReason::KeyMaterial,
                    },
                );
            }
        };
        if recheck.verified().host_identity != *self.context.host_identity() {
            return CheckedPreAuthDecision::Fail(
                CheckedConnectPreAuthError::VerifiedSlotMismatch {
                    reason: VerifiedSlotMismatchReason::HostIdentity,
                },
            );
        }
        if recheck.validate_binding().is_err() {
            return CheckedPreAuthDecision::Fail(
                CheckedConnectPreAuthError::VerifiedSlotMismatch {
                    reason: VerifiedSlotMismatchReason::KeyMaterial,
                },
            );
        }

        let current = match reload_store(&mut self.reloader) {
            Ok(value) => value,
            Err(error) => return CheckedPreAuthDecision::Fail(error),
        };
        if &current.generation == self.context.trust_store_generation() {
            return allow_authentication(recheck, current.generation);
        }

        let input = HostKeyVerificationInput {
            host_identity: recheck.verified().host_identity.clone(),
            key_algorithm: recheck.verified().key_algorithm.clone(),
            public_key_base64: recheck.public_key_base64().to_string(),
        };
        match self.context.verifier().verify(&current.store, &input) {
            HostKeyVerificationDecision::Proceed(verified) => {
                CheckedPreAuthDecision::AllowAuthentication(CheckedAuthenticationApproval::new(
                    verified,
                    current.generation,
                ))
            }
            HostKeyVerificationDecision::Challenge(_) => CheckedPreAuthDecision::Fail(
                CheckedConnectPreAuthError::StoreGenerationChangedUnknown,
            ),
            HostKeyVerificationDecision::Block(block) => {
                CheckedPreAuthDecision::Block(Box::new(block))
            }
            HostKeyVerificationDecision::Fail(error) => CheckedPreAuthDecision::Fail(
                CheckedConnectPreAuthError::HostKeyVerificationFailed(error),
            ),
        }
    }
}

fn reload_store<R: KnownHostsStoreReloader>(
    reloader: &mut R,
) -> Result<CheckedConnectStoreReload, CheckedConnectPreAuthError> {
    reloader
        .reload()
        .map(CheckedConnectStoreReload::new)
        .map_err(CheckedConnectPreAuthError::StoreReloadFailed)
}

fn allow_authentication(
    recheck: VerifiedHostKeyForRecheck,
    generation: TrustStoreGeneration,
) -> CheckedPreAuthDecision {
    CheckedPreAuthDecision::AllowAuthentication(CheckedAuthenticationApproval::new(
        recheck.verified().clone(),
        generation,
    ))
}
