use std::sync::Arc;
use std::time::Duration;

use regex::Regex;
use serde::Serialize;
use tokio::process::Command;

use crate::{
    current_unix_secs, legacy_network::LegacyNetworkGate, run_remote_command, OrbitBaseSession,
    OrbitCoreError,
};

#[derive(Debug)]
pub(crate) struct NetSnapshot {
    rx_bytes: u64,
    tx_bytes: u64,
    at_unix_secs: u64,
}

#[derive(Debug, Serialize)]
struct SystemStatsResponse {
    sampled_at_unix: u64,
    cpu_usage_percent: f64,
    mem_available_mb: u64,
    mem_used_percent: f64,
    disk_used_percent: f64,
    ping_latency_ms: Option<f64>,
    rx_rate_kbps: f64,
    tx_rate_kbps: f64,
    system_info: SystemInventory,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct SystemInventory {
    pub os_name: String,
    pub cpu_core_count: u32,
    pub cpu_thread_count: u32,
    pub memory_total_mb: u64,
    pub swap_total_mb: u64,
    pub swap_used_mb: u64,
    pub disk_total_mb: u64,
    pub disk_used_mb: u64,
}

impl Default for SystemInventory {
    fn default() -> Self {
        Self {
            os_name: "系统信息暂不可用".to_string(),
            cpu_core_count: 0,
            cpu_thread_count: 0,
            memory_total_mb: 0,
            swap_total_mb: 0,
            swap_used_mb: 0,
            disk_total_mb: 0,
            disk_used_mb: 0,
        }
    }
}

pub(crate) async fn fetch_system_stats_for_base(
    base: &Arc<OrbitBaseSession>,
) -> Result<String, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
    // 采集策略：优先 Linux 常见命令，失败时回退到 /proc，避免因单命令缺失导致整体失败。
    let top_output = run_remote_command(base, "top -bn1 | head -n 8")
        .await
        .unwrap_or_default();
    let cpu_proc = run_remote_command(
        base,
        "cat /proc/stat 2>/dev/null | awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}'",
    )
    .await
    .unwrap_or_default();
    let free_output = run_remote_command(base, "free -m 2>/dev/null")
        .await
        .unwrap_or_default();
    let meminfo_output = run_remote_command(base, "cat /proc/meminfo 2>/dev/null")
        .await
        .unwrap_or_default();
    let disk_output = run_remote_command(base, "df -P / 2>/dev/null")
        .await
        .unwrap_or_default();
    let net_output = run_remote_command(base, "cat /proc/net/dev 2>/dev/null")
        .await
        .unwrap_or_default();
    let system_identity_output = run_remote_command(base, SYSTEM_IDENTITY_COMMAND)
        .await
        .unwrap_or_default();

    let cpu_usage_percent = parse_cpu_usage(&top_output)
        .or_else(|_| parse_cpu_from_proc_stat(&cpu_proc))
        .unwrap_or(0.0);
    let memory = parse_memory_inventory(&free_output)
        .or_else(|_| parse_memory_from_meminfo(&meminfo_output))
        .unwrap_or_default();
    let disk = parse_disk_inventory(&disk_output).unwrap_or_default();
    let (os_name, cpu_core_count, cpu_thread_count) =
        parse_system_identity(&system_identity_output);
    let (rx_rate_kbps, tx_rate_kbps) = compute_network_rate_kbps(base, &net_output)
        .await
        .unwrap_or((0.0, 0.0));
    let ping_latency_ms = measure_ping_ms(&base.host).await;
    let sampled_at_unix = current_unix_secs();

    let payload = SystemStatsResponse {
        sampled_at_unix,
        cpu_usage_percent,
        mem_available_mb: memory.available_mb,
        mem_used_percent: memory.used_percent,
        disk_used_percent: disk.used_percent,
        ping_latency_ms,
        rx_rate_kbps,
        tx_rate_kbps,
        system_info: SystemInventory {
            os_name,
            cpu_core_count,
            cpu_thread_count,
            memory_total_mb: memory.total_mb,
            swap_total_mb: memory.swap_total_mb,
            swap_used_mb: memory.swap_used_mb,
            disk_total_mb: disk.total_mb,
            disk_used_mb: disk.used_mb,
        },
    };

    serde_json::to_string(&payload).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) fn parse_cpu_usage(top_output: &str) -> Result<f64, OrbitCoreError> {
    let cpu_line = Regex::new(r"(?mi)(?:^%?Cpu\(s\):|^Cpu\(s\):).*?([0-9]+(?:\.[0-9]+)?)\s*id")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = cpu_line.captures(top_output) {
        let idle = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok((100.0 - idle).clamp(0.0, 100.0));
    }

    // macOS/BSD top 格式: "CPU usage: 12.34% user, 5.00% sys, 82.66% idle"
    let bsd = Regex::new(
        r"(?mi)cpu usage:\s*([0-9]+(?:\.[0-9]+)?)%\s*user,\s*([0-9]+(?:\.[0-9]+)?)%\s*sys",
    )
    .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    if let Some(caps) = bsd.captures(top_output) {
        let user = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        let sys = caps
            .get(2)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok((user + sys).clamp(0.0, 100.0));
    }

    Err(OrbitCoreError::Internal("无法解析 CPU 使用率".to_string()))
}

pub(crate) fn parse_cpu_from_proc_stat(raw: &str) -> Result<f64, OrbitCoreError> {
    let nums: Vec<u64> = raw
        .split_whitespace()
        .filter_map(|v| v.parse::<u64>().ok())
        .collect();
    if nums.len() < 4 {
        return Err(OrbitCoreError::Internal("proc stat 字段不足".to_string()));
    }

    let idle = nums[3] as f64;
    let total: f64 = nums.iter().map(|v| *v as f64).sum();
    if total <= 0.0 {
        return Ok(0.0);
    }
    Ok(((total - idle) / total * 100.0).clamp(0.0, 100.0))
}

pub(crate) const SYSTEM_IDENTITY_COMMAND: &str = "os=$(. /etc/os-release 2>/dev/null && printf '%s' \"${PRETTY_NAME:-}\"); [ -n \"$os\" ] || os=$(uname -srm 2>/dev/null); threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0); cores=$(lscpu -p=CORE,SOCKET 2>/dev/null | awk -F, '!/^#/ && NF>=2 {print $1\",\"$2}' | sort -u | wc -l | tr -d ' '); printf 'os=%s\\ncpu=%s %s\\n' \"$os\" \"$cores\" \"$threads\"";

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct MemoryInventory {
    pub total_mb: u64,
    pub available_mb: u64,
    pub used_percent: f64,
    pub swap_total_mb: u64,
    pub swap_used_mb: u64,
}

pub(crate) fn parse_memory_inventory(free_output: &str) -> Result<MemoryInventory, OrbitCoreError> {
    let mem_line = free_output
        .lines()
        .find(|line| line.trim_start().starts_with("Mem:"))
        .ok_or_else(|| OrbitCoreError::Internal("无法解析内存信息".to_string()))?;

    let nums: Vec<u64> = mem_line
        .split_whitespace()
        .skip(1)
        .filter_map(|v| v.parse::<u64>().ok())
        .collect();

    if nums.len() < 3 {
        return Err(OrbitCoreError::Internal("内存数据字段不足".to_string()));
    }

    let total = nums[0];
    let used = nums[1];
    let available = if nums.len() >= 6 { nums[5] } else { nums[2] };
    let used_percent = if total == 0 {
        0.0
    } else {
        (used as f64 / total as f64) * 100.0
    };

    let swap = free_output
        .lines()
        .find(|line| line.trim_start().starts_with("Swap:"))
        .map(|line| {
            let values: Vec<u64> = line
                .split_whitespace()
                .skip(1)
                .filter_map(|value| value.parse::<u64>().ok())
                .collect();
            (
                values.first().copied().unwrap_or(0),
                values.get(1).copied().unwrap_or(0),
            )
        })
        .unwrap_or((0, 0));

    Ok(MemoryInventory {
        total_mb: total,
        available_mb: available,
        used_percent: used_percent.clamp(0.0, 100.0),
        swap_total_mb: swap.0,
        swap_used_mb: swap.1,
    })
}

pub(crate) fn parse_memory_from_meminfo(
    meminfo_output: &str,
) -> Result<MemoryInventory, OrbitCoreError> {
    let mut total_kb = 0u64;
    let mut available_kb = 0u64;
    let mut swap_total_kb = 0u64;
    let mut swap_free_kb = 0u64;
    for line in meminfo_output.lines() {
        if line.starts_with("MemTotal:") {
            total_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        } else if line.starts_with("MemAvailable:") {
            available_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        } else if line.starts_with("SwapTotal:") {
            swap_total_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        } else if line.starts_with("SwapFree:") {
            swap_free_kb = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
        }
    }

    if total_kb == 0 {
        return Err(OrbitCoreError::Internal("meminfo 缺少总内存".to_string()));
    }

    let used_kb = total_kb.saturating_sub(available_kb);
    let used_percent = (used_kb as f64 / total_kb as f64 * 100.0).clamp(0.0, 100.0);
    Ok(MemoryInventory {
        total_mb: total_kb / 1024,
        available_mb: available_kb / 1024,
        used_percent,
        swap_total_mb: swap_total_kb / 1024,
        swap_used_mb: swap_total_kb.saturating_sub(swap_free_kb) / 1024,
    })
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct DiskInventory {
    pub total_mb: u64,
    pub used_mb: u64,
    pub used_percent: f64,
}

pub(crate) fn parse_disk_inventory(df_output: &str) -> Result<DiskInventory, OrbitCoreError> {
    let re = Regex::new(r"(?m)^\S+\s+(\d+)\s+(\d+)\s+\S+\s+(\d+)%\s+/\s*$")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = re.captures(df_output) {
        let total_kb = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        let used_kb = caps
            .get(2)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        let used_percent = caps
            .get(3)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok(DiskInventory {
            total_mb: total_kb / 1024,
            used_mb: used_kb / 1024,
            used_percent: used_percent.clamp(0.0, 100.0),
        });
    }

    Err(OrbitCoreError::Internal("无法解析磁盘使用率".to_string()))
}

pub(crate) fn parse_os_name(raw: &str) -> String {
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        "系统信息暂不可用".to_string()
    } else {
        compact.chars().take(120).collect()
    }
}

pub(crate) fn parse_system_identity(raw: &str) -> (String, u32, u32) {
    let os_name = raw
        .lines()
        .find_map(|line| line.strip_prefix("os="))
        .map(parse_os_name)
        .unwrap_or_else(|| parse_os_name(raw));
    let cpu_raw = raw
        .lines()
        .find_map(|line| line.strip_prefix("cpu="))
        .unwrap_or_default();
    let (cores, threads) = parse_cpu_topology(cpu_raw);
    (os_name, cores, threads)
}

pub(crate) fn parse_cpu_topology(raw: &str) -> (u32, u32) {
    let values: Vec<u32> = raw
        .split_whitespace()
        .filter_map(|value| value.parse::<u32>().ok())
        .collect();
    let threads = values.get(1).copied().unwrap_or(0);
    let cores = values
        .first()
        .copied()
        .filter(|count| *count > 0)
        .unwrap_or(threads);
    (cores, threads)
}

pub(crate) async fn compute_network_rate_kbps(
    session: &Arc<OrbitBaseSession>,
    net_dev_output: &str,
) -> Result<(f64, f64), OrbitCoreError> {
    let re =
        Regex::new(r"(?m)^\s*([^:]+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s*(\d+)")
            .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    let mut rx_total = 0u64;
    let mut tx_total = 0u64;

    for caps in re.captures_iter(net_dev_output) {
        let iface = caps.get(1).map(|m| m.as_str().trim()).unwrap_or_default();
        if iface == "lo" {
            continue;
        }

        let rx = caps
            .get(2)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        let tx = caps
            .get(3)
            .and_then(|m| m.as_str().parse::<u64>().ok())
            .unwrap_or(0);
        rx_total = rx_total.saturating_add(rx);
        tx_total = tx_total.saturating_add(tx);
    }

    let now = current_unix_secs();
    let mut snapshot = session.net_snapshot.lock().await;
    let (rx_rate_kbps, tx_rate_kbps) = if let Some(last) = snapshot.as_ref() {
        let elapsed = now.saturating_sub(last.at_unix_secs).max(1);
        let rx_rate = bytes_over_interval_to_kbps(rx_total.saturating_sub(last.rx_bytes), elapsed);
        let tx_rate = bytes_over_interval_to_kbps(tx_total.saturating_sub(last.tx_bytes), elapsed);
        (rx_rate, tx_rate)
    } else {
        (0.0, 0.0)
    };

    *snapshot = Some(NetSnapshot {
        rx_bytes: rx_total,
        tx_bytes: tx_total,
        at_unix_secs: now,
    });

    Ok((rx_rate_kbps.max(0.0), tx_rate_kbps.max(0.0)))
}

fn bytes_over_interval_to_kbps(bytes: u64, elapsed_seconds: u64) -> f64 {
    bytes as f64 * 8.0 / elapsed_seconds.max(1) as f64 / 1000.0
}

pub(crate) async fn measure_ping_ms(host: &str) -> Option<f64> {
    let target = host_without_port(host).to_string();
    if target.is_empty() {
        return None;
    }

    let mut cmd = Command::new("ping");
    #[cfg(windows)]
    {
        // ping.exe is a console subsystem process. Without CREATE_NO_WINDOW,
        // every monitor refresh briefly creates a visible console window next
        // to the WinUI client.
        cmd.creation_flags(0x08000000);
        cmd.arg("-n").arg("1").arg("-w").arg("1000");
    }
    #[cfg(not(windows))]
    {
        cmd.arg("-c").arg("1");
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        {
            cmd.arg("-W").arg("1000");
        }
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        {
            cmd.arg("-W").arg("1");
        }
    }
    cmd.arg(&target);

    let output = tokio::time::timeout(Duration::from_secs(3), cmd.output())
        .await
        .ok()?
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let re = Regex::new(r"time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms").ok()?;
    re.captures(&text)
        .and_then(|caps| caps.get(1))
        .and_then(|m| m.as_str().parse::<f64>().ok())
}

fn host_without_port(host: &str) -> &str {
    let trimmed = host.trim();
    if trimmed.starts_with('[') {
        if let Some(end) = trimmed.find(']') {
            return &trimmed[1..end];
        }
    }
    // 仅一个冒号时，按 host:port 处理；多个冒号视为 IPv6 地址本体。
    if trimmed.matches(':').count() == 1 {
        return trimmed.split(':').next().unwrap_or(trimmed);
    }
    trimmed
}

#[cfg(test)]
mod network_rate_tests {
    use super::bytes_over_interval_to_kbps;

    #[test]
    fn converts_byte_deltas_to_real_decimal_kilobits_per_second() {
        assert_eq!(bytes_over_interval_to_kbps(125_000, 1), 1_000.0);
        assert_eq!(bytes_over_interval_to_kbps(250_000, 2), 1_000.0);
    }
}
