use std::fmt;
use std::sync::{Arc, Mutex};

use russh::keys::ssh_key::PublicKey;
use thiserror::Error;

use super::host_key::{decode_public_key_base64, fingerprint_sha256_from_base64};
use super::host_key_verifier::VerifiedHostKey;
use super::known_hosts_store::{canonical_public_key, normalize_algorithm};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum VerifiedHostKeySlotError {
    #[error("verified host key slot is unavailable")]
    Unavailable,
    #[error("verified host key slot is empty")]
    MissingVerification,
    #[error("verified host key slot contains a different verification result")]
    ConflictingVerification,
    #[error("verified host key recheck material is invalid")]
    InvalidRecheckMaterial,
    #[error("verified host key recheck material does not match its verified summary")]
    RecheckBindingMismatch,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct VerifiedHostKeyForRecheck {
    verified: VerifiedHostKey,
    public_key_base64: String,
}

impl fmt::Debug for VerifiedHostKeyForRecheck {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifiedHostKeyForRecheck")
            .field("verified", &self.verified)
            .field("public_key_base64", &"[REDACTED]")
            .finish()
    }
}

impl VerifiedHostKeyForRecheck {
    pub(crate) fn new(
        verified: VerifiedHostKey,
        public_key_base64: &str,
    ) -> Result<Self, VerifiedHostKeySlotError> {
        let public_key_base64 = canonical_public_key(public_key_base64)
            .map_err(|_| VerifiedHostKeySlotError::InvalidRecheckMaterial)?;
        let algorithm = normalize_algorithm(&verified.key_algorithm)
            .map_err(|_| VerifiedHostKeySlotError::InvalidRecheckMaterial)?;
        let public_key_blob = decode_public_key_base64(&public_key_base64)
            .map_err(|_| VerifiedHostKeySlotError::InvalidRecheckMaterial)?;
        let embedded_algorithm = PublicKey::from_bytes(&public_key_blob)
            .map_err(|_| VerifiedHostKeySlotError::InvalidRecheckMaterial)?
            .algorithm()
            .as_str()
            .to_ascii_lowercase();
        let fingerprint = fingerprint_sha256_from_base64(&public_key_base64)
            .map_err(|_| VerifiedHostKeySlotError::InvalidRecheckMaterial)?;
        if algorithm != verified.key_algorithm
            || algorithm != embedded_algorithm
            || fingerprint != verified.fingerprint_sha256
        {
            return Err(VerifiedHostKeySlotError::RecheckBindingMismatch);
        }
        Ok(Self {
            verified,
            public_key_base64,
        })
    }

    pub(crate) fn verified(&self) -> &VerifiedHostKey {
        &self.verified
    }

    pub(crate) fn public_key_base64(&self) -> &str {
        &self.public_key_base64
    }

    pub(crate) fn validate_binding(&self) -> Result<(), VerifiedHostKeySlotError> {
        Self::new(self.verified.clone(), &self.public_key_base64).map(|_| ())
    }
}

/// Per-connection handoff for the verified result produced during KEX.
#[derive(Clone, Default)]
pub(crate) struct VerifiedHostKeySlot {
    value: Arc<Mutex<Option<VerifiedHostKeyForRecheck>>>,
}

impl fmt::Debug for VerifiedHostKeySlot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let occupied = self
            .value
            .lock()
            .map(|value| value.is_some())
            .unwrap_or(false);
        formatter
            .debug_struct("VerifiedHostKeySlot")
            .field("occupied", &occupied)
            .finish()
    }
}

impl VerifiedHostKeySlot {
    pub(crate) fn record(
        &self,
        verified: VerifiedHostKey,
        public_key_base64: &str,
    ) -> Result<(), VerifiedHostKeySlotError> {
        let recheck = VerifiedHostKeyForRecheck::new(verified, public_key_base64)?;
        let mut value = self
            .value
            .lock()
            .map_err(|_| VerifiedHostKeySlotError::Unavailable)?;
        match value.as_ref() {
            Some(existing) if existing != &recheck => {
                Err(VerifiedHostKeySlotError::ConflictingVerification)
            }
            Some(_) => Ok(()),
            None => {
                *value = Some(recheck);
                Ok(())
            }
        }
    }

    pub(crate) fn require_verified(&self) -> Result<VerifiedHostKey, VerifiedHostKeySlotError> {
        self.require_for_recheck()
            .map(|value| value.verified().clone())
    }

    pub(crate) fn require_for_recheck(
        &self,
    ) -> Result<VerifiedHostKeyForRecheck, VerifiedHostKeySlotError> {
        self.value
            .lock()
            .map_err(|_| VerifiedHostKeySlotError::Unavailable)?
            .clone()
            .ok_or(VerifiedHostKeySlotError::MissingVerification)
    }

    #[cfg(test)]
    pub(crate) fn inject_unchecked_for_tests(
        &self,
        verified: VerifiedHostKey,
        public_key_base64: String,
    ) -> Result<(), VerifiedHostKeySlotError> {
        let mut value = self
            .value
            .lock()
            .map_err(|_| VerifiedHostKeySlotError::Unavailable)?;
        *value = Some(VerifiedHostKeyForRecheck {
            verified,
            public_key_base64,
        });
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> Result<bool, VerifiedHostKeySlotError> {
        self.value
            .lock()
            .map(|value| value.is_none())
            .map_err(|_| VerifiedHostKeySlotError::Unavailable)
    }
}
