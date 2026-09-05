use orbit_linux_bridge::{
    decimal_id, register_terminal_output, BridgeError, CheckedConnectionRequest, CheckedCoreClient,
    RequestId,
};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let password = Zeroizing::new(std::env::var("ORBITTERM_SMOKE_PASSWORD")?);
    let username = std::env::var("ORBITTERM_SMOKE_USERNAME")?;
    let directory = tempfile::Builder::new()
        .prefix("OrbitTerm-linux-smoke-")
        .tempdir()?;
    let known_hosts_path = directory.path().join("known_hosts");
    let known_hosts = known_hosts_path
        .to_str()
        .ok_or("temporary known_hosts path is not UTF-8")?;
    let core = CheckedCoreClient::new();

    let first_request_id = RequestId::new();
    let first = connect(
        &core,
        &username,
        password.as_str(),
        known_hosts,
        &first_request_id,
    )?;
    let base_session_id = if first.kind == "host_key_challenge" {
        let challenge = first.require_kind("host_key_challenge")?;
        let challenge_id = challenge
            .get("challenge_id")
            .and_then(serde_json::Value::as_str)
            .ok_or("missing challenge id")?;
        core.accept_and_persist_host_key(
            challenge_id,
            known_hosts,
            "OrbitTerm Linux checked smoke",
            &first_request_id,
        )?
        .require_kind("host_key_trust_persisted")?;
        let connected = connect(
            &core,
            &username,
            password.as_str(),
            known_hosts,
            &RequestId::new(),
        )?;
        decimal_id(connected.require_kind("connected")?, "session_id")?
    } else {
        decimal_id(first.require_kind("connected")?, "session_id")?
    };

    core.monitor_snapshot(base_session_id, &RequestId::new())?
        .require_kind("monitor_snapshot")?;

    let executed = core.exec(
        base_session_id,
        "printf ORBITTERM_EXEC_SMOKE_OK",
        &RequestId::new(),
    )?;
    let stdout = executed
        .require_kind("exec_result")?
        .get("stdout")
        .and_then(serde_json::Value::as_str)
        .ok_or("missing checked exec stdout")?;
    if stdout != "ORBITTERM_EXEC_SMOKE_OK" {
        return Err("checked exec marker mismatch".into());
    }

    let sftp = core.open_sftp(base_session_id, &RequestId::new())?;
    let sftp_session_id = decimal_id(sftp.require_kind("sftp_channel_opened")?, "sftp_session_id")?;
    core.list_sftp(sftp_session_id, "/", &RequestId::new())?
        .require_kind("sftp_directory_list")?;
    core.close_sftp(sftp_session_id)?;

    let docker = core.docker_list(base_session_id, &RequestId::new())?;
    if docker.kind != "docker_containers" && docker.kind != "error" {
        return Err("unexpected checked Docker response kind".into());
    }

    let (sender, receiver) = mpsc::channel();
    register_terminal_output(sender)?;
    let opened = core.open_terminal(base_session_id, 100, 30, &RequestId::new())?;
    let terminal_channel_id = decimal_id(
        opened.require_kind("terminal_channel_opened")?,
        "terminal_channel_id",
    )?;
    core.write_terminal(
        terminal_channel_id,
        b"printf 'ORBITTERM_LINUX_SMOKE_OK\\n'; exit\n",
    )?;

    let marker = b"ORBITTERM_LINUX_SMOKE_OK";
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut output = Vec::new();
    while Instant::now() < deadline && !output.windows(marker.len()).any(|part| part == marker) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match receiver.recv_timeout(remaining.min(Duration::from_millis(500))) {
            Ok(chunk) if chunk.channel_id == terminal_channel_id => output.extend(chunk.bytes),
            Ok(_) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    if !output.windows(marker.len()).any(|part| part == marker) {
        return Err("checked terminal marker was not received".into());
    }

    let _ = core.close_terminal(terminal_channel_id);
    core.disconnect(base_session_id)?;
    println!("checked SSH, Host Key, exec, monitor, SFTP, Docker probe and PTY smoke passed");
    Ok(())
}

fn connect(
    core: &CheckedCoreClient,
    username: &str,
    password: &str,
    known_hosts: &str,
    request_id: &RequestId,
) -> Result<orbit_linux_bridge::CheckedEnvelope, BridgeError> {
    core.connect(
        &CheckedConnectionRequest {
            host: "127.0.0.1",
            port: 22,
            username,
            password,
            private_key: "",
            private_key_passphrase: "",
            allow_password_fallback: false,
            jump_host: None,
            known_hosts_path: known_hosts,
        },
        request_id,
    )
}
