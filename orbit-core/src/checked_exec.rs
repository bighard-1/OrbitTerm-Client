use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use russh::ChannelMsg;
use thiserror::Error;

use crate::security::CheckedChannelAccessError;
use crate::session_pool::{require_active_verified_base_session, VerifiedBaseSessionGuard};

pub(crate) const MAX_COMMAND_BYTES: usize = 16 * 1024;
const MAX_CONFIGURED_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const DEFAULT_BATCH_TIMEOUT_SECONDS: u32 = 30;
pub(crate) const MAX_BATCH_TIMEOUT_SECONDS: u32 = 300;
pub(crate) const DEFAULT_BATCH_STDOUT_BYTES: u32 = 256 * 1024;
pub(crate) const MAX_BATCH_STDOUT_BYTES: u32 = 1024 * 1024;
pub(crate) const DEFAULT_BATCH_STDERR_BYTES: u32 = 64 * 1024;
pub(crate) const MAX_BATCH_STDERR_BYTES: u32 = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CheckedExecOptions {
    timeout: Duration,
    max_stdout_bytes: usize,
    max_stderr_bytes: usize,
}

impl CheckedExecOptions {
    pub(crate) const fn monitor_snapshot() -> Self {
        Self {
            timeout: Duration::from_secs(5),
            max_stdout_bytes: 256 * 1024,
            max_stderr_bytes: 256 * 1024,
        }
    }

    pub(crate) const fn docker_operation() -> Self {
        Self {
            timeout: Duration::from_secs(12),
            max_stdout_bytes: 1024 * 1024,
            max_stderr_bytes: 256 * 1024,
        }
    }

    pub(crate) fn batch(
        timeout_seconds: u32,
        max_stdout_bytes: u32,
        max_stderr_bytes: u32,
    ) -> Result<Self, CheckedExecError> {
        let timeout_seconds = if timeout_seconds == 0 {
            DEFAULT_BATCH_TIMEOUT_SECONDS
        } else {
            timeout_seconds
        };
        let max_stdout_bytes = if max_stdout_bytes == 0 {
            DEFAULT_BATCH_STDOUT_BYTES
        } else {
            max_stdout_bytes
        };
        let max_stderr_bytes = if max_stderr_bytes == 0 {
            DEFAULT_BATCH_STDERR_BYTES
        } else {
            max_stderr_bytes
        };
        if timeout_seconds > MAX_BATCH_TIMEOUT_SECONDS
            || max_stdout_bytes > MAX_BATCH_STDOUT_BYTES
            || max_stderr_bytes > MAX_BATCH_STDERR_BYTES
        {
            return Err(CheckedExecError::InvalidOptions);
        }
        Self {
            timeout: Duration::from_secs(u64::from(timeout_seconds)),
            max_stdout_bytes: max_stdout_bytes as usize,
            max_stderr_bytes: max_stderr_bytes as usize,
        }
        .validate()
    }

    #[cfg(test)]
    pub(crate) fn batch_values_for_tests(self) -> (u64, usize, usize) {
        (
            self.timeout.as_secs(),
            self.max_stdout_bytes,
            self.max_stderr_bytes,
        )
    }

    fn validate(self) -> Result<Self, CheckedExecError> {
        if self.timeout.is_zero()
            || self.max_stdout_bytes == 0
            || self.max_stderr_bytes == 0
            || self.max_stdout_bytes > MAX_CONFIGURED_OUTPUT_BYTES
            || self.max_stderr_bytes > MAX_CONFIGURED_OUTPUT_BYTES
        {
            return Err(CheckedExecError::InvalidOptions);
        }
        Ok(self)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct CheckedExecOutput {
    stdout: String,
    stderr: String,
    exit_status: u32,
}

impl fmt::Debug for CheckedExecOutput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedExecOutput")
            .field("stdout", &"[REDACTED]")
            .field("stderr", &"[REDACTED]")
            .field("exit_status", &self.exit_status)
            .finish()
    }
}

impl CheckedExecOutput {
    pub(crate) fn new(stdout: String, stderr: String, exit_status: u32) -> Self {
        Self {
            stdout,
            stderr,
            exit_status,
        }
    }

    pub(crate) fn stdout(&self) -> &str {
        &self.stdout
    }

    #[allow(
        dead_code,
        reason = "reserved for checked Docker and batch command migration"
    )]
    pub(crate) fn stderr(&self) -> &str {
        &self.stderr
    }

    #[allow(
        dead_code,
        reason = "reserved for checked Docker and batch command migration"
    )]
    pub(crate) const fn exit_status(&self) -> u32 {
        self.exit_status
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum CheckedExecError {
    #[error("checked exec channel access was denied")]
    ChannelAccess(CheckedChannelAccessError),
    #[error("checked exec command is invalid")]
    InvalidCommand,
    #[error("checked exec command is too large")]
    CommandTooLarge,
    #[error("checked exec options are invalid")]
    InvalidOptions,
    #[error("checked exec request failed")]
    ExecRequestFailed,
    #[error("checked exec output failed")]
    ExecOutputFailed,
    #[error("checked exec output limit was exceeded")]
    OutputLimitExceeded,
    #[error("checked exec timed out")]
    Timeout,
    #[error("checked exec command returned a nonzero status")]
    CommandFailed { exit_status: u32 },
}

impl From<CheckedChannelAccessError> for CheckedExecError {
    fn from(value: CheckedChannelAccessError) -> Self {
        Self::ChannelAccess(value)
    }
}

pub(crate) trait CheckedExecBackend {
    fn execute<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
        command: &'a str,
        options: CheckedExecOptions,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>;
}

struct RusshCheckedExecBackend;

impl CheckedExecBackend for RusshCheckedExecBackend {
    fn execute<'a>(
        &'a self,
        guard: &'a VerifiedBaseSessionGuard,
        command: &'a str,
        options: CheckedExecOptions,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(async move {
            let execution = async {
                guard.revalidate()?;
                let ssh = guard.base().ssh.lock().await;
                let mut channel = ssh
                    .channel_open_session()
                    .await
                    .map_err(|_| CheckedChannelAccessError::ChannelOpenFailed)?;
                drop(ssh);

                channel
                    .exec(true, command)
                    .await
                    .map_err(|_| CheckedExecError::ExecRequestFailed)?;

                let mut stdout = Vec::new();
                let mut stderr = Vec::new();
                let mut exit_status = None;
                while let Some(message) = channel.wait().await {
                    match message {
                        ChannelMsg::Data { data } => {
                            append_bounded(&mut stdout, &data, options.max_stdout_bytes)?
                        }
                        ChannelMsg::ExtendedData { data, .. } => {
                            append_bounded(&mut stderr, &data, options.max_stderr_bytes)?
                        }
                        ChannelMsg::ExitStatus { exit_status: value } => {
                            exit_status = Some(value);
                        }
                        _ => {}
                    }
                }

                let exit_status = exit_status.ok_or(CheckedExecError::ExecOutputFailed)?;
                if exit_status != 0 {
                    return Err(CheckedExecError::CommandFailed { exit_status });
                }
                let stdout =
                    String::from_utf8(stdout).map_err(|_| CheckedExecError::ExecOutputFailed)?;
                let stderr =
                    String::from_utf8(stderr).map_err(|_| CheckedExecError::ExecOutputFailed)?;
                guard.revalidate()?;
                Ok(CheckedExecOutput::new(stdout, stderr, exit_status))
            };

            tokio::time::timeout(options.timeout, execution)
                .await
                .map_err(|_| CheckedExecError::Timeout)?
        })
    }
}

pub(crate) async fn run_remote_command_checked(
    base_session_id: u64,
    command: &str,
    options: CheckedExecOptions,
) -> Result<CheckedExecOutput, CheckedExecError> {
    run_remote_command_checked_with_backend(
        base_session_id,
        command,
        options,
        &RusshCheckedExecBackend,
    )
    .await
}

pub(crate) async fn run_remote_command_checked_with_backend<B: CheckedExecBackend>(
    base_session_id: u64,
    command: &str,
    options: CheckedExecOptions,
    backend: &B,
) -> Result<CheckedExecOutput, CheckedExecError> {
    validate_command(command)?;
    let options = options.validate()?;
    let guard = require_active_verified_base_session(base_session_id)?;
    guard.revalidate()?;
    let output = backend.execute(&guard, command, options).await?;
    guard.revalidate()?;
    Ok(output)
}

pub(crate) fn validate_command(command: &str) -> Result<(), CheckedExecError> {
    if command.trim().is_empty() || command.chars().any(char::is_control) {
        return Err(CheckedExecError::InvalidCommand);
    }
    if command.len() > MAX_COMMAND_BYTES {
        return Err(CheckedExecError::CommandTooLarge);
    }
    Ok(())
}

fn append_bounded(
    destination: &mut Vec<u8>,
    data: &[u8],
    limit: usize,
) -> Result<(), CheckedExecError> {
    if destination
        .len()
        .checked_add(data.len())
        .is_none_or(|length| length > limit)
    {
        return Err(CheckedExecError::OutputLimitExceeded);
    }
    destination.extend_from_slice(data);
    Ok(())
}

#[cfg(test)]
pub(crate) fn append_bounded_for_tests(
    destination: &mut Vec<u8>,
    data: &[u8],
    limit: usize,
) -> Result<(), CheckedExecError> {
    append_bounded(destination, data, limit)
}
