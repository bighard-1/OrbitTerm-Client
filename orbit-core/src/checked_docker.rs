use std::future::Future;
use std::pin::Pin;

use thiserror::Error;

use crate::checked_exec::{
    run_remote_command_checked, CheckedExecError, CheckedExecOptions, CheckedExecOutput,
};
use crate::docker::{
    parse_containers_output, parse_stats_output, DOCKER_LIST_COMMAND, DOCKER_STATS_COMMAND,
};
use crate::docker_validator::{
    DockerCommandValidator, DockerUpdateOptions, DockerValidationError, ValidatedContainerId,
    ValidatedContainerName,
};
use crate::security::{
    CheckedChannelAccessError, DockerActionResultPayload, DockerContainerPayload,
    DockerContainersPayload, DockerLogsPayload, DockerStatsItemPayload, DockerStatsPayload,
    HostKeyFfiProtocolError,
};
use crate::session_pool::require_active_verified_base_session;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedDockerError {
    #[error("checked Docker channel access was denied")]
    ChannelAccess(CheckedChannelAccessError),
    #[error("checked Docker input validation failed")]
    Validation(DockerValidationError),
    #[error("checked Docker command execution failed")]
    Exec(CheckedExecError),
    #[error("checked Docker output parsing failed")]
    ParseFailed,
    #[error("checked Docker result invariant failed")]
    InternalInvariantViolation,
}

impl From<CheckedChannelAccessError> for CheckedDockerError {
    fn from(value: CheckedChannelAccessError) -> Self {
        Self::ChannelAccess(value)
    }
}

impl From<DockerValidationError> for CheckedDockerError {
    fn from(value: DockerValidationError) -> Self {
        Self::Validation(value)
    }
}

impl From<CheckedExecError> for CheckedDockerError {
    fn from(value: CheckedExecError) -> Self {
        Self::Exec(value)
    }
}

impl From<HostKeyFfiProtocolError> for CheckedDockerError {
    fn from(_value: HostKeyFfiProtocolError) -> Self {
        Self::InternalInvariantViolation
    }
}

pub(crate) trait CheckedDockerBackend {
    fn execute<'a>(
        &'a self,
        base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>;
}

struct CoreCheckedDockerBackend;

impl CheckedDockerBackend for CoreCheckedDockerBackend {
    fn execute<'a>(
        &'a self,
        base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(run_remote_command_checked(
            base_session_id,
            command,
            CheckedExecOptions::docker_operation(),
        ))
    }
}

pub(crate) async fn fetch_docker_containers_checked(
    base_session_id: u64,
) -> Result<DockerContainersPayload, CheckedDockerError> {
    fetch_docker_containers_checked_with_backend(base_session_id, &CoreCheckedDockerBackend).await
}

pub(crate) async fn fetch_docker_containers_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    backend: &B,
) -> Result<DockerContainersPayload, CheckedDockerError> {
    let output = execute_checked(base_session_id, DOCKER_LIST_COMMAND, backend).await?;
    let containers = parse_containers_output(output.stdout())
        .map_err(|_| CheckedDockerError::ParseFailed)?
        .into_iter()
        .map(|item| DockerContainerPayload {
            id: item.id,
            name: item.name,
            image: item.image,
            state: item.state,
            status: item.status,
            running_for: item.running_for,
        })
        .collect();
    Ok(DockerContainersPayload::new(base_session_id, containers)?)
}

pub(crate) async fn fetch_docker_stats_checked(
    base_session_id: u64,
) -> Result<DockerStatsPayload, CheckedDockerError> {
    fetch_docker_stats_checked_with_backend(base_session_id, &CoreCheckedDockerBackend).await
}

pub(crate) async fn fetch_docker_stats_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    backend: &B,
) -> Result<DockerStatsPayload, CheckedDockerError> {
    let output = execute_checked(base_session_id, DOCKER_STATS_COMMAND, backend).await?;
    let stats = parse_stats_output(output.stdout())
        .map_err(|_| CheckedDockerError::ParseFailed)?
        .into_iter()
        .map(|item| {
            DockerStatsItemPayload::new(
                item.id,
                item.name,
                item.cpu_percent,
                item.mem_percent,
                item.mem_usage,
                item.net_io,
                item.block_io,
                item.pids,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DockerStatsPayload::new(base_session_id, stats)?)
}

pub(crate) async fn fetch_docker_logs_checked(
    base_session_id: u64,
    container_id: &str,
    tail_lines: u32,
) -> Result<DockerLogsPayload, CheckedDockerError> {
    fetch_docker_logs_checked_with_backend(
        base_session_id,
        container_id,
        tail_lines,
        &CoreCheckedDockerBackend,
    )
    .await
}

pub(crate) async fn fetch_docker_logs_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    container_id: &str,
    tail_lines: u32,
    backend: &B,
) -> Result<DockerLogsPayload, CheckedDockerError> {
    let command = DockerCommandValidator::logs_command(container_id, tail_lines)?;
    let output = execute_checked(base_session_id, command.as_str(), backend).await?;
    Ok(DockerLogsPayload::new(
        base_session_id,
        container_id.to_string(),
        output.stdout().to_string(),
    )?)
}

pub(crate) async fn docker_action_checked(
    base_session_id: u64,
    container_id: &str,
    action: &str,
) -> Result<DockerActionResultPayload, CheckedDockerError> {
    docker_action_checked_with_backend(
        base_session_id,
        container_id,
        action,
        &CoreCheckedDockerBackend,
    )
    .await
}

pub(crate) async fn docker_action_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    container_id: &str,
    action: &str,
    backend: &B,
) -> Result<DockerActionResultPayload, CheckedDockerError> {
    let action = DockerCommandValidator::validate_action(action)?;
    let command = DockerCommandValidator::action_command(container_id, action.wire_token())?;
    execute_checked(base_session_id, command.as_str(), backend).await?;
    Ok(DockerActionResultPayload::new(
        base_session_id,
        container_id.to_string(),
        action.wire_token().to_string(),
    )?)
}

pub(crate) async fn docker_rename_checked(
    base_session_id: u64,
    container_id: ValidatedContainerId,
    new_name: ValidatedContainerName,
) -> Result<(), CheckedDockerError> {
    docker_rename_checked_with_backend(
        base_session_id,
        container_id,
        new_name,
        &CoreCheckedDockerBackend,
    )
    .await
}

pub(crate) async fn docker_rename_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    container_id: ValidatedContainerId,
    new_name: ValidatedContainerName,
    backend: &B,
) -> Result<(), CheckedDockerError> {
    let command = DockerCommandValidator::rename_command_typed(&container_id, &new_name);
    execute_checked(base_session_id, command.as_str(), backend).await?;
    Ok(())
}

pub(crate) async fn docker_update_checked(
    base_session_id: u64,
    container_id: ValidatedContainerId,
    options: DockerUpdateOptions,
) -> Result<(), CheckedDockerError> {
    docker_update_checked_with_backend(
        base_session_id,
        container_id,
        options,
        &CoreCheckedDockerBackend,
    )
    .await
}

pub(crate) async fn docker_update_checked_with_backend<B: CheckedDockerBackend>(
    base_session_id: u64,
    container_id: ValidatedContainerId,
    options: DockerUpdateOptions,
    backend: &B,
) -> Result<(), CheckedDockerError> {
    let command = DockerCommandValidator::update_command_typed(&container_id, &options);
    execute_checked(base_session_id, command.as_str(), backend).await?;
    Ok(())
}

async fn execute_checked<B: CheckedDockerBackend>(
    base_session_id: u64,
    command: &str,
    backend: &B,
) -> Result<CheckedExecOutput, CheckedDockerError> {
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    let output = backend.execute(base_session_id, command).await?;
    guard.revalidate()?;
    Ok(output)
}
