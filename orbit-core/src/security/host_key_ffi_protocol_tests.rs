use std::io;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use super::{
    fingerprint_sha256_from_base64, AddTrustedKeyOutcome, ChallengeId, ChallengeRegistryError,
    HostIdentity, HostKeyBlock, HostKeyBlockReason, HostKeyChallengePayload,
    HostKeyChallengeReason, HostKeyConnectedPayload, HostKeyConnectionTestSucceededPayload,
    HostKeyFfiBlockReasonCode, HostKeyFfiEnvelope, HostKeyFfiErrorCode, HostKeyFfiErrorPayload,
    HostKeyFfiKnownState, HostKeyFfiProtocolError, HostKeyFfiResult, HostKeyFfiResultKind,
    HostKeyFfiSecurityGeneration, HostKeyRejectedPayload, HostKeyTrustPersistedPayload,
    HostKeyVerificationError, KnownHostMarker, KnownHostRecordSummary, KnownHostsStoreError,
    PendingChallengeState, PersistedHostKeyChallenge, RegisteredHostKeyChallenge,
    RejectedHostKeyChallenge, SessionSecurityGeneration, VerifiedHostKey,
    HOST_KEY_FFI_SCHEMA_VERSION,
};

const KEY_A: &str = "AQIDBA==";
const CHALLENGE_ID: &str = "AAAAAAAAAAAAAAAAAAAAAA";
const REQUEST_ID: &str = "request-123";
const CREATED_AT: SystemTime = SystemTime::UNIX_EPOCH;

fn identity() -> HostIdentity {
    HostIdentity::parse("Example.COM", 22).unwrap()
}

fn fingerprint() -> String {
    fingerprint_sha256_from_base64(KEY_A).unwrap()
}

fn registered_challenge() -> RegisteredHostKeyChallenge {
    RegisteredHostKeyChallenge {
        challenge_id: ChallengeId::parse(CHALLENGE_ID).unwrap(),
        request_id: Some(REQUEST_ID.to_string()),
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint(),
        created_at: CREATED_AT,
        expires_at: CREATED_AT + Duration::from_secs(120),
        reason_code: HostKeyChallengeReason::UnknownHostKey,
        store_generation_hint: Some("store-generation-a".to_string()),
        reused_existing_challenge: false,
        related_request_count: 1,
    }
}

fn verified_key() -> VerifiedHostKey {
    VerifiedHostKey {
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint(),
        matched_record: KnownHostRecordSummary {
            line_number: 1,
            marker: KnownHostMarker::None,
        },
    }
}

fn persisted_challenge() -> PersistedHostKeyChallenge {
    PersistedHostKeyChallenge {
        challenge_id: ChallengeId::parse(CHALLENGE_ID).unwrap(),
        request_id: Some(REQUEST_ID.to_string()),
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint(),
        persisted_at: CREATED_AT + Duration::from_secs(5),
    }
}

fn rejected_challenge() -> RejectedHostKeyChallenge {
    RejectedHostKeyChallenge {
        challenge_id: ChallengeId::parse(CHALLENGE_ID).unwrap(),
        request_id: Some(REQUEST_ID.to_string()),
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint(),
        rejected_at: CREATED_AT + Duration::from_secs(5),
    }
}

fn round_trip(envelope: &HostKeyFfiEnvelope) -> (String, HostKeyFfiEnvelope) {
    let json = envelope.to_json().unwrap();
    let decoded = HostKeyFfiEnvelope::from_json(&json).unwrap();
    (json, decoded)
}

#[test]
fn challenge_envelope_uses_stable_versioned_snake_case_wire_shape() {
    let payload = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyChallenge(payload),
    )
    .unwrap();
    let (json, decoded) = round_trip(&envelope);
    let value: Value = serde_json::from_str(&json).unwrap();

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "host_key_challenge");
    assert_eq!(value["data"]["challenge_id"], CHALLENGE_ID);
    assert_eq!(value["data"]["reason_code"], "unknown_host");
    assert_eq!(value["data"]["known_state"], "unknown");
    assert_eq!(value["data"]["can_trust"], true);
    assert_eq!(value["data"]["can_replace"], false);
    assert_eq!(value["data"]["expires_at_unix"], 120);
    assert_eq!(value["data"]["reused_existing_challenge"], false);
    assert_eq!(value["data"]["related_request_count"], 1);
    assert!(value["data"].get("related_requests").is_none());
    assert!(value["error"].is_null());
    assert_eq!(decoded, envelope);
}

#[test]
fn reused_challenge_fields_are_additive_and_legacy_payloads_still_decode() {
    let mut registered = registered_challenge();
    registered.request_id = Some("request-current".to_string());
    registered.reused_existing_challenge = true;
    registered.related_request_count = 3;
    let payload = HostKeyChallengePayload::from_registered(&registered).unwrap();
    let envelope = HostKeyFfiEnvelope::new(
        Some("request-current".to_string()),
        HostKeyFfiResult::HostKeyChallenge(payload),
    )
    .unwrap();
    let json = envelope.to_json().unwrap();
    let value: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(value["data"]["reused_existing_challenge"], true);
    assert_eq!(value["data"]["related_request_count"], 3);
    assert!(!json.contains("related_requests"));
    assert!(!json.contains(KEY_A));
    assert!(!json.contains("known_hosts_path"));

    let mut legacy = value;
    legacy["data"]
        .as_object_mut()
        .unwrap()
        .remove("reused_existing_challenge");
    legacy["data"]
        .as_object_mut()
        .unwrap()
        .remove("related_request_count");
    let decoded = HostKeyFfiEnvelope::from_json(&legacy.to_string()).unwrap();
    let HostKeyFfiResult::HostKeyChallenge(decoded_payload) = decoded.result else {
        panic!("challenge payload");
    };
    assert!(!decoded_payload.reused_existing_challenge);
    assert_eq!(decoded_payload.related_request_count, 0);
}

#[test]
fn blocked_changed_envelope_contains_old_and_new_fingerprints() {
    let block = HostKeyBlock {
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        presented_fingerprint_sha256: fingerprint_sha256_from_base64("BQYHCA==").unwrap(),
        reason_code: HostKeyBlockReason::Changed,
        previous_fingerprint_sha256: Some(fingerprint()),
    };
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyBlocked((&block).into()),
    )
    .unwrap();
    let (json, decoded) = round_trip(&envelope);
    let value: Value = serde_json::from_str(&json).unwrap();

    assert_eq!(value["kind"], "host_key_blocked");
    assert_eq!(value["data"]["reason_code"], "changed");
    assert_eq!(value["data"]["known_state"], "changed");
    assert_eq!(value["data"]["can_trust"], false);
    assert_eq!(value["data"]["can_replace"], true);
    assert_eq!(value["data"]["message_key"], "host_key.changed");
    assert_eq!(decoded, envelope);
}

#[test]
fn revoked_and_certificate_authority_reasons_are_distinct() {
    for (reason, expected_code, expected_state) in [
        (
            HostKeyBlockReason::Revoked,
            "revoked",
            HostKeyFfiKnownState::Revoked,
        ),
        (
            HostKeyBlockReason::CertificateAuthorityUnsupported,
            "cert_authority_unsupported",
            HostKeyFfiKnownState::Unsupported,
        ),
    ] {
        let block = HostKeyBlock {
            host_identity: identity(),
            key_algorithm: "ssh-ed25519".to_string(),
            presented_fingerprint_sha256: fingerprint(),
            reason_code: reason,
            previous_fingerprint_sha256: None,
        };
        let payload: super::HostKeyBlockedPayload = (&block).into();
        assert_eq!(payload.known_state, expected_state);
        let json = serde_json::to_value(payload).unwrap();
        assert_eq!(json["reason_code"], expected_code);
    }
}

#[test]
fn changed_without_previous_trusted_fingerprint_remains_blocked_without_replace_capability() {
    let block = HostKeyBlock {
        host_identity: identity(),
        key_algorithm: "ssh-ed25519".to_string(),
        presented_fingerprint_sha256: fingerprint(),
        reason_code: HostKeyBlockReason::Changed,
        previous_fingerprint_sha256: None,
    };
    let payload: super::HostKeyBlockedPayload = (&block).into();
    assert!(!payload.can_trust);
    assert!(!payload.can_replace);
    assert!(HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyBlocked(payload)
    )
    .is_ok());
}

#[test]
fn connected_and_connection_test_payloads_round_trip() {
    let connected = HostKeyConnectedPayload::from_verified(42, &verified_key()).unwrap();
    let connected_envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::Connected(connected),
    )
    .unwrap();
    let (connected_json, connected_decoded) = round_trip(&connected_envelope);
    let value: Value = serde_json::from_str(&connected_json).unwrap();
    assert_eq!(value["kind"], "connected");
    assert_eq!(value["data"]["session_id"], 42);
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(connected_decoded, connected_envelope);

    let tested = HostKeyConnectionTestSucceededPayload::from_verified(&verified_key());
    let tested_envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::ConnectionTestSucceeded(tested),
    )
    .unwrap();
    let (tested_json, tested_decoded) = round_trip(&tested_envelope);
    assert!(tested_json.contains("\"kind\":\"connection_test_succeeded\""));
    assert_eq!(tested_decoded, tested_envelope);
}

#[test]
fn persisted_and_rejected_payloads_exclude_public_key() {
    let persisted = HostKeyTrustPersistedPayload::from_persisted(
        &persisted_challenge(),
        AddTrustedKeyOutcome::Added,
    );
    let persisted_envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyTrustPersisted(persisted),
    )
    .unwrap();
    let (persisted_json, persisted_decoded) = round_trip(&persisted_envelope);
    assert!(persisted_json.contains("\"status\":\"trusted_added\""));
    assert!(!persisted_json.contains(KEY_A));
    assert_eq!(persisted_decoded, persisted_envelope);

    let rejected = HostKeyRejectedPayload::from(&rejected_challenge());
    let rejected_envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyRejected(rejected),
    )
    .unwrap();
    let (rejected_json, rejected_decoded) = round_trip(&rejected_envelope);
    assert!(rejected_json.contains("\"status\":\"rejected\""));
    assert!(!rejected_json.contains(KEY_A));
    assert_eq!(rejected_decoded, rejected_envelope);
}

#[test]
fn error_envelope_has_error_only_and_round_trips_identifiers() {
    let payload = HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::ChallengeExpired,
        Some("challenge_expired"),
        Some(REQUEST_ID.to_string()),
        Some(CHALLENGE_ID.to_string()),
    );
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::Error(payload),
    )
    .unwrap();
    let (json, decoded) = round_trip(&envelope);
    let value: Value = serde_json::from_str(&json).unwrap();

    assert_eq!(value["kind"], "error");
    assert!(value["data"].is_null());
    assert_eq!(value["error"]["code"], "challenge_expired");
    assert_eq!(value["error"]["request_id"], REQUEST_ID);
    assert_eq!(value["error"]["challenge_id"], CHALLENGE_ID);
    assert_eq!(value["error"]["retryable"], true);
    assert_eq!(decoded, envelope);
}

#[test]
fn all_result_kinds_have_stable_strings() {
    let cases = [
        (HostKeyFfiResultKind::Connected, "connected"),
        (
            HostKeyFfiResultKind::ConnectionTestSucceeded,
            "connection_test_succeeded",
        ),
        (
            HostKeyFfiResultKind::SftpChannelOpened,
            "sftp_channel_opened",
        ),
        (
            HostKeyFfiResultKind::TerminalChannelOpened,
            "terminal_channel_opened",
        ),
        (HostKeyFfiResultKind::ExecResult, "exec_result"),
        (HostKeyFfiResultKind::MonitorSnapshot, "monitor_snapshot"),
        (HostKeyFfiResultKind::DockerContainers, "docker_containers"),
        (HostKeyFfiResultKind::DockerStats, "docker_stats"),
        (HostKeyFfiResultKind::DockerLogs, "docker_logs"),
        (
            HostKeyFfiResultKind::DockerActionResult,
            "docker_action_result",
        ),
        (HostKeyFfiResultKind::HostKeyChallenge, "host_key_challenge"),
        (
            HostKeyFfiResultKind::HostKeyChallengeAccepted,
            "host_key_challenge_accepted",
        ),
        (
            HostKeyFfiResultKind::HostKeyChallengeStatus,
            "host_key_challenge_status",
        ),
        (
            HostKeyFfiResultKind::HostKeyCleanupCompleted,
            "host_key_cleanup_completed",
        ),
        (HostKeyFfiResultKind::HostKeyBlocked, "host_key_blocked"),
        (
            HostKeyFfiResultKind::HostKeyTrustPersisted,
            "host_key_trust_persisted",
        ),
        (HostKeyFfiResultKind::HostKeyRejected, "host_key_rejected"),
        (HostKeyFfiResultKind::ProtocolVersion, "protocol_version"),
        (HostKeyFfiResultKind::Error, "error"),
    ];
    for (kind, expected) in cases {
        assert_eq!(serde_json::to_value(kind).unwrap(), expected);
    }
}

#[test]
fn all_error_codes_have_stable_strings_and_message_keys() {
    let cases = [
        (HostKeyFfiErrorCode::HostKeyUnknown, "host_key_unknown"),
        (HostKeyFfiErrorCode::HostKeyChanged, "host_key_changed"),
        (HostKeyFfiErrorCode::HostKeyRevoked, "host_key_revoked"),
        (
            HostKeyFfiErrorCode::HostKeyUnsupported,
            "host_key_unsupported",
        ),
        (HostKeyFfiErrorCode::HostKeyInvalid, "host_key_invalid"),
        (
            HostKeyFfiErrorCode::KnownHostsReadFailed,
            "known_hosts_read_failed",
        ),
        (
            HostKeyFfiErrorCode::KnownHostsSaveFailed,
            "known_hosts_save_failed",
        ),
        (
            HostKeyFfiErrorCode::KnownHostsPermissionDenied,
            "known_hosts_permission_denied",
        ),
        (
            HostKeyFfiErrorCode::KnownHostsFileTooLarge,
            "known_hosts_file_too_large",
        ),
        (
            HostKeyFfiErrorCode::ChallengeNotFound,
            "challenge_not_found",
        ),
        (HostKeyFfiErrorCode::ChallengeExpired, "challenge_expired"),
        (
            HostKeyFfiErrorCode::ChallengeAlreadyResolved,
            "challenge_already_resolved",
        ),
        (HostKeyFfiErrorCode::ChallengeMismatch, "challenge_mismatch"),
        (
            HostKeyFfiErrorCode::PendingLimitReached,
            "pending_limit_reached",
        ),
        (
            HostKeyFfiErrorCode::PerHostPendingLimitReached,
            "per_host_pending_limit_reached",
        ),
        (
            HostKeyFfiErrorCode::RelatedRequestLimitReached,
            "related_request_limit_reached",
        ),
        (HostKeyFfiErrorCode::InvalidRequest, "invalid_request"),
        (HostKeyFfiErrorCode::InvalidJson, "invalid_json"),
        (HostKeyFfiErrorCode::InvalidUtf8, "invalid_utf8"),
        (HostKeyFfiErrorCode::FfiInternalError, "ffi_internal_error"),
        (HostKeyFfiErrorCode::SshConnectFailed, "ssh_connect_failed"),
        (HostKeyFfiErrorCode::SshAuthFailed, "ssh_auth_failed"),
        (HostKeyFfiErrorCode::SshTimeout, "ssh_timeout"),
        (
            HostKeyFfiErrorCode::SessionPoolFailed,
            "session_pool_failed",
        ),
        (HostKeyFfiErrorCode::SessionNotFound, "session_not_found"),
        (
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
            "legacy_session_not_allowed",
        ),
        (
            HostKeyFfiErrorCode::VerifiedSessionRequired,
            "verified_session_required",
        ),
        (
            HostKeyFfiErrorCode::SecurityGenerationMismatch,
            "security_generation_mismatch",
        ),
        (HostKeyFfiErrorCode::SessionDraining, "session_draining"),
        (
            HostKeyFfiErrorCode::SessionTerminating,
            "session_terminating",
        ),
        (HostKeyFfiErrorCode::SessionClosed, "session_closed"),
        (
            HostKeyFfiErrorCode::ChannelOpenFailed,
            "channel_open_failed",
        ),
        (HostKeyFfiErrorCode::InvalidPtySize, "invalid_pty_size"),
        (HostKeyFfiErrorCode::PtyRequestFailed, "pty_request_failed"),
        (HostKeyFfiErrorCode::ShellStartFailed, "shell_start_failed"),
        (
            HostKeyFfiErrorCode::SubsystemRequestFailed,
            "subsystem_request_failed",
        ),
        (
            HostKeyFfiErrorCode::SftpRegistrationFailed,
            "sftp_registration_failed",
        ),
        (HostKeyFfiErrorCode::InvalidCommand, "invalid_command"),
        (HostKeyFfiErrorCode::CommandTooLarge, "command_too_large"),
        (
            HostKeyFfiErrorCode::InvalidExecOptions,
            "invalid_exec_options",
        ),
        (
            HostKeyFfiErrorCode::ExecRequestFailed,
            "exec_request_failed",
        ),
        (HostKeyFfiErrorCode::ExecOutputFailed, "exec_output_failed"),
        (
            HostKeyFfiErrorCode::ExecOutputLimitExceeded,
            "exec_output_limit_exceeded",
        ),
        (HostKeyFfiErrorCode::ExecTimeout, "exec_timeout"),
        (
            HostKeyFfiErrorCode::ExecCommandFailed,
            "exec_command_failed",
        ),
        (
            HostKeyFfiErrorCode::MonitorSnapshotFailed,
            "monitor_snapshot_failed",
        ),
        (
            HostKeyFfiErrorCode::DockerInvalidContainerId,
            "docker_invalid_container_id",
        ),
        (
            HostKeyFfiErrorCode::DockerInvalidContainerName,
            "docker_invalid_container_name",
        ),
        (
            HostKeyFfiErrorCode::DockerInvalidAction,
            "docker_invalid_action",
        ),
        (
            HostKeyFfiErrorCode::DockerInvalidLogsTail,
            "docker_invalid_logs_tail",
        ),
        (
            HostKeyFfiErrorCode::DockerInvalidUpdateOption,
            "docker_invalid_update_option",
        ),
        (
            HostKeyFfiErrorCode::DockerCommandFailed,
            "docker_command_failed",
        ),
        (
            HostKeyFfiErrorCode::DockerParseFailed,
            "docker_parse_failed",
        ),
    ];
    for (code, expected) in cases {
        assert_eq!(serde_json::to_value(code).unwrap(), expected);
        assert!(!code.message_key().is_empty());
    }
}

#[test]
fn verification_registry_and_store_errors_map_without_string_parsing() {
    let verification = HostKeyFfiErrorPayload::from_verification_error(
        &HostKeyVerificationError::InvalidAlgorithm,
        Some(REQUEST_ID.to_string()),
    );
    assert_eq!(verification.code, HostKeyFfiErrorCode::HostKeyInvalid);
    assert_eq!(
        verification.detail_code.as_deref(),
        Some("invalid_algorithm")
    );

    let registry = HostKeyFfiErrorPayload::from_registry_error(
        &ChallengeRegistryError::ChallengeAlreadyResolved {
            state: PendingChallengeState::Rejected,
        },
        Some(REQUEST_ID.to_string()),
        Some(CHALLENGE_ID.to_string()),
    );
    assert_eq!(registry.code, HostKeyFfiErrorCode::ChallengeAlreadyResolved);
    assert_eq!(registry.detail_code.as_deref(), Some("rejected"));

    let related_limit = HostKeyFfiErrorPayload::from_registry_error(
        &ChallengeRegistryError::RelatedRequestLimitReached,
        Some(REQUEST_ID.to_string()),
        Some(CHALLENGE_ID.to_string()),
    );
    assert_eq!(
        related_limit.code,
        HostKeyFfiErrorCode::RelatedRequestLimitReached
    );
    assert_eq!(
        related_limit.detail_code.as_deref(),
        Some("related_request_limit")
    );

    let store = HostKeyFfiErrorPayload::from_store_error(
        &KnownHostsStoreError::ReadFailed {
            kind: io::ErrorKind::PermissionDenied,
        },
        Some(REQUEST_ID.to_string()),
        None,
    );
    assert_eq!(store.code, HostKeyFfiErrorCode::KnownHostsPermissionDenied);
    assert!(!store.retryable);
}

#[test]
fn store_error_mapping_never_serializes_local_path_or_source_error_text() {
    let payload = HostKeyFfiErrorPayload::from_store_error(
        &KnownHostsStoreError::AtomicReplaceFailed {
            kind: io::ErrorKind::Other,
        },
        Some(REQUEST_ID.to_string()),
        Some(CHALLENGE_ID.to_string()),
    );
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::Error(payload),
    )
    .unwrap();
    let json = envelope.to_json().unwrap();

    assert!(!json.contains("/Users/"));
    assert!(!json.contains("known_hosts_path"));
    assert!(!json.contains("PermissionDenied"));
    assert!(!json.contains(KEY_A));
}

#[test]
fn missing_required_payload_field_is_rejected() {
    let payload = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyChallenge(payload),
    )
    .unwrap();
    let mut value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
    value["data"]
        .as_object_mut()
        .unwrap()
        .remove("fingerprint_sha256");

    assert_eq!(
        HostKeyFfiEnvelope::from_json(&value.to_string()),
        Err(HostKeyFfiProtocolError::InvalidPayload)
    );
}

#[test]
fn unsupported_schema_version_is_distinguished_from_invalid_json() {
    let json = json!({
        "schema_version": 2,
        "request_id": null,
        "kind": "error",
        "data": null,
        "error": {
            "code": "invalid_request",
            "message_key": "error.request.invalid",
            "detail_code": null,
            "retryable": false,
            "request_id": null,
            "challenge_id": null
        }
    });
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json.to_string()),
        Err(HostKeyFfiProtocolError::UnsupportedSchemaVersion { received: 2 })
    );
    assert_eq!(
        HostKeyFfiEnvelope::from_json("not-json"),
        Err(HostKeyFfiProtocolError::InvalidJson)
    );
}

#[test]
fn data_and_error_mutual_exclusion_is_enforced() {
    let error = HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        None,
        Some(REQUEST_ID.to_string()),
        None,
    );
    let envelope =
        HostKeyFfiEnvelope::new(Some(REQUEST_ID.to_string()), HostKeyFfiResult::Error(error))
            .unwrap();
    let mut value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
    value["data"] = json!({ "unexpected": true });
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&value.to_string()),
        Err(HostKeyFfiProtocolError::InvalidEnvelope)
    );

    let missing_data = json!({
        "schema_version": 1,
        "request_id": REQUEST_ID,
        "kind": "connected",
        "data": null,
        "error": null
    });
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&missing_data.to_string()),
        Err(HostKeyFfiProtocolError::MissingDataPayload)
    );

    let missing_error = json!({
        "schema_version": 1,
        "request_id": REQUEST_ID,
        "kind": "error",
        "data": null,
        "error": null
    });
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&missing_error.to_string()),
        Err(HostKeyFfiProtocolError::MissingErrorPayload)
    );
}

#[test]
fn request_id_mismatch_is_rejected() {
    let payload = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    assert_eq!(
        HostKeyFfiEnvelope::new(
            Some("different-request".to_string()),
            HostKeyFfiResult::HostKeyChallenge(payload)
        ),
        Err(HostKeyFfiProtocolError::RequestIdMismatch)
    );
}

#[test]
fn unsafe_correlation_id_and_malformed_fingerprint_are_rejected() {
    let payload = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    assert_eq!(
        HostKeyFfiEnvelope::new(
            Some("/Users/example/known_hosts".to_string()),
            HostKeyFfiResult::HostKeyChallenge(payload.clone())
        ),
        Err(HostKeyFfiProtocolError::InvalidPayload)
    );

    let mut malformed = payload;
    malformed.fingerprint_sha256 = "SHA256:not-a-32-byte-digest".to_string();
    assert_eq!(
        HostKeyFfiEnvelope::new(
            Some(REQUEST_ID.to_string()),
            HostKeyFfiResult::HostKeyChallenge(malformed)
        ),
        Err(HostKeyFfiProtocolError::InvalidPayload)
    );
}

#[test]
fn unknown_fields_are_ignored_within_the_same_schema_version() {
    let payload = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    let envelope = HostKeyFfiEnvelope::new(
        Some(REQUEST_ID.to_string()),
        HostKeyFfiResult::HostKeyChallenge(payload),
    )
    .unwrap();
    let mut value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
    value["future_envelope_field"] = json!("ignored");
    value["data"]["future_payload_field"] = json!(42);

    let decoded = HostKeyFfiEnvelope::from_json(&value.to_string()).unwrap();
    assert_eq!(decoded.kind(), HostKeyFfiResultKind::HostKeyChallenge);
}

#[test]
fn protocol_json_excludes_sensitive_fields_and_full_public_key() {
    let challenge = HostKeyChallengePayload::from_registered(&registered_challenge()).unwrap();
    let error = HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::HostKeyInvalid,
        Some("invalid_public_key"),
        Some(REQUEST_ID.to_string()),
        None,
    );
    let outputs = [
        HostKeyFfiEnvelope::new(
            Some(REQUEST_ID.to_string()),
            HostKeyFfiResult::HostKeyChallenge(challenge),
        )
        .unwrap()
        .to_json()
        .unwrap(),
        HostKeyFfiEnvelope::new(Some(REQUEST_ID.to_string()), HostKeyFfiResult::Error(error))
            .unwrap()
            .to_json()
            .unwrap(),
    ];

    for json in outputs {
        assert!(!json.contains(KEY_A));
        assert!(!json.contains("password"));
        assert!(!json.contains("private_key"));
        assert!(!json.contains("access_token"));
        assert!(!json.contains("known_hosts_path"));
        assert!(!format!("{json:?}").contains(KEY_A));
    }
}

#[test]
fn legacy_session_generation_cannot_be_reported_as_checked() {
    assert_eq!(
        HostKeyFfiSecurityGeneration::try_from(&SessionSecurityGeneration::LegacyUnverified),
        Err(HostKeyFfiProtocolError::LegacySessionNotAllowed)
    );
    assert_eq!(
        HostKeyFfiSecurityGeneration::try_from(&SessionSecurityGeneration::HostKeyVerified {
            host_identity: identity(),
            key_algorithm: "ssh-ed25519".to_string(),
            fingerprint_sha256: fingerprint(),
            trust_store_generation: super::TrustStoreGeneration::from_contents(b"store-a"),
        }),
        Ok(HostKeyFfiSecurityGeneration::HostKeyVerified)
    );
}

#[test]
fn timestamp_before_unix_epoch_is_rejected() {
    let mut registered = registered_challenge();
    registered.expires_at = UNIX_EPOCH.checked_sub(Duration::from_secs(1)).unwrap();
    assert_eq!(
        HostKeyChallengePayload::from_registered(&registered),
        Err(HostKeyFfiProtocolError::InvalidTimestamp)
    );
}

#[test]
fn protocol_error_maps_to_stable_error_payload() {
    let payload =
        HostKeyFfiProtocolError::InvalidJson.to_error_payload(Some(REQUEST_ID.to_string()));
    assert_eq!(payload.code, HostKeyFfiErrorCode::InvalidJson);
    assert_eq!(payload.message_key, "error.json.invalid");
    assert_eq!(payload.detail_code.as_deref(), Some("invalid_json"));
    assert!(!payload.retryable);
}

#[test]
fn schema_version_constant_is_one() {
    assert_eq!(HOST_KEY_FFI_SCHEMA_VERSION, 1);
}

#[test]
fn block_reason_wire_strings_remain_stable() {
    assert_eq!(
        serde_json::to_value(HostKeyFfiBlockReasonCode::CertAuthorityUnsupported).unwrap(),
        "cert_authority_unsupported"
    );
}
