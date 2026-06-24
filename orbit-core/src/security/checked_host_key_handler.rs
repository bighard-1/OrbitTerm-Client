use std::time::SystemTime;

use russh::client;
use russh::keys::ssh_key::PublicKey;

use super::connect_pre_auth_error::ConnectPreAuthError;
use super::host_key_verification_context::HostKeyVerificationContext;
use super::host_key_verifier::{HostKeyVerificationDecision, HostKeyVerificationInput};
use super::russh_host_key_adapter::RusshHostKeyAdapter;

/// Checked SSH handler for public physical connection paths.
///
/// It cannot be constructed without an explicit verification context, and it
/// proceeds only after the trust store returns a verified decision.
#[derive(Clone, Debug)]
pub(crate) struct CheckedHostKeyHandler {
    context: HostKeyVerificationContext,
    adapter: RusshHostKeyAdapter,
}

impl CheckedHostKeyHandler {
    pub(crate) fn new(context: HostKeyVerificationContext) -> Self {
        Self {
            context,
            adapter: RusshHostKeyAdapter,
        }
    }

    pub(crate) fn context(&self) -> &HostKeyVerificationContext {
        &self.context
    }

    pub(crate) fn verify_presented_host_key(
        &mut self,
        server_public_key: &PublicKey,
        now: SystemTime,
    ) -> Result<bool, ConnectPreAuthError> {
        let presented = self
            .adapter
            .adapt(server_public_key)
            .map_err(ConnectPreAuthError::AdapterFailed)?;
        let input = HostKeyVerificationInput {
            host_identity: self.context.host_identity().clone(),
            key_algorithm: presented.key_algorithm().to_string(),
            public_key_base64: presented.public_key_base64().to_string(),
        };

        match self
            .context
            .verifier()
            .verify(self.context.trust_store(), &input)
        {
            HostKeyVerificationDecision::Proceed(verified) => {
                self.context
                    .verified_slot()
                    .record(verified, presented.public_key_base64())
                    .map_err(ConnectPreAuthError::VerifiedSlotFailed)?;
                Ok(true)
            }
            HostKeyVerificationDecision::Challenge(draft) => {
                let registered = self
                    .context
                    .challenge_service()
                    .register_unknown_challenge(
                        draft,
                        presented.public_key_base64(),
                        self.context.request_id(),
                        self.context.trust_store_generation(),
                        now,
                    )
                    .map_err(ConnectPreAuthError::ChallengeServiceFailed)?;
                Err(ConnectPreAuthError::HostKeyChallenge(Box::new(registered)))
            }
            HostKeyVerificationDecision::Block(block) => {
                Err(ConnectPreAuthError::HostKeyBlocked(Box::new(block)))
            }
            HostKeyVerificationDecision::Fail(error) => {
                Err(ConnectPreAuthError::HostKeyVerificationFailed(error))
            }
        }
    }
}

impl client::Handler for CheckedHostKeyHandler {
    type Error = ConnectPreAuthError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        self.verify_presented_host_key(server_public_key, SystemTime::now())
    }
}
