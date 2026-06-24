use std::fmt;

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};

use super::known_hosts_store::KnownHostsStore;

const GENERATION_PREFIX: &str = "sha256:";

/// Opaque digest of canonical Known Hosts store contents.
///
/// It intentionally contains neither a file path nor key material and is used
/// only to detect trust-store changes between security-sensitive steps.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct TrustStoreGeneration(String);

impl TrustStoreGeneration {
    pub fn from_store(store: &KnownHostsStore) -> Self {
        Self::from_contents(store.to_text().as_bytes())
    }

    pub fn from_contents(contents: &[u8]) -> Self {
        let digest = Sha256::digest(contents);
        Self(format!(
            "{GENERATION_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(digest)
        ))
    }

    pub(crate) fn as_hint(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for TrustStoreGeneration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("TrustStoreGeneration")
            .field(&"[OPAQUE]")
            .finish()
    }
}
