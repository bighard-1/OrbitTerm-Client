use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::{rngs::OsRng, RngCore};

use crate::OrbitCoreError;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const HEADER_MAGIC: &[u8; 4] = b"OTC1";

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
    out.extend_from_slice(HEADER_MAGIC);
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

    if &encrypted_blob[0..4] != HEADER_MAGIC {
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

pub(crate) fn derive_key_strong(master_password: &[u8], salt: &[u8]) -> Result<[u8; 32], OrbitCoreError> {
    let params = Params::new(64 * 1024, 3, 4, Some(32))
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(master_password, salt, &mut key)
        .map_err(|_| OrbitCoreError::Internal("Argon2 key derivation failed".to_string()))?;
    Ok(key)
}
