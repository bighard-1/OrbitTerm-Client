use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{HostKeyFfiResult, TerminalChannelOpenedPayload};
use crate::checked_terminal::{
    discard_terminal_channel_checked, open_terminal_channel_checked, CheckedPtySize,
    CheckedTerminalError, TerminalChannelId,
};
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[no_mangle]
pub extern "C" fn orbit_terminal_open_checked_v1(
    base_session_id: u64,
    cols: u32,
    rows: u32,
    request_id: *const c_char,
) -> *mut c_char {
    terminal_open_checked_response(
        base_session_id,
        cols,
        rows,
        request_id,
        open_terminal_channel_checked,
    )
}

fn terminal_open_checked_response<F, Fut>(
    base_session_id: u64,
    cols: u32,
    rows: u32,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64, u32, u32) -> Fut,
    Fut: Future<Output = Result<TerminalChannelId, CheckedTerminalError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 {
            return Err(invalid_request("invalid_base_session_id", Some(request_id)));
        }
        CheckedPtySize::new(cols, rows)
            .map_err(|error| terminal_error_payload(error, Some(request_id.clone())))?;

        let terminal_channel_id = ORBIT_RUNTIME
            .block_on(opener(base_session_id, cols, rows))
            .map_err(|error| terminal_error_payload(error, Some(request_id.clone())))?;
        let envelope = (|| {
            let payload = TerminalChannelOpenedPayload::new(
                base_session_id,
                terminal_channel_id.get(),
                cols,
                rows,
            )
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
            let envelope = success_envelope(
                Some(request_id),
                HostKeyFfiResult::TerminalChannelOpened(payload),
            )?;

            // Preflight serialization before publishing the opaque terminal ID to C.
            envelope.to_json().map_err(|_| {
                HostKeyFfiErrorPayload::new(
                    HostKeyFfiErrorCode::FfiInternalError,
                    Some("terminal_open_response_serialization_failed"),
                    envelope.request_id.clone(),
                    None,
                )
            })?;
            Ok(envelope)
        })();
        if envelope.is_err() {
            ORBIT_RUNTIME.block_on(discard_terminal_channel_checked(terminal_channel_id));
        }
        envelope
    })
}

fn terminal_error_payload(
    error: CheckedTerminalError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedTerminalError::ChannelAccess(error) => {
            HostKeyFfiErrorPayload::from_checked_channel_error(error, request_id)
        }
        CheckedTerminalError::InvalidPtySize => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::InvalidPtySize,
            Some("invalid_pty_size"),
            request_id,
            None,
        ),
        CheckedTerminalError::PtyRequestFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::PtyRequestFailed,
            Some("pty_request_failed"),
            request_id,
            None,
        ),
        CheckedTerminalError::ShellStartFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ShellStartFailed,
            Some("shell_start_failed"),
            request_id,
            None,
        ),
        CheckedTerminalError::TerminalRegistrationFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("terminal_registration_failed"),
            request_id,
            None,
        ),
    }
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_request_id", None));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // into Rust-owned memory before asynchronous work begins.
    let request_id = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("request_id_invalid_utf8"),
                None,
                None,
            )
        })?;
    if request_id.is_empty()
        || request_id.len() > MAX_REQUEST_ID_BYTES
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(invalid_request("invalid_request_id", None));
    }
    Ok(request_id)
}

fn invalid_request(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        Some(detail),
        request_id,
        None,
    )
}

#[cfg(test)]
pub(crate) fn terminal_open_checked_response_for_tests<F, Fut>(
    base_session_id: u64,
    cols: u32,
    rows: u32,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64, u32, u32) -> Fut,
    Fut: Future<Output = Result<TerminalChannelId, CheckedTerminalError>>,
{
    terminal_open_checked_response(base_session_id, cols, rows, request_id, opener)
}
