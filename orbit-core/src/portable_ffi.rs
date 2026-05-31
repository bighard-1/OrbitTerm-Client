use std::collections::HashMap;
use std::os::raw::c_char;

use crate::portable::{parse_portable_config, portable_changed_fields, portable_merge};
use crate::{c_ptr_to_string, to_c_string_ptr, OrbitCoreError};

#[no_mangle]
pub extern "C" fn orbit_portable_validate(portable_json: *const c_char) -> *mut c_char {
    let raw = match c_ptr_to_string(portable_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    match parse_portable_config(&raw).and_then(|portable| {
        serde_json::to_string(&portable)
            .map_err(|e| OrbitCoreError::Internal(format!("PortableServerConfig 编码失败: {e}")))
    }) {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_portable_changed_fields(
    base_json: *const c_char,
    newer_json: *const c_char,
) -> *mut c_char {
    let base_raw = match c_ptr_to_string(base_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let newer_raw = match c_ptr_to_string(newer_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = parse_portable_config(&base_raw).and_then(|base| {
        parse_portable_config(&newer_raw).and_then(|newer| {
            serde_json::to_string(&portable_changed_fields(&base, &newer))
                .map_err(|e| OrbitCoreError::Internal(format!("字段差异编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_portable_merge(
    remote_json: *const c_char,
    local_json: *const c_char,
    local_changed_fields_json: *const c_char,
) -> *mut c_char {
    let remote_raw = match c_ptr_to_string(remote_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let local_raw = match c_ptr_to_string(local_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let fields_raw = match c_ptr_to_string(local_changed_fields_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let result = parse_portable_config(&remote_raw).and_then(|remote| {
        parse_portable_config(&local_raw).and_then(|local| {
            let fields: Vec<String> =
                serde_json::from_str(&fields_raw).map_err(|_| OrbitCoreError::InvalidInput)?;
            let merged = portable_merge(remote, local, &fields);
            serde_json::to_string(&merged)
                .map_err(|e| OrbitCoreError::Internal(format!("合并结果编码失败: {e}")))
        })
    });
    match result {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}

#[no_mangle]
pub extern "C" fn orbit_vector_clock_bump(
    vector_clock_json: *const c_char,
    actor: *const c_char,
) -> *mut c_char {
    let raw = match c_ptr_to_string(vector_clock_json) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };
    let actor = match c_ptr_to_string(actor) {
        Ok(v) => v,
        Err(e) => return to_c_string_ptr(format!("ERR:{}", e)),
    };

    let mut map: HashMap<String, i64> = serde_json::from_str(&raw).unwrap_or_default();
    let clean_actor = actor.trim();
    if clean_actor.is_empty() {
        return to_c_string_ptr("ERR:参数不合法".to_string());
    }
    let next = map.get(clean_actor).copied().unwrap_or(0) + 1;
    map.insert(clean_actor.to_string(), next);
    match serde_json::to_string(&map) {
        Ok(payload) => to_c_string_ptr(format!("OK:{}", payload)),
        Err(e) => to_c_string_ptr(format!("ERR:{}", e)),
    }
}
