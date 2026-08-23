use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::PathBuf;

use super::checked_connect_coordinator::CheckedConnectPreAuthError;
use super::checked_test_connection::{
    run_checked_test_connection, CheckedAuthenticationError, CheckedJumpHostRequest,
    CheckedTestConnectionError, CheckedTestConnectionOutcome, CheckedTestInputError,
    CheckedTestTimeoutStage,
};
use super::connect_pre_auth_error::ConnectPreAuthError;
use super::host_key_challenge_service::HostKeyChallengeServiceError;
use super::host_key_ffi_api::{ffi_response, success_envelope, FfiOperationResult};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{
    HostKeyBlockedPayload, HostKeyChallengePayload, HostKeyConnectionTestSucceededPayload,
    HostKeyFfiResult,
};
use super::host_key_verification_context::HostKeyVerificationContextError;
use super::verified_host_key_slot::VerifiedHostKeySlotError;
use crate::ORBIT_RUNTIME;

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn orbit_test_ssh_connection_checked_v1(
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

        let outcome = ORBIT_RUNTIME.block_on(run_checked_test_connection(request));
        outcome_to_ffi(outcome, request_id)
    })
}

fn outcome_to_ffi(outcome: CheckedTestConnectionOutcome, request_id: String) -> FfiOperationResult {
    let request_id = Some(request_id);
    match outcome {
        CheckedTestConnectionOutcome::Succeeded(approval) => success_envelope(
            request_id,
            HostKeyFfiResult::ConnectionTestSucceeded(
                HostKeyConnectionTestSucceededPayload::from_verified(approval.verified_host_key()),
            ),
        ),
        CheckedTestConnectionOutcome::Challenge(challenge) => {
            let payload = HostKeyChallengePayload::from_registered(&challenge)
                .map_err(|error| error.to_error_payload(request_id.clone()))?;
            success_envelope(request_id, HostKeyFfiResult::HostKeyChallenge(payload))
        }
        CheckedTestConnectionOutcome::Blocked(block) => success_envelope(
            request_id,
            HostKeyFfiResult::HostKeyBlocked(HostKeyBlockedPayload::from(block.as_ref())),
        ),
        CheckedTestConnectionOutcome::Error(error) => {
            Err(connection_error_payload(&error, request_id))
        }
    }
}

pub(crate) fn connection_error_payload(
    error: &CheckedTestConnectionError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedTestConnectionError::Timeout { stage } => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SshTimeout,
            Some(match stage {
                CheckedTestTimeoutStage::Connect => "connect_timeout",
                CheckedTestTimeoutStage::Authentication => "authentication_timeout",
            }),
            request_id,
            None,
        ),
        CheckedTestConnectionError::Connect(error) => connect_error_payload(error, request_id),
        CheckedTestConnectionError::PreAuthentication(error) => {
            pre_authentication_error_payload(error, request_id)
        }
        CheckedTestConnectionError::Authentication(error) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SshAuthFailed,
            Some(match error {
                CheckedAuthenticationError::Failed => "authentication_failed",
            }),
            request_id,
            None,
        ),
    }
}

fn connect_error_payload(
    error: &ConnectPreAuthError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        ConnectPreAuthError::HostKeyChallenge(_) | ConnectPreAuthError::HostKeyBlocked(_) => {
            internal_error("unexpected_host_key_connect_outcome", request_id)
        }
        ConnectPreAuthError::HostKeyVerificationFailed(error) => {
            HostKeyFfiErrorPayload::from_verification_error(error, request_id)
        }
        ConnectPreAuthError::ChallengeServiceFailed(error) => {
            challenge_service_error_payload(error, request_id)
        }
        ConnectPreAuthError::AdapterFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::HostKeyInvalid,
            Some("host_key_adapter_failed"),
            request_id,
            None,
        ),
        ConnectPreAuthError::VerifiedSlotFailed(error) => {
            verified_slot_error_payload(*error, request_id)
        }
        ConnectPreAuthError::Protocol(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SshConnectFailed,
            Some("ssh_transport_or_kex_failed"),
            request_id,
            None,
        ),
    }
}

fn pre_authentication_error_payload(
    error: &CheckedConnectPreAuthError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        CheckedConnectPreAuthError::VerifiedSlotEmpty => {
            internal_error("verified_slot_empty", request_id)
        }
        CheckedConnectPreAuthError::VerifiedSlotUnavailable => {
            internal_error("verified_slot_unavailable", request_id)
        }
        CheckedConnectPreAuthError::VerifiedSlotMismatch { .. } => {
            internal_error("verified_slot_mismatch", request_id)
        }
        CheckedConnectPreAuthError::StoreReloadFailed(error) => {
            HostKeyFfiErrorPayload::from_store_error(error, request_id, None)
        }
        CheckedConnectPreAuthError::StoreGenerationChangedUnknown => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::HostKeyUnknown,
            Some("store_generation_changed_unknown"),
            request_id,
            None,
        ),
        CheckedConnectPreAuthError::HostKeyVerificationFailed(error) => {
            HostKeyFfiErrorPayload::from_verification_error(error, request_id)
        }
        CheckedConnectPreAuthError::ContextCreationFailed(error) => {
            context_error_payload(error, request_id)
        }
    }
}

fn context_error_payload(
    error: &HostKeyVerificationContextError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        HostKeyVerificationContextError::InvalidRequestId => {
            invalid_request("invalid_request_id", request_id)
        }
        HostKeyVerificationContextError::StoreUnavailable(error) => {
            HostKeyFfiErrorPayload::from_store_error(error, request_id, None)
        }
    }
}

fn challenge_service_error_payload(
    error: &HostKeyChallengeServiceError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        HostKeyChallengeServiceError::Registry(error) => {
            HostKeyFfiErrorPayload::from_registry_error(error, request_id, None)
        }
        HostKeyChallengeServiceError::Unavailable => {
            internal_error("registry_unavailable", request_id)
        }
    }
}

fn verified_slot_error_payload(
    error: VerifiedHostKeySlotError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    internal_error(
        match error {
            VerifiedHostKeySlotError::Unavailable => "verified_slot_unavailable",
            VerifiedHostKeySlotError::MissingVerification => "verified_slot_empty",
            VerifiedHostKeySlotError::ConflictingVerification => "verified_slot_conflict",
            VerifiedHostKeySlotError::InvalidRecheckMaterial => "verified_slot_invalid_material",
            VerifiedHostKeySlotError::RecheckBindingMismatch => "verified_slot_binding_mismatch",
        },
        request_id,
    )
}

fn input_error_payload(
    error: CheckedTestInputError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    invalid_request(
        match error {
            CheckedTestInputError::InvalidHost => "invalid_host",
            CheckedTestInputError::InvalidUsername => "invalid_username",
            CheckedTestInputError::InvalidRequestId => "invalid_request_id",
            CheckedTestInputError::MissingCredentials => "missing_credentials",
            CheckedTestInputError::InvalidKnownHostsPath => "invalid_known_hosts_path",
        },
        request_id,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn parse_checked_connection_request(
    host: *const c_char,
    port: i32,
    username: *const c_char,
    password: *const c_char,
    private_key: *const c_char,
    private_key_passphrase: *const c_char,
    allow_password_fallback: i32,
    known_hosts_path: *const c_char,
    request_id: *const c_char,
) -> Result<super::checked_test_connection::CheckedTestConnectionRequest, HostKeyFfiErrorPayload> {
    let request_id = parse_request_id(request_id)?;
    let host = parse_required_string(host, "null_host", "host_invalid_utf8", &request_id)?;
    let username = parse_required_string(
        username,
        "null_username",
        "username_invalid_utf8",
        &request_id,
    )?;
    let password = parse_optional_string(password, "password_invalid_utf8", &request_id)?;
    let private_key = parse_optional_string(private_key, "private_key_invalid_utf8", &request_id)?;
    let private_key_passphrase = parse_optional_string(
        private_key_passphrase,
        "private_key_passphrase_invalid_utf8",
        &request_id,
    )?;
    let known_hosts_path = parse_required_string(
        known_hosts_path,
        "null_known_hosts_path",
        "known_hosts_path_invalid_utf8",
        &request_id,
    )?;
    let port = u16::try_from(port)
        .ok()
        .filter(|value| *value != 0)
        .ok_or_else(|| invalid_request("invalid_port", Some(request_id.clone())))?;

    super::checked_test_connection::CheckedTestConnectionRequest::new(
        host,
        port,
        username,
        password,
        private_key,
        private_key_passphrase,
        allow_password_fallback != 0,
        PathBuf::from(known_hosts_path),
        request_id.clone(),
    )
    .map_err(|error| input_error_payload(error, Some(request_id)))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn parse_checked_connection_request_with_jump(
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
) -> Result<super::checked_test_connection::CheckedTestConnectionRequest, HostKeyFfiErrorPayload> {
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
    if jump_enabled == 0 {
        return Ok(request);
    }
    if jump_enabled != 1 {
        return Err(invalid_request(
            "invalid_jump_enabled",
            Some(request.request_id().to_string()),
        ));
    }
    let request_id = request.request_id().to_string();
    let jump_host = parse_required_string(
        jump_host,
        "null_jump_host",
        "jump_host_invalid_utf8",
        &request_id,
    )?;
    let jump_username = parse_required_string(
        jump_username,
        "null_jump_username",
        "jump_username_invalid_utf8",
        &request_id,
    )?;
    let jump_password =
        parse_optional_string(jump_password, "jump_password_invalid_utf8", &request_id)?;
    let jump_private_key = parse_optional_string(
        jump_private_key,
        "jump_private_key_invalid_utf8",
        &request_id,
    )?;
    let jump_private_key_passphrase = parse_optional_string(
        jump_private_key_passphrase,
        "jump_private_key_passphrase_invalid_utf8",
        &request_id,
    )?;
    let jump_port = u16::try_from(jump_port)
        .ok()
        .filter(|value| *value != 0)
        .ok_or_else(|| invalid_request("invalid_jump_port", Some(request_id.clone())))?;
    let jump = CheckedJumpHostRequest::new(
        jump_host,
        jump_port,
        jump_username,
        jump_password,
        jump_private_key,
        jump_private_key_passphrase,
        jump_allow_password_fallback != 0,
    )
    .map_err(|error| input_error_payload(error, Some(request_id)))?;
    Ok(request.with_jump_host(jump))
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    let request_id =
        parse_required_string(pointer, "null_request_id", "request_id_invalid_utf8", "")?;
    if request_id.is_empty() || request_id.len() > 256 || request_id.chars().any(char::is_control) {
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
    // SAFETY: The non-null C string is borrowed only for this call and is
    // copied into Rust-owned memory before any asynchronous work begins.
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

fn parse_optional_string(
    pointer: *const c_char,
    utf8_detail: &'static str,
    request_id: &str,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Ok(String::new());
    }
    parse_required_string(pointer, "unused", utf8_detail, request_id)
}

fn invalid_request(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        Some(detail),
        request_id,
        None,
    )
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
    outcome: CheckedTestConnectionOutcome,
    request_id: &str,
) -> String {
    let envelope = outcome_to_ffi(outcome, request_id.to_string());
    match envelope {
        Ok(value) => value.to_json().expect("test envelope JSON"),
        Err(error) => super::host_key_ffi_protocol::HostKeyFfiEnvelope::new(
            error.request_id.clone(),
            HostKeyFfiResult::Error(error),
        )
        .expect("test error envelope")
        .to_json()
        .expect("test error JSON"),
    }
}

#[cfg(test)]
pub(crate) fn error_payload_for_tests(
    error: &CheckedTestConnectionError,
    request_id: &str,
) -> HostKeyFfiErrorPayload {
    connection_error_payload(error, Some(request_id.to_string()))
}
