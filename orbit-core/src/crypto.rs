use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use rand::{rngs::OsRng, RngCore};
use sha2::Sha256;

use crate::OrbitCoreError;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const V1_HEADER_MAGIC: &[u8; 4] = b"OTC1";
const V2_HEADER_MAGIC: &[u8; 4] = b"OTC2";
const CONFIG_ROOT_KEY_LEN: usize = 32;
const V2_RECORD_INFO: &[u8] = b"OrbitTerm.Config.Record.V2";

#[uniffi::export]
pub fn encrypt_config(
    master_password: String,
    plaintext: Vec<u8>,
) -> Result<Vec<u8>, OrbitCoreError> {
    if master_password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);

    let key = derive_key(master_password.as_bytes(), &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| OrbitCoreError::EncryptFailed)?;

    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext.as_slice())
        .map_err(|_| OrbitCoreError::EncryptFailed)?;

    let mut out = Vec::with_capacity(4 + 1 + 1 + SALT_LEN + NONCE_LEN + encrypted.len());
    out.extend_from_slice(V1_HEADER_MAGIC);
    out.push(SALT_LEN as u8);
    out.push(NONCE_LEN as u8);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&encrypted);

    Ok(out)
}

#[uniffi::export]
pub fn decrypt_config(
    master_password: String,
    encrypted_blob: Vec<u8>,
) -> Result<Vec<u8>, OrbitCoreError> {
    if master_password.is_empty() || encrypted_blob.len() < 4 + 1 + 1 + SALT_LEN + NONCE_LEN {
        return Err(OrbitCoreError::InvalidInput);
    }

    if &encrypted_blob[0..4] != V1_HEADER_MAGIC {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt_len = encrypted_blob[4] as usize;
    let nonce_len = encrypted_blob[5] as usize;

    if salt_len == 0 || nonce_len != NONCE_LEN {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt_start = 6;
    let nonce_start = salt_start + salt_len;
    let cipher_start = nonce_start + nonce_len;

    if encrypted_blob.len() <= cipher_start {
        return Err(OrbitCoreError::DecryptFailed);
    }

    let salt = &encrypted_blob[salt_start..nonce_start];
    let nonce = &encrypted_blob[nonce_start..cipher_start];
    let ciphertext = &encrypted_blob[cipher_start..];

    let key = derive_key(master_password.as_bytes(), salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| OrbitCoreError::DecryptFailed)?;

    let plaintext = cipher
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .map_err(|_| OrbitCoreError::DecryptFailed)?;

    Ok(plaintext)
}

/// Derives the account-scoped V2 root key once per unlocked account session.
/// The scope is public and stable across Apple and Android clients; it is only
/// used as a domain-separated Argon2 salt and is never transmitted in a blob.
pub fn derive_config_root_key_v2(
    master_password: &[u8],
    account_scope: &[u8],
) -> Result<[u8; CONFIG_ROOT_KEY_LEN], OrbitCoreError> {
    if master_password.is_empty() || account_scope.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut scope_salt = Sha256::new();
    use sha2::Digest;
    scope_salt.update(b"OrbitTerm.Config.Root.V2\0");
    scope_salt.update(account_scope);
    let salt = scope_salt.finalize();
    derive_key(master_password, &salt)
}

/// Encrypts one V2 record with a pre-derived account root key. Each ciphertext
/// uses an independent random record salt and nonce, so records do not reuse
/// an AES key even though Argon2 is intentionally paid only once per session.
pub fn encrypt_config_v2(root_key: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, OrbitCoreError> {
    if root_key.len() != CONFIG_ROOT_KEY_LEN {
        return Err(OrbitCoreError::InvalidInput);
    }
    let mut record_salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut record_salt);
    OsRng.fill_bytes(&mut nonce);
    let record_key = derive_v2_record_key(root_key, &record_salt)?;
    let cipher =
        Aes256Gcm::new_from_slice(&record_key).map_err(|_| OrbitCoreError::EncryptFailed)?;
    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| OrbitCoreError::EncryptFailed)?;

    let mut out = Vec::with_capacity(4 + 1 + 1 + SALT_LEN + NONCE_LEN + encrypted.len());
    out.extend_from_slice(V2_HEADER_MAGIC);
    out.push(SALT_LEN as u8);
    out.push(NONCE_LEN as u8);
    out.extend_from_slice(&record_salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&encrypted);
    Ok(out)
}

/// Decrypts a V2 record only. Callers select this function from the explicit
/// OTC2 format marker; V1 fallback is deliberately not based on an error.
pub fn decrypt_config_v2(
    root_key: &[u8],
    encrypted_blob: &[u8],
) -> Result<Vec<u8>, OrbitCoreError> {
    if encrypted_blob.len() < 4 + 1 + 1 + SALT_LEN + NONCE_LEN
        || &encrypted_blob[..4] != V2_HEADER_MAGIC
    {
        return Err(OrbitCoreError::DecryptFailed);
    }
    let salt_len = encrypted_blob[4] as usize;
    let nonce_len = encrypted_blob[5] as usize;
    if salt_len != SALT_LEN || nonce_len != NONCE_LEN {
        return Err(OrbitCoreError::DecryptFailed);
    }
    let salt_start = 6;
    let nonce_start = salt_start + salt_len;
    let cipher_start = nonce_start + nonce_len;
    if encrypted_blob.len() <= cipher_start {
        return Err(OrbitCoreError::DecryptFailed);
    }
    let record_key = derive_v2_record_key(root_key, &encrypted_blob[salt_start..nonce_start])?;
    let cipher =
        Aes256Gcm::new_from_slice(&record_key).map_err(|_| OrbitCoreError::DecryptFailed)?;
    cipher
        .decrypt(
            Nonce::from_slice(&encrypted_blob[nonce_start..cipher_start]),
            &encrypted_blob[cipher_start..],
        )
        .map_err(|_| OrbitCoreError::DecryptFailed)
}

pub fn is_config_v2(encrypted_blob: &[u8]) -> bool {
    encrypted_blob.starts_with(V2_HEADER_MAGIC)
}

fn derive_v2_record_key(
    root_key: &[u8],
    record_salt: &[u8],
) -> Result<[u8; CONFIG_ROOT_KEY_LEN], OrbitCoreError> {
    if root_key.len() != CONFIG_ROOT_KEY_LEN {
        return Err(OrbitCoreError::InvalidInput);
    }
    if record_salt.len() != SALT_LEN {
        return Err(OrbitCoreError::DecryptFailed);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(record_salt), root_key);
    let mut key = [0u8; CONFIG_ROOT_KEY_LEN];
    hkdf.expand(V2_RECORD_INFO, &mut key)
        .map_err(|_| OrbitCoreError::Internal("V2 record key derivation failed".to_string()))?;
    Ok(key)
}

fn derive_key(master_password: &[u8], salt: &[u8]) -> Result<[u8; 32], OrbitCoreError> {
    let params = Params::new(64 * 1024, 3, 2, Some(32))
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(master_password, salt, &mut key)
        .map_err(|_| OrbitCoreError::Internal("Argon2 key derivation failed".to_string()))?;
    Ok(key)
}

pub(crate) fn derive_key_strong(
    master_password: &[u8],
    salt: &[u8],
) -> Result<[u8; 32], OrbitCoreError> {
    let params = Params::new(64 * 1024, 3, 4, Some(32))
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(master_password, salt, &mut key)
        .map_err(|_| OrbitCoreError::Internal("Argon2 key derivation failed".to_string()))?;
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_remains_readable() {
        let blob = encrypt_config("correct horse".to_string(), b"legacy".to_vec()).unwrap();
        assert_eq!(
            decrypt_config("correct horse".to_string(), blob).unwrap(),
            b"legacy"
        );
    }

    #[test]
    fn v2_round_trip_and_randomizes_records() {
        let root = derive_config_root_key_v2(b"correct horse", b"account-scope").unwrap();
        let first = encrypt_config_v2(&root, b"payload").unwrap();
        let second = encrypt_config_v2(&root, b"payload").unwrap();
        assert!(is_config_v2(&first));
        assert_ne!(first, second);
        assert_eq!(decrypt_config_v2(&root, &first).unwrap(), b"payload");
    }

    #[test]
    fn v2_rejects_wrong_scope_and_malformed_header() {
        let root = derive_config_root_key_v2(b"correct horse", b"account-a").unwrap();
        let other = derive_config_root_key_v2(b"correct horse", b"account-b").unwrap();
        let blob = encrypt_config_v2(&root, b"payload").unwrap();
        assert!(decrypt_config_v2(&other, &blob).is_err());
        let mut malformed = blob.clone();
        malformed[4] = 0;
        assert!(decrypt_config_v2(&root, &malformed).is_err());
        assert!(decrypt_config_v2(&root, b"OTC1bad").is_err());
    }
}
