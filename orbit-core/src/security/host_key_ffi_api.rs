use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
#[cfg(test)]
use std::sync::Mutex;
use std::time::SystemTime;

#[cfg(test)]
use super::host_key_challenge_registry::PendingHostKeyChallengeRegistry;
use super::host_key_challenge_registry::{ChallengeId, ChallengeRegistryError};
use super::host_key_challenge_service::{
    shared_host_key_challenge_service, HostKeyChallengeServiceError,
};
#[cfg(test)]
use super::host_key_ffi_error::HostKeyFfiProtocolError;
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_lifecycle::{
    HostKeyChallengeStatusPayload, HostKeyCleanupCompletedPayload, HostKeyProtocolVersionPayload,
};
use super::host_key_ffi_protocol::HostKeyTrustPersistedPayload;
use super::host_key_ffi_protocol::{HostKeyFfiEnvelope, HostKeyFfiResult};
use super::host_key_trust_persistence::{
    persist_snapshot_to_known_hosts, HostKeyTrustPersistenceError,
};

pub(crate) type FfiOperationResult = Result<HostKeyFfiEnvelope, HostKeyFfiErrorPayload>;

const DEFAULT_TRUST_COMMENT: &str = "OrbitTerm";
const MAX_KNOWN_HOSTS_PATH_BYTES: usize = 4096;

const FALLBACK_INTERNAL_ERROR_JSON: &str = r#"{"schema_version":1,"request_id":null,"kind":"error","data":null,"error":{"code":"ffi_internal_error","message_key":"error.ffi.internal","detail_code":"response_encoding_failed","retryable":false,"request_id":null,"challenge_id":null}}"#;

#[no_mangle]
pub extern "C" fn orbit_hostkey_challenge_accept_v1(challenge_id: *const c_char) -> *mut c_char {
    ffi_response(|| {
        let challenge_id = parse_challenge_id(challenge_id)?;
        let accepted = shared_host_key_challenge_service()
            .accept(challenge_id.as_str(), SystemTime::now())
            .map_err(|error| service_error_payload(&error, Some(&challenge_id)))?;
        let request_id = accepted.request_id.clone();
        success_envelope(
            request_id,
            HostKeyFfiResult::HostKeyChallengeAccepted((&accepted).into()),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_hostkey_challenge_accept_and_persist_v1(
    challenge_id: *const c_char,
    known_hosts_path: *const c_char,
    comment: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let challenge_id = parse_challenge_id(challenge_id)?;
        let known_hosts_path = parse_known_hosts_path(known_hosts_path)?;
        let comment = parse_optional_comment(comment)?;

        let snapshot = shared_host_key_challenge_service()
            .snapshot_pending(challenge_id.as_str(), SystemTime::now())
            .map_err(|error| service_error_payload(&error, Some(&challenge_id)))?;

        let outcome = persist_snapshot_to_known_hosts(
            &snapshot,
            &known_hosts_path,
            comment.as_deref().or(Some(DEFAULT_TRUST_COMMENT)),
        )
        .map_err(|error| persistence_error_payload(&error, &challenge_id))?;

        let persisted = shared_host_key_challenge_service()
            .mark_persisted_if_pending(&snapshot, SystemTime::now())
            .map_err(|_| {
                HostKeyFfiErrorPayload::new(
                    HostKeyFfiErrorCode::ChallengeMismatch,
                    Some("trust_persisted_registry_commit_failed"),
                    snapshot.request_id.clone(),
                    Some(challenge_id.as_str().to_string()),
                )
            })?;

        let request_id = persisted.request_id.clone();
        success_envelope(
            request_id,
            HostKeyFfiResult::HostKeyTrustPersisted(HostKeyTrustPersistedPayload::from_persisted(
                &persisted, outcome,
            )),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_hostkey_challenge_reject_v1(challenge_id: *const c_char) -> *mut c_char {
    ffi_response(|| {
        let challenge_id = parse_challenge_id(challenge_id)?;
        let rejected = shared_host_key_challenge_service()
            .reject(challenge_id.as_str(), SystemTime::now())
            .map_err(|error| service_error_payload(&error, Some(&challenge_id)))?;
        let request_id = rejected.request_id.clone();
        success_envelope(
            request_id,
            HostKeyFfiResult::HostKeyRejected((&rejected).into()),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_hostkey_challenge_status_v1(challenge_id: *const c_char) -> *mut c_char {
    ffi_response(|| {
        let challenge_id = parse_challenge_id(challenge_id)?;
        let state = shared_host_key_challenge_service()
            .status(challenge_id.as_str(), SystemTime::now())
            .map_err(|error| service_error_payload(&error, Some(&challenge_id)))?
            .ok_or_else(|| {
                HostKeyFfiErrorPayload::from_registry_error(
                    &ChallengeRegistryError::ChallengeNotFound,
                    None,
                    Some(challenge_id.as_str().to_string()),
                )
            })?;
        success_envelope(
            None,
            HostKeyFfiResult::HostKeyChallengeStatus(HostKeyChallengeStatusPayload::new(
                challenge_id.as_str().to_string(),
                state,
            )),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_hostkey_challenge_cleanup_expired_v1() -> *mut c_char {
    ffi_response(|| {
        let expired_count = shared_host_key_challenge_service()
            .cleanup_expired(SystemTime::now())
            .map_err(|error| service_error_payload(&error, None))?;
        let expired_count =
            u64::try_from(expired_count).map_err(|_| internal_error("cleanup_count_overflow"))?;
        success_envelope(
            None,
            HostKeyFfiResult::HostKeyCleanupCompleted(HostKeyCleanupCompletedPayload {
                expired_count,
            }),
        )
    })
}

#[no_mangle]
pub extern "C" fn orbit_hostkey_protocol_version_v1() -> *mut c_char {
    ffi_response(|| {
        success_envelope(
            None,
            HostKeyFfiResult::ProtocolVersion(HostKeyProtocolVersionPayload::current()),
        )
    })
}

fn parse_challenge_id(pointer: *const c_char) -> Result<ChallengeId, HostKeyFfiErrorPayload> {
    let value = parse_required_c_string(pointer, "null_challenge_id", "challenge_id_invalid_utf8")?;
    ChallengeId::parse(&value).map_err(|_| {
        HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::InvalidRequest,
            Some("invalid_challenge_id"),
            None,
            None,
        )
    })
}

fn parse_known_hosts_path(pointer: *const c_char) -> Result<PathBuf, HostKeyFfiErrorPayload> {
    let value = parse_required_c_string(
        pointer,
        "null_known_hosts_path",
        "known_hosts_path_invalid_utf8",
    )?;
    if value.is_empty() || value.len() > MAX_KNOWN_HOSTS_PATH_BYTES {
        return Err(HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::InvalidRequest,
            Some("invalid_known_hosts_path"),
            None,
            None,
        ));
    }
    Ok(PathBuf::from(value))
}

fn parse_optional_comment(
    pointer: *const c_char,
) -> Result<Option<String>, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Ok(None);
    }
    parse_required_c_string(pointer, "null_comment", "comment_invalid_utf8").map(Some)
}

fn parse_required_c_string(
    pointer: *const c_char,
    null_detail: &'static str,
    utf8_detail: &'static str,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::InvalidRequest,
            Some(null_detail),
            None,
            None,
        ));
    }
    // SAFETY: A non-null input pointer is borrowed only for this call. The C
    // caller remains responsible for providing a readable NUL-terminated string.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some(utf8_detail),
                None,
                None,
            )
        })
}

pub(crate) fn success_envelope(
    request_id: Option<String>,
    result: HostKeyFfiResult,
) -> FfiOperationResult {
    HostKeyFfiEnvelope::new(request_id.clone(), result)
        .map_err(|error| error.to_error_payload(request_id))
}

fn service_error_payload(
    error: &HostKeyChallengeServiceError,
    challenge_id: Option<&ChallengeId>,
) -> HostKeyFfiErrorPayload {
    match error {
        HostKeyChallengeServiceError::Registry(error) => {
            HostKeyFfiErrorPayload::from_registry_error(
                error,
                None,
                challenge_id.map(|value| value.as_str().to_string()),
            )
        }
        HostKeyChallengeServiceError::Unavailable => internal_error("registry_lock_failed"),
    }
}

fn internal_error(detail_code: &'static str) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::FfiInternalError,
        Some(detail_code),
        None,
        None,
    )
}

fn persistence_error_payload(
    error: &HostKeyTrustPersistenceError,
    challenge_id: &ChallengeId,
) -> HostKeyFfiErrorPayload {
    let challenge_id = Some(challenge_id.as_str().to_string());
    match error {
        HostKeyTrustPersistenceError::InvalidPath => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::InvalidRequest,
            Some("invalid_known_hosts_path"),
            None,
            challenge_id,
        ),
        HostKeyTrustPersistenceError::ParentDirectoryCreateFailed { kind }
        | HostKeyTrustPersistenceError::ParentPermissionFailed { kind } => {
            let code = if *kind == std::io::ErrorKind::PermissionDenied {
                HostKeyFfiErrorCode::KnownHostsPermissionDenied
            } else {
                HostKeyFfiErrorCode::KnownHostsSaveFailed
            };
            HostKeyFfiErrorPayload::new(code, Some("known_hosts_parent_failed"), None, challenge_id)
        }
        HostKeyTrustPersistenceError::Store(store_error) => {
            HostKeyFfiErrorPayload::from_store_error(store_error, None, challenge_id)
        }
    }
}

pub(crate) fn ffi_response(operation: impl FnOnce() -> FfiOperationResult) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let json = match operation() {
            Ok(envelope) => serialize_envelope(envelope),
            Err(error) => serialize_error(error),
        };
        string_to_owned_c_pointer(json)
    })) {
        Ok(pointer) => pointer,
        Err(_) => string_to_owned_c_pointer(serialize_error(internal_error("panic_caught"))),
    }
}

fn serialize_error(error: HostKeyFfiErrorPayload) -> String {
    let request_id = error.request_id.clone();
    let envelope = HostKeyFfiEnvelope {
        schema_version: super::host_key_ffi_protocol::HOST_KEY_FFI_SCHEMA_VERSION,
        request_id,
        result: HostKeyFfiResult::Error(error),
    };
    serialize_envelope(envelope)
}

fn serialize_envelope(envelope: HostKeyFfiEnvelope) -> String {
    envelope
        .to_json()
        .unwrap_or_else(|_| FALLBACK_INTERNAL_ERROR_JSON.to_string())
}

fn string_to_owned_c_pointer(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or_else(|_| {
            CString::new(FALLBACK_INTERNAL_ERROR_JSON)
                .map(CString::into_raw)
                .unwrap_or(ptr::null_mut())
        })
}

#[cfg(test)]
pub(crate) fn reset_registry_for_tests(
    replacement: PendingHostKeyChallengeRegistry,
) -> Result<(), HostKeyFfiProtocolError> {
    shared_host_key_challenge_service()
        .replace_registry(replacement)
        .map_err(|_| HostKeyFfiProtocolError::SerializationFailed)
}

#[cfg(test)]
pub(crate) fn challenge_service_for_tests(
) -> &'static super::host_key_challenge_service::HostKeyChallengeService {
    shared_host_key_challenge_service()
}

#[cfg(test)]
pub(crate) static HOST_KEY_FFI_TEST_SERIAL: Mutex<()> = Mutex::new(());
