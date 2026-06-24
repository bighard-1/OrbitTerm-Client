use thiserror::Error;

use super::host_key_challenge_registry::RegisteredHostKeyChallenge;
use super::host_key_challenge_service::HostKeyChallengeServiceError;
use super::host_key_verifier::{HostKeyBlock, HostKeyVerificationError};
use super::russh_host_key_adapter::RusshHostKeyAdapterError;
use super::verified_host_key_slot::VerifiedHostKeySlotError;

/// Structured failures that occur before SSH user authentication begins.
#[derive(Debug, Error)]
pub(crate) enum ConnectPreAuthError {
    #[error("host key requires an explicit trust decision")]
    HostKeyChallenge(Box<RegisteredHostKeyChallenge>),
    #[error("host key was blocked by the trust policy")]
    HostKeyBlocked(Box<HostKeyBlock>),
    #[error("host key verification failed")]
    HostKeyVerificationFailed(#[source] HostKeyVerificationError),
    #[error("host key challenge registry failed")]
    ChallengeServiceFailed(#[source] HostKeyChallengeServiceError),
    #[error("server host key adaptation failed")]
    AdapterFailed(#[source] RusshHostKeyAdapterError),
    #[error("verified host key handoff failed")]
    VerifiedSlotFailed(#[source] VerifiedHostKeySlotError),
    #[error("SSH protocol failed before authentication")]
    Protocol(#[source] russh::Error),
}

impl From<russh::Error> for ConnectPreAuthError {
    fn from(error: russh::Error) -> Self {
        Self::Protocol(error)
    }
}
