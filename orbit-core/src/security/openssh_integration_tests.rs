use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::ptr;
use std::thread;
use std::time::Duration;

use serde_json::Value;

use super::checked_docker_ffi::orbit_docker_list_checked_v1;
use super::checked_exec_ffi::orbit_exec_checked_v1;
use super::checked_monitor_ffi::orbit_monitor_snapshot_checked_v1;
use super::checked_sftp_ffi::orbit_sftp_open_checked_v1;
use super::checked_ssh_connect_ffi::orbit_ssh_connect_checked_v1;
use super::checked_terminal_ffi::orbit_terminal_open_checked_v1;
use super::checked_test_connection_ffi::orbit_test_ssh_connection_checked_v1;
use super::host_key_ffi_api::orbit_hostkey_challenge_accept_and_persist_v1;
use crate::c_ffi::{
    orbit_exec_command, orbit_free_string, orbit_sftp_connect, orbit_sftp_disconnect,
    orbit_sftp_list_dir, orbit_ssh_connect, orbit_ssh_disconnect, orbit_terminal_close,
    orbit_test_ssh_connection,
};

const OPT_IN_VARIABLE: &str = "ORBITTERM_RUN_OPENSSH_SMOKE";

struct OpenSshFixtureConfig {
    scenario: String,
    root: PathBuf,
    host: String,
    port: i32,
    username: String,
    private_key: String,
    known_hosts_path: PathBuf,
    remote_test_dir: PathBuf,
    host_public_key: String,
    sshd_log_path: PathBuf,
}

impl OpenSshFixtureConfig {
    fn from_environment() -> Self {
        assert_eq!(std::env::var(OPT_IN_VARIABLE).as_deref(), Ok("1"));
        let root = required_path("ORBITTERM_OPENSSH_FIXTURE_ROOT");
        let known_hosts_path = required_path("ORBITTERM_OPENSSH_KNOWN_HOSTS_PATH");
        let private_key_path = required_path("ORBITTERM_OPENSSH_USER_KEY_PATH");
        let host_public_key_path = required_path("ORBITTERM_OPENSSH_HOST_PUBLIC_KEY_PATH");
        let sshd_log_path = required_path("ORBITTERM_OPENSSH_SSHD_LOG_PATH");
        let remote_test_dir = required_path("ORBITTERM_OPENSSH_REMOTE_TEST_DIR")
            .canonicalize()
            .expect("remote fixture directory");
        let canonical_root = root.canonicalize().expect("fixture root must exist");
        let canonical_parent = known_hosts_path
            .parent()
            .expect("known_hosts parent")
            .canonicalize()
            .expect("known_hosts parent must exist");
        assert!(canonical_parent.starts_with(&canonical_root));
        assert!(remote_test_dir.starts_with(&canonical_root));
        let known_hosts_path =
            canonical_parent.join(known_hosts_path.file_name().expect("known_hosts file name"));
        assert!(canonical_root
            .to_string_lossy()
            .to_ascii_lowercase()
            .contains("orbitterm"));
        let home = required_path("HOME").canonicalize().expect("fixture HOME");
        assert!(home.starts_with(&canonical_root));

        let host_public_key_line =
            fs::read_to_string(host_public_key_path).expect("read generated host public key");
        let host_public_key = host_public_key_line
            .split_whitespace()
            .nth(1)
            .expect("host public key body")
            .to_string();

        Self {
            scenario: required_env("ORBITTERM_OPENSSH_SCENARIO"),
            root: canonical_root,
            host: required_env("ORBITTERM_OPENSSH_HOST"),
            port: required_env("ORBITTERM_OPENSSH_PORT")
                .parse()
                .expect("OpenSSH port"),
            username: required_env("ORBITTERM_OPENSSH_USERNAME"),
            private_key: fs::read_to_string(private_key_path).expect("read generated user key"),
            known_hosts_path,
            remote_test_dir,
            host_public_key,
            sshd_log_path,
        }
    }

    fn connection_arguments(
        &self,
        request_id: &str,
    ) -> (CString, CString, CString, CString, CString, CString) {
        (
            c_string(&self.host),
            c_string(&self.username),
            c_string(""),
            c_string(&self.private_key),
            c_string(
                self.known_hosts_path
                    .to_str()
                    .expect("UTF-8 known_hosts path"),
            ),
            c_string(request_id),
        )
    }

    fn accepted_auth_count(&self) -> usize {
        log_count(&self.sshd_log_path, "Accepted publickey for ")
    }

    fn connection_count(&self) -> usize {
        log_count(&self.sshd_log_path, "Connection from 127.0.0.1")
    }
}

fn required_env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("missing {name}"))
}

fn required_path(name: &str) -> PathBuf {
    PathBuf::from(required_env(name))
}

fn c_string(value: &str) -> CString {
    CString::new(value).expect("fixture strings must not contain NUL")
}

fn take_owned_string(pointer: *mut c_char) -> String {
    assert!(!pointer.is_null());
    // SAFETY: Orbit C ABI strings are NUL-terminated and remain valid until
    // released exactly once with orbit_free_string.
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .expect("Orbit response must be UTF-8")
        .to_string();
    orbit_free_string(pointer);
    value
}

fn take_json(pointer: *mut c_char) -> Value {
    let text = take_owned_string(pointer);
    serde_json::from_str(&text).unwrap_or_else(|_| panic!("invalid JSON envelope kind"))
}

fn log_count(path: &Path, needle: &str) -> usize {
    fs::read_to_string(path)
        .unwrap_or_default()
        .matches(needle)
        .count()
}

fn wait_for_sshd_log_flush() {
    thread::sleep(Duration::from_millis(150));
}

fn assert_envelope(value: &Value, request_id: &str, kind: &str) {
    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["request_id"], request_id);
    assert_eq!(value["kind"], kind);
}

fn call_checked_test(config: &OpenSshFixtureConfig, request_id: &str) -> Value {
    let (host, username, password, private_key, known_hosts, request_id) =
        config.connection_arguments(request_id);
    take_json(orbit_test_ssh_connection_checked_v1(
        host.as_ptr(),
        config.port,
        username.as_ptr(),
        password.as_ptr(),
        private_key.as_ptr(),
        ptr::null(),
        0,
        known_hosts.as_ptr(),
        request_id.as_ptr(),
    ))
}

fn call_checked_connect(config: &OpenSshFixtureConfig, request_id: &str) -> Value {
    let (host, username, password, private_key, known_hosts, request_id) =
        config.connection_arguments(request_id);
    take_json(orbit_ssh_connect_checked_v1(
        host.as_ptr(),
        config.port,
        username.as_ptr(),
        password.as_ptr(),
        private_key.as_ptr(),
        ptr::null(),
        0,
        known_hosts.as_ptr(),
        request_id.as_ptr(),
    ))
}

fn decimal_id(value: &Value) -> u64 {
    value
        .as_str()
        .and_then(|value| value.parse().ok())
        .or_else(|| value.as_u64())
        .expect("decimal session identifier")
}

fn assert_blocked(config: &OpenSshFixtureConfig, reason: &str) {
    let before_auth = config.accepted_auth_count();
    let request_id = format!("openssh-{}-blocked", config.scenario);
    let response = call_checked_connect(config, &request_id);
    assert_envelope(&response, &request_id, "host_key_blocked");
    assert_eq!(response["data"]["reason_code"], reason);
    assert_eq!(response["data"]["can_trust"], false);
    assert_eq!(response["data"]["can_replace"], reason == "changed");
    assert!(response["data"]["presented_fingerprint_sha256"]
        .as_str()
        .is_some_and(|value| value.starts_with("SHA256:")));
    if reason == "changed" {
        assert!(response["data"]["previous_fingerprint_sha256"]
            .as_str()
            .is_some_and(|value| value.starts_with("SHA256:")));
    }
    wait_for_sshd_log_flush();
    assert_eq!(config.accepted_auth_count(), before_auth);
}

fn run_trusted_flow(config: &OpenSshFixtureConfig) {
    assert!(!config.known_hosts_path.exists());
    let before_unknown_auth = config.accepted_auth_count();
    let challenge_request = "openssh-unknown";
    let challenge = call_checked_test(config, challenge_request);
    assert_envelope(&challenge, challenge_request, "host_key_challenge");
    assert_eq!(challenge["data"]["request_id"], challenge_request);
    assert_eq!(challenge["data"]["host"], config.host);
    assert_eq!(challenge["data"]["port"], config.port);
    assert_eq!(challenge["data"]["key_algorithm"], "ssh-ed25519");
    assert!(challenge["data"]["fingerprint_sha256"]
        .as_str()
        .is_some_and(|value| value.starts_with("SHA256:")));
    assert!(!challenge.to_string().contains(&config.host_public_key));
    wait_for_sshd_log_flush();
    assert_eq!(config.accepted_auth_count(), before_unknown_auth);

    let challenge_id = challenge["data"]["challenge_id"]
        .as_str()
        .expect("challenge ID");
    let challenge_id_c = c_string(challenge_id);
    let known_hosts_c = c_string(
        config
            .known_hosts_path
            .to_str()
            .expect("UTF-8 known_hosts path"),
    );
    let comment = c_string("OrbitTerm OpenSSH smoke");
    let persisted = take_json(orbit_hostkey_challenge_accept_and_persist_v1(
        challenge_id_c.as_ptr(),
        known_hosts_c.as_ptr(),
        comment.as_ptr(),
    ));
    assert_envelope(&persisted, challenge_request, "host_key_trust_persisted");
    assert_eq!(persisted["data"]["challenge_id"], challenge_id);
    assert!(config.known_hosts_path.is_file());
    assert!(fs::read_to_string(&config.known_hosts_path)
        .expect("persisted known_hosts")
        .contains("ssh-ed25519"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&config.known_hosts_path)
                .expect("known_hosts metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    let trusted_test_request = "openssh-trusted-test";
    let trusted_test = call_checked_test(config, trusted_test_request);
    assert_envelope(
        &trusted_test,
        trusted_test_request,
        "connection_test_succeeded",
    );

    let connect_request = "openssh-trusted-connect";
    let connected = call_checked_connect(config, connect_request);
    assert_envelope(&connected, connect_request, "connected");
    let base_session_id = decimal_id(&connected["data"]["session_id"]);
    assert_eq!(
        connected["data"]["security_generation"],
        "host_key_verified"
    );

    let terminal_request = c_string("openssh-terminal");
    let terminal = take_json(orbit_terminal_open_checked_v1(
        base_session_id,
        120,
        36,
        terminal_request.as_ptr(),
    ));
    assert_envelope(&terminal, "openssh-terminal", "terminal_channel_opened");
    let terminal_id = decimal_id(&terminal["data"]["terminal_channel_id"]);
    assert!(take_owned_string(orbit_terminal_close(terminal_id)).starts_with("OK:"));

    let sftp_request = c_string("openssh-sftp");
    let sftp = take_json(orbit_sftp_open_checked_v1(
        base_session_id,
        sftp_request.as_ptr(),
    ));
    assert_envelope(&sftp, "openssh-sftp", "sftp_channel_opened");
    let sftp_id = decimal_id(&sftp["data"]["sftp_session_id"]);
    let remote_test_dir = c_string(
        config
            .remote_test_dir
            .to_str()
            .expect("UTF-8 remote fixture directory"),
    );
    assert!(
        take_owned_string(orbit_sftp_list_dir(sftp_id, remote_test_dir.as_ptr()))
            .starts_with("OK:")
    );
    assert!(take_owned_string(orbit_sftp_disconnect(sftp_id)).starts_with("OK:"));

    let exec_request = c_string("openssh-exec");
    let command = c_string("printf orbitterm-smoke");
    let exec = take_json(orbit_exec_checked_v1(
        base_session_id,
        command.as_ptr(),
        30,
        262_144,
        65_536,
        exec_request.as_ptr(),
    ));
    assert_envelope(&exec, "openssh-exec", "exec_result");
    assert_eq!(exec["data"]["stdout"], "orbitterm-smoke");
    assert_eq!(exec["data"]["stderr"], "");

    let nonzero_request = c_string("openssh-exec-nonzero");
    let nonzero_command = c_string("false");
    let nonzero = take_json(orbit_exec_checked_v1(
        base_session_id,
        nonzero_command.as_ptr(),
        30,
        262_144,
        65_536,
        nonzero_request.as_ptr(),
    ));
    assert_envelope(&nonzero, "openssh-exec-nonzero", "error");
    assert_eq!(nonzero["error"]["code"], "exec_command_failed");

    let multiline_request = c_string("openssh-exec-multiline");
    let multiline_command = c_string("printf one\nprintf two");
    let multiline = take_json(orbit_exec_checked_v1(
        base_session_id,
        multiline_command.as_ptr(),
        30,
        262_144,
        65_536,
        multiline_request.as_ptr(),
    ));
    assert_envelope(&multiline, "openssh-exec-multiline", "error");
    assert_eq!(multiline["error"]["code"], "invalid_command");

    let monitor_request = c_string("openssh-monitor");
    let monitor = take_json(orbit_monitor_snapshot_checked_v1(
        base_session_id,
        monitor_request.as_ptr(),
    ));
    assert_eq!(monitor["request_id"], "openssh-monitor");
    match monitor["kind"].as_str() {
        Some("monitor_snapshot") => {
            assert_eq!(
                monitor["data"]["base_session_id"],
                base_session_id.to_string()
            );
        }
        Some("error") => {
            assert!(matches!(
                monitor["error"]["code"].as_str(),
                Some("exec_command_failed" | "monitor_snapshot_failed")
            ));
            eprintln!("OpenSSH smoke: Monitor commands unavailable on fixture platform");
        }
        other => panic!("unexpected Monitor outcome: {other:?}"),
    }

    let docker_probe_request = c_string("openssh-docker-probe");
    let docker_probe_command = c_string("command -v docker >/dev/null 2>&1");
    let docker_probe = take_json(orbit_exec_checked_v1(
        base_session_id,
        docker_probe_command.as_ptr(),
        30,
        4_096,
        4_096,
        docker_probe_request.as_ptr(),
    ));
    if docker_probe["kind"] == "exec_result" {
        let docker_request = c_string("openssh-docker-list");
        let docker = take_json(orbit_docker_list_checked_v1(
            base_session_id,
            docker_request.as_ptr(),
        ));
        assert_eq!(docker["request_id"], "openssh-docker-list");
        assert!(matches!(
            docker["kind"].as_str(),
            Some("docker_containers" | "error")
        ));
    } else {
        assert_eq!(docker_probe["error"]["code"], "exec_command_failed");
        eprintln!("OpenSSH smoke: Docker unavailable on fixture host; skipped");
    }

    assert!(take_owned_string(orbit_ssh_disconnect(base_session_id)).starts_with("OK:"));
}

#[test]
#[ignore = "requires the loopback OpenSSH fixture script"]
fn openssh_checked_end_to_end_smoke() {
    let config = OpenSshFixtureConfig::from_environment();
    match config.scenario.as_str() {
        "trusted" => run_trusted_flow(&config),
        "changed" => assert_blocked(&config, "changed"),
        "revoked" => assert_blocked(&config, "revoked"),
        scenario => panic!("unsupported OpenSSH scenario: {scenario}"),
    }
    assert!(config.known_hosts_path.starts_with(&config.root));
}

#[test]
#[ignore = "requires a no-feature Release build and loopback OpenSSH fixture"]
fn openssh_release_legacy_no_socket_smoke() {
    let config = OpenSshFixtureConfig::from_environment();
    assert_eq!(config.scenario, "legacy-no-socket");
    let before_connections = config.connection_count();
    let before_auth = config.accepted_auth_count();
    let (host, username, password, private_key, _, _) =
        config.connection_arguments("unused-legacy-request");
    let legacy_calls = [
        orbit_test_ssh_connection(
            host.as_ptr(),
            config.port,
            username.as_ptr(),
            password.as_ptr(),
            private_key.as_ptr(),
            ptr::null(),
            0,
        ),
        orbit_ssh_connect(
            host.as_ptr(),
            config.port,
            username.as_ptr(),
            password.as_ptr(),
            private_key.as_ptr(),
            ptr::null(),
            0,
        ),
        orbit_sftp_connect(
            host.as_ptr(),
            config.port,
            username.as_ptr(),
            password.as_ptr(),
            private_key.as_ptr(),
            ptr::null(),
            0,
        ),
        orbit_exec_command(0, c_string("printf forbidden").as_ptr()),
    ];
    for pointer in legacy_calls {
        assert_eq!(take_owned_string(pointer), "ERR:legacy_network_disabled");
    }
    wait_for_sshd_log_flush();
    assert_eq!(config.connection_count(), before_connections);

    let checked = call_checked_test(&config, "openssh-release-checked-reaches-sshd");
    assert_envelope(
        &checked,
        "openssh-release-checked-reaches-sshd",
        "host_key_challenge",
    );
    wait_for_sshd_log_flush();
    assert!(config.connection_count() > before_connections);
    assert_eq!(config.accepted_auth_count(), before_auth);
}
