use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex};

use base64::Engine;
use jni::objects::{GlobalRef, JByteArray, JObject, JString, JValue};
use jni::sys::{jboolean, jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};
use once_cell::sync::Lazy;
use serde_json::json;

use crate::portable::{parse_portable_config, portable_changed_fields, portable_merge};
use crate::security::checked_docker_ffi::{
    orbit_docker_action_checked_v1, orbit_docker_list_checked_v1, orbit_docker_logs_checked_v1,
    orbit_docker_stats_checked_v1,
};
use crate::security::checked_exec_ffi::orbit_exec_checked_v1;
use crate::security::checked_monitor_ffi::orbit_monitor_snapshot_checked_v1;
use crate::security::checked_port_forward_ffi::{
    orbit_local_tunnel_start_checked_v1, orbit_local_tunnel_stop_checked_v1,
};
use crate::security::checked_sftp_ffi::{
    install_sftp_progress_sink, orbit_sftp_cancel_checked_v1, orbit_sftp_chmod_checked_v1,
    orbit_sftp_create_file_checked_v1, orbit_sftp_download_checked_v1, orbit_sftp_list_checked_v1,
    orbit_sftp_mkdir_checked_v1, orbit_sftp_open_checked_v1, orbit_sftp_read_text_checked_v1,
    orbit_sftp_remove_checked_v1, orbit_sftp_rename_checked_v1, orbit_sftp_upload_checked_v1,
    orbit_sftp_write_text_checked_v1,
};
use crate::security::checked_ssh_connect_ffi::{
    orbit_ssh_connect_checked_v1, orbit_ssh_connect_checked_v2,
};
use crate::security::checked_terminal_ffi::orbit_terminal_open_checked_v1;
use crate::security::host_key_ffi_api::{
    orbit_hostkey_challenge_accept_and_persist_v1, orbit_hostkey_challenge_reject_v1,
};
use crate::{
    decrypt_config, decrypt_config_v2, derive_config_root_key_v2, encrypt_config,
    encrypt_config_v2, OrbitCoreError,
};

static TERMINAL_OUTPUT_RECEIVER: Lazy<Mutex<Option<(Arc<JavaVM>, GlobalRef)>>> =
    Lazy::new(|| Mutex::new(None));
static SFTP_PROGRESS_RECEIVER: Lazy<Mutex<Option<(Arc<JavaVM>, GlobalRef)>>> =
    Lazy::new(|| Mutex::new(None));

fn emit_sftp_progress_to_android(request_id: &str, transferred: u64, total: Option<u64>) {
    let Some((vm, receiver)) = SFTP_PROGRESS_RECEIVER
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().cloned())
    else {
        return;
    };
    let Ok(mut env) = vm.attach_current_thread_as_daemon() else {
        return;
    };
    let Ok(request) = env.new_string(request_id) else {
        return;
    };
    let request = JObject::from(request);
    let _ = env.call_method(
        receiver.as_obj(),
        "onSftpTransferProgress",
        "(Ljava/lang/String;JJ)V",
        &[
            JValue::Object(&request),
            JValue::Long(transferred.min(i64::MAX as u64) as jlong),
            JValue::Long(total.map_or(-1, |value| value.min(i64::MAX as u64) as jlong)),
        ],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
}

extern "C" fn emit_terminal_output_to_android(channel_id: u64, data: *const u8, len: usize) {
    if data.is_null() {
        return;
    }
    let Some((vm, receiver)) = TERMINAL_OUTPUT_RECEIVER
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().cloned())
    else {
        return;
    };
    let Ok(mut env) = vm.attach_current_thread_as_daemon() else {
        return;
    };
    // The core invokes this synchronously. Android performs a bounded,
    // non-blocking hand-off and may drop a newest chunk under sustained UI
    // backpressure; this callback must return without waiting for a consumer.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let Ok(byte_array) = env.byte_array_from_slice(bytes) else {
        return;
    };
    let byte_array_object = JObject::from(byte_array);
    let _ = env.call_method(
        receiver.as_obj(),
        "onTerminalData",
        "(J[B)V",
        &[
            JValue::Long(channel_id as jlong),
            JValue::Object(&byte_array_object),
        ],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
}

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

fn c_string(value: String) -> Result<CString, String> {
    CString::new(value).map_err(|_| "ERR:参数不合法".to_string())
}

fn valid_request_id(request_id: &str) -> bool {
    !request_id.is_empty()
        && request_id.len() <= 256
        && request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

fn terminal_command_response(
    kind: &str,
    terminal_channel_id: jlong,
    request_id: Option<&str>,
    result: Result<(), OrbitCoreError>,
) -> String {
    match result {
        Ok(()) => json!({
            "schema_version": 1,
            "request_id": request_id,
            "kind": kind,
            "data": {
                "terminal_channel_id": terminal_channel_id.to_string(),
                "security_generation": "host_key_verified",
            },
            "error": serde_json::Value::Null,
        })
        .to_string(),
        Err(error) => {
            let (code, retryable) = match error {
                OrbitCoreError::InvalidInput => ("invalid_terminal_request", false),
                OrbitCoreError::LegacyNetworkDisabled => ("legacy_network_disabled", false),
                // Checked terminal operations only reach this branch after their
                // verified-session gate. Do not expose transport text to Java.
                OrbitCoreError::SshFailed(_) => ("session_closed", false),
                OrbitCoreError::Internal(_) => ("ffi_internal_error", false),
                OrbitCoreError::EncryptFailed | OrbitCoreError::DecryptFailed => {
                    ("ffi_internal_error", false)
                }
                OrbitCoreError::SftpFailed(_) | OrbitCoreError::SftpTransferCancelled => {
                    ("native_operation_failed", false)
                }
            };
            json!({
                "schema_version": 1,
                "request_id": request_id,
                "kind": "error",
                "data": serde_json::Value::Null,
                "error": {
                    "code": code,
                    "message_key": "error.terminal.operation_failed",
                    "detail_code": serde_json::Value::Null,
                    "retryable": retryable,
                    "request_id": request_id,
                    "challenge_id": serde_json::Value::Null,
                },
            })
            .to_string()
        }
    }
}

fn ssh_disconnect_response(
    base_session_id: jlong,
    request_id: Option<&str>,
    result: Result<(), OrbitCoreError>,
) -> String {
    match result {
        Ok(()) => json!({
            "schema_version": 1,
            "request_id": request_id,
            "kind": "ssh_disconnect_completed",
            "data": { "base_session_id": base_session_id.to_string() },
            "error": serde_json::Value::Null,
        })
        .to_string(),
        Err(_) => json!({
            "schema_version": 1,
            "request_id": request_id,
            "kind": "error",
            "data": serde_json::Value::Null,
            "error": {
                "code": "ssh_disconnect_failed",
                "message_key": "error.ssh.disconnect_failed",
                "detail_code": serde_json::Value::Null,
                "retryable": false,
                "request_id": request_id,
                "challenge_id": serde_json::Value::Null,
            },
        })
        .to_string(),
    }
}

fn take_ffi_string(pointer: *mut c_char) -> String {
    if pointer.is_null() {
        return "ERR:ffi_response_null".to_string();
    }
    // The checked C ABI returns an owned string allocated by orbit-core. Copy it
    // before releasing the native allocation so JNI never leaks or borrows it.
    let result = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    crate::c_ffi::orbit_free_string(pointer);
    result
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitGenerateEd25519KeyPair(
    mut env: JNIEnv,
    _this: JObject,
    comment: JString,
) -> jstring {
    let result = match jstring_to_rust(&mut env, comment) {
        Ok(comment) => {
            match crate::key_generation::generate_ed25519_key_pair(&comment).and_then(|pair| {
                serde_json::to_string(&pair).map_err(|_| {
                    OrbitCoreError::Internal("key_pair_serialization_failed".to_string())
                })
            }) {
                Ok(payload) => format!("OK:{payload}"),
                Err(error) => format!("ERR:{error}"),
            }
        }
        Err(error) => format!("ERR:{error}"),
    };
    java_string(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitPublicKeyFromPrivate(
    mut env: JNIEnv,
    _this: JObject,
    private_key: JString,
    passphrase: JString,
) -> jstring {
    let result = (|| -> Result<String, OrbitCoreError> {
        let private_key = jstring_to_rust(&mut env, private_key)?;
        let passphrase = jstring_to_rust(&mut env, passphrase)?;
        crate::key_generation::derive_public_key(&private_key, &passphrase)
    })();
    java_string(
        &mut env,
        match result {
            Ok(public_key) => format!("OK:{public_key}"),
            Err(error) => format!("ERR:{error}"),
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitExecChecked(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    command: JString,
    timeout_seconds: jint,
    max_stdout_bytes: jint,
    max_stderr_bytes: jint,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 || timeout_seconds < 0 || max_stdout_bytes < 0 || max_stderr_bytes < 0 {
        return java_string(&mut env, "ERR:invalid_exec_request".to_string());
    }
    let result = (|| -> Result<String, String> {
        let command =
            c_string(jstring_to_rust(&mut env, command).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_exec_checked_v1(
            base_session_id as u64,
            command.as_ptr(),
            timeout_seconds as u32,
            max_stdout_bytes as u32,
            max_stderr_bytes as u32,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitStartCheckedLocalTunnel(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    bind_host: JString,
    bind_port: jint,
    destination_host: JString,
    destination_port: jint,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0
        || !(0..=u16::MAX as jint).contains(&bind_port)
        || !(1..=u16::MAX as jint).contains(&destination_port)
    {
        return java_string(&mut env, "ERR:invalid_local_tunnel_request".to_string());
    }
    let result = (|| -> Result<String, String> {
        let bind = c_string(jstring_to_rust(&mut env, bind_host).map_err(|e| format!("ERR:{e}"))?)?;
        let destination =
            c_string(jstring_to_rust(&mut env, destination_host).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_local_tunnel_start_checked_v1(
            base_session_id as u64,
            bind.as_ptr(),
            bind_port as u16,
            destination.as_ptr(),
            destination_port as u16,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitStopCheckedLocalTunnel(
    mut env: JNIEnv,
    _this: JObject,
    tunnel_id: jlong,
    request_id: JString,
) -> jstring {
    if tunnel_id <= 0 {
        return java_string(&mut env, "ERR:invalid_tunnel_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_local_tunnel_stop_checked_v1(
            tunnel_id as u64,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitInstallSftpProgressCallback(
    env: JNIEnv,
    _this: JObject,
    receiver: JObject,
) -> jboolean {
    let Ok(vm) = env.get_java_vm() else { return 0 };
    let Ok(receiver) = env.new_global_ref(receiver) else {
        return 0;
    };
    *SFTP_PROGRESS_RECEIVER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((Arc::new(vm), receiver));
    install_sftp_progress_sink(Arc::new(emit_sftp_progress_to_android));
    1
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitListCheckedDocker(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_base_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_docker_list_checked_v1(
            base_session_id as u64,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitStatsCheckedDocker(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_base_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_docker_stats_checked_v1(
            base_session_id as u64,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitMonitorSnapshot(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_base_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_monitor_snapshot_checked_v1(
            base_session_id as u64,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDockerAction(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    container_id: JString,
    action: JString,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_base_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let container =
            c_string(jstring_to_rust(&mut env, container_id).map_err(|e| format!("ERR:{e}"))?)?;
        let action = c_string(jstring_to_rust(&mut env, action).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_docker_action_checked_v1(
            base_session_id as u64,
            container.as_ptr(),
            action.as_ptr(),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDockerLogs(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    container_id: JString,
    tail: jint,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 || !(1..=10_000).contains(&tail) {
        return java_string(&mut env, "ERR:invalid_docker_logs_request".to_string());
    }
    let result = (|| -> Result<String, String> {
        let container =
            c_string(jstring_to_rust(&mut env, container_id).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_docker_logs_checked_v1(
            base_session_id as u64,
            container.as_ptr(),
            tail as u32,
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitInstallTerminalOutputCallback(
    env: JNIEnv,
    _this: JObject,
    receiver: JObject,
) -> jboolean {
    let result = (|| {
        let vm = env.get_java_vm().map_err(|_| ())?;
        let receiver = env.new_global_ref(receiver).map_err(|_| ())?;
        let mut slot = TERMINAL_OUTPUT_RECEIVER.lock().map_err(|_| ())?;
        *slot = Some((Arc::new(vm), receiver));
        crate::c_ffi::orbit_terminal_set_callback(Some(emit_terminal_output_to_android));
        Ok::<(), ()>(())
    })();
    jboolean::from(result.is_ok())
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCheckedSshConnect(
    mut env: JNIEnv,
    _this: JObject,
    host: JString,
    port: jint,
    username: JString,
    password: JString,
    private_key: JString,
    private_key_passphrase: JString,
    allow_password_fallback: jboolean,
    known_hosts_path: JString,
    request_id: JString,
) -> jstring {
    let result = (|| -> Result<String, String> {
        let host = c_string(jstring_to_rust(&mut env, host).map_err(|e| format!("ERR:{e}"))?)?;
        let username =
            c_string(jstring_to_rust(&mut env, username).map_err(|e| format!("ERR:{e}"))?)?;
        let password =
            c_string(jstring_to_rust(&mut env, password).map_err(|e| format!("ERR:{e}"))?)?;
        let private_key =
            c_string(jstring_to_rust(&mut env, private_key).map_err(|e| format!("ERR:{e}"))?)?;
        let private_key_passphrase = c_string(
            jstring_to_rust(&mut env, private_key_passphrase).map_err(|e| format!("ERR:{e}"))?,
        )?;
        let known_hosts_path =
            c_string(jstring_to_rust(&mut env, known_hosts_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_ssh_connect_checked_v1(
            host.as_ptr(),
            port,
            username.as_ptr(),
            password.as_ptr(),
            private_key.as_ptr(),
            private_key_passphrase.as_ptr(),
            i32::from(allow_password_fallback != 0),
            known_hosts_path.as_ptr(),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

/// Android binding for the one-hop checked ProxyJump ABI. The core validates
/// the jump host and destination independently against the same known-hosts
/// store before it exposes a reusable base session.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCheckedSshConnectViaJump(
    mut env: JNIEnv,
    _this: JObject,
    host: JString,
    port: jint,
    username: JString,
    password: JString,
    private_key: JString,
    private_key_passphrase: JString,
    allow_password_fallback: jboolean,
    jump_host: JString,
    jump_port: jint,
    jump_username: JString,
    jump_password: JString,
    jump_private_key: JString,
    jump_private_key_passphrase: JString,
    jump_allow_password_fallback: jboolean,
    known_hosts_path: JString,
    request_id: JString,
) -> jstring {
    let result = (|| -> Result<String, String> {
        let host = c_string(jstring_to_rust(&mut env, host).map_err(|e| format!("ERR:{e}"))?)?;
        let username =
            c_string(jstring_to_rust(&mut env, username).map_err(|e| format!("ERR:{e}"))?)?;
        let password =
            c_string(jstring_to_rust(&mut env, password).map_err(|e| format!("ERR:{e}"))?)?;
        let private_key =
            c_string(jstring_to_rust(&mut env, private_key).map_err(|e| format!("ERR:{e}"))?)?;
        let private_key_passphrase = c_string(
            jstring_to_rust(&mut env, private_key_passphrase).map_err(|e| format!("ERR:{e}"))?,
        )?;
        let jump_host =
            c_string(jstring_to_rust(&mut env, jump_host).map_err(|e| format!("ERR:{e}"))?)?;
        let jump_username =
            c_string(jstring_to_rust(&mut env, jump_username).map_err(|e| format!("ERR:{e}"))?)?;
        let jump_password =
            c_string(jstring_to_rust(&mut env, jump_password).map_err(|e| format!("ERR:{e}"))?)?;
        let jump_private_key =
            c_string(jstring_to_rust(&mut env, jump_private_key).map_err(|e| format!("ERR:{e}"))?)?;
        let jump_private_key_passphrase = c_string(
            jstring_to_rust(&mut env, jump_private_key_passphrase)
                .map_err(|e| format!("ERR:{e}"))?,
        )?;
        let known_hosts_path =
            c_string(jstring_to_rust(&mut env, known_hosts_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_ssh_connect_checked_v2(
            host.as_ptr(),
            port,
            username.as_ptr(),
            password.as_ptr(),
            private_key.as_ptr(),
            private_key_passphrase.as_ptr(),
            i32::from(allow_password_fallback != 0),
            1,
            jump_host.as_ptr(),
            jump_port,
            jump_username.as_ptr(),
            jump_password.as_ptr(),
            jump_private_key.as_ptr(),
            jump_private_key_passphrase.as_ptr(),
            i32::from(jump_allow_password_fallback != 0),
            known_hosts_path.as_ptr(),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitAcceptHostKeyAndPersist(
    mut env: JNIEnv,
    _this: JObject,
    challenge_id: JString,
    known_hosts_path: JString,
) -> jstring {
    let result = (|| -> Result<String, String> {
        let challenge_id =
            c_string(jstring_to_rust(&mut env, challenge_id).map_err(|e| format!("ERR:{e}"))?)?;
        let known_hosts_path =
            c_string(jstring_to_rust(&mut env, known_hosts_path).map_err(|e| format!("ERR:{e}"))?)?;
        let comment = c_string("OrbitTerm Android".to_string())?;
        Ok(take_ffi_string(
            orbit_hostkey_challenge_accept_and_persist_v1(
                challenge_id.as_ptr(),
                known_hosts_path.as_ptr(),
                comment.as_ptr(),
            ),
        ))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitRejectHostKeyChallenge(
    mut env: JNIEnv,
    _this: JObject,
    challenge_id: JString,
) -> jstring {
    let result = (|| -> Result<String, String> {
        let challenge_id =
            c_string(jstring_to_rust(&mut env, challenge_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_hostkey_challenge_reject_v1(
            challenge_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDisconnectCheckedSsh(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    request_id: JString,
) -> jstring {
    let response = (|| {
        let request_id = jstring_to_rust(&mut env, request_id).ok()?;
        if base_session_id <= 0 || !valid_request_id(&request_id) {
            return Some(ssh_disconnect_response(
                base_session_id,
                valid_request_id(&request_id).then_some(request_id.as_str()),
                Err(OrbitCoreError::InvalidInput),
            ));
        }
        Some(ssh_disconnect_response(
            base_session_id,
            Some(request_id.as_str()),
            crate::ORBIT_RUNTIME.block_on(crate::session_pool::release_base_session(
                base_session_id as u64,
            )),
        ))
    })()
    .unwrap_or_else(|| {
        ssh_disconnect_response(base_session_id, None, Err(OrbitCoreError::InvalidInput))
    });
    java_string(&mut env, response)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitOpenCheckedTerminal(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    cols: jint,
    rows: jint,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 || cols <= 0 || rows <= 0 {
        return java_string(&mut env, "ERR:invalid_terminal_request".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_terminal_open_checked_v1(
            base_session_id as u64,
            cols as u32,
            rows as u32,
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitWriteCheckedTerminal(
    mut env: JNIEnv,
    _this: JObject,
    terminal_channel_id: jlong,
    data: JByteArray,
    request_id: JString,
) -> jstring {
    let response = (|| {
        let request_id = jstring_to_rust(&mut env, request_id).ok()?;
        if terminal_channel_id <= 0 || !valid_request_id(&request_id) {
            return Some(terminal_command_response(
                "terminal_write_completed",
                terminal_channel_id,
                valid_request_id(&request_id).then_some(request_id.as_str()),
                Err(OrbitCoreError::InvalidInput),
            ));
        }
        let bytes = env.convert_byte_array(data).ok()?;
        Some(terminal_command_response(
            "terminal_write_completed",
            terminal_channel_id,
            Some(request_id.as_str()),
            crate::ORBIT_RUNTIME.block_on(crate::terminal_write(terminal_channel_id as u64, bytes)),
        ))
    })()
    .unwrap_or_else(|| {
        terminal_command_response(
            "terminal_write_completed",
            terminal_channel_id,
            None,
            Err(OrbitCoreError::InvalidInput),
        )
    });
    java_string(&mut env, response)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitResizeCheckedTerminal(
    mut env: JNIEnv,
    _this: JObject,
    terminal_channel_id: jlong,
    cols: jint,
    rows: jint,
    request_id: JString,
) -> jstring {
    let response = (|| {
        let request_id = jstring_to_rust(&mut env, request_id).ok()?;
        if terminal_channel_id <= 0
            || !(1..=1_000).contains(&cols)
            || !(1..=1_000).contains(&rows)
            || !valid_request_id(&request_id)
        {
            return Some(terminal_command_response(
                "terminal_resize_completed",
                terminal_channel_id,
                valid_request_id(&request_id).then_some(request_id.as_str()),
                Err(OrbitCoreError::InvalidInput),
            ));
        }
        Some(terminal_command_response(
            "terminal_resize_completed",
            terminal_channel_id,
            Some(request_id.as_str()),
            crate::ORBIT_RUNTIME.block_on(crate::terminal_resize(
                terminal_channel_id as u64,
                cols as u32,
                rows as u32,
            )),
        ))
    })()
    .unwrap_or_else(|| {
        terminal_command_response(
            "terminal_resize_completed",
            terminal_channel_id,
            None,
            Err(OrbitCoreError::InvalidInput),
        )
    });
    java_string(&mut env, response)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCloseCheckedTerminal(
    mut env: JNIEnv,
    _this: JObject,
    terminal_channel_id: jlong,
    request_id: JString,
) -> jstring {
    let response = (|| {
        let request_id = jstring_to_rust(&mut env, request_id).ok()?;
        if terminal_channel_id <= 0 || !valid_request_id(&request_id) {
            return Some(terminal_command_response(
                "terminal_close_completed",
                terminal_channel_id,
                valid_request_id(&request_id).then_some(request_id.as_str()),
                Err(OrbitCoreError::InvalidInput),
            ));
        }
        Some(terminal_command_response(
            "terminal_close_completed",
            terminal_channel_id,
            Some(request_id.as_str()),
            crate::ORBIT_RUNTIME.block_on(crate::terminal_close(terminal_channel_id as u64)),
        ))
    })()
    .unwrap_or_else(|| {
        terminal_command_response(
            "terminal_close_completed",
            terminal_channel_id,
            None,
            Err(OrbitCoreError::InvalidInput),
        )
    });
    java_string(&mut env, response)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitOpenCheckedSftp(
    mut env: JNIEnv,
    _this: JObject,
    base_session_id: jlong,
    request_id: JString,
) -> jstring {
    if base_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_base_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_open_checked_v1(
            base_session_id as u64,
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitListCheckedSftp(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let remote_path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_list_checked_v1(
            sftp_session_id as u64,
            remote_path.as_ptr(),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCreateCheckedSftpDirectory(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let remote_path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_mkdir_checked_v1(
            sftp_session_id as u64,
            remote_path.as_ptr(),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCreateCheckedSftpFile(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let remote_path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_create_file_checked_v1(
            sftp_session_id as u64,
            remote_path.as_ptr(),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitRenameCheckedSftpEntry(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    old_remote_path: JString,
    new_remote_path: JString,
    expected_size: jlong,
    expected_permissions_octal: jint,
    expected_modified_at_unix: jlong,
    expected_is_directory: jboolean,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0
        || expected_size < 0
        || expected_permissions_octal < 0
        || expected_modified_at_unix < 0
    {
        return java_string(&mut env, "ERR:invalid_sftp_snapshot".to_string());
    }
    let result = (|| -> Result<String, String> {
        let old_remote_path =
            c_string(jstring_to_rust(&mut env, old_remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let new_remote_path =
            c_string(jstring_to_rust(&mut env, new_remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_rename_checked_v1(
            sftp_session_id as u64,
            old_remote_path.as_ptr(),
            new_remote_path.as_ptr(),
            expected_size as u64,
            expected_permissions_octal as u32,
            expected_modified_at_unix as u64,
            i32::from(expected_is_directory != 0),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitRemoveCheckedSftpEntry(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    expected_size: jlong,
    expected_permissions_octal: jint,
    expected_modified_at_unix: jlong,
    expected_is_directory: jboolean,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0
        || expected_size < 0
        || expected_permissions_octal < 0
        || expected_modified_at_unix < 0
    {
        return java_string(&mut env, "ERR:invalid_sftp_snapshot".to_string());
    }
    let result = (|| -> Result<String, String> {
        let remote_path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request_id =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_remove_checked_v1(
            sftp_session_id as u64,
            remote_path.as_ptr(),
            expected_size as u64,
            expected_permissions_octal as u32,
            expected_modified_at_unix as u64,
            i32::from(expected_is_directory != 0),
            request_id.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitChmodCheckedSftpEntry(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    mode: jint,
    expected_size: jlong,
    expected_permissions_octal: jint,
    expected_modified_at_unix: jlong,
    expected_is_directory: jboolean,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0
        || mode < 0
        || mode > 0o7777
        || expected_size < 0
        || expected_permissions_octal < 0
        || expected_modified_at_unix < 0
    {
        return java_string(&mut env, "ERR:invalid_sftp_chmod_request".to_string());
    }
    let result = (|| -> Result<String, String> {
        let path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_chmod_checked_v1(
            sftp_session_id as u64,
            path.as_ptr(),
            mode as u32,
            expected_size as u64,
            expected_permissions_octal as u32,
            expected_modified_at_unix as u64,
            i32::from(expected_is_directory != 0),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDownloadCheckedSftpFile(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    local_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let remote =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let local =
            c_string(jstring_to_rust(&mut env, local_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_download_checked_v1(
            sftp_session_id as u64,
            remote.as_ptr(),
            local.as_ptr(),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitUploadCheckedSftpFile(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    local_path: JString,
    remote_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let local =
            c_string(jstring_to_rust(&mut env, local_path).map_err(|e| format!("ERR:{e}"))?)?;
        let remote =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_upload_checked_v1(
            sftp_session_id as u64,
            local.as_ptr(),
            remote.as_ptr(),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitCancelCheckedSftpTransfer(
    mut env: JNIEnv,
    _this: JObject,
    request_id: JString,
) -> jstring {
    let response = (|| {
        let request_id = jstring_to_rust(&mut env, request_id).ok()?;
        if !valid_request_id(&request_id) {
            return Some(json!({
                "schema_version": 1, "request_id": serde_json::Value::Null, "kind": "error",
                "data": serde_json::Value::Null,
                "error": { "code": "invalid_sftp_cancel_request", "message_key": "error.sftp.cancel_invalid", "detail_code": serde_json::Value::Null, "retryable": false, "request_id": serde_json::Value::Null, "challenge_id": serde_json::Value::Null }
            }).to_string());
        }
        let request = c_string(request_id.clone()).ok()?;
        let cancelled = orbit_sftp_cancel_checked_v1(request.as_ptr());
        Some(if cancelled {
            json!({
                "schema_version": 1, "request_id": request_id, "kind": "sftp_transfer_cancelled",
                "data": { "cancelled": true }, "error": serde_json::Value::Null,
            }).to_string()
        } else {
            json!({
                "schema_version": 1, "request_id": request_id, "kind": "error",
                "data": serde_json::Value::Null,
                "error": { "code": "sftp_transfer_not_found", "message_key": "error.sftp.transfer_not_found", "detail_code": serde_json::Value::Null, "retryable": false, "request_id": request_id, "challenge_id": serde_json::Value::Null }
            }).to_string()
        })
    })()
    .unwrap_or_else(|| json!({
        "schema_version": 1, "request_id": serde_json::Value::Null, "kind": "error",
        "data": serde_json::Value::Null,
        "error": { "code": "invalid_sftp_cancel_request", "message_key": "error.sftp.cancel_invalid", "detail_code": serde_json::Value::Null, "retryable": false, "request_id": serde_json::Value::Null, "challenge_id": serde_json::Value::Null }
    }).to_string());
    java_string(&mut env, response)
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitReadCheckedSftpText(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0 {
        return java_string(&mut env, "ERR:invalid_sftp_session_id".to_string());
    }
    let result = (|| -> Result<String, String> {
        let path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        Ok(take_ffi_string(orbit_sftp_read_text_checked_v1(
            sftp_session_id as u64,
            path.as_ptr(),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitWriteCheckedSftpText(
    mut env: JNIEnv,
    _this: JObject,
    sftp_session_id: jlong,
    remote_path: JString,
    content: JByteArray,
    expected_size: jlong,
    expected_permissions_octal: jint,
    expected_modified_at_unix: jlong,
    expected_is_directory: jboolean,
    request_id: JString,
) -> jstring {
    if sftp_session_id <= 0
        || expected_size < 0
        || expected_permissions_octal < 0
        || expected_modified_at_unix < 0
    {
        return java_string(&mut env, "ERR:invalid_sftp_snapshot".to_string());
    }
    let result = (|| -> Result<String, String> {
        let path =
            c_string(jstring_to_rust(&mut env, remote_path).map_err(|e| format!("ERR:{e}"))?)?;
        let request =
            c_string(jstring_to_rust(&mut env, request_id).map_err(|e| format!("ERR:{e}"))?)?;
        let bytes = env
            .convert_byte_array(content)
            .map_err(|_| "ERR:invalid_sftp_text_content".to_string())?;
        Ok(take_ffi_string(orbit_sftp_write_text_checked_v1(
            sftp_session_id as u64,
            path.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            expected_size as u64,
            expected_permissions_octal as u32,
            expected_modified_at_unix as u64,
            i32::from(expected_is_directory != 0),
            request.as_ptr(),
        )))
    })();
    java_string(&mut env, result.unwrap_or_else(|error| error))
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
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDeriveConfigRootKeyV2(
    mut env: JNIEnv,
    _this: JObject,
    master_password: JString,
    account_scope: JString,
) -> jstring {
    let password = match jstring_to_rust(&mut env, master_password) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{e}")),
    };
    let scope = match jstring_to_rust(&mut env, account_scope) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{e}")),
    };
    match derive_config_root_key_v2(password.as_bytes(), scope.as_bytes()) {
        Ok(key) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(key)
            ),
        ),
        Err(error) => java_string(&mut env, format!("ERR:{error}")),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitEncryptConfigV2(
    mut env: JNIEnv,
    _this: JObject,
    root_key: JByteArray,
    plaintext: JByteArray,
) -> jstring {
    let root_key = match env.convert_byte_array(root_key) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:参数不合法".to_string()),
    };
    let plaintext = match env.convert_byte_array(plaintext) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:参数不合法".to_string()),
    };
    match encrypt_config_v2(&root_key, &plaintext) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(error) => java_string(&mut env, format!("ERR:{error}")),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_orbitterm_android_core_OrbitCoreBridge_orbitDecryptConfigV2(
    mut env: JNIEnv,
    _this: JObject,
    root_key: JByteArray,
    encrypted_base64: JString,
) -> jstring {
    let root_key = match env.convert_byte_array(root_key) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:参数不合法".to_string()),
    };
    let encrypted_b64 = match jstring_to_rust(&mut env, encrypted_base64) {
        Ok(v) => v,
        Err(e) => return java_string(&mut env, format!("ERR:{e}")),
    };
    let encrypted = match base64::engine::general_purpose::STANDARD.decode(encrypted_b64) {
        Ok(v) => v,
        Err(_) => return java_string(&mut env, "ERR:Base64 解码失败".to_string()),
    };
    match decrypt_config_v2(&root_key, &encrypted) {
        Ok(payload) => java_string(
            &mut env,
            format!(
                "OK:{}",
                base64::engine::general_purpose::STANDARD.encode(payload)
            ),
        ),
        Err(error) => java_string(&mut env, format!("ERR:{error}")),
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
