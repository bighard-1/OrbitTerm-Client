use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{ExecResultPayload, HostKeyFfiResult};
use crate::checked_exec::{
    run_remote_command_checked, validate_command, CheckedExecError, CheckedExecOptions,
    CheckedExecOutput,
};
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[no_mangle]
pub extern "C" fn orbit_exec_checked_v1(
    base_session_id: u64,
    command: *const c_char,
    timeout_seconds: u32,
    max_stdout_bytes: u32,
    max_stderr_bytes: u32,
    request_id: *const c_char,
) -> *mut c_char {
    exec_response(
        base_session_id,
        command,
        timeout_seconds,
        max_stdout_bytes,
        max_stderr_bytes,
        request_id,
        |base_session_id, command, options| async move {
            run_remote_command_checked(base_session_id, &command, options).await
        },
    )
}

fn exec_response<F, Fut>(
    base_session_id: u64,
    command: *const c_char,
    timeout_seconds: u32,
    max_stdout_bytes: u32,
    max_stderr_bytes: u32,
    request_id: *const c_char,
    runner: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, CheckedExecOptions) -> Fut,
    Fut: Future<Output = Result<CheckedExecOutput, CheckedExecError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 {
            return Err(invalid_request("invalid_base_session_id", Some(request_id)));
        }
        let command = parse_command(command, &request_id)?;
        let options =
            CheckedExecOptions::batch(timeout_seconds, max_stdout_bytes, max_stderr_bytes)
                .map_err(|error| exec_error_payload(error, Some(request_id.clone())))?;
        let output = ORBIT_RUNTIME
            .block_on(runner(base_session_id, command, options))
            .map_err(|error| exec_error_payload(error, Some(request_id.clone())))?;
        let payload = ExecResultPayload::new(
            base_session_id,
            output.exit_status(),
            output.stdout().to_string(),
            output.stderr().to_string(),
        )
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::FfiInternalError,
                Some("exec_result_invariant"),
                Some(request_id.clone()),
                None,
            )
        })?;
        success_envelope(Some(request_id), HostKeyFfiResult::ExecResult(payload))
    })
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_request_id", None));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // before asynchronous work begins.
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

fn parse_command(
    pointer: *const c_char,
    request_id: &str,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request(
            "null_command",
            Some(request_id.to_string()),
        ));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // before asynchronous work begins.
    let command = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("command_invalid_utf8"),
                Some(request_id.to_string()),
                None,
            )
        })?;
    validate_command(&command)
        .map_err(|error| exec_error_payload(error, Some(request_id.to_string())))?;
    Ok(command)
}

fn exec_error_payload(
    error: CheckedExecError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    let (code, detail) = match error {
        CheckedExecError::ChannelAccess(error) => {
            return HostKeyFfiErrorPayload::from_checked_channel_error(error, request_id);
        }
        CheckedExecError::InvalidCommand => {
            (HostKeyFfiErrorCode::InvalidCommand, "invalid_command")
        }
        CheckedExecError::CommandTooLarge => {
            (HostKeyFfiErrorCode::CommandTooLarge, "command_too_large")
        }
        CheckedExecError::InvalidOptions => (
            HostKeyFfiErrorCode::InvalidExecOptions,
            "invalid_exec_options",
        ),
        CheckedExecError::ExecRequestFailed => (
            HostKeyFfiErrorCode::ExecRequestFailed,
            "exec_request_failed",
        ),
        CheckedExecError::ExecOutputFailed => {
            (HostKeyFfiErrorCode::ExecOutputFailed, "exec_output_failed")
        }
        CheckedExecError::OutputLimitExceeded => (
            HostKeyFfiErrorCode::ExecOutputLimitExceeded,
            "exec_output_limit_exceeded",
        ),
        CheckedExecError::Timeout => (HostKeyFfiErrorCode::ExecTimeout, "exec_timeout"),
        CheckedExecError::CommandFailed { .. } => (
            HostKeyFfiErrorCode::ExecCommandFailed,
            "exec_command_failed",
        ),
    };
    HostKeyFfiErrorPayload::new(code, Some(detail), request_id, None)
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
pub(crate) fn exec_response_for_tests<F, Fut>(
    base_session_id: u64,
    command: *const c_char,
    timeout_seconds: u32,
    max_stdout_bytes: u32,
    max_stderr_bytes: u32,
    request_id: *const c_char,
    runner: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, CheckedExecOptions) -> Fut,
    Fut: Future<Output = Result<CheckedExecOutput, CheckedExecError>>,
{
    exec_response(
        base_session_id,
        command,
        timeout_seconds,
        max_stdout_bytes,
        max_stderr_bytes,
        request_id,
        runner,
    )
}
