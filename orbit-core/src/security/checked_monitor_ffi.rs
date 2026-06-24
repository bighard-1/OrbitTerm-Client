use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{HostKeyFfiResult, MonitorSnapshotPayload};
use crate::checked_exec::CheckedExecError;
use crate::checked_monitor::{
    fetch_system_stats_checked, CheckedMonitorSnapshotError, MonitorMetric,
};
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;

#[no_mangle]
pub extern "C" fn orbit_monitor_snapshot_checked_v1(
    base_session_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    monitor_snapshot_response(base_session_id, request_id, fetch_system_stats_checked)
}

fn monitor_snapshot_response<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    fetcher: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<MonitorSnapshotPayload, CheckedMonitorSnapshotError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 {
            return Err(invalid_request("invalid_base_session_id", Some(request_id)));
        }
        let payload = ORBIT_RUNTIME
            .block_on(fetcher(base_session_id))
            .map_err(|error| monitor_error_payload(error, Some(request_id.clone())))?;
        success_envelope(Some(request_id), HostKeyFfiResult::MonitorSnapshot(payload))
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

fn monitor_error_payload(
    error: CheckedMonitorSnapshotError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedMonitorSnapshotError::ChannelAccess(error) => {
            HostKeyFfiErrorPayload::from_checked_channel_error(error, request_id)
        }
        CheckedMonitorSnapshotError::Exec(error) => exec_error_payload(error, request_id),
        CheckedMonitorSnapshotError::MetricUnavailable(metric) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::MonitorSnapshotFailed,
            Some(match metric {
                MonitorMetric::Cpu => "monitor_cpu_unavailable",
                MonitorMetric::Memory => "monitor_memory_unavailable",
                MonitorMetric::Disk => "monitor_disk_unavailable",
                MonitorMetric::Network => "monitor_network_unavailable",
            }),
            request_id,
            None,
        ),
        CheckedMonitorSnapshotError::InternalInvariantViolation => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("monitor_snapshot_invariant"),
            request_id,
            None,
        ),
    }
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
            Some("monitor_exec_configuration_invalid"),
            request_id,
            None,
        ),
        CheckedExecError::ExecRequestFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecRequestFailed,
            Some("exec_request_failed"),
            request_id,
            None,
        ),
        CheckedExecError::ExecOutputFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecOutputFailed,
            Some("exec_output_failed"),
            request_id,
            None,
        ),
        CheckedExecError::OutputLimitExceeded => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecOutputFailed,
            Some("exec_output_limit_exceeded"),
            request_id,
            None,
        ),
        CheckedExecError::Timeout => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecTimeout,
            Some("exec_timeout"),
            request_id,
            None,
        ),
        CheckedExecError::CommandFailed { .. } => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::ExecCommandFailed,
            Some("exec_command_failed"),
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

#[cfg(test)]
pub(crate) fn monitor_snapshot_response_for_tests<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    fetcher: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<MonitorSnapshotPayload, CheckedMonitorSnapshotError>>,
{
    monitor_snapshot_response(base_session_id, request_id, fetcher)
}
