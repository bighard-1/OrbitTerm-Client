use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{
    DockerActionResultPayload, DockerContainersPayload, DockerLogsPayload, DockerStatsPayload,
    HostKeyFfiResult,
};
use crate::checked_docker::{
    docker_action_checked, fetch_docker_containers_checked, fetch_docker_logs_checked,
    fetch_docker_stats_checked, CheckedDockerError,
};
use crate::checked_exec::CheckedExecError;
use crate::docker_validator::DockerValidationError;
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[no_mangle]
pub extern "C" fn orbit_docker_list_checked_v1(
    base_session_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    docker_list_response(base_session_id, request_id, fetch_docker_containers_checked)
}

#[no_mangle]
pub extern "C" fn orbit_docker_stats_checked_v1(
    base_session_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    docker_stats_response(base_session_id, request_id, fetch_docker_stats_checked)
}

#[no_mangle]
pub extern "C" fn orbit_docker_logs_checked_v1(
    base_session_id: u64,
    container_id: *const c_char,
    tail: u32,
    request_id: *const c_char,
) -> *mut c_char {
    docker_logs_response(
        base_session_id,
        container_id,
        tail,
        request_id,
        |base_session_id, container_id, tail| async move {
            fetch_docker_logs_checked(base_session_id, &container_id, tail).await
        },
    )
}

#[no_mangle]
pub extern "C" fn orbit_docker_action_checked_v1(
    base_session_id: u64,
    container_id: *const c_char,
    action: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    docker_action_response(
        base_session_id,
        container_id,
        action,
        request_id,
        |base_session_id, container_id, action| async move {
            docker_action_checked(base_session_id, &container_id, &action).await
        },
    )
}

pub(crate) fn docker_list_response<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    fetcher: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<DockerContainersPayload, CheckedDockerError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        validate_base_session_id(base_session_id, &request_id)?;
        let payload = ORBIT_RUNTIME
            .block_on(fetcher(base_session_id))
            .map_err(|error| docker_error_payload(error, Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::DockerContainers(payload),
        )
    })
}

pub(crate) fn docker_stats_response<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    fetcher: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<DockerStatsPayload, CheckedDockerError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        validate_base_session_id(base_session_id, &request_id)?;
        let payload = ORBIT_RUNTIME
            .block_on(fetcher(base_session_id))
            .map_err(|error| docker_error_payload(error, Some(request_id.clone())))?;
        success_envelope(Some(request_id), HostKeyFfiResult::DockerStats(payload))
    })
}

pub(crate) fn docker_logs_response<F, Fut>(
    base_session_id: u64,
    container_id: *const c_char,
    tail: u32,
    request_id: *const c_char,
    fetcher: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, u32) -> Fut,
    Fut: Future<Output = Result<DockerLogsPayload, CheckedDockerError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        validate_base_session_id(base_session_id, &request_id)?;
        let container_id = parse_required_string(
            container_id,
            "null_container_id",
            "container_id_invalid_utf8",
            &request_id,
        )?;
        let payload = ORBIT_RUNTIME
            .block_on(fetcher(base_session_id, container_id, tail))
            .map_err(|error| docker_error_payload(error, Some(request_id.clone())))?;
        success_envelope(Some(request_id), HostKeyFfiResult::DockerLogs(payload))
    })
}

pub(crate) fn docker_action_response<F, Fut>(
    base_session_id: u64,
    container_id: *const c_char,
    action: *const c_char,
    request_id: *const c_char,
    runner: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, String) -> Fut,
    Fut: Future<Output = Result<DockerActionResultPayload, CheckedDockerError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        validate_base_session_id(base_session_id, &request_id)?;
        let container_id = parse_required_string(
            container_id,
            "null_container_id",
            "container_id_invalid_utf8",
            &request_id,
        )?;
        let action = parse_required_string(
            action,
            "null_docker_action",
            "docker_action_invalid_utf8",
            &request_id,
        )?;
        let payload = ORBIT_RUNTIME
            .block_on(runner(base_session_id, container_id, action))
            .map_err(|error| docker_error_payload(error, Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::DockerActionResult(payload),
        )
    })
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    let request_id =
        parse_required_string(pointer, "null_request_id", "request_id_invalid_utf8", "")?;
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

fn parse_required_string(
    pointer: *const c_char,
    null_detail: &'static str,
    utf8_detail: &'static str,
    request_id: &str,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request(
            null_detail,
            (!request_id.is_empty()).then(|| request_id.to_string()),
        ));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // before asynchronous work begins.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some(utf8_detail),
                (!request_id.is_empty()).then(|| request_id.to_string()),
                None,
            )
        })
}

fn validate_base_session_id(
    base_session_id: u64,
    request_id: &str,
) -> Result<(), HostKeyFfiErrorPayload> {
    if base_session_id == 0 {
        return Err(invalid_request(
            "invalid_base_session_id",
            Some(request_id.to_string()),
        ));
    }
    Ok(())
}

pub(crate) fn docker_error_payload(
    error: CheckedDockerError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedDockerError::ChannelAccess(error) => {
            HostKeyFfiErrorPayload::from_checked_channel_error(error, request_id)
        }
        CheckedDockerError::Validation(error) => validation_error_payload(error, request_id),
        CheckedDockerError::Exec(error) => exec_error_payload(error, request_id),
        CheckedDockerError::ParseFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::DockerParseFailed,
            Some("docker_parse_failed"),
            request_id,
            None,
        ),
        CheckedDockerError::InternalInvariantViolation => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("docker_result_invariant"),
            request_id,
            None,
        ),
    }
}

fn validation_error_payload(
    error: DockerValidationError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    let code = match error {
        DockerValidationError::EmptyContainerId
        | DockerValidationError::InvalidContainerIdLength
        | DockerValidationError::InvalidContainerIdCharacter => {
            HostKeyFfiErrorCode::DockerInvalidContainerId
        }
        DockerValidationError::InvalidContainerName => {
            HostKeyFfiErrorCode::DockerInvalidContainerName
        }
        DockerValidationError::InvalidAction => HostKeyFfiErrorCode::DockerInvalidAction,
        DockerValidationError::InvalidTail => HostKeyFfiErrorCode::DockerInvalidLogsTail,
        DockerValidationError::InvalidRestartPolicy
        | DockerValidationError::InvalidMemoryLimit
        | DockerValidationError::InvalidCpuShares
        | DockerValidationError::EmptyUpdateOptions
        | DockerValidationError::InvalidTimestamp
        | DockerValidationError::UnsupportedOption
        | DockerValidationError::UnsafeParameter => HostKeyFfiErrorCode::DockerInvalidUpdateOption,
        DockerValidationError::InternalInvariantViolation => HostKeyFfiErrorCode::FfiInternalError,
    };
    HostKeyFfiErrorPayload::new(code, Some(error.reason_code()), request_id, None)
}

fn exec_error_payload(
    error: CheckedExecError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedExecError::ChannelAccess(error) => {
            HostKeyFfiErrorPayload::from_checked_channel_error(error, request_id)
        }
        CheckedExecError::InvalidCommand
        | CheckedExecError::CommandTooLarge
        | CheckedExecError::InvalidOptions => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("docker_exec_configuration_invalid"),
            request_id,
            None,
        ),
        CheckedExecError::ExecRequestFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecRequestFailed,
            Some("exec_request_failed"),
            request_id,
            None,
        ),
        CheckedExecError::ExecOutputFailed | CheckedExecError::OutputLimitExceeded => {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::ExecOutputFailed,
                Some(match error {
                    CheckedExecError::OutputLimitExceeded => "exec_output_limit_exceeded",
                    _ => "exec_output_failed",
                }),
                request_id,
                None,
            )
        }
        CheckedExecError::Timeout => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecTimeout,
            Some("exec_timeout"),
            request_id,
            None,
        ),
        CheckedExecError::CommandFailed { .. } => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::DockerCommandFailed,
            Some("docker_command_failed"),
            request_id,
            None,
        ),
    }
}

fn invalid_request(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        Some(detail),
        request_id,
        None,
    )
}
