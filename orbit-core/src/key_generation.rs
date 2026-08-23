use russh::keys::{ssh_key::LineEnding, Algorithm, PrivateKey};
use serde::Serialize;

use crate::OrbitCoreError;

#[derive(Debug, Serialize)]
pub(crate) struct GeneratedEd25519KeyPair {
    pub private_key: String,
    pub public_key: String,
    pub format: &'static str,
}

/// Generates portable OpenSSH Ed25519 material in the shared security core.
///
/// Platform UIs must immediately move the returned private material into their
/// account-scoped Keychain/Keystore vault and must never log or diagnose it.
pub(crate) fn generate_ed25519_key_pair(
    raw_comment: &str,
) -> Result<GeneratedEd25519KeyPair, OrbitCoreError> {
    let comment: String = raw_comment
        .trim()
        .chars()
        .filter(|character| !character.is_control())
        .take(80)
        .collect();
    let comment = if comment.is_empty() {
        "orbitterm-mobile".to_string()
    } else {
        comment
    };

    let mut key = PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519)
        .map_err(|_| OrbitCoreError::Internal("ed25519_generation_failed".to_string()))?;
    key.set_comment(comment);
    let private_key = key
        .to_openssh(LineEnding::LF)
        .map_err(|_| OrbitCoreError::Internal("openssh_private_encoding_failed".to_string()))?
        .to_string();
    let public_key = key
        .public_key()
        .to_openssh()
        .map_err(|_| OrbitCoreError::Internal("openssh_public_encoding_failed".to_string()))?;

    Ok(GeneratedEd25519KeyPair {
        private_key,
        public_key,
        format: "OpenSSH Ed25519",
    })
}

pub(crate) fn derive_public_key(
    private_key: &str,
    passphrase: &str,
) -> Result<String, OrbitCoreError> {
    crate::ssh_session::decode_supported_private_key(private_key, passphrase)?
        .public_key()
        .to_openssh()
        .map_err(|_| OrbitCoreError::Internal("openssh_public_encoding_failed".to_string()))
}

#[cfg(test)]
mod tests {
    use super::{derive_public_key, generate_ed25519_key_pair};
    use russh::keys::{Algorithm, PrivateKey, PublicKey};

    #[test]
    fn generated_pair_round_trips_through_live_ssh_decoders() {
        let generated = generate_ed25519_key_pair("mobile test").expect("generate key");
        let private_key = PrivateKey::from_openssh(&generated.private_key).expect("private key");
        let public_key = PublicKey::from_openssh(&generated.public_key).expect("public key");
        assert_eq!(private_key.algorithm(), Algorithm::Ed25519);
        assert_eq!(public_key.algorithm(), Algorithm::Ed25519);
        assert_eq!(
            private_key.public_key().to_bytes().unwrap(),
            public_key.to_bytes().unwrap()
        );
        assert_eq!(
            derive_public_key(&generated.private_key, "").unwrap(),
            generated.public_key
        );
    }

    #[test]
    fn generated_comment_is_sanitized_and_bounded() {
        let generated = generate_ed25519_key_pair(&format!("mobile\n{}", "x".repeat(100)))
            .expect("generate key");
        let public_key = PublicKey::from_openssh(&generated.public_key).expect("public key");
        assert!(!public_key.comment().contains('\n'));
        assert!(public_key.comment().chars().count() <= 80);
    }
}
