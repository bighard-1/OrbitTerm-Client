use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::Ordering;

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
const TOP_MARKER: &str = "__ORBIT_MONITOR_TOP__";
const CPU_MARKER: &str = "__ORBIT_MONITOR_CPU__";
const FREE_MARKER: &str = "__ORBIT_MONITOR_FREE__";
const MEMINFO_MARKER: &str = "__ORBIT_MONITOR_MEMINFO__";
const DISK_MARKER: &str = "__ORBIT_MONITOR_DISK__";
const NET_MARKER: &str = "__ORBIT_MONITOR_NET__";
const SYSTEM_MARKER: &str = "__ORBIT_MONITOR_SYSTEM__";

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
    // Signal bulk SFTP loops to create one bounded scheduling checkpoint for
    // this sample. This keeps monitoring on the verified shared transport but
    // prevents a continuous transfer from monopolizing successive turns.
    guard
        .base()
        .monitor_sample_generation
        .fetch_add(1, Ordering::SeqCst);
    tokio::task::yield_now().await;
    // One checked exec replaces seven sequential channel round trips. Besides
    // making the one-second refresh cadence reliable on high-latency hosts,
    // this prevents continuous monitor collection from competing with SFTP
    // traffic for the same encrypted SSH transport.
    let command = monitor_snapshot_command();
    let output = execute_checked(&guard, backend, &command).await?;
    let sections = parse_monitor_snapshot(output.stdout())?;

    let cpu_usage_percent = monitor::parse_cpu_usage(sections.top)
        .or_else(|_| monitor::parse_cpu_from_proc_stat(sections.cpu))
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Cpu))?;
    let memory = monitor::parse_memory_inventory(sections.free)
        .or_else(|_| monitor::parse_memory_from_meminfo(sections.meminfo))
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Memory))?;
    let disk = monitor::parse_disk_inventory(sections.disk)
        .map_err(|_| CheckedMonitorSnapshotError::MetricUnavailable(MonitorMetric::Disk))?;
    let (os_name, cpu_core_count, cpu_thread_count) =
        monitor::parse_system_identity(sections.system);
    let (rx_rate_kbps, tx_rate_kbps) =
        monitor::compute_network_rate_kbps(guard.base(), sections.net)
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

fn monitor_snapshot_command() -> String {
    format!(
        "printf '{TOP_MARKER}\\n'; {TOP_COMMAND}; printf '\\n{CPU_MARKER}\\n'; {CPU_PROC_COMMAND}; printf '\\n{FREE_MARKER}\\n'; {FREE_COMMAND}; printf '\\n{MEMINFO_MARKER}\\n'; {MEMINFO_COMMAND}; printf '\\n{DISK_MARKER}\\n'; {DISK_COMMAND}; printf '\\n{NET_MARKER}\\n'; {NET_COMMAND}; printf '\\n{SYSTEM_MARKER}\\n'; {SYSTEM_IDENTITY_COMMAND}"
    )
}

struct MonitorSnapshotSections<'a> {
    top: &'a str,
    cpu: &'a str,
    free: &'a str,
    meminfo: &'a str,
    disk: &'a str,
    net: &'a str,
    system: &'a str,
}

fn parse_monitor_snapshot(
    output: &str,
) -> Result<MonitorSnapshotSections<'_>, CheckedMonitorSnapshotError> {
    Ok(MonitorSnapshotSections {
        top: monitor_section(output, TOP_MARKER, Some(CPU_MARKER))?,
        cpu: monitor_section(output, CPU_MARKER, Some(FREE_MARKER))?,
        free: monitor_section(output, FREE_MARKER, Some(MEMINFO_MARKER))?,
        meminfo: monitor_section(output, MEMINFO_MARKER, Some(DISK_MARKER))?,
        disk: monitor_section(output, DISK_MARKER, Some(NET_MARKER))?,
        net: monitor_section(output, NET_MARKER, Some(SYSTEM_MARKER))?,
        system: monitor_section(output, SYSTEM_MARKER, None)?,
    })
}

fn monitor_section<'a>(
    output: &'a str,
    marker: &str,
    next_marker: Option<&str>,
) -> Result<&'a str, CheckedMonitorSnapshotError> {
    let start = output
        .find(marker)
        .map(|index| index + marker.len())
        .ok_or(CheckedMonitorSnapshotError::InternalInvariantViolation)?;
    let tail = &output[start..];
    let end = next_marker
        .and_then(|next| tail.find(next))
        .unwrap_or(tail.len());
    Ok(tail[..end].trim_matches(['\r', '\n']))
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
pub(crate) fn monitor_command_for_tests() -> String {
    monitor_snapshot_command()
}

#[cfg(test)]
pub(crate) fn monitor_output_for_tests(sections: [&str; 7]) -> String {
    format!(
        "{TOP_MARKER}\n{}\n{CPU_MARKER}\n{}\n{FREE_MARKER}\n{}\n{MEMINFO_MARKER}\n{}\n{DISK_MARKER}\n{}\n{NET_MARKER}\n{}\n{SYSTEM_MARKER}\n{}",
        sections[0], sections[1], sections[2], sections[3], sections[4], sections[5], sections[6]
    )
}
