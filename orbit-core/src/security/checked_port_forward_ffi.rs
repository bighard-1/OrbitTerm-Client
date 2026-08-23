use std::ffi::CStr;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{
    HostKeyFfiResult, LocalTunnelStartedPayload, LocalTunnelStoppedPayload,
};
use crate::checked_port_forward::{start_local_tunnel, stop_local_tunnel};
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;
const MAX_HOST_BYTES: usize = 253;

#[no_mangle]
pub extern "C" fn orbit_local_tunnel_start_checked_v1(
    base_session_id: u64,
    bind_host: *const c_char,
    bind_port: u16,
    destination_host: *const c_char,
    destination_port: u16,
    request_id: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 || destination_port == 0 {
            return Err(invalid_request(
                "invalid_local_tunnel_port",
                Some(request_id),
            ));
        }
        let bind_host = parse_host(bind_host, "invalid_bind_host", &request_id)?;
        let destination_host =
            parse_host(destination_host, "invalid_destination_host", &request_id)?;
        let started = ORBIT_RUNTIME
            .block_on(start_local_tunnel(
                base_session_id,
                bind_host,
                bind_port,
                destination_host,
                destination_port,
            ))
            .map_err(|error| {
                HostKeyFfiErrorPayload::from_checked_channel_error(error, Some(request_id.clone()))
            })?;
        let payload = LocalTunnelStartedPayload::new(
            base_session_id,
            started.tunnel_id,
            started.bind_host,
            started.bind_port,
        )
        .map_err(|_| invalid_request("invalid_local_tunnel_result", Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::LocalTunnelStarted(payload),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_local_tunnel_stop_checked_v1(
    tunnel_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if tunnel_id == 0 {
            return Err(invalid_request("invalid_tunnel_id", Some(request_id)));
        }
        ORBIT_RUNTIME
            .block_on(stop_local_tunnel(tunnel_id))
            .map_err(|error| {
                HostKeyFfiErrorPayload::from_checked_channel_error(error, Some(request_id.clone()))
            })?;
        let payload = LocalTunnelStoppedPayload::new(tunnel_id)
            .map_err(|_| invalid_request("invalid_tunnel_result", Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::LocalTunnelStopped(payload),
        )
    })
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    let value = parse_string(pointer, "null_request_id", None)?;
    if value.is_empty()
        || value.len() > MAX_REQUEST_ID_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(invalid_request("invalid_request_id", None));
    }
    Ok(value)
}

fn parse_host(
    pointer: *const c_char,
    detail: &'static str,
    request_id: &str,
) -> Result<String, HostKeyFfiErrorPayload> {
    let value = parse_string(pointer, detail, Some(request_id.to_string()))?;
    if value.is_empty()
        || value.len() > MAX_HOST_BYTES
        || value
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(invalid_request(detail, Some(request_id.to_string())));
    }
    Ok(value)
}

fn parse_string(
    pointer: *const c_char,
    detail: &'static str,
    request_id: Option<String>,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request(detail, request_id));
    }
    // SAFETY: The pointer is borrowed only for this call and copied before async work begins.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some(detail),
                request_id,
                None,
            )
        })
}

fn invalid_request(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        Some(detail),
        request_id,
        None,
    )
}
