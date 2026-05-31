use std::collections::HashMap;

use base64::Engine;
use jni::objects::{JByteArray, JObject, JString};
use jni::sys::{jlong, jstring};
use jni::JNIEnv;

use crate::portable::{parse_portable_config, portable_changed_fields, portable_merge};
use crate::{decrypt_config, encrypt_config, OrbitCoreError};

fn jstring_to_rust(env: &mut JNIEnv, value: JString) -> Result<String, OrbitCoreError> {
    env.get_string(&value)
        .map(|s| s.to_string_lossy().into_owned())
        .map_err(|_| OrbitCoreError::InvalidInput)
}

fn java_string(env: &mut JNIEnv, value: String) -> jstring {
    env.new_string(value)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitEncryptConfig(
    mut env: JNIEnv,
    _this: JObject,
    master_password: JString,
    plaintext: JByteArray,
    _plaintext_len: jlong,
) -> jstring {
    let password = match jstring_to_rust(&mut env, master_password) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let bytes = match env.convert_byte_array(plaintext) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:参数不合法".to_string()),
    };
    match encrypt_config(password, bytes) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDecryptConfig(
    mut env: JNIEnv,
    _this: JObject,
    master_password: JString,
    encrypted_base64: JString,
) -> jstring {
    let password = match jstring_to_rust(&mut env, master_password) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let encrypted_b64 = match jstring_to_rust(&mut env, encrypted_base64) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:Base64 解码失败".to_string()),
    };
    match decrypt_config(password, encrypted) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableValidate(
    mut env: JNIEnv,
    _this: JObject,
    portable_json: JString,
) -> jstring {
    let raw = match jstring_to_rust(&mut env, portable_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    match parse_portable_config(&raw).and_then(|portable| {
        serde_json::to_string(&portable)
            .map_err(|e| OrbitCoreError::Internal(format!("PortableServerConfig 编码失败: {e}")))
    }) {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableChangedFields(
    mut env: JNIEnv,
    _this: JObject,
    base_json: JString,
    newer_json: JString,
) -> jstring {
    let base_raw = match jstring_to_rust(&mut env, base_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let newer_raw = match jstring_to_rust(&mut env, newer_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let result = parse_portable_config(&base_raw).and_then(|base| {
        parse_portable_config(&newer_raw).and_then(|newer| {
            serde_json::to_string(&portable_changed_fields(&base, &newer))
                .map_err(|e| OrbitCoreError::Internal(format!("字段差异编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPortableMerge(
    mut env: JNIEnv,
    _this: JObject,
    remote_json: JString,
    local_json: JString,
    local_changed_fields_json: JString,
) -> jstring {
    let remote_raw = match jstring_to_rust(&mut env, remote_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let local_raw = match jstring_to_rust(&mut env, local_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let fields_raw = match jstring_to_rust(&mut env, local_changed_fields_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let result = parse_portable_config(&remote_raw).and_then(|remote| {
        parse_portable_config(&local_raw).and_then(|local| {
            let fields: Vec<String> =
                serde_json::from_str(&fields_raw).map_err(|_| OrbitCoreError::InvalidInput)?;
            serde_json::to_string(&portable_merge(remote, local, &fields))
                .map_err(|e| OrbitCoreError::Internal(format!("合并结果编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitVectorClockBump(
    mut env: JNIEnv,
    _this: JObject,
    vector_clock_json: JString,
    actor: JString,
) -> jstring {
    let raw = match jstring_to_rust(&mut env, vector_clock_json) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let actor = match jstring_to_rust(&mut env, actor) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{}", e)),
    };
    let clean_actor = actor.trim();
    if clean_actor.is_empty() {
        return java_string(&mut env, "ERR:参数不合法".to_string());
    }
    let mut map: HashMap<String, i64> = serde_json::from_str(&raw).unwrap_or_default();
    map.insert(
        clean_actor.to_string(),
        map.get(clean_actor).copied().unwrap_or(0) + 1,
    );
    match serde_json::to_string(&map) {
        Ok(payload) => java_string(&mut env, format!("OK:{}", payload)),
        Err(e) => java_string(&mut env, format!("ERR:{}", e)),
    }
}
