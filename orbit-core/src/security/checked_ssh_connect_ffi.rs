use std::os::raw::c_char;

use super::checked_ssh_connect::{
    run_checked_ssh_connect, CheckedSessionPoolStage, CheckedSshConnectError,
    CheckedSshConnectOutcome,
};
use super::checked_test_connection_ffi::{
    connection_error_payload, parse_checked_connection_request,
    parse_checked_connection_request_with_jump,
};
use super::host_key_ffi_api::{ffi_response, success_envelope, FfiOperationResult};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{
    HostKeyBlockedPayload, HostKeyChallengePayload, HostKeyConnectedPayload, HostKeyFfiResult,
};
use crate::{session_pool, ORBIT_RUNTIME};

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn orbit_ssh_connect_checked_v1(
    host: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
    known_hosts_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let request = parse_checked_connection_request(
            host,
            port,
            username,
            password,
            private_key,
            private_key_passphrase,
            allow_password_fallback,
            known_hosts_path,
            request_id,
        )?;
        let request_id = request.request_id().to_string();
        let outcome = ORBIT_RUNTIME.block_on(run_checked_ssh_connect(request));
        outcome_to_ffi(outcome, request_id)
    })
}

/// Checked SSH connection with an optional single ProxyJump hop.
///
/// The v1 ABI remains untouched for existing clients. Both the jump host and
/// the destination are independently checked against `known_hosts`; a jump
/// channel is never a substitute for destination host-key verification.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn orbit_ssh_connect_checked_v2(
    host: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
    jump_enabled: i32,
    jump_host: *const c_char,
    jump_port: i32,
    jump_username: *const c_char,
    jump_password: *const c_char,
    jump_private_key: *const c_char,
    jump_private_key_passphrase: *const c_char,
    jump_allow_password_fallback: i32,
    known_hosts_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let request = parse_checked_connection_request_with_jump(
            host,
            port,
            username,
            password,
            private_key,
            private_key_passphrase,
            allow_password_fallback,
            jump_enabled,
            jump_host,
            jump_port,
            jump_username,
            jump_password,
            jump_private_key,
            jump_private_key_passphrase,
            jump_allow_password_fallback,
            known_hosts_path,
            request_id,
        )?;
        let request_id = request.request_id().to_string();
        let outcome = ORBIT_RUNTIME.block_on(run_checked_ssh_connect(request));
        outcome_to_ffi(outcome, request_id)
    })
}

fn outcome_to_ffi(outcome: CheckedSshConnectOutcome, request_id: String) -> FfiOperationResult {
    let request_id = Some(request_id);
    match outcome {
        CheckedSshConnectOutcome::Connected(connected) => {
            let payload = HostKeyConnectedPayload::from_security_generation(
                connected.base.id,
                &connected.security_generation,
            )
            .map_err(|error| error.to_error_payload(request_id.clone()))?;
            let envelope =
                success_envelope(request_id.clone(), HostKeyFfiResult::Connected(payload));
            match envelope {
                Ok(value) if value.to_json().is_ok() => Ok(value),
                Ok(_) => {
                    let _ = ORBIT_RUNTIME
                        .block_on(session_pool::release_base_session(connected.base.id));
                    Err(internal_error(
                        "connected_json_serialization_failed",
                        request_id,
                    ))
                }
                Err(error) => {
                    let _ = ORBIT_RUNTIME
                        .block_on(session_pool::release_base_session(connected.base.id));
                    Err(error)
                }
            }
        }
        CheckedSshConnectOutcome::Challenge(challenge) => {
            let payload = HostKeyChallengePayload::from_registered(&challenge)
                .map_err(|error| error.to_error_payload(request_id.clone()))?;
            success_envelope(request_id, HostKeyFfiResult::HostKeyChallenge(payload))
        }
        CheckedSshConnectOutcome::Blocked(block) => success_envelope(
            request_id,
            HostKeyFfiResult::HostKeyBlocked(HostKeyBlockedPayload::from(block.as_ref())),
        ),
        CheckedSshConnectOutcome::Error(error) => Err(connect_error_payload(&error, request_id)),
    }
}

fn connect_error_payload(
    error: &CheckedSshConnectError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedSshConnectError::Connection(error) => connection_error_payload(error, request_id),
        CheckedSshConnectError::SessionPool { stage } => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SessionPoolFailed,
            Some(match stage {
                CheckedSessionPoolStage::CandidateLookup => "candidate_lookup_failed",
                CheckedSessionPoolStage::CreationGate => "creation_gate_failed",
                CheckedSessionPoolStage::ExactLookup => "exact_lookup_failed",
                CheckedSessionPoolStage::Insert => "verified_session_insert_failed",
            }),
            request_id,
            None,
        ),
    }
}

fn internal_error(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::FfiInternalError,
        Some(detail),
        request_id,
        None,
    )
}

#[cfg(test)]
pub(crate) fn outcome_json_for_tests(
    outcome: CheckedSshConnectOutcome,
    request_id: &str,
) -> String {
    match outcome_to_ffi(outcome, request_id.to_string()) {
        Ok(value) => value.to_json().expect("checked connect envelope JSON"),
        Err(error) => super::host_key_ffi_protocol::HostKeyFfiEnvelope::new(
            error.request_id.clone(),
            HostKeyFfiResult::Error(error),
        )
        .expect("checked connect error envelope")
        .to_json()
        .expect("checked connect error JSON"),
    }
}

#[cfg(test)]
pub(crate) fn error_payload_for_tests(
    error: &CheckedSshConnectError,
    request_id: &str,
) -> HostKeyFfiErrorPayload {
    connect_error_payload(error, Some(request_id.to_string()))
}
