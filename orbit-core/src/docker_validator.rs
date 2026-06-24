use std::fmt;

use thiserror::Error;

const MIN_CONTAINER_ID_LENGTH: usize = 12;
const MAX_CONTAINER_ID_LENGTH: usize = 64;
const MAX_LOG_TAIL: u32 = 10_000;
const LEGACY_DEFAULT_LOG_TAIL: u32 = 200;
const LEGACY_MAX_EFFECTIVE_LOG_TAIL: u32 = 2_000;
const MAX_CONTAINER_NAME_LENGTH: usize = 128;
const MAX_MEMORY_LIMIT_DIGITS: usize = 19;
const MIN_CPU_SHARES: u32 = 2;
const MAX_CPU_SHARES: u32 = 262_144;

pub(crate) struct DockerCommandValidator;

impl DockerCommandValidator {
    pub(crate) fn validate_container_id(
        raw: &str,
    ) -> Result<ValidatedContainerId, DockerValidationError> {
        ValidatedContainerId::parse(raw)
    }

    pub(crate) fn validate_action(raw: &str) -> Result<DockerAction, DockerValidationError> {
        DockerAction::parse(raw)
    }

    pub(crate) fn validate_logs_options(
        tail_lines: u32,
    ) -> Result<DockerLogsOptions, DockerValidationError> {
        DockerLogsOptions::new(tail_lines)
    }

    pub(crate) fn validate_container_name(
        raw: &str,
    ) -> Result<ValidatedContainerName, DockerValidationError> {
        ValidatedContainerName::parse(raw)
    }

    pub(crate) fn validate_update_options(
        restart_policy: Option<&str>,
        memory_limit: Option<&str>,
        cpu_shares: Option<u32>,
    ) -> Result<DockerUpdateOptions, DockerValidationError> {
        DockerUpdateOptions::parse(restart_policy, memory_limit, cpu_shares)
    }

    pub(crate) fn action_command(
        container_id: &str,
        action: &str,
    ) -> Result<ValidatedDockerCommand, DockerValidationError> {
        let container_id = Self::validate_container_id(container_id)?;
        let action = Self::validate_action(action)?;
        Ok(ValidatedDockerCommand::for_action(&container_id, action))
    }

    pub(crate) fn logs_command(
        container_id: &str,
        tail_lines: u32,
    ) -> Result<ValidatedDockerCommand, DockerValidationError> {
        let container_id = Self::validate_container_id(container_id)?;
        let options = Self::validate_logs_options(tail_lines)?;
        Ok(ValidatedDockerCommand::for_logs(&container_id, options))
    }

    pub(crate) fn rename_command(
        container_id: &str,
        new_name: &str,
    ) -> Result<ValidatedDockerCommand, DockerValidationError> {
        let container_id = Self::validate_container_id(container_id)?;
        let new_name = Self::validate_container_name(new_name)?;
        Ok(Self::rename_command_typed(&container_id, &new_name))
    }

    pub(crate) fn rename_command_typed(
        container_id: &ValidatedContainerId,
        new_name: &ValidatedContainerName,
    ) -> ValidatedDockerCommand {
        ValidatedDockerCommand::for_rename(container_id, new_name)
    }

    pub(crate) fn update_command(
        container_id: &str,
        options: DockerUpdateOptions,
    ) -> Result<ValidatedDockerCommand, DockerValidationError> {
        let container_id = Self::validate_container_id(container_id)?;
        Ok(Self::update_command_typed(&container_id, &options))
    }

    pub(crate) fn update_command_typed(
        container_id: &ValidatedContainerId,
        options: &DockerUpdateOptions,
    ) -> ValidatedDockerCommand {
        ValidatedDockerCommand::for_update(container_id, options)
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct ValidatedContainerId(String);

impl ValidatedContainerId {
    fn parse(raw: &str) -> Result<Self, DockerValidationError> {
        if raw.is_empty() {
            return Err(DockerValidationError::EmptyContainerId);
        }
        if !(MIN_CONTAINER_ID_LENGTH..=MAX_CONTAINER_ID_LENGTH).contains(&raw.len()) {
            return Err(DockerValidationError::InvalidContainerIdLength);
        }
        if !raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(DockerValidationError::InvalidContainerIdCharacter);
        }
        Ok(Self(raw.to_string()))
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ValidatedContainerId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ValidatedContainerId")
            .field("value", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum DockerAction {
    Start,
    Stop,
    Restart,
    Kill,
    Pause,
    Unpause,
    Remove,
}

impl DockerAction {
    fn parse(raw: &str) -> Result<Self, DockerValidationError> {
        for (token, action) in [
            ("start", Self::Start),
            ("stop", Self::Stop),
            ("restart", Self::Restart),
            ("kill", Self::Kill),
            ("pause", Self::Pause),
            ("unpause", Self::Unpause),
            ("remove", Self::Remove),
        ] {
            if raw.eq_ignore_ascii_case(token) {
                return Ok(action);
            }
        }
        Err(DockerValidationError::InvalidAction)
    }

    const fn cli_token(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
            Self::Kill => "kill",
            Self::Pause => "pause",
            Self::Unpause => "unpause",
            Self::Remove => "rm",
        }
    }

    pub(crate) const fn wire_token(self) -> &'static str {
        match self {
            Self::Remove => "remove",
            _ => self.cli_token(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct DockerLogsOptions {
    effective_tail_lines: u32,
}

impl DockerLogsOptions {
    fn new(tail_lines: u32) -> Result<Self, DockerValidationError> {
        if tail_lines > MAX_LOG_TAIL {
            return Err(DockerValidationError::InvalidTail);
        }
        let effective_tail_lines = if tail_lines == 0 {
            LEGACY_DEFAULT_LOG_TAIL
        } else {
            tail_lines.min(LEGACY_MAX_EFFECTIVE_LOG_TAIL)
        };
        Ok(Self {
            effective_tail_lines,
        })
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct ValidatedContainerName(String);

impl ValidatedContainerName {
    fn parse(raw: &str) -> Result<Self, DockerValidationError> {
        if raw.is_empty() || raw.len() > MAX_CONTAINER_NAME_LENGTH {
            return Err(DockerValidationError::InvalidContainerName);
        }
        let mut bytes = raw.bytes();
        if !bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
            || !bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
        {
            return Err(DockerValidationError::InvalidContainerName);
        }
        Ok(Self(raw.to_string()))
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ValidatedContainerName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ValidatedContainerName")
            .field("value", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum DockerRestartPolicy {
    No,
    Always,
    UnlessStopped,
    OnFailure,
}

impl DockerRestartPolicy {
    fn parse(raw: &str) -> Result<Self, DockerValidationError> {
        match raw {
            "no" => Ok(Self::No),
            "always" => Ok(Self::Always),
            "unless-stopped" => Ok(Self::UnlessStopped),
            "on-failure" => Ok(Self::OnFailure),
            _ => Err(DockerValidationError::InvalidRestartPolicy),
        }
    }

    const fn cli_token(self) -> &'static str {
        match self {
            Self::No => "no",
            Self::Always => "always",
            Self::UnlessStopped => "unless-stopped",
            Self::OnFailure => "on-failure",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct ValidatedMemoryLimit(String);

impl ValidatedMemoryLimit {
    fn parse(raw: &str) -> Result<Self, DockerValidationError> {
        let (digits, suffix) = match raw.as_bytes().last().copied() {
            Some(byte) if byte.is_ascii_alphabetic() => (&raw[..raw.len() - 1], Some(byte)),
            _ => (raw, None),
        };
        if digits.is_empty()
            || digits.len() > MAX_MEMORY_LIMIT_DIGITS
            || digits.starts_with('0')
            || !digits.bytes().all(|byte| byte.is_ascii_digit())
            || suffix
                .is_some_and(|byte| !matches!(byte.to_ascii_lowercase(), b'b' | b'k' | b'm' | b'g'))
        {
            return Err(DockerValidationError::InvalidMemoryLimit);
        }
        let mut canonical = digits.to_string();
        if let Some(suffix) = suffix {
            canonical.push(char::from(suffix.to_ascii_lowercase()));
        }
        Ok(Self(canonical))
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ValidatedMemoryLimit {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ValidatedMemoryLimit")
            .field("value", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DockerUpdateOptions {
    restart_policy: Option<DockerRestartPolicy>,
    memory_limit: Option<ValidatedMemoryLimit>,
    cpu_shares: Option<u32>,
}

impl DockerUpdateOptions {
    fn parse(
        restart_policy: Option<&str>,
        memory_limit: Option<&str>,
        cpu_shares: Option<u32>,
    ) -> Result<Self, DockerValidationError> {
        let restart_policy = restart_policy.map(DockerRestartPolicy::parse).transpose()?;
        let memory_limit = memory_limit.map(ValidatedMemoryLimit::parse).transpose()?;
        if cpu_shares.is_some_and(|value| !(MIN_CPU_SHARES..=MAX_CPU_SHARES).contains(&value)) {
            return Err(DockerValidationError::InvalidCpuShares);
        }
        if restart_policy.is_none() && memory_limit.is_none() && cpu_shares.is_none() {
            return Err(DockerValidationError::EmptyUpdateOptions);
        }
        Ok(Self {
            restart_policy,
            memory_limit,
            cpu_shares,
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ValidatedDockerCommand(String);

impl ValidatedDockerCommand {
    fn for_action(container_id: &ValidatedContainerId, action: DockerAction) -> Self {
        let command = match action {
            DockerAction::Remove => format!("docker rm -f {}", container_id.as_str()),
            _ => format!("docker {} {}", action.cli_token(), container_id.as_str()),
        };
        Self(command)
    }

    fn for_logs(container_id: &ValidatedContainerId, options: DockerLogsOptions) -> Self {
        Self(format!(
            "docker logs --tail {} {} 2>&1",
            options.effective_tail_lines,
            container_id.as_str()
        ))
    }

    fn for_rename(container_id: &ValidatedContainerId, new_name: &ValidatedContainerName) -> Self {
        Self(format!(
            "docker rename {} {}",
            container_id.as_str(),
            new_name.as_str()
        ))
    }

    fn for_update(container_id: &ValidatedContainerId, options: &DockerUpdateOptions) -> Self {
        let mut command = String::from("docker update");
        if let Some(policy) = options.restart_policy {
            command.push_str(" --restart ");
            command.push_str(policy.cli_token());
        }
        if let Some(memory_limit) = &options.memory_limit {
            command.push_str(" --memory ");
            command.push_str(memory_limit.as_str());
        }
        if let Some(cpu_shares) = options.cpu_shares {
            command.push_str(" --cpu-shares ");
            command.push_str(&cpu_shares.to_string());
        }
        command.push(' ');
        command.push_str(container_id.as_str());
        Self(command)
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ValidatedDockerCommand {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ValidatedDockerCommand")
            .field("command", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub(crate) enum DockerValidationError {
    #[error("Docker container ID is empty")]
    EmptyContainerId,
    #[error("Docker container ID length is invalid")]
    InvalidContainerIdLength,
    #[error("Docker container ID contains an invalid character")]
    InvalidContainerIdCharacter,
    #[error("Docker container name is invalid")]
    InvalidContainerName,
    #[error("Docker action is invalid")]
    InvalidAction,
    #[error("Docker logs tail is invalid")]
    InvalidTail,
    #[error("Docker restart policy is invalid")]
    InvalidRestartPolicy,
    #[error("Docker memory limit is invalid")]
    InvalidMemoryLimit,
    #[error("Docker CPU shares value is invalid")]
    InvalidCpuShares,
    #[error("Docker update options are empty")]
    EmptyUpdateOptions,
    #[allow(dead_code, reason = "reserved for future typed Docker time filters")]
    #[error("Docker timestamp is invalid")]
    InvalidTimestamp,
    #[allow(dead_code, reason = "reserved for future typed Docker operations")]
    #[error("Docker option is unsupported")]
    UnsupportedOption,
    #[allow(dead_code, reason = "reserved for future typed Docker operations")]
    #[error("Docker parameter is unsafe")]
    UnsafeParameter,
    #[allow(dead_code, reason = "reserved for checked Docker invariant mapping")]
    #[error("Docker validation invariant failed")]
    InternalInvariantViolation,
}

impl DockerValidationError {
    pub(crate) const fn reason_code(self) -> &'static str {
        match self {
            Self::EmptyContainerId => "empty_container_id",
            Self::InvalidContainerIdLength => "invalid_container_id_length",
            Self::InvalidContainerIdCharacter => "invalid_container_id_character",
            Self::InvalidContainerName => "invalid_container_name",
            Self::InvalidAction => "invalid_action",
            Self::InvalidTail => "invalid_tail",
            Self::InvalidRestartPolicy => "invalid_restart_policy",
            Self::InvalidMemoryLimit => "invalid_memory_limit",
            Self::InvalidCpuShares => "invalid_cpu_shares",
            Self::EmptyUpdateOptions => "empty_update_options",
            Self::InvalidTimestamp => "invalid_timestamp",
            Self::UnsupportedOption => "unsupported_option",
            Self::UnsafeParameter => "unsafe_parameter",
            Self::InternalInvariantViolation => "internal_invariant",
        }
    }
}
