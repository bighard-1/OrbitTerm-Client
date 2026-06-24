use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;

use crate::docker_validator::{DockerCommandValidator, DockerValidationError};
use crate::{
    legacy_network::LegacyNetworkGate, run_remote_command, OrbitBaseSession, OrbitCoreError,
};

pub(crate) const DOCKER_LIST_COMMAND: &str = "docker ps -a --format '{{json .}}'";
pub(crate) const DOCKER_STATS_COMMAND: &str = "docker stats --no-stream --format '{{json .}}'";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DockerContainerItem {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) image: String,
    pub(crate) state: String,
    pub(crate) status: String,
    pub(crate) running_for: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct DockerStatsItem {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) cpu_percent: f64,
    pub(crate) mem_percent: f64,
    pub(crate) mem_usage: String,
    pub(crate) net_io: String,
    pub(crate) block_io: String,
    pub(crate) pids: u32,
}

pub(crate) async fn fetch_containers(
    base: &Arc<OrbitBaseSession>,
) -> Result<String, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
    let output = run_remote_command(base, DOCKER_LIST_COMMAND).await?;
    let items = parse_containers_output(&output)
        .map_err(|e| OrbitCoreError::Internal(format!("docker ps json parse failed: {e}")))?;

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn fetch_stats(base: &Arc<OrbitBaseSession>) -> Result<String, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
    let output = run_remote_command(base, DOCKER_STATS_COMMAND).await?;
    let items = parse_stats_output(&output)
        .map_err(|e| OrbitCoreError::Internal(format!("docker stats json parse failed: {e}")))?;

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn run_action(
    base: &Arc<OrbitBaseSession>,
    container_id: &str,
    action: &str,
) -> Result<String, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
    let command = DockerCommandValidator::action_command(container_id, action)
        .map_err(map_validation_error)?;
    run_remote_command(base, command.as_str()).await
}

pub(crate) async fn fetch_logs(
    base: &Arc<OrbitBaseSession>,
    container_id: &str,
    tail_lines: u32,
) -> Result<String, OrbitCoreError> {
    LegacyNetworkGate::require_current()?;
    let command = DockerCommandValidator::logs_command(container_id, tail_lines)
        .map_err(map_validation_error)?;
    run_remote_command(base, command.as_str()).await
}

fn map_validation_error(error: DockerValidationError) -> OrbitCoreError {
    let _stable_reason_code = error.reason_code();
    OrbitCoreError::InvalidInput
}

fn parse_percent(raw: &str) -> f64 {
    raw.trim()
        .trim_end_matches('%')
        .parse::<f64>()
        .unwrap_or(0.0)
}

pub(crate) fn parse_containers_output(
    output: &str,
) -> Result<Vec<DockerContainerItem>, serde_json::Error> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let value: Value = serde_json::from_str(line)?;
            Ok(DockerContainerItem {
                id: string_field(&value, "ID"),
                name: string_field(&value, "Names"),
                image: string_field(&value, "Image"),
                state: string_field(&value, "State"),
                status: string_field(&value, "Status"),
                running_for: string_field(&value, "RunningFor"),
            })
        })
        .collect()
}

pub(crate) fn parse_stats_output(output: &str) -> Result<Vec<DockerStatsItem>, serde_json::Error> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let value: Value = serde_json::from_str(line)?;
            Ok(DockerStatsItem {
                id: string_field(&value, "ID"),
                name: string_field(&value, "Name"),
                cpu_percent: parse_percent(
                    value.get("CPUPerc").and_then(Value::as_str).unwrap_or(""),
                ),
                mem_percent: parse_percent(
                    value.get("MemPerc").and_then(Value::as_str).unwrap_or(""),
                ),
                mem_usage: string_field(&value, "MemUsage"),
                net_io: string_field(&value, "NetIO"),
                block_io: string_field(&value, "BlockIO"),
                pids: value
                    .get("PIDs")
                    .and_then(Value::as_str)
                    .and_then(|value| value.trim().parse::<u32>().ok())
                    .unwrap_or(0),
            })
        })
        .collect()
}

fn string_field(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}
