use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;

use crate::checked_exec::{CheckedExecError, CheckedExecOutput};
use crate::checked_monitor::{
    fetch_system_stats_checked_with_backend, monitor_commands_for_tests, CheckedMonitorBackend,
    CheckedMonitorSnapshotError, MonitorMetric,
};
use crate::security::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, MonitorSnapshotDiagnostic,
    SessionLifecycleState, SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-monitor-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-monitor-store"),
    }
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

struct FakeMonitorBackend {
    outputs: HashMap<&'static str, Result<CheckedExecOutput, CheckedExecError>>,
    calls: Mutex<Vec<String>>,
    ping: Option<f64>,
}

impl FakeMonitorBackend {
    fn successful(ping: Option<f64>) -> Self {
        let commands = monitor_commands_for_tests();
        let values = [
            "%Cpu(s): 1.0 us, 2.0 sy, 90.0 id\n",
            "100 20 30 850 0 0 0\n",
            "Mem: 1000 400 100 0 0 600\n",
            "MemTotal: 1024000 kB\nMemAvailable: 614400 kB\n",
            "/dev/root 100 20 80 20% /\n",
            "eth0: 1024 0 0 0 0 0 0 0 2048 0 0 0 0 0 0 0\n",
        ];
        let outputs = commands
            .into_iter()
            .zip(values)
            .map(|(command, value)| {
                (
                    command,
                    Ok(CheckedExecOutput::new(value.to_string(), String::new(), 0)),
                )
            })
            .collect();
        Self {
            outputs,
            calls: Mutex::new(Vec::new()),
            ping,
        }
    }

    fn failing(error: CheckedExecError) -> Self {
        let mut backend = Self::successful(Some(1.0));
        backend
            .outputs
            .insert(monitor_commands_for_tests()[0], Err(error));
        backend
    }

    fn call_count(&self) -> usize {
        self.calls.lock().unwrap().len()
    }
}

impl CheckedMonitorBackend for FakeMonitorBackend {
    fn execute<'a>(
        &'a self,
        _base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.calls.lock().unwrap().push(command.to_string());
            self.outputs
                .get(command)
                .cloned()
                .unwrap_or(Err(CheckedExecError::ExecOutputFailed))
        })
    }

    fn ping<'a>(
        &'a self,
        _host: &'a str,
    ) -> Pin<Box<dyn Future<Output = Option<f64>> + Send + 'a>> {
        Box::pin(async move { self.ping })
    }
}

#[tokio::test]
async fn active_verified_snapshot_runs_every_checked_command_and_returns_stats() {
    let base = TestBase::new(verified_generation());
    let backend = FakeMonitorBackend::successful(Some(4.5));
    let payload = fetch_system_stats_checked_with_backend(base.id, &backend)
        .await
        .unwrap();

    assert_eq!(backend.call_count(), 6);
    assert_eq!(payload.base_session_id, base.id.to_string());
    assert_eq!(payload.stats.cpu_usage_percent.as_f64(), Some(10.0));
    assert_eq!(payload.stats.mem_available_mb, 600);
    assert_eq!(payload.stats.mem_used_percent.as_f64(), Some(40.0));
    assert_eq!(payload.stats.disk_used_percent.as_f64(), Some(20.0));
    assert_eq!(
        payload
            .stats
            .ping_latency_ms
            .as_ref()
            .and_then(serde_json::Number::as_f64),
        Some(4.5)
    );
    assert!(payload.diagnostics.is_empty());
}

#[tokio::test]
async fn ping_unavailable_is_partial_success_with_stable_diagnostic() {
    let base = TestBase::new(verified_generation());
    let backend = FakeMonitorBackend::successful(None);
    let payload = fetch_system_stats_checked_with_backend(base.id, &backend)
        .await
        .unwrap();
    assert_eq!(payload.stats.ping_latency_ms, None);
    assert_eq!(
        payload.diagnostics,
        vec![MonitorSnapshotDiagnostic::PingUnavailable]
    );
}

#[tokio::test]
async fn legacy_and_non_active_snapshot_requests_fail_before_exec() {
    let backend = FakeMonitorBackend::successful(Some(1.0));
    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    assert_eq!(
        fetch_system_stats_checked_with_backend(legacy.id, &backend)
            .await
            .unwrap_err(),
        CheckedMonitorSnapshotError::ChannelAccess(
            CheckedChannelAccessError::LegacySessionNotAllowed
        )
    );

    for state in [
        SessionLifecycleState::Draining,
        SessionLifecycleState::Terminating,
        SessionLifecycleState::Closed,
    ] {
        let base = TestBase::new(verified_generation());
        resolve_base_session_by_base_id(base.id)
            .unwrap()
            .metadata
            .transition_to(state)
            .unwrap();
        assert!(fetch_system_stats_checked_with_backend(base.id, &backend)
            .await
            .is_err());
    }
    assert_eq!(backend.call_count(), 0);
}

#[tokio::test]
async fn exec_and_parse_failures_are_not_replaced_with_zero_metrics() {
    let base = TestBase::new(verified_generation());
    let backend = FakeMonitorBackend::failing(CheckedExecError::ExecRequestFailed);
    assert_eq!(
        fetch_system_stats_checked_with_backend(base.id, &backend)
            .await
            .unwrap_err(),
        CheckedMonitorSnapshotError::Exec(CheckedExecError::ExecRequestFailed)
    );
    assert_eq!(backend.call_count(), 1);

    let mut backend = FakeMonitorBackend::successful(Some(1.0));
    backend.outputs.insert(
        monitor_commands_for_tests()[4],
        Ok(CheckedExecOutput::new(
            "not-disk-stats".to_string(),
            String::new(),
            0,
        )),
    );
    assert_eq!(
        fetch_system_stats_checked_with_backend(base.id, &backend)
            .await
            .unwrap_err(),
        CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Disk)
    );
}

#[test]
fn monitor_errors_do_not_expose_commands_credentials_or_paths() {
    for error in [
        CheckedMonitorSnapshotError::Exec(CheckedExecError::ExecOutputFailed),
        CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Cpu),
        CheckedMonitorSnapshotError::InternalInvariantViolation,
    ] {
        let output = format!("{error:?} {error}");
        for forbidden in [
            "password",
            "private_key",
            "token",
            "known_hosts",
            "cat /proc",
        ] {
            assert!(!output.contains(forbidden));
        }
    }
}
