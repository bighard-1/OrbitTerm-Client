use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine;
use rand::{rngs::OsRng, RngCore};
use russh::client;
use thiserror::Error;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const HEADER_MAGIC: &[u8; 4] = b"OTC1";

uniffi::setup_scaffolding!();

#[derive(Debug, Error, uniffi::Error)]
pub enum OrbitCoreError {
    #[error("参数不合法")]
    InvalidInput,
    #[error("加密失败")]
    EncryptFailed,
    #[error("解密失败")]
    DecryptFailed,
    #[error("SSH 连接失败: {0}")]
    SshFailed(String),
    #[error("内部错误: {0}")]
    Internal(String),
}

impl From<russh::Error> for OrbitCoreError {
    fn from(value: russh::Error) -> Self {
        OrbitCoreError::SshFailed(value.to_string())
    }
}

#[uniffi::export]
pub fn encrypt_config(master_password: String, plaintext: Vec<u8>) -> Result<Vec<u8>, OrbitCoreError> {
    if master_password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);

    let key = derive_key(master_password.as_bytes(), &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| OrbitCoreError::EncryptFailed)?;

    // 使用随机 nonce 执行 AEAD 加密，自动附带完整性校验 Tag。
    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext.as_slice())
        .map_err(|_| OrbitCoreError::EncryptFailed)?;

    // 数据格式: magic(4) + salt_len(1) + nonce_len(1) + salt + nonce + ciphertext。
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
pub fn decrypt_config(master_password: String, encrypted_blob: Vec<u8>) -> Result<Vec<u8>, OrbitCoreError> {
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

#[derive(Clone, Default)]
struct OrbitSshClientHandler;

impl client::Handler for OrbitSshClientHandler {
    type Error = OrbitCoreError;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // 首版实现默认接受服务端公钥。
        // 生产环境应引入 known_hosts / 指纹校验策略，防止 MITM。
        Ok(true)
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn test_ssh_connection(
    ip: String,
    username: String,
    password: String,
) -> Result<String, OrbitCoreError> {
    if ip.trim().is_empty() || username.trim().is_empty() || password.is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let config = Arc::new(client::Config::default());
    let addr = if ip.contains(':') {
        ip
    } else {
        format!("{}:22", ip)
    };

    let mut ssh_session = client::connect(config, addr, OrbitSshClientHandler)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    let auth_result = ssh_session
        .authenticate_password(username, password)
        .await
        .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

    if auth_result.success() {
        Ok("SSH connection success".to_string())
    } else {
        Err(OrbitCoreError::SshFailed(
            "SSH authentication failed".to_string(),
        ))
    }
}

fn derive_key(master_password: &[u8], salt: &[u8]) -> Result<[u8; 32], OrbitCoreError> {
    let params = Params::new(64 * 1024, 3, 2, Some(32)).map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(master_password, salt, &mut key)
        .map_err(|_| OrbitCoreError::Internal("Argon2 key derivation failed".to_string()))?;
    Ok(key)
}

fn c_ptr_to_string(ptr: *const c_char) -> Result<String, OrbitCoreError> {
    if ptr.is_null() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let raw = unsafe { CStr::from_ptr(ptr) };
    raw.to_str()
        .map(|s| s.to_string())
        .map_err(|_| OrbitCoreError::InvalidInput)
}

fn to_c_string_ptr(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("internal string error").expect("fallback CString must be valid"))
        .into_raw()
}

#[no_mangle]
pub extern "C" fn orbit_encrypt_config(
    master_password: *const c_char,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
) -> *mut c_char {
    let password = match c_ptr_to_string(master_password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    if plaintext_ptr.is_null() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }

    let plaintext = unsafe { std::slice::from_raw_parts(plaintext_ptr, plaintext_len) };
    match encrypt_config(password, plaintext.to_vec()) {
        Ok(bytes) => {
            let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
            to_c_string_ptr(format!("OK:{}", b64))
        }
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_decrypt_config(
    master_password: *const c_char,
    encrypted_base64: *const c_char,
) -> *mut c_char {
    let password = match c_ptr_to_string(master_password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let encrypted_b64 = match c_ptr_to_string(encrypted_base64) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return to_c_string_ptr("ERR:Base64 解码失败".to_string()),
    };

    match decrypt_config(password, encrypted) {
        Ok(bytes) => {
            let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
            to_c_string_ptr(format!("OK:{}", b64))
        }
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_test_ssh_connection(
    ip: *const c_char,
    username: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let ip = match c_ptr_to_string(ip) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let username = match c_ptr_to_string(username) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let password = match c_ptr_to_string(password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:runtime init failed: {}", e)),
    };

    let result = rt.block_on(test_ssh_connection(ip, username, password));
    match result {
        Ok(msg) => to_c_string_ptr(format!("OK:{}", msg)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}
