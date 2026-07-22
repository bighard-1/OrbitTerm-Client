use std::future::Future;
use std::pin::Pin;

use thiserror::Error;

use crate::checked_exec::{
    run_remote_command_checked, CheckedExecError, CheckedExecOptions, CheckedExecOutput,
};
use crate::current_unix_secs;
use crate::monitor;
use crate::security::{
    CheckedChannelAccessError, MonitorSnapshotDiagnostic, MonitorSnapshotPayload,
    MonitorSnapshotStatsPayload, MonitorSystemInfoPayload,
};
use crate::session_pool::{require_active_verified_base_session, VerifiedBaseSessionGuard};

const TOP_COMMAND: &str = "top -bn1 | head -n 8";
const CPU_PROC_COMMAND: &str =
    "cat /proc/stat 2>/dev/null | awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}'";
const FREE_COMMAND: &str = "free -m 2>/dev/null";
const MEMINFO_COMMAND: &str = "cat /proc/meminfo 2>/dev/null";
const DISK_COMMAND: &str = "df -P / 2>/dev/null";
const NET_COMMAND: &str = "cat /proc/net/dev 2>/dev/null";
const SYSTEM_IDENTITY_COMMAND: &str = monitor::SYSTEM_IDENTITY_COMMAND;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MonitorMetric {
    Cpu,
    Memory,
    Disk,
    Network,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedMonitorSnapshotError {
    #[error("checked monitor channel access was denied")]
    ChannelAccess(CheckedChannelAccessError),
    #[error("checked monitor command execution failed")]
    Exec(CheckedExecError),
    #[error("checked monitor metric is unavailable")]
    MetricUnavailable(MonitorMetric),
    #[error("checked monitor invariant failed")]
    InternalInvariantViolation,
}

impl From<CheckedChannelAccessError> for CheckedMonitorSnapshotError {
    fn from(value: CheckedChannelAccessError) -> Self {
        Self::ChannelAccess(value)
    }
}

impl From<CheckedExecError> for CheckedMonitorSnapshotError {
    fn from(value: CheckedExecError) -> Self {
        Self::Exec(value)
    }
}

pub(crate) trait CheckedMonitorBackend {
    fn execute<'a>(
        &'a self,
        base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>;

    fn ping<'a>(&'a self, host: &'a str) -> Pin<Box<dyn Future<Output = Option<f64>> + Send + 'a>>;
}

struct CoreCheckedMonitorBackend;

impl CheckedMonitorBackend for CoreCheckedMonitorBackend {
    fn execute<'a>(
        &'a self,
        base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(run_remote_command_checked(
            base_session_id,
            command,
            CheckedExecOptions::monitor_snapshot(),
        ))
    }

    fn ping<'a>(&'a self, host: &'a str) -> Pin<Box<dyn Future<Output = Option<f64>> + Send + 'a>> {
        Box::pin(monitor::measure_ping_ms(host))
    }
}

pub(crate) async fn fetch_system_stats_checked(
    base_session_id: u64,
) -> Result<MonitorSnapshotPayload, CheckedMonitorSnapshotError> {
    fetch_system_stats_checked_with_backend(base_session_id, &CoreCheckedMonitorBackend).await
}

pub(crate) async fn fetch_system_stats_checked_with_backend<B: CheckedMonitorBackend>(
    base_session_id: u64,
    backend: &B,
) -> Result<MonitorSnapshotPayload, CheckedMonitorSnapshotError> {
    let guard = require_active_verified_base_session(base_session_id)?;
    let top_output = execute_checked(&guard, backend, TOP_COMMAND).await?;
    let cpu_proc = execute_checked(&guard, backend, CPU_PROC_COMMAND).await?;
    let free_output = execute_checked(&guard, backend, FREE_COMMAND).await?;
    let meminfo_output = execute_checked(&guard, backend, MEMINFO_COMMAND).await?;
    let disk_output = execute_checked(&guard, backend, DISK_COMMAND).await?;
    let net_output = execute_checked(&guard, backend, NET_COMMAND).await?;
    let system_identity_output = execute_checked(&guard, backend, SYSTEM_IDENTITY_COMMAND).await?;

    let cpu_usage_percent = monitor::parse_cpu_usage(top_output.stdout())
        .or_else(|_| monitor::parse_cpu_from_proc_stat(cpu_proc.stdout()))
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Cpu))?;
    let memory = monitor::parse_memory_inventory(free_output.stdout())
        .or_else(|_| monitor::parse_memory_from_meminfo(meminfo_output.stdout()))
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Memory))?;
    let disk = monitor::parse_disk_inventory(disk_output.stdout())
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Disk))?;
    let (os_name, cpu_core_count, cpu_thread_count) =
        monitor::parse_system_identity(system_identity_output.stdout());
    let (rx_rate_kbps, tx_rate_kbps) =
        monitor::compute_network_rate_kbps(guard.base(), net_output.stdout())
            .await
            .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Network))?;

    guard.revalidate()?;
    let ping_latency_ms = backend.ping(&guard.base().host).await;
    guard.revalidate()?;
    let diagnostics = if ping_latency_ms.is_some() {
        Vec::new()
    } else {
        vec![MonitorSnapshotDiagnostic::PingUnavailable]
    };
    let stats = MonitorSnapshotStatsPayload::new(
        current_unix_secs(),
        cpu_usage_percent,
        memory.available_mb,
        memory.used_percent,
        disk.used_percent,
        ping_latency_ms,
        rx_rate_kbps,
        tx_rate_kbps,
        MonitorSystemInfoPayload::new(
            os_name,
            cpu_core_count,
            cpu_thread_count,
            memory.total_mb,
            memory.swap_total_mb,
            memory.swap_used_mb,
            disk.total_mb,
            disk.used_mb,
        )
        .map_err(|_| CheckedMonitorSnapshotError::InternalInvariantViolation)?,
    )
    .map_err(|_| CheckedMonitorSnapshotError::InternalInvariantViolation)?;
    MonitorSnapshotPayload::new(base_session_id, stats, diagnostics)
        .map_err(|_| CheckedMonitorSnapshotError::InternalInvariantViolation)
}

async fn execute_checked<B: CheckedMonitorBackend>(
    guard: &VerifiedBaseSessionGuard,
    backend: &B,
    command: &str,
) -> Result<CheckedExecOutput, CheckedMonitorSnapshotError> {
    guard.revalidate()?;
    let output = backend.execute(guard.base_session_id(), command).await?;
    guard.revalidate()?;
    Ok(output)
}

#[cfg(test)]
pub(crate) const fn monitor_commands_for_tests() -> [&'static str; 7] {
    [
        TOP_COMMAND,
        CPU_PROC_COMMAND,
        FREE_COMMAND,
        MEMINFO_COMMAND,
        DISK_COMMAND,
        NET_COMMAND,
        SYSTEM_IDENTITY_COMMAND,
    ]
}
