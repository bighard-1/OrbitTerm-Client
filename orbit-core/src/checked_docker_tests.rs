use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;

use crate::checked_docker::{
    docker_action_checked_with_backend, docker_rename_checked_with_backend,
    docker_update_checked_with_backend, fetch_docker_containers_checked_with_backend,
    fetch_docker_logs_checked_with_backend, fetch_docker_stats_checked_with_backend,
    CheckedDockerBackend, CheckedDockerError,
};
use crate::checked_exec::{CheckedExecError, CheckedExecOutput};
use crate::docker_validator::{DockerCommandValidator, DockerValidationError};
use crate::security::{
    fingerprint_sha256, CheckedChannelAccessError, HostIdentity, SessionLifecycleState,
    SessionSecurityGeneration, TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    resolve_base_session_by_base_id,
};

const CONTAINER_ID: &str = "0123456789ab";

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("example.com", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"checked-docker-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"checked-docker-store"),
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

struct FakeDockerBackend {
    result: Result<CheckedExecOutput, CheckedExecError>,
    calls: Mutex<Vec<String>>,
}

impl FakeDockerBackend {
    fn stdout(value: &str) -> Self {
        Self {
            result: Ok(CheckedExecOutput::new(value.to_string(), String::new(), 0)),
            calls: Mutex::new(Vec::new()),
        }
    }

    fn failing(error: CheckedExecError) -> Self {
        Self {
            result: Err(error),
            calls: Mutex::new(Vec::new()),
        }
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl CheckedDockerBackend for FakeDockerBackend {
    fn execute<'a>(
        &'a self,
        _base_session_id: u64,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<CheckedExecOutput, CheckedExecError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.calls.lock().unwrap().push(command.to_string());
            self.result.clone()
        })
    }
}

#[tokio::test]
async fn active_verified_base_runs_checked_list_stats_logs_and_action() {
    let base = TestBase::new(verified_generation());
    let list_backend = FakeDockerBackend::stdout(
        r#"{"ID":"0123456789ab","Names":"web","Image":"nginx","State":"running","Status":"Up","RunningFor":"1m"}"#,
    );
    let list = fetch_docker_containers_checked_with_backend(base.id, &list_backend)
        .await
        .unwrap();
    assert_eq!(list.base_session_id, base.id.to_string());
    assert_eq!(list.containers[0].id, CONTAINER_ID);

    let stats_backend = FakeDockerBackend::stdout(
        r#"{"ID":"0123456789ab","Name":"web","CPUPerc":"12.5%","MemPerc":"25%","MemUsage":"10MiB / 40MiB","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"2"}"#,
    );
    let stats = fetch_docker_stats_checked_with_backend(base.id, &stats_backend)
        .await
        .unwrap();
    assert_eq!(stats.stats[0].cpu_percent.as_f64(), Some(12.5));

    let logs_backend = FakeDockerBackend::stdout("line one\nline two\n");
    let logs = fetch_docker_logs_checked_with_backend(base.id, CONTAINER_ID, 100, &logs_backend)
        .await
        .unwrap();
    assert_eq!(logs.logs, "line one\nline two\n");
    assert_eq!(
        logs_backend.calls(),
        ["docker logs --tail 100 0123456789ab 2>&1"]
    );

    let action_backend = FakeDockerBackend::stdout("");
    let action =
        docker_action_checked_with_backend(base.id, CONTAINER_ID, "restart", &action_backend)
            .await
            .unwrap();
    assert_eq!(action.action, "restart");
    assert_eq!(action_backend.calls(), ["docker restart 0123456789ab"]);
}

#[tokio::test]
async fn rename_and_update_are_typed_checked_operations() {
    let base = TestBase::new(verified_generation());
    let rename_backend = FakeDockerBackend::stdout("");
    let container_id = DockerCommandValidator::validate_container_id(CONTAINER_ID).unwrap();
    let new_name = DockerCommandValidator::validate_container_name("web-prod").unwrap();
    docker_rename_checked_with_backend(base.id, container_id, new_name, &rename_backend)
        .await
        .unwrap();
    assert_eq!(
        rename_backend.calls(),
        ["docker rename 0123456789ab web-prod"]
    );

    let options =
        DockerCommandValidator::validate_update_options(Some("always"), Some("512m"), Some(1024))
            .unwrap();
    let update_backend = FakeDockerBackend::stdout("");
    let container_id = DockerCommandValidator::validate_container_id(CONTAINER_ID).unwrap();
    docker_update_checked_with_backend(base.id, container_id, options, &update_backend)
        .await
        .unwrap();
    assert_eq!(
        update_backend.calls(),
        ["docker update --restart always --memory 512m --cpu-shares 1024 0123456789ab"]
    );
}

#[tokio::test]
async fn legacy_non_active_unknown_and_untyped_ids_fail_before_exec() {
    let backend = FakeDockerBackend::stdout("");
    let legacy = TestBase::new(SessionSecurityGeneration::LegacyUnverified);
    assert_eq!(
        fetch_docker_containers_checked_with_backend(legacy.id, &backend)
            .await
            .unwrap_err(),
        CheckedDockerError::ChannelAccess(CheckedChannelAccessError::LegacySessionNotAllowed)
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
        assert!(
            fetch_docker_containers_checked_with_backend(base.id, &backend)
                .await
                .is_err()
        );
    }
    for non_base_id in [1_u64, 2, 9_000_000_000] {
        assert_eq!(
            fetch_docker_containers_checked_with_backend(non_base_id, &backend)
                .await
                .unwrap_err(),
            CheckedDockerError::ChannelAccess(CheckedChannelAccessError::SessionNotFound)
        );
    }
    assert!(backend.calls().is_empty());
}

#[tokio::test]
async fn malicious_parameters_fail_before_exec_and_are_not_echoed() {
    let base = TestBase::new(verified_generation());
    let backend = FakeDockerBackend::stdout("");
    let attack = "0123456789ab;echo stolen-secret";
    let error = docker_action_checked_with_backend(base.id, attack, "start", &backend)
        .await
        .unwrap_err();
    assert_eq!(
        error,
        CheckedDockerError::Validation(DockerValidationError::InvalidContainerIdCharacter)
    );
    assert!(!format!("{error:?} {error}").contains(attack));
    assert!(backend.calls().is_empty());

    assert!(DockerCommandValidator::validate_container_name("web;id").is_err());
    let invalid_update =
        DockerCommandValidator::validate_update_options(Some("always;id"), None, None);
    assert!(invalid_update.is_err());
    assert!(backend.calls().is_empty());
}

#[tokio::test]
async fn checked_exec_and_parse_failures_remain_structured() {
    let base = TestBase::new(verified_generation());
    let exec_backend = FakeDockerBackend::failing(CheckedExecError::Timeout);
    assert_eq!(
        fetch_docker_containers_checked_with_backend(base.id, &exec_backend)
            .await
            .unwrap_err(),
        CheckedDockerError::Exec(CheckedExecError::Timeout)
    );

    let parse_backend = FakeDockerBackend::stdout("not-json");
    assert_eq!(
        fetch_docker_containers_checked_with_backend(base.id, &parse_backend)
            .await
            .unwrap_err(),
        CheckedDockerError::ParseFailed
    );
}
