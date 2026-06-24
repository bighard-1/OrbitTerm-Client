use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_docker_ffi::{
    docker_action_response, docker_error_payload, docker_list_response, docker_logs_response,
    docker_stats_response, orbit_docker_action_checked_v1, orbit_docker_list_checked_v1,
    orbit_docker_logs_checked_v1,
};
use super::{
    DockerActionResultPayload, DockerContainerPayload, DockerContainersPayload, DockerLogsPayload,
    DockerStatsItemPayload, DockerStatsPayload, HostKeyFfiEnvelope, HostKeyFfiResultKind,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_docker::CheckedDockerError;
use crate::checked_exec::CheckedExecError;
use crate::docker_validator::DockerValidationError;
use crate::security::{
    fingerprint_sha256, HostIdentity, SessionLifecycleState, SessionSecurityGeneration,
    TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

const REQUEST_ID: &str = "checked-docker-request";
const CONTAINER_ID: &str = "0123456789ab";

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-docker-ffi-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-docker-ffi-store"),
    }
}

fn read_and_free(pointer: *mut c_char) -> (String, Value) {
    assert!(!pointer.is_null());
    // SAFETY: Checked FFI responses are Rust-owned NUL-terminated strings.
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap()
        .to_string();
    orbit_free_string(pointer);
    let value = serde_json::from_str(&json).unwrap();
    (json, value)
}

fn containers(base_session_id: u64) -> DockerContainersPayload {
    DockerContainersPayload::new(
        base_session_id,
        vec![DockerContainerPayload {
            id: CONTAINER_ID.to_string(),
            name: "web".to_string(),
            image: "nginx".to_string(),
            state: "running".to_string(),
            status: "Up".to_string(),
            running_for: "1m".to_string(),
        }],
    )
    .unwrap()
}

fn stats(base_session_id: u64) -> DockerStatsPayload {
    DockerStatsPayload::new(
        base_session_id,
        vec![DockerStatsItemPayload::new(
            CONTAINER_ID.to_string(),
            "web".to_string(),
            1.5,
            25.0,
            "10MiB / 40MiB".to_string(),
            "1kB / 2kB".to_string(),
            "0B / 0B".to_string(),
            2,
        )
        .unwrap()],
    )
    .unwrap()
}

#[test]
fn checked_docker_success_envelopes_round_trip_request_and_string_ids() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let base_session_id = (1_u64 << 48) | 44;

    let cases = [
        docker_list_response(base_session_id, request_id.as_ptr(), move |_| async move {
            Ok(containers(base_session_id))
        }),
        docker_stats_response(base_session_id, request_id.as_ptr(), move |_| async move {
            Ok(stats(base_session_id))
        }),
        docker_logs_response(
            base_session_id,
            CString::new(CONTAINER_ID).unwrap().as_ptr(),
            100,
            request_id.as_ptr(),
            move |_, container_id, _| async move {
                Ok(
                    DockerLogsPayload::new(base_session_id, container_id, "log line".into())
                        .unwrap(),
                )
            },
        ),
        docker_action_response(
            base_session_id,
            CString::new(CONTAINER_ID).unwrap().as_ptr(),
            CString::new("restart").unwrap().as_ptr(),
            request_id.as_ptr(),
            move |_, container_id, action| async move {
                Ok(DockerActionResultPayload::new(base_session_id, container_id, action).unwrap())
            },
        ),
    ];

    for pointer in cases {
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["request_id"], REQUEST_ID);
        assert_eq!(
            value["data"]["base_session_id"],
            base_session_id.to_string()
        );
        let envelope = HostKeyFfiEnvelope::from_json(&json).unwrap();
        assert!(matches!(
            envelope.kind(),
            HostKeyFfiResultKind::DockerContainers
                | HostKeyFfiResultKind::DockerStats
                | HostKeyFfiResultKind::DockerLogs
                | HostKeyFfiResultKind::DockerActionResult
        ));
        for forbidden in ["password", "private_key", "public_key", "known_hosts"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn ffi_rejects_null_invalid_utf8_control_zero_and_null_parameters() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let container_id = CString::new(CONTAINER_ID).unwrap();

    let (_, null_request) = read_and_free(orbit_docker_list_checked_v1(1, std::ptr::null()));
    assert_eq!(null_request["error"]["code"], "invalid_request");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_request) = read_and_free(orbit_docker_list_checked_v1(
        1,
        invalid_utf8.as_ptr().cast(),
    ));
    assert_eq!(invalid_request["error"]["code"], "invalid_utf8");

    let control = CString::new("line\nbreak").unwrap();
    let (_, control) = read_and_free(orbit_docker_list_checked_v1(1, control.as_ptr()));
    assert_eq!(control["error"]["code"], "invalid_request");

    let (_, zero) = read_and_free(orbit_docker_list_checked_v1(0, request_id.as_ptr()));
    assert_eq!(zero["error"]["code"], "invalid_request");

    let (_, null_container) = read_and_free(orbit_docker_logs_checked_v1(
        1,
        std::ptr::null(),
        100,
        request_id.as_ptr(),
    ));
    assert_eq!(null_container["error"]["code"], "invalid_request");

    let (_, invalid_container_utf8) = read_and_free(orbit_docker_logs_checked_v1(
        1,
        invalid_utf8.as_ptr().cast(),
        100,
        request_id.as_ptr(),
    ));
    assert_eq!(invalid_container_utf8["error"]["code"], "invalid_utf8");

    let (_, null_action) = read_and_free(orbit_docker_action_checked_v1(
        1,
        container_id.as_ptr(),
        std::ptr::null(),
        request_id.as_ptr(),
    ));
    assert_eq!(null_action["error"]["code"], "invalid_request");

    let (_, invalid_action_utf8) = read_and_free(orbit_docker_action_checked_v1(
        1,
        container_id.as_ptr(),
        invalid_utf8.as_ptr().cast(),
        request_id.as_ptr(),
    ));
    assert_eq!(invalid_action_utf8["error"]["code"], "invalid_utf8");
}

#[test]
fn exported_checked_docker_rejects_unknown_and_legacy_sessions() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let (_, unknown) = read_and_free(orbit_docker_list_checked_v1(
        (1_u64 << 48) | 999_999,
        request_id.as_ptr(),
    ));
    assert_eq!(unknown["error"]["code"], "session_not_found");

    let base = insert_synthetic_base_session_for_tests(
        "example.com",
        "root",
        SessionSecurityGeneration::LegacyUnverified,
    )
    .unwrap();
    let (_, legacy) = read_and_free(orbit_docker_list_checked_v1(base.id, request_id.as_ptr()));
    remove_synthetic_base_session_for_tests(base.id);
    assert_eq!(legacy["error"]["code"], "legacy_session_not_allowed");

    for (state, expected) in [
        (SessionLifecycleState::Draining, "session_draining"),
        (SessionLifecycleState::Terminating, "session_terminating"),
        (SessionLifecycleState::Closed, "session_closed"),
    ] {
        let base =
            insert_synthetic_base_session_for_tests("example.com", "root", verified_generation())
                .unwrap();
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        let (_, response) =
            read_and_free(orbit_docker_list_checked_v1(base.id, request_id.as_ptr()));
        remove_synthetic_base_session_for_tests(base.id);
        assert_eq!(response["error"]["code"], expected);
    }
}

#[test]
fn exported_logs_and_action_reject_invalid_typed_inputs() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let container_id = CString::new(CONTAINER_ID).unwrap();
    let malicious_id = CString::new("0123456789ab;id").unwrap();
    let malicious_action = CString::new("start;id").unwrap();

    let (_, invalid_id) = read_and_free(orbit_docker_logs_checked_v1(
        1,
        malicious_id.as_ptr(),
        100,
        request_id.as_ptr(),
    ));
    assert_eq!(invalid_id["error"]["code"], "docker_invalid_container_id");

    let (_, invalid_tail) = read_and_free(orbit_docker_logs_checked_v1(
        1,
        container_id.as_ptr(),
        10_001,
        request_id.as_ptr(),
    ));
    assert_eq!(invalid_tail["error"]["code"], "docker_invalid_logs_tail");

    let (_, invalid_action) = read_and_free(orbit_docker_action_checked_v1(
        1,
        container_id.as_ptr(),
        malicious_action.as_ptr(),
        request_id.as_ptr(),
    ));
    assert_eq!(invalid_action["error"]["code"], "docker_invalid_action");
}

#[test]
fn validation_exec_and_parse_errors_map_to_stable_redacted_codes() {
    let request_id = Some(REQUEST_ID.to_string());
    let cases = [
        (
            CheckedDockerError::Validation(DockerValidationError::InvalidContainerIdCharacter),
            "docker_invalid_container_id",
        ),
        (
            CheckedDockerError::Validation(DockerValidationError::InvalidContainerName),
            "docker_invalid_container_name",
        ),
        (
            CheckedDockerError::Validation(DockerValidationError::InvalidAction),
            "docker_invalid_action",
        ),
        (
            CheckedDockerError::Validation(DockerValidationError::InvalidTail),
            "docker_invalid_logs_tail",
        ),
        (
            CheckedDockerError::Validation(DockerValidationError::InvalidMemoryLimit),
            "docker_invalid_update_option",
        ),
        (
            CheckedDockerError::Exec(CheckedExecError::Timeout),
            "exec_timeout",
        ),
        (
            CheckedDockerError::Exec(CheckedExecError::CommandFailed { exit_status: 1 }),
            "docker_command_failed",
        ),
        (CheckedDockerError::ParseFailed, "docker_parse_failed"),
    ];
    for (error, expected) in cases {
        let payload = docker_error_payload(error, request_id.clone());
        assert_eq!(serde_json::to_value(&payload).unwrap()["code"], expected);
        let output = format!("{payload:?}");
        for forbidden in ["stolen-secret", "password", "private_key", "known_hosts"] {
            assert!(!output.contains(forbidden));
        }
    }
}

#[test]
fn header_declares_checked_docker_and_preserves_legacy_signatures() {
    let header = include_str!("../../include/orbit_core.h");
    for symbol in [
        "orbit_docker_list_checked_v1",
        "orbit_docker_stats_checked_v1",
        "orbit_docker_logs_checked_v1",
        "orbit_docker_action_checked_v1",
    ] {
        assert!(header.contains(symbol));
    }
    assert!(header.contains("char *orbit_fetch_docker_containers(uint64_t session_id);"));
    assert!(header.contains("char *orbit_fetch_docker_stats(uint64_t session_id);"));
    assert!(header.contains(
        "char *orbit_docker_action(uint64_t session_id, const char *container_id, const char *action);"
    ));
    assert!(header.contains(
        "char *orbit_fetch_docker_logs(uint64_t session_id, const char *container_id, uint32_t tail_lines);"
    ));
}
