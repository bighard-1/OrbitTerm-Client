use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{HostKeyFfiResult, SftpChannelOpenedPayload};
use crate::checked_sftp::{discard_sftp_channel_checked, open_sftp_channel_checked, SftpSessionId};
use crate::security::CheckedChannelAccessError;
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[no_mangle]
pub extern "C" fn orbit_sftp_open_checked_v1(
    base_session_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_open_checked_response(base_session_id, request_id, open_sftp_channel_checked)
}

fn sftp_open_checked_response<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<SftpSessionId, CheckedChannelAccessError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 {
            return Err(invalid_request("invalid_base_session_id", Some(request_id)));
        }

        let sftp_session_id = ORBIT_RUNTIME
            .block_on(opener(base_session_id))
            .map_err(|error| {
                HostKeyFfiErrorPayload::from_checked_channel_error(error, Some(request_id.clone()))
            })?;
        let envelope = (|| {
            let payload = SftpChannelOpenedPayload::new(base_session_id, sftp_session_id.get())
                .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
            let envelope = success_envelope(
                Some(request_id),
                HostKeyFfiResult::SftpChannelOpened(payload),
            )?;

            // Preflight serialization before publishing the opaque SFTP ID to C.
            envelope.to_json().map_err(|_| {
                HostKeyFfiErrorPayload::new(
                    HostKeyFfiErrorCode::FfiInternalError,
                    Some("sftp_open_response_serialization_failed"),
                    envelope.request_id.clone(),
                    None,
                )
            })?;
            Ok(envelope)
        })();
        if envelope.is_err() {
            ORBIT_RUNTIME.block_on(discard_sftp_channel_checked(sftp_session_id));
        }
        envelope
    })
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
pub(crate) fn sftp_open_checked_response_for_tests<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<SftpSessionId, CheckedChannelAccessError>>,
{
    sftp_open_checked_response(base_session_id, request_id, opener)
}
