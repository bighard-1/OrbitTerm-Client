use std::os::raw::c_char;

use base64::Engine;

use crate::crypto::derive_key_strong;
use crate::{
    c_ptr_to_string, decrypt_config, decrypt_config_v2, derive_config_root_key_v2, encrypt_config,
    encrypt_config_v2, to_c_string_ptr,
};

#[no_mangle]
pub extern "C" fn orbit_argon2id_derive(
    password: *const c_char,
    salt_ptr: *const u8,
    salt_len: usize,
) -> *mut c_char {
    let password = match c_ptr_to_string(password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    if salt_ptr.is_null() || salt_len == 0 {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }

    let salt = unsafe { std::slice::from_raw_parts(salt_ptr, salt_len) };
    match derive_key_strong(password.as_bytes(), salt) {
        Ok(key) => {
            let payload = base64::engine::general_purpose::STANDARD.encode(key);
            to_c_string_ptr(format!("OK:{}", payload))
        }
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
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
pub extern "C" fn orbit_derive_config_root_key_v2(
    master_password: *const c_char,
    account_scope: *const c_char,
) -> *mut c_char {
    let password = match c_ptr_to_string(master_password) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let scope = match c_ptr_to_string(account_scope) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    match derive_config_root_key_v2(password.as_bytes(), scope.as_bytes()) {
        Ok(key) => to_c_string_ptr(format!(
            "OK:{}",
            base64::engine::general_purpose::STANDARD.encode(key)
        )),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_encrypt_config_v2(
    root_key_ptr: *const u8,
    root_key_len: usize,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
) -> *mut c_char {
    if root_key_ptr.is_null() || plaintext_ptr.is_null() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }
    let root_key = unsafe { std::slice::from_raw_parts(root_key_ptr, root_key_len) };
    let plaintext = unsafe { std::slice::from_raw_parts(plaintext_ptr, plaintext_len) };
    match encrypt_config_v2(root_key, plaintext) {
        Ok(bytes) => to_c_string_ptr(format!(
            "OK:{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        )),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_decrypt_config_v2(
    root_key_ptr: *const u8,
    root_key_len: usize,
    encrypted_base64: *const c_char,
) -> *mut c_char {
    if root_key_ptr.is_null() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }
    let encrypted_b64 = match c_ptr_to_string(encrypted_base64) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return to_c_string_ptr("ERR:Base64 解码失败".to_string()),
    };
    let root_key = unsafe { std::slice::from_raw_parts(root_key_ptr, root_key_len) };
    match decrypt_config_v2(root_key, &encrypted) {
        Ok(bytes) => to_c_string_ptr(format!(
            "OK:{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        )),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}
