use serde::Deserialize;
use serde_json::Value;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::mpsc::Sender;
use std::sync::Mutex;
use thiserror::Error;
use uuid::Uuid;

pub const CHECKED_ABI_SCHEMA_VERSION: u32 = 1;

pub const ALLOWED_NETWORK_SYMBOLS: &[&str] = &[
    "orbit_test_ssh_connection_checked_v1",
    "orbit_ssh_connect_checked_v1",
    "orbit_ssh_connect_checked_v2",
    "orbit_hostkey_challenge_accept_and_persist_v1",
    "orbit_terminal_open_checked_v1",
    "orbit_terminal_write",
    "orbit_terminal_resize",
    "orbit_terminal_close",
    "orbit_sftp_open_checked_v1",
    "orbit_sftp_list_checked_v1",
    "orbit_sftp_read_text_checked_v1",
    "orbit_sftp_download_checked_v1",
    "orbit_sftp_upload_checked_v1",
    "orbit_sftp_mkdir_checked_v1",
    "orbit_sftp_create_file_checked_v1",
    "orbit_sftp_rename_checked_v1",
    "orbit_sftp_remove_checked_v1",
    "orbit_sftp_chmod_checked_v1",
    "orbit_sftp_write_text_checked_v1",
    "orbit_sftp_disconnect",
    "orbit_monitor_snapshot_checked_v1",
    "orbit_docker_list_checked_v1",
    "orbit_docker_stats_checked_v1",
    "orbit_docker_logs_checked_v1",
    "orbit_docker_action_checked_v1",
    "orbit_local_tunnel_start_checked_v1",
    "orbit_local_tunnel_stop_checked_v1",
    "orbit_exec_checked_v1",
    "orbit_ssh_disconnect",
];

const MAX_TERMINAL_WRITE_BYTES: usize = 64 * 1024;
const MAX_TERMINAL_CALLBACK_BYTES: usize = 1024 * 1024;
const MAX_SFTP_TEXT_BYTES: usize = 2 * 1024 * 1024;
const MAX_DOCKER_LOG_BYTES: usize = 1024 * 1024;
static TERMINAL_OUTPUT: Mutex<Option<Sender<TerminalChunk>>> = Mutex::new(None);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestId(String);

impl RequestId {
    pub fn new() -> Self {
        Self(format!("linux-{}", Uuid::new_v4().simple()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for RequestId {
    fn default() -> Self {
        Self::new()
    }
}

pub struct CheckedConnectionRequest<'a> {
    pub host: &'a str,
    pub port: u16,
    pub username: &'a str,
    pub password: &'a str,
    pub private_key: &'a str,
    pub private_key_passphrase: &'a str,
    pub allow_password_fallback: bool,
    pub jump_host: Option<CheckedJumpHostRequest<'a>>,
    pub known_hosts_path: &'a str,
}

pub struct CheckedJumpHostRequest<'a> {
    pub host: &'a str,
    pub port: u16,
    pub username: &'a str,
    pub password: &'a str,
    pub private_key: &'a str,
    pub private_key_passphrase: &'a str,
    pub allow_password_fallback: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalChunk {
    pub channel_id: u64,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SftpEntry {
    pub name: String,
    pub size: u64,
    pub permissions: String,
    pub permissions_octal: u32,
    pub modified_at_unix: u64,
}

impl SftpEntry {
    pub fn is_directory(&self) -> bool {
        self.permissions.starts_with('d')
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SftpDirectoryListing {
    pub sftp_session_id: String,
    pub path: String,
    pub security_generation: String,
    pub entries: Vec<SftpEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SftpSession {
    pub id: u64,
    pub home_path: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SftpTextFile {
    pub sftp_session_id: String,
    pub path: String,
    pub security_generation: String,
    pub byte_length: u64,
    pub content: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SftpEntrySnapshot {
    pub size: u64,
    pub permissions_octal: u32,
    pub modified_at_unix: u64,
    pub is_directory: bool,
}

impl From<&SftpEntry> for SftpEntrySnapshot {
    fn from(entry: &SftpEntry) -> Self {
        Self {
            size: entry.size,
            permissions_octal: entry.permissions_octal,
            modified_at_unix: entry.modified_at_unix,
            is_directory: entry.is_directory(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct SftpOperationPayload {
    sftp_session_id: String,
    security_generation: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MonitorSnapshot {
    pub base_session_id: String,
    pub security_generation: String,
    pub stats: MonitorStats,
    pub diagnostics: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MonitorStats {
    pub sampled_at_unix: u64,
    pub cpu_usage_percent: f64,
    pub mem_available_mb: u64,
    pub mem_used_percent: f64,
    pub disk_used_percent: f64,
    pub ping_latency_ms: Option<f64>,
    pub rx_rate_kbps: f64,
    pub tx_rate_kbps: f64,
    pub system_info: MonitorSystemInfo,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct MonitorSystemInfo {
    pub os_name: String,
    pub cpu_core_count: u32,
    pub cpu_thread_count: u32,
    pub memory_total_mb: u64,
    pub swap_total_mb: u64,
    pub swap_used_mb: u64,
    pub disk_total_mb: u64,
    pub disk_used_mb: u64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct CheckedExecOutput {
    pub base_session_id: String,
    pub security_generation: String,
    pub stdout: String,
    pub stderr: String,
    pub exit_status: u32,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct DockerContainer {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub running_for: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct DockerStat {
    pub id: String,
    pub name: String,
    pub cpu_percent: f64,
    pub mem_percent: f64,
    pub mem_usage: String,
    pub net_io: String,
    pub block_io: String,
    pub pids: u32,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct DockerLogs {
    pub container_id: String,
    pub logs: String,
}

#[derive(Default)]
pub struct CheckedCoreClient;

impl CheckedCoreClient {
    pub fn new() -> Self {
        // Referencing a typed Rust symbol keeps orbit-core linked into the Linux
        // executable while all network calls remain on its audited C ABI.
        std::hint::black_box(orbit_core::encrypt_config);
        Self
    }

    pub fn connect(
        &self,
        request: &CheckedConnectionRequest<'_>,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        validate_connection_request(request)?;
        let host = c_string("host", request.host.trim())?;
        let username = c_string("username", request.username.trim())?;
        let password = c_string("password", request.password)?;
        let private_key = c_string("private_key", request.private_key)?;
        let passphrase = c_string("private_key_passphrase", request.private_key_passphrase)?;
        let known_hosts = c_string("known_hosts_path", request.known_hosts_path)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        let jump = request.jump_host.as_ref();
        let jump_host = c_string("jump_host", jump.map_or("", |value| value.host.trim()))?;
        let jump_username = c_string(
            "jump_username",
            jump.map_or("", |value| value.username.trim()),
        )?;
        let jump_password = c_string("jump_password", jump.map_or("", |value| value.password))?;
        let jump_private_key = c_string(
            "jump_private_key",
            jump.map_or("", |value| value.private_key),
        )?;
        let jump_passphrase = c_string(
            "jump_private_key_passphrase",
            jump.map_or("", |value| value.private_key_passphrase),
        )?;
        // SAFETY: All pointers remain valid for this synchronous call and the
        // returned Rust allocation is copied and released exactly once below.
        let pointer = unsafe {
            orbit_ssh_connect_checked_v2(
                host.as_ptr(),
                i32::from(request.port),
                username.as_ptr(),
                password.as_ptr(),
                private_key.as_ptr(),
                passphrase.as_ptr(),
                i32::from(request.allow_password_fallback),
                i32::from(jump.is_some()),
                jump_host.as_ptr(),
                jump.map_or(22, |value| i32::from(value.port)),
                jump_username.as_ptr(),
                jump_password.as_ptr(),
                jump_private_key.as_ptr(),
                jump_passphrase.as_ptr(),
                i32::from(jump.is_some_and(|value| value.allow_password_fallback)),
                known_hosts.as_ptr(),
                request_id_c.as_ptr(),
            )
        };
        decode_envelope(pointer, request_id)
    }

    pub fn accept_and_persist_host_key(
        &self,
        challenge_id: &str,
        known_hosts_path: &str,
        comment: &str,
        original_request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        if challenge_id.trim().is_empty()
            || known_hosts_path.trim().is_empty()
            || comment.len() > 128
            || comment.chars().any(char::is_control)
        {
            return Err(BridgeError::InvalidInput("host_key_trust"));
        }
        let challenge_id = c_string("challenge_id", challenge_id)?;
        let known_hosts_path = c_string("known_hosts_path", known_hosts_path)?;
        let comment = c_string("comment", comment)?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_hostkey_challenge_accept_and_persist_v1(
                challenge_id.as_ptr(),
                known_hosts_path.as_ptr(),
                comment.as_ptr(),
            )
        };
        decode_envelope(pointer, original_request_id)
    }

    pub fn open_terminal(
        &self,
        base_session_id: u64,
        columns: u32,
        rows: u32,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(base_session_id)?;
        ensure_terminal_size(columns, rows)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_terminal_open_checked_v1(base_session_id, columns, rows, request_id_c.as_ptr())
        };
        decode_envelope(pointer, request_id)
    }

    pub fn write_terminal(&self, channel_id: u64, bytes: &[u8]) -> Result<(), BridgeError> {
        ensure_session(channel_id)?;
        if bytes.is_empty() || bytes.len() > MAX_TERMINAL_WRITE_BYTES {
            return Err(BridgeError::InvalidInput("terminal_write"));
        }
        // SAFETY: The byte slice remains valid for this synchronous call.
        decode_control(unsafe { orbit_terminal_write(channel_id, bytes.as_ptr(), bytes.len()) })
    }

    pub fn resize_terminal(
        &self,
        channel_id: u64,
        columns: u32,
        rows: u32,
    ) -> Result<(), BridgeError> {
        ensure_session(channel_id)?;
        ensure_terminal_size(columns, rows)?;
        // SAFETY: This call takes only scalar values.
        decode_control(unsafe { orbit_terminal_resize(channel_id, columns, rows) })
    }

    pub fn close_terminal(&self, channel_id: u64) -> Result<(), BridgeError> {
        ensure_session(channel_id)?;
        // SAFETY: This call takes only a validated opaque identifier.
        decode_control(unsafe { orbit_terminal_close(channel_id) })
    }

    pub fn disconnect(&self, base_session_id: u64) -> Result<(), BridgeError> {
        ensure_session(base_session_id)?;
        // SAFETY: This call takes only a validated opaque identifier.
        decode_control(unsafe { orbit_ssh_disconnect(base_session_id) })
    }

    pub fn open_sftp(
        &self,
        base_session_id: u64,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(base_session_id)?;
        self.session_call(base_session_id, request_id, orbit_sftp_open_checked_v1)
    }

    pub fn open_sftp_session(&self, base_session_id: u64) -> Result<SftpSession, BridgeError> {
        let request_id = RequestId::new();
        let envelope = self.open_sftp(base_session_id, &request_id)?;
        let data = envelope.require_kind("sftp_channel_opened")?;
        verify_generation(data)?;
        let returned_base = decimal_id(data, "base_session_id")?;
        if returned_base != base_session_id {
            return Err(BridgeError::SessionMismatch);
        }
        let id = decimal_id(data, "sftp_session_id")?;
        let home_path = data
            .get("home_path")
            .and_then(Value::as_str)
            .ok_or(BridgeError::InvalidPayloadShape)?;
        validate_remote_path(home_path)?;
        Ok(SftpSession {
            id,
            home_path: home_path.to_owned(),
        })
    }

    pub fn list_sftp(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_remote_path(remote_path)?;
        let path = c_string("remote_path", remote_path)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_sftp_list_checked_v1(sftp_session_id, path.as_ptr(), request_id_c.as_ptr())
        };
        decode_envelope(pointer, request_id)
    }

    pub fn list_sftp_directory(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
    ) -> Result<SftpDirectoryListing, BridgeError> {
        let request_id = RequestId::new();
        let envelope = self.list_sftp(sftp_session_id, remote_path, &request_id)?;
        let listing: SftpDirectoryListing = decode_payload(&envelope, "sftp_directory_list")?;
        if parse_decimal_text(&listing.sftp_session_id, "sftp_session_id")? != sftp_session_id
            || listing.path != remote_path
        {
            return Err(BridgeError::SessionMismatch);
        }
        validate_generation(&listing.security_generation)?;
        if listing.entries.len() > 5_000
            || listing.entries.iter().any(|entry| {
                entry.name.is_empty()
                    || entry.name.len() > 255
                    || entry.name.contains('/')
                    || entry.name.chars().any(char::is_control)
                    || entry.permissions.len() > 32
                    || entry.permissions.chars().any(char::is_control)
            })
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(listing)
    }

    pub fn read_sftp_text(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
    ) -> Result<SftpTextFile, BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_remote_path(remote_path)?;
        let request_id = RequestId::new();
        let path = c_string("remote_path", remote_path)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_sftp_read_text_checked_v1(sftp_session_id, path.as_ptr(), request_id_c.as_ptr())
        };
        let envelope = decode_envelope(pointer, &request_id)?;
        let file: SftpTextFile = decode_payload(&envelope, "sftp_text_file")?;
        if parse_decimal_text(&file.sftp_session_id, "sftp_session_id")? != sftp_session_id
            || file.path != remote_path
            || file.content.len() > MAX_SFTP_TEXT_BYTES
            || file.byte_length != file.content.len() as u64
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        validate_generation(&file.security_generation)?;
        Ok(file)
    }

    pub fn create_sftp_directory(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
    ) -> Result<(), BridgeError> {
        self.sftp_path_operation(
            sftp_session_id,
            remote_path,
            orbit_sftp_mkdir_checked_v1,
            "sftp_mutation_completed",
        )
    }

    pub fn create_sftp_file(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
    ) -> Result<(), BridgeError> {
        self.sftp_path_operation(
            sftp_session_id,
            remote_path,
            orbit_sftp_create_file_checked_v1,
            "sftp_mutation_completed",
        )
    }

    pub fn rename_sftp_entry(
        &self,
        sftp_session_id: u64,
        old_path: &str,
        new_path: &str,
        snapshot: &SftpEntrySnapshot,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(old_path)?;
        validate_mutation_path(new_path)?;
        if old_path == new_path {
            return Err(BridgeError::InvalidInput("sftp_rename"));
        }
        let old_path = c_string("old_remote_path", old_path)?;
        let new_path = c_string("new_remote_path", new_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_sftp_rename_checked_v1(
                sftp_session_id,
                old_path.as_ptr(),
                new_path.as_ptr(),
                snapshot.size,
                snapshot.permissions_octal,
                snapshot.modified_at_unix,
                i32::from(snapshot.is_directory),
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            "sftp_mutation_completed",
            sftp_session_id,
        )
    }

    pub fn remove_sftp_entry(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        snapshot: &SftpEntrySnapshot,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(remote_path)?;
        let path = c_string("remote_path", remote_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_sftp_remove_checked_v1(
                sftp_session_id,
                path.as_ptr(),
                snapshot.size,
                snapshot.permissions_octal,
                snapshot.modified_at_unix,
                i32::from(snapshot.is_directory),
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            "sftp_mutation_completed",
            sftp_session_id,
        )
    }

    pub fn chmod_sftp_entry(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        mode: u32,
        snapshot: &SftpEntrySnapshot,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(remote_path)?;
        if mode > 0o7777 {
            return Err(BridgeError::InvalidInput("sftp_mode"));
        }
        let path = c_string("remote_path", remote_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_sftp_chmod_checked_v1(
                sftp_session_id,
                path.as_ptr(),
                mode,
                snapshot.size,
                snapshot.permissions_octal,
                snapshot.modified_at_unix,
                i32::from(snapshot.is_directory),
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            "sftp_mutation_completed",
            sftp_session_id,
        )
    }

    pub fn write_sftp_text(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        content: &str,
        snapshot: &SftpEntrySnapshot,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(remote_path)?;
        if snapshot.is_directory
            || content.len() > MAX_SFTP_TEXT_BYTES
            || content.as_bytes().contains(&0)
        {
            return Err(BridgeError::InvalidInput("sftp_text"));
        }
        let path = c_string("remote_path", remote_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_sftp_write_text_checked_v1(
                sftp_session_id,
                path.as_ptr(),
                content.as_ptr(),
                content.len(),
                snapshot.size,
                snapshot.permissions_octal,
                snapshot.modified_at_unix,
                0,
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            "sftp_mutation_completed",
            sftp_session_id,
        )
    }

    pub fn upload_sftp_file(
        &self,
        sftp_session_id: u64,
        local_path: &str,
        remote_path: &str,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(remote_path)?;
        let local = std::path::Path::new(local_path);
        if !local.is_absolute() || !local.is_file() {
            return Err(BridgeError::InvalidInput("local_upload_path"));
        }
        self.sftp_transfer_operation(
            sftp_session_id,
            local_path,
            remote_path,
            orbit_sftp_upload_checked_v1,
            "sftp_upload_completed",
        )
    }

    pub fn download_sftp_file(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        local_path: &str,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_remote_path(remote_path)?;
        let local = std::path::Path::new(local_path);
        if !local.is_absolute() || local.exists() {
            return Err(BridgeError::InvalidInput("local_download_path"));
        }
        let remote = c_string("remote_path", remote_path)?;
        let local = c_string("local_path", local_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_sftp_download_checked_v1(
                sftp_session_id,
                remote.as_ptr(),
                local.as_ptr(),
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            "sftp_download_completed",
            sftp_session_id,
        )
    }

    fn sftp_path_operation(
        &self,
        sftp_session_id: u64,
        remote_path: &str,
        function: unsafe extern "C" fn(u64, *const c_char, *const c_char) -> *mut c_char,
        kind: &str,
    ) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        validate_mutation_path(remote_path)?;
        let path = c_string("remote_path", remote_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe { function(sftp_session_id, path.as_ptr(), request.as_ptr()) };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            kind,
            sftp_session_id,
        )
    }

    fn sftp_transfer_operation(
        &self,
        sftp_session_id: u64,
        local_path: &str,
        remote_path: &str,
        function: unsafe extern "C" fn(
            u64,
            *const c_char,
            *const c_char,
            *const c_char,
        ) -> *mut c_char,
        kind: &str,
    ) -> Result<(), BridgeError> {
        let local = c_string("local_path", local_path)?;
        let remote = c_string("remote_path", remote_path)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            function(
                sftp_session_id,
                local.as_ptr(),
                remote.as_ptr(),
                request.as_ptr(),
            )
        };
        validate_sftp_operation(
            &decode_envelope(pointer, &request_id)?,
            kind,
            sftp_session_id,
        )
    }

    pub fn close_sftp(&self, sftp_session_id: u64) -> Result<(), BridgeError> {
        ensure_session(sftp_session_id)?;
        // SAFETY: This call takes only a validated opaque identifier.
        decode_control(unsafe { orbit_sftp_disconnect(sftp_session_id) })
    }

    pub fn monitor_snapshot(
        &self,
        base_session_id: u64,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(base_session_id)?;
        self.session_call(
            base_session_id,
            request_id,
            orbit_monitor_snapshot_checked_v1,
        )
    }

    pub fn monitor(&self, base_session_id: u64) -> Result<MonitorSnapshot, BridgeError> {
        let request_id = RequestId::new();
        let envelope = self.monitor_snapshot(base_session_id, &request_id)?;
        let snapshot: MonitorSnapshot = decode_payload(&envelope, "monitor_snapshot")?;
        if parse_decimal_text(&snapshot.base_session_id, "base_session_id")? != base_session_id {
            return Err(BridgeError::SessionMismatch);
        }
        validate_generation(&snapshot.security_generation)?;
        let stats = &snapshot.stats;
        if stats.sampled_at_unix == 0
            || !valid_percent(stats.cpu_usage_percent)
            || !valid_percent(stats.mem_used_percent)
            || !valid_percent(stats.disk_used_percent)
            || stats
                .ping_latency_ms
                .is_some_and(|value| !value.is_finite() || value < 0.0)
            || !stats.rx_rate_kbps.is_finite()
            || stats.rx_rate_kbps < 0.0
            || !stats.tx_rate_kbps.is_finite()
            || stats.tx_rate_kbps < 0.0
            || stats.system_info.os_name.trim().is_empty()
            || stats.system_info.swap_used_mb > stats.system_info.swap_total_mb
            || stats.system_info.disk_used_mb > stats.system_info.disk_total_mb
            || snapshot.diagnostics.len() > 8
            || snapshot
                .diagnostics
                .iter()
                .any(|item| item != "ping_unavailable")
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(snapshot)
    }

    pub fn docker_list(
        &self,
        base_session_id: u64,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(base_session_id)?;
        self.session_call(base_session_id, request_id, orbit_docker_list_checked_v1)
    }

    pub fn docker_containers(
        &self,
        base_session_id: u64,
    ) -> Result<Vec<DockerContainer>, BridgeError> {
        let request_id = RequestId::new();
        let envelope = self.docker_list(base_session_id, &request_id)?;
        #[derive(Deserialize)]
        struct Payload {
            base_session_id: String,
            security_generation: String,
            containers: Vec<DockerContainer>,
        }
        let payload: Payload = decode_payload(&envelope, "docker_containers")?;
        validate_docker_common(
            base_session_id,
            &payload.base_session_id,
            &payload.security_generation,
        )?;
        if payload.containers.len() > 10_000
            || payload.containers.iter().any(|item| {
                !valid_container_id(&item.id)
                    || [
                        &item.name,
                        &item.image,
                        &item.state,
                        &item.status,
                        &item.running_for,
                    ]
                    .iter()
                    .any(|value| value.len() > 512 || value.chars().any(char::is_control))
            })
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(payload.containers)
    }

    pub fn docker_stats(&self, base_session_id: u64) -> Result<Vec<DockerStat>, BridgeError> {
        ensure_session(base_session_id)?;
        let request_id = RequestId::new();
        let envelope =
            self.session_call(base_session_id, &request_id, orbit_docker_stats_checked_v1)?;
        #[derive(Deserialize)]
        struct Payload {
            base_session_id: String,
            security_generation: String,
            stats: Vec<DockerStat>,
        }
        let payload: Payload = decode_payload(&envelope, "docker_stats")?;
        validate_docker_common(
            base_session_id,
            &payload.base_session_id,
            &payload.security_generation,
        )?;
        if payload.stats.len() > 10_000
            || payload.stats.iter().any(|item| {
                !valid_container_id(&item.id)
                    || !item.cpu_percent.is_finite()
                    || item.cpu_percent < 0.0
                    || !valid_percent(item.mem_percent)
            })
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(payload.stats)
    }

    pub fn docker_logs(
        &self,
        base_session_id: u64,
        container_id: &str,
        tail: u32,
    ) -> Result<DockerLogs, BridgeError> {
        ensure_session(base_session_id)?;
        validate_container_id(container_id)?;
        if !(1..=10_000).contains(&tail) {
            return Err(BridgeError::InvalidInput("docker_tail"));
        }
        let request_id = RequestId::new();
        let container = c_string("container_id", container_id)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_docker_logs_checked_v1(
                base_session_id,
                container.as_ptr(),
                tail,
                request_id_c.as_ptr(),
            )
        };
        let envelope = decode_envelope(pointer, &request_id)?;
        #[derive(Deserialize)]
        struct Payload {
            base_session_id: String,
            security_generation: String,
            container_id: String,
            logs: String,
        }
        let payload: Payload = decode_payload(&envelope, "docker_logs")?;
        validate_docker_common(
            base_session_id,
            &payload.base_session_id,
            &payload.security_generation,
        )?;
        if payload.container_id != container_id
            || payload.logs.len() > MAX_DOCKER_LOG_BYTES
            || payload.logs.contains('\0')
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(DockerLogs {
            container_id: payload.container_id,
            logs: payload.logs,
        })
    }

    pub fn docker_action(
        &self,
        base_session_id: u64,
        container_id: &str,
        action: &str,
    ) -> Result<(), BridgeError> {
        ensure_session(base_session_id)?;
        validate_container_id(container_id)?;
        if !matches!(
            action,
            "start" | "stop" | "restart" | "kill" | "pause" | "unpause" | "remove"
        ) {
            return Err(BridgeError::InvalidInput("docker_action"));
        }
        let request_id = RequestId::new();
        let container = c_string("container_id", container_id)?;
        let action_c = c_string("docker_action", action)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_docker_action_checked_v1(
                base_session_id,
                container.as_ptr(),
                action_c.as_ptr(),
                request_id_c.as_ptr(),
            )
        };
        let envelope = decode_envelope(pointer, &request_id)?;
        let data = envelope.require_kind("docker_action_result")?;
        verify_generation(data)?;
        if decimal_id(data, "base_session_id")? != base_session_id
            || data.get("container_id").and_then(Value::as_str) != Some(container_id)
            || data.get("action").and_then(Value::as_str) != Some(action)
            || data.get("status").and_then(Value::as_str) != Some("completed")
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(())
    }

    pub fn exec(
        &self,
        base_session_id: u64,
        command: &str,
        request_id: &RequestId,
    ) -> Result<CheckedEnvelope, BridgeError> {
        ensure_session(base_session_id)?;
        if command.trim().is_empty()
            || command.len() > 8 * 1024
            || command.chars().any(char::is_control)
        {
            return Err(BridgeError::InvalidInput("command"));
        }
        let command = c_string("command", command)?;
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call.
        let pointer = unsafe {
            orbit_exec_checked_v1(
                base_session_id,
                command.as_ptr(),
                0,
                0,
                0,
                request_id_c.as_ptr(),
            )
        };
        decode_envelope(pointer, request_id)
    }

    pub fn exec_output(
        &self,
        base_session_id: u64,
        command: &str,
    ) -> Result<CheckedExecOutput, BridgeError> {
        let request_id = RequestId::new();
        let envelope = self.exec(base_session_id, command, &request_id)?;
        let output: CheckedExecOutput = decode_payload(&envelope, "exec_result")?;
        if parse_decimal_text(&output.base_session_id, "base_session_id")? != base_session_id
            || validate_generation(&output.security_generation).is_err()
            || output.stdout.len() > 1024 * 1024
            || output.stderr.len() > 1024 * 1024
            || output.stdout.contains('\0')
            || output.stderr.contains('\0')
        {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(output)
    }

    pub fn start_local_tunnel(
        &self,
        base_session_id: u64,
        bind_host: &str,
        bind_port: u16,
        destination_host: &str,
        destination_port: u16,
    ) -> Result<(u64, String, u16), BridgeError> {
        ensure_session(base_session_id)?;
        if !matches!(bind_host, "127.0.0.1" | "::1" | "localhost")
            || destination_host.is_empty()
            || destination_host.len() > 253
            || destination_host
                .chars()
                .any(|character| character.is_control() || character.is_whitespace())
            || destination_port == 0
        {
            return Err(BridgeError::InvalidInput("local_tunnel"));
        }
        let request_id = RequestId::new();
        let bind_host = c_string("bind_host", bind_host)?;
        let destination_host = c_string("destination_host", destination_host)?;
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe {
            orbit_local_tunnel_start_checked_v1(
                base_session_id,
                bind_host.as_ptr(),
                bind_port,
                destination_host.as_ptr(),
                destination_port,
                request.as_ptr(),
            )
        };
        let envelope = decode_envelope(pointer, &request_id)?;
        let data = envelope.require_kind("local_tunnel_started")?;
        verify_generation(data)?;
        if decimal_id(data, "base_session_id")? != base_session_id {
            return Err(BridgeError::InvalidPayloadShape);
        }
        let tunnel_id = decimal_id(data, "tunnel_id")?;
        let actual_host = data
            .get("bind_host")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or(BridgeError::InvalidPayloadShape)?
            .to_owned();
        let actual_port = data
            .get("bind_port")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .ok_or(BridgeError::InvalidPayloadShape)?;
        Ok((tunnel_id, actual_host, actual_port))
    }

    pub fn stop_local_tunnel(&self, tunnel_id: u64) -> Result<(), BridgeError> {
        ensure_session(tunnel_id)?;
        let request_id = RequestId::new();
        let request = c_string("request_id", request_id.as_str())?;
        let pointer = unsafe { orbit_local_tunnel_stop_checked_v1(tunnel_id, request.as_ptr()) };
        let envelope = decode_envelope(pointer, &request_id)?;
        let data = envelope.require_kind("local_tunnel_stopped")?;
        if decimal_id(data, "tunnel_id")? != tunnel_id {
            return Err(BridgeError::InvalidPayloadShape);
        }
        Ok(())
    }

    fn session_call(
        &self,
        session_id: u64,
        request_id: &RequestId,
        function: unsafe extern "C" fn(u64, *const c_char) -> *mut c_char,
    ) -> Result<CheckedEnvelope, BridgeError> {
        let request_id_c = c_string("request_id", request_id.as_str())?;
        // SAFETY: CString storage outlives the synchronous FFI call and the
        // supplied function follows the orbit-core checked ABI contract.
        let pointer = unsafe { function(session_id, request_id_c.as_ptr()) };
        decode_envelope(pointer, request_id)
    }
}

pub fn register_terminal_output(sender: Sender<TerminalChunk>) -> Result<(), BridgeError> {
    *TERMINAL_OUTPUT
        .lock()
        .map_err(|_| BridgeError::CallbackUnavailable)? = Some(sender);
    // SAFETY: The callback is a process-lifetime function with the exact C ABI.
    unsafe { orbit_terminal_set_callback(Some(terminal_output_callback)) };
    Ok(())
}

pub fn decimal_id(data: &Value, field: &'static str) -> Result<u64, BridgeError> {
    let value = data.get(field).ok_or(BridgeError::InvalidPayloadShape)?;
    if let Some(number) = value.as_u64() {
        return (number != 0)
            .then_some(number)
            .ok_or(BridgeError::InvalidIdentifier(field));
    }
    let text = value
        .as_str()
        .ok_or(BridgeError::InvalidIdentifier(field))?;
    if text == "0"
        || text.starts_with('0')
        || text.is_empty()
        || !text.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(BridgeError::InvalidIdentifier(field));
    }
    text.parse()
        .map_err(|_| BridgeError::InvalidIdentifier(field))
}

extern "C" fn terminal_output_callback(channel_id: u64, data: *const u8, length: usize) {
    if channel_id == 0 || data.is_null() || length == 0 || length > MAX_TERMINAL_CALLBACK_BYTES {
        return;
    }
    // SAFETY: orbit-core guarantees that callback bytes remain valid for the
    // duration of this callback. They are copied before returning.
    let bytes = unsafe { std::slice::from_raw_parts(data, length) }.to_vec();
    if let Ok(holder) = TERMINAL_OUTPUT.lock() {
        if let Some(sender) = holder.as_ref() {
            let _ = sender.send(TerminalChunk { channel_id, bytes });
        }
    }
}

fn validate_connection_request(request: &CheckedConnectionRequest<'_>) -> Result<(), BridgeError> {
    if request.host.trim().is_empty()
        || request.host.chars().any(char::is_whitespace)
        || request.username.trim().is_empty()
        || request.known_hosts_path.trim().is_empty()
        || (request.password.is_empty() && request.private_key.is_empty())
        || request.password.len() > 16 * 1024
        || request.private_key.len() > 1024 * 1024
        || request.private_key_passphrase.len() > 16 * 1024
    {
        return Err(BridgeError::InvalidInput("connection"));
    }
    if let Some(jump) = &request.jump_host {
        if jump.host.trim().is_empty()
            || jump.host.chars().any(char::is_whitespace)
            || jump.username.trim().is_empty()
            || (jump.password.is_empty() && jump.private_key.is_empty())
            || jump.password.len() > 16 * 1024
            || jump.private_key.len() > 1024 * 1024
            || jump.private_key_passphrase.len() > 16 * 1024
        {
            return Err(BridgeError::InvalidInput("jump_host"));
        }
    }
    Ok(())
}

fn validate_remote_path(path: &str) -> Result<(), BridgeError> {
    if path.is_empty()
        || path.len() > 512
        || !path.starts_with('/')
        || path.contains('\\')
        || path.chars().any(char::is_control)
        || path.split('/').any(|segment| segment == "..")
    {
        return Err(BridgeError::InvalidInput("remote_path"));
    }
    Ok(())
}

fn validate_mutation_path(path: &str) -> Result<(), BridgeError> {
    validate_remote_path(path)?;
    if path == "/" || path.ends_with('/') || path.contains("//") || path.contains("/./") {
        Err(BridgeError::InvalidInput("sftp_mutation_path"))
    } else {
        Ok(())
    }
}

fn validate_sftp_operation(
    envelope: &CheckedEnvelope,
    kind: &str,
    expected_session_id: u64,
) -> Result<(), BridgeError> {
    let payload: SftpOperationPayload = decode_payload(envelope, kind)?;
    if parse_decimal_text(&payload.sftp_session_id, "sftp_session_id")? != expected_session_id {
        return Err(BridgeError::SessionMismatch);
    }
    validate_generation(&payload.security_generation)
}

fn decode_payload<T: for<'de> Deserialize<'de>>(
    envelope: &CheckedEnvelope,
    kind: &str,
) -> Result<T, BridgeError> {
    serde_json::from_value(envelope.require_kind(kind)?.clone())
        .map_err(|_| BridgeError::InvalidPayloadShape)
}

fn parse_decimal_text(value: &str, field: &'static str) -> Result<u64, BridgeError> {
    if value.is_empty()
        || value == "0"
        || value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(BridgeError::InvalidIdentifier(field));
    }
    value
        .parse()
        .map_err(|_| BridgeError::InvalidIdentifier(field))
}

fn validate_generation(value: &str) -> Result<(), BridgeError> {
    if value == "host_key_verified" {
        Ok(())
    } else {
        Err(BridgeError::UnverifiedPayload)
    }
}

fn verify_generation(value: &Value) -> Result<(), BridgeError> {
    value
        .get("security_generation")
        .and_then(Value::as_str)
        .ok_or(BridgeError::InvalidPayloadShape)
        .and_then(validate_generation)
}

fn valid_percent(value: f64) -> bool {
    value.is_finite() && (0.0..=100.0).contains(&value)
}

fn valid_container_id(value: &str) -> bool {
    (12..=128).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn validate_container_id(value: &str) -> Result<(), BridgeError> {
    if valid_container_id(value) {
        Ok(())
    } else {
        Err(BridgeError::InvalidInput("container_id"))
    }
}

fn validate_docker_common(
    expected_session_id: u64,
    returned_session_id: &str,
    generation: &str,
) -> Result<(), BridgeError> {
    if parse_decimal_text(returned_session_id, "base_session_id")? != expected_session_id {
        return Err(BridgeError::SessionMismatch);
    }
    validate_generation(generation)
}

fn ensure_session(id: u64) -> Result<(), BridgeError> {
    if id == 0 {
        Err(BridgeError::InvalidInput("session_id"))
    } else {
        Ok(())
    }
}

fn ensure_terminal_size(columns: u32, rows: u32) -> Result<(), BridgeError> {
    if !(1..=1000).contains(&columns) || !(1..=1000).contains(&rows) {
        Err(BridgeError::InvalidInput("terminal_size"))
    } else {
        Ok(())
    }
}

fn c_string(field: &'static str, value: &str) -> Result<CString, BridgeError> {
    CString::new(value).map_err(|_| BridgeError::InteriorNul(field))
}

fn decode_envelope(
    pointer: *mut c_char,
    request_id: &RequestId,
) -> Result<CheckedEnvelope, BridgeError> {
    let json = take_core_string(pointer)?;
    CheckedEnvelope::decode(&json, request_id.as_str())
}

fn decode_control(pointer: *mut c_char) -> Result<(), BridgeError> {
    let response = take_core_string(pointer)?;
    if response.starts_with("OK:") {
        Ok(())
    } else {
        Err(BridgeError::ControlRejected)
    }
}

fn take_core_string(pointer: *mut c_char) -> Result<String, BridgeError> {
    if pointer.is_null() {
        return Err(BridgeError::NullResponse);
    }
    // SAFETY: orbit-core returns a NUL-terminated allocation owned by its C
    // boundary. We copy it before releasing the pointer exactly once.
    let copied = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| BridgeError::InvalidUtf8);
    // SAFETY: The pointer came from orbit-core and has not been freed yet.
    unsafe { orbit_free_string(pointer) };
    copied
}

unsafe extern "C" {
    fn orbit_ssh_connect_checked_v2(
        host: *const c_char,
        port: i32,
        username: *const c_char,
        password: *const c_char,
        private_key: *const c_char,
        private_key_passphrase: *const c_char,
        allow_password_fallback: i32,
        jump_enabled: i32,
        jump_host: *const c_char,
        jump_port: i32,
        jump_username: *const c_char,
        jump_password: *const c_char,
        jump_private_key: *const c_char,
        jump_private_key_passphrase: *const c_char,
        jump_allow_password_fallback: i32,
        known_hosts_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_hostkey_challenge_accept_and_persist_v1(
        challenge_id: *const c_char,
        known_hosts_path: *const c_char,
        comment: *const c_char,
    ) -> *mut c_char;
    fn orbit_terminal_open_checked_v1(
        base_session_id: u64,
        columns: u32,
        rows: u32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_terminal_set_callback(callback: Option<extern "C" fn(u64, *const u8, usize)>);
    fn orbit_terminal_write(channel_id: u64, data: *const u8, length: usize) -> *mut c_char;
    fn orbit_terminal_resize(channel_id: u64, columns: u32, rows: u32) -> *mut c_char;
    fn orbit_terminal_close(channel_id: u64) -> *mut c_char;
    fn orbit_ssh_disconnect(base_session_id: u64) -> *mut c_char;
    fn orbit_sftp_open_checked_v1(base_session_id: u64, request_id: *const c_char) -> *mut c_char;
    fn orbit_sftp_list_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_read_text_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_download_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        local_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_upload_checked_v1(
        sftp_session_id: u64,
        local_path: *const c_char,
        remote_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_mkdir_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_create_file_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_rename_checked_v1(
        sftp_session_id: u64,
        old_remote_path: *const c_char,
        new_remote_path: *const c_char,
        expected_size: u64,
        expected_permissions_octal: u32,
        expected_modified_at_unix: u64,
        expected_is_directory: i32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_remove_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        expected_size: u64,
        expected_permissions_octal: u32,
        expected_modified_at_unix: u64,
        expected_is_directory: i32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_chmod_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        mode: u32,
        expected_size: u64,
        expected_permissions_octal: u32,
        expected_modified_at_unix: u64,
        expected_is_directory: i32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_write_text_checked_v1(
        sftp_session_id: u64,
        remote_path: *const c_char,
        content: *const u8,
        content_len: usize,
        expected_size: u64,
        expected_permissions_octal: u32,
        expected_modified_at_unix: u64,
        expected_is_directory: i32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_sftp_disconnect(sftp_session_id: u64) -> *mut c_char;
    fn orbit_monitor_snapshot_checked_v1(
        base_session_id: u64,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_docker_list_checked_v1(base_session_id: u64, request_id: *const c_char)
        -> *mut c_char;
    fn orbit_docker_stats_checked_v1(
        base_session_id: u64,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_docker_logs_checked_v1(
        base_session_id: u64,
        container_id: *const c_char,
        tail: u32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_docker_action_checked_v1(
        base_session_id: u64,
        container_id: *const c_char,
        action: *const c_char,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_exec_checked_v1(
        base_session_id: u64,
        command: *const c_char,
        timeout_seconds: u32,
        max_stdout_bytes: u32,
        max_stderr_bytes: u32,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_local_tunnel_start_checked_v1(
        base_session_id: u64,
        bind_host: *const c_char,
        bind_port: u16,
        destination_host: *const c_char,
        destination_port: u16,
        request_id: *const c_char,
    ) -> *mut c_char;
    fn orbit_local_tunnel_stop_checked_v1(tunnel_id: u64, request_id: *const c_char)
        -> *mut c_char;
    fn orbit_free_string(pointer: *mut c_char);
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct CheckedEnvelope {
    pub schema_version: u32,
    pub kind: String,
    pub request_id: Option<String>,
    pub data: Option<Value>,
    pub error: Option<CheckedError>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct CheckedError {
    pub code: String,
    pub message_key: String,
    pub detail_code: Option<String>,
    pub request_id: Option<String>,
}

impl CheckedEnvelope {
    pub fn decode(json: &str, expected_request_id: &str) -> Result<Self, BridgeError> {
        let envelope: Self = serde_json::from_str(json).map_err(BridgeError::MalformedEnvelope)?;
        if envelope.schema_version != CHECKED_ABI_SCHEMA_VERSION {
            return Err(BridgeError::UnsupportedSchema(envelope.schema_version));
        }
        let error_request_id = envelope
            .error
            .as_ref()
            .and_then(|error| error.request_id.as_deref());
        if envelope.request_id.as_deref() != Some(expected_request_id)
            || error_request_id.is_some_and(|actual| actual != expected_request_id)
        {
            return Err(BridgeError::RequestIdMismatch);
        }
        match (&envelope.data, &envelope.error, envelope.kind.as_str()) {
            (Some(_), None, kind) if kind != "error" => Ok(envelope),
            (None, Some(_), "error") => Ok(envelope),
            _ => Err(BridgeError::InvalidPayloadShape),
        }
    }

    pub fn require_kind(&self, expected: &str) -> Result<&Value, BridgeError> {
        if let Some(error) = &self.error {
            return Err(BridgeError::Core {
                code: error.code.clone(),
                message_key: error.message_key.clone(),
                detail_code: error.detail_code.clone(),
            });
        }
        if self.kind != expected {
            return Err(BridgeError::UnexpectedKind {
                expected: expected.into(),
                actual: self.kind.clone(),
            });
        }
        self.data.as_ref().ok_or(BridgeError::InvalidPayloadShape)
    }
}

#[derive(Debug, Error)]
pub enum BridgeError {
    #[error("输入字段不合法：{0}")]
    InvalidInput(&'static str),
    #[error("输入字段包含 NUL：{0}")]
    InteriorNul(&'static str),
    #[error("orbit-core 返回空指针")]
    NullResponse,
    #[error("orbit-core 返回了非 UTF-8 文本")]
    InvalidUtf8,
    #[error("orbit-core 拒绝了终端控制操作")]
    ControlRejected,
    #[error("终端输出回调不可用")]
    CallbackUnavailable,
    #[error("受检 ABI 返回了无效标识符：{0}")]
    InvalidIdentifier(&'static str),
    #[error("受检 ABI 返回的会话标识与请求不匹配")]
    SessionMismatch,
    #[error("受检 ABI 返回的数据不属于 Host Key 已验证安全代际")]
    UnverifiedPayload,
    #[error("受检 ABI 返回了无法解析的信封：{0}")]
    MalformedEnvelope(serde_json::Error),
    #[error("不支持的受检 ABI schema 版本：{0}")]
    UnsupportedSchema(u32),
    #[error("受检 ABI request_id 不匹配")]
    RequestIdMismatch,
    #[error("受检 ABI 的 data/error 结构不合法")]
    InvalidPayloadShape,
    #[error("受检 ABI 类型不匹配：期望 {expected}，收到 {actual}")]
    UnexpectedKind { expected: String, actual: String },
    #[error("orbit-core 拒绝请求：{code}（{message_key}，detail={detail_code:?}）")]
    Core {
        code: String,
        message_key: String,
        detail_code: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_structured_success_envelope() {
        let envelope = CheckedEnvelope::decode(
            r#"{"schema_version":1,"kind":"connected","request_id":"req-1","data":{"base_session_id":"42"},"error":null}"#,
            "req-1",
        )
        .expect("valid envelope");
        assert_eq!(
            envelope.require_kind("connected").unwrap()["base_session_id"],
            "42"
        );
    }

    #[test]
    fn rejects_request_id_confusion() {
        let result = CheckedEnvelope::decode(
            r#"{"schema_version":1,"kind":"connected","request_id":"other","data":{},"error":null}"#,
            "req-1",
        );
        assert!(matches!(result, Err(BridgeError::RequestIdMismatch)));
    }

    #[test]
    fn rejects_data_and_error_together() {
        let result = CheckedEnvelope::decode(
            r#"{"schema_version":1,"kind":"error","request_id":"req-1","data":{},"error":{"code":"blocked","message_key":"blocked","request_id":"req-1"}}"#,
            "req-1",
        );
        assert!(matches!(result, Err(BridgeError::InvalidPayloadShape)));
    }

    #[test]
    fn accepts_checked_connect_numeric_session_id() {
        let data = serde_json::json!({ "session_id": 281474976710657_u64 });
        assert_eq!(decimal_id(&data, "session_id").unwrap(), 281474976710657);
    }

    #[test]
    fn decodes_checked_sftp_listing_without_path_confusion() {
        let envelope = CheckedEnvelope::decode(
            r#"{"schema_version":1,"kind":"sftp_directory_list","request_id":"req-sftp","data":{"sftp_session_id":"17","path":"/srv","security_generation":"host_key_verified","entries":[{"name":"logs","size":4096,"permissions":"drwxr-xr-x","permissions_octal":493,"modified_at_unix":1700000000}]},"error":null}"#,
            "req-sftp",
        )
        .expect("valid envelope");
        let listing: SftpDirectoryListing =
            decode_payload(&envelope, "sftp_directory_list").expect("typed listing");
        assert_eq!(
            parse_decimal_text(&listing.sftp_session_id, "id").unwrap(),
            17
        );
        assert_eq!(listing.path, "/srv");
        assert!(listing.entries[0].is_directory());
        assert!(validate_generation(&listing.security_generation).is_ok());
    }

    #[test]
    fn rejects_unverified_tool_payloads() {
        assert!(matches!(
            validate_generation("legacy_unchecked"),
            Err(BridgeError::UnverifiedPayload)
        ));
    }

    #[test]
    fn validates_docker_identifiers_and_percentages() {
        assert!(valid_container_id("0123456789ab"));
        assert!(!valid_container_id("../../socket"));
        assert!(valid_percent(100.0));
        assert!(!valid_percent(f64::NAN));
        assert!(!valid_percent(100.1));
    }
}
