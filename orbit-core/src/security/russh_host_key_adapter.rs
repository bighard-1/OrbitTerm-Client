use std::fmt;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use russh::keys::ssh_key::PublicKey;
use thiserror::Error;

use super::host_key::fingerprint_sha256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum RusshHostKeyAdapterError {
    #[error("server host key algorithm is invalid")]
    InvalidAlgorithm,
    #[error("server host public key could not be encoded")]
    EncodingFailed,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct PresentedHostKey {
    key_algorithm: String,
    public_key_base64: String,
    fingerprint_sha256: String,
}

impl fmt::Debug for PresentedHostKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PresentedHostKey")
            .field("key_algorithm", &self.key_algorithm)
            .field("public_key_base64", &"[REDACTED]")
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .finish()
    }
}

impl PresentedHostKey {
    pub(crate) fn key_algorithm(&self) -> &str {
        &self.key_algorithm
    }

    pub(crate) fn public_key_base64(&self) -> &str {
        &self.public_key_base64
    }

    pub(crate) fn fingerprint_sha256(&self) -> &str {
        &self.fingerprint_sha256
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct RusshHostKeyAdapter;

impl RusshHostKeyAdapter {
    pub(crate) fn adapt(
        &self,
        server_public_key: &PublicKey,
    ) -> Result<PresentedHostKey, RusshHostKeyAdapterError> {
        let key_algorithm = server_public_key.algorithm().as_str().trim().to_string();
        if key_algorithm.is_empty()
            || key_algorithm.chars().any(char::is_control)
            || key_algorithm.chars().any(char::is_whitespace)
        {
            return Err(RusshHostKeyAdapterError::InvalidAlgorithm);
        }

        let public_key_blob = server_public_key
            .to_bytes()
            .map_err(|_| RusshHostKeyAdapterError::EncodingFailed)?;
        Ok(PresentedHostKey {
            key_algorithm,
            public_key_base64: STANDARD.encode(&public_key_blob),
            fingerprint_sha256: fingerprint_sha256(&public_key_blob),
        })
    }
}
