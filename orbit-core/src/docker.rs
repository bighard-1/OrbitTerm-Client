use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;

use crate::{run_remote_command, OrbitBaseSession, OrbitCoreError};

#[derive(Debug, Serialize)]
struct DockerContainerItem {
    id: String,
    name: String,
    image: String,
    state: String,
    status: String,
    running_for: String,
}

#[derive(Debug, Serialize)]
struct DockerStatsItem {
    id: String,
    name: String,
    cpu_percent: f64,
    mem_percent: f64,
    mem_usage: String,
    net_io: String,
    block_io: String,
    pids: u32,
}

pub(crate) async fn fetch_containers(
    base: &Arc<OrbitBaseSession>,
) -> Result<String, OrbitCoreError> {
    let output = run_remote_command(base, "docker ps -a --format '{{json .}}'").await?;
    let mut items: Vec<DockerContainerItem> = Vec::new();

    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = serde_json::from_str(line)
            .map_err(|e| OrbitCoreError::Internal(format!("docker ps json parse failed: {e}")))?;

        items.push(DockerContainerItem {
            id: value
                .get("ID")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            name: value
                .get("Names")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            image: value
                .get("Image")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            state: value
                .get("State")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            status: value
                .get("Status")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            running_for: value
                .get("RunningFor")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
        });
    }

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn fetch_stats(base: &Arc<OrbitBaseSession>) -> Result<String, OrbitCoreError> {
    let output = run_remote_command(base, "docker stats --no-stream --format '{{json .}}'").await?;
    let mut items: Vec<DockerStatsItem> = Vec::new();

    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = serde_json::from_str(line).map_err(|e| {
            OrbitCoreError::Internal(format!("docker stats json parse failed: {e}"))
        })?;

        let cpu_percent =
            parse_percent(value.get("CPUPerc").and_then(|v| v.as_str()).unwrap_or(""));
        let mem_percent =
            parse_percent(value.get("MemPerc").and_then(|v| v.as_str()).unwrap_or(""));
        let pids = value
            .get("PIDs")
            .and_then(|v| v.as_str())
            .and_then(|s| s.trim().parse::<u32>().ok())
            .unwrap_or(0);

        items.push(DockerStatsItem {
            id: value
                .get("ID")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            name: value
                .get("Name")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            cpu_percent,
            mem_percent,
            mem_usage: value
                .get("MemUsage")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            net_io: value
                .get("NetIO")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            block_io: value
                .get("BlockIO")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            pids,
        });
    }

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn run_action(
    base: &Arc<OrbitBaseSession>,
    container_id: &str,
    action: &str,
) -> Result<String, OrbitCoreError> {
    if container_id.trim().is_empty() || action.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let normalized_action = action.trim().to_lowercase();
    if !matches!(
        normalized_action.as_str(),
        "start" | "stop" | "restart" | "kill" | "remove"
    ) {
        return Err(OrbitCoreError::InvalidInput);
    }

    let cmd = if normalized_action == "remove" {
        format!("docker rm -f {}", container_id.trim())
    } else {
        format!("docker {} {}", normalized_action, container_id.trim())
    };
    run_remote_command(base, &cmd).await
}

pub(crate) async fn fetch_logs(
    base: &Arc<OrbitBaseSession>,
    container_id: &str,
    tail_lines: u32,
) -> Result<String, OrbitCoreError> {
    if container_id.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let safe_tail = if tail_lines == 0 {
        200
    } else {
        tail_lines.min(2000)
    };
    let cmd = format!(
        "docker logs --tail {} {} 2>&1",
        safe_tail,
        container_id.trim()
    );
    run_remote_command(base, &cmd).await
}

fn parse_percent(raw: &str) -> f64 {
    raw.trim()
        .trim_end_matches('%')
        .parse::<f64>()
        .unwrap_or(0.0)
}
