use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

use super::checked_monitor_ffi::{
    monitor_snapshot_response_for_tests, orbit_monitor_snapshot_checked_v1,
};
use super::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, HostKeyFfiEnvelope,
    HostKeyFfiResultKind, MonitorSnapshotDiagnostic, MonitorSnapshotPayload,
    MonitorSnapshotStatsPayload, SessionLifecycleState, SessionSecurityGeneration,
    TrustStoreGeneration,
};
use crate::c_ffi::orbit_free_string;
use crate::checked_exec::CheckedExecError;
use crate::checked_monitor::{CheckedMonitorSnapshotError, MonitorMetric};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

const REQUEST_ID: &str = "checked-monitor-request";

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-monitor-ffi-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-monitor-ffi-store"),
    }
}

fn snapshot(base_session_id: u64) -> MonitorSnapshotPayload {
    MonitorSnapshotPayload::new(
        base_session_id,
        MonitorSnapshotStatsPayload::new(1_700_000_000, 12.5, 512, 48.0, 61.0, None, 1.5, 2.5)
            .unwrap(),
        vec![MonitorSnapshotDiagnostic::PingUnavailable],
    )
    .unwrap()
}

struct TestBase {
    id: u64,
}

impl TestBase {
    fn new(generation: SessionSecurityGeneration) -> Self {
        let base = insert_synthetic_base_session_for_tests("example.com", "root", generation)
            .expect("insert synthetic base");
        Self { id: base.id }
    }
}

impl Drop for TestBase {
    fn drop(&mut self) {
        remove_synthetic_base_session_for_tests(self.id);
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

fn call_exported(base_session_id: u64, request_id: *const c_char) -> (String, Value) {
    read_and_free(orbit_monitor_snapshot_checked_v1(
        base_session_id,
        request_id,
    ))
}

#[test]
fn ffi_rejects_null_invalid_utf8_oversized_control_and_zero_inputs() {
    let (_, null_request) = call_exported(1, std::ptr::null());
    assert_eq!(null_request["error"]["code"], "invalid_request");

    let invalid_utf8 = [0xff_u8, 0];
    let (_, invalid_utf8) = call_exported(1, invalid_utf8.as_ptr().cast());
    assert_eq!(invalid_utf8["error"]["code"], "invalid_utf8");

    for invalid in ["x".repeat(257), "line\nbreak".to_string()] {
        let invalid = CString::new(invalid).unwrap();
        let (_, response) = call_exported(1, invalid.as_ptr());
        assert_eq!(response["error"]["code"], "invalid_request");
    }

    let request_id = CString::new(REQUEST_ID).unwrap();
    let (_, zero) = call_exported(0, request_id.as_ptr());
    assert_eq!(zero["request_id"], REQUEST_ID);
    assert_eq!(zero["error"]["code"], "invalid_request");
}

#[test]
fn unknown_legacy_and_non_active_bases_fail_closed() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let unknown_base_id = (1_u64 << 48) | 888_888;
    let (_, unknown) = call_exported(unknown_base_id, request_id.as_ptr());
    assert_eq!(unknown["error"]["code"], "session_not_found");

    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    let (_, legacy) = call_exported(legacy.id, request_id.as_ptr());
    assert_eq!(legacy["error"]["code"], "legacy_session_not_allowed");

    for (state, expected) in [
        (SessionLifecycleState::Draining, "session_draining"),
        (SessionLifecycleState::Terminating, "session_terminating"),
        (SessionLifecycleState::Closed, "session_closed"),
    ] {
        let base = TestBase::new(verified_generation());
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        let (_, response) = call_exported(base.id, request_id.as_ptr());
        assert_eq!(response["error"]["code"], expected);
    }
}

#[test]
fn success_returns_monitor_snapshot_with_string_id_and_no_sensitive_fields() {
    let base = TestBase::new(verified_generation());
    let request_id = CString::new(REQUEST_ID).unwrap();
    let pointer =
        monitor_snapshot_response_for_tests(base.id, request_id.as_ptr(), |base_id| async move {
            Ok(snapshot(base_id))
        });
    let (json, value) = read_and_free(pointer);

    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], REQUEST_ID);
    assert_eq!(value["kind"], "monitor_snapshot");
    assert_eq!(value["data"]["base_session_id"], base.id.to_string());
    assert_eq!(value["data"]["security_generation"], "host_key_verified");
    assert_eq!(value["data"]["stats"]["cpu_usage_percent"], 12.5);
    assert_eq!(value["data"]["diagnostics"][0], "ping_unavailable");
    assert_eq!(
        HostKeyFfiEnvelope::from_json(&json).unwrap().kind(),
        HostKeyFfiResultKind::MonitorSnapshot
    );
    for forbidden in [
        "password",
        "private_key",
        "passphrase",
        "token",
        "public_key",
        "known_hosts",
    ] {
        assert!(!json.contains(forbidden));
    }
}

#[test]
fn monitor_stats_reject_non_finite_and_out_of_range_values() {
    assert!(MonitorSnapshotStatsPayload::new(
        1_700_000_000,
        f64::NAN,
        512,
        48.0,
        61.0,
        None,
        1.5,
        2.5,
    )
    .is_err());
    assert!(MonitorSnapshotStatsPayload::new(
        1_700_000_000,
        101.0,
        512,
        48.0,
        61.0,
        None,
        1.5,
        2.5,
    )
    .is_err());
}

#[test]
fn exec_and_monitor_errors_map_to_stable_codes() {
    let request_id = CString::new(REQUEST_ID).unwrap();
    let cases = [
        (
            CheckedMonitorSnapshotError::Exec(CheckedExecError::ChannelAccess(
                CheckedChannelAccessError::ChannelOpenFailed,
            )),
            "channel_open_failed",
        ),
        (
            CheckedMonitorSnapshotError::Exec(CheckedExecError::ExecRequestFailed),
            "exec_request_failed",
        ),
        (
            CheckedMonitorSnapshotError::Exec(CheckedExecError::ExecOutputFailed),
            "exec_output_failed",
        ),
        (
            CheckedMonitorSnapshotError::Exec(CheckedExecError::Timeout),
            "exec_timeout",
        ),
        (
            CheckedMonitorSnapshotError::Exec(CheckedExecError::CommandFailed { exit_status: 1 }),
            "exec_command_failed",
        ),
        (
            CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Cpu),
            "monitor_snapshot_failed",
        ),
    ];
    for (error, expected) in cases {
        let pointer =
            monitor_snapshot_response_for_tests(1, request_id.as_ptr(), move |_| async move {
                Err(error)
            });
        let (json, value) = read_and_free(pointer);
        assert_eq!(value["error"]["code"], expected);
        assert_eq!(value["request_id"], REQUEST_ID);
        for forbidden in ["password", "private_key", "public_key", "known_hosts"] {
            assert!(!json.contains(forbidden));
        }
    }
}

#[test]
fn header_declares_additive_checked_monitor_and_preserves_legacy_monitor() {
    let header = include_str!("../../include/orbit_core.h");
    assert!(header.contains("orbit_monitor_snapshot_checked_v1"));
    assert!(header.contains("uint64_t base_session_id"));
    assert!(header.contains("const char *request_id"));
    assert!(header.contains("char *orbit_fetch_system_stats(uint64_t session_id);"));
    assert!(header.contains("char *orbit_fetch_docker_containers"));
    assert!(header.contains("char *orbit_exec_command"));
    assert!(header.contains("orbit_free_string"));
}
