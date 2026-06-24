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

    let cpu_usage_percent = parse_cpu_usage(&top_output)
        .or_else(|_| parse_cpu_from_proc_stat(&cpu_proc))
        .unwrap_or(0.0);
    let (mem_available_mb, mem_used_percent) = parse_memory_stats(&free_output)
        .or_else(|_| parse_memory_from_meminfo(&meminfo_output))
        .unwrap_or((0, 0.0));
    let disk_used_percent = parse_disk_usage(&disk_output).unwrap_or(0.0);
    let (rx_rate_kbps, tx_rate_kbps) = compute_network_rate_kbps(base, &net_output)
        .await
        .unwrap_or((0.0, 0.0));
    let ping_latency_ms = measure_ping_ms(&base.host).await;
    let sampled_at_unix = current_unix_secs();

    let payload = SystemStatsResponse {
        sampled_at_unix,
        cpu_usage_percent,
        mem_available_mb,
        mem_used_percent,
        disk_used_percent,
        ping_latency_ms,
        rx_rate_kbps,
        tx_rate_kbps,
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

pub(crate) fn parse_memory_stats(free_output: &str) -> Result<(u64, f64), OrbitCoreError> {
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

    Ok((available, used_percent.clamp(0.0, 100.0)))
}

pub(crate) fn parse_memory_from_meminfo(
    meminfo_output: &str,
) -> Result<(u64, f64), OrbitCoreError> {
    let mut total_kb = 0u64;
    let mut available_kb = 0u64;
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
        }
    }

    if total_kb == 0 {
        return Err(OrbitCoreError::Internal("meminfo 缺少总内存".to_string()));
    }

    let used_kb = total_kb.saturating_sub(available_kb);
    let used_percent = (used_kb as f64 / total_kb as f64 * 100.0).clamp(0.0, 100.0);
    Ok((available_kb / 1024, used_percent))
}

pub(crate) fn parse_disk_usage(df_output: &str) -> Result<f64, OrbitCoreError> {
    let re = Regex::new(r"(?m)^\S+\s+\S+\s+\S+\s+\S+\s+(\d+)%\s+/\s*$")
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))?;

    if let Some(caps) = re.captures(df_output) {
        let used = caps
            .get(1)
            .and_then(|m| m.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        return Ok(used.clamp(0.0, 100.0));
    }

    Err(OrbitCoreError::Internal("无法解析磁盘使用率".to_string()))
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
        let rx_rate = rx_total.saturating_sub(last.rx_bytes) as f64 / elapsed as f64 / 1024.0;
        let tx_rate = tx_total.saturating_sub(last.tx_bytes) as f64 / elapsed as f64 / 1024.0;
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

pub(crate) async fn measure_ping_ms(host: &str) -> Option<f64> {
    let target = host_without_port(host).to_string();
    if target.is_empty() {
        return None;
    }

    let mut cmd = Command::new("ping");
    cmd.arg("-c").arg("1");
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        cmd.arg("-W").arg("1000");
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        cmd.arg("-W").arg("1");
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
