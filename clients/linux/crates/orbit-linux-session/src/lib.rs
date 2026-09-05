use regex::Regex;
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use thiserror::Error;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

pub const EXPECTED_FREERDP_VERSION: &str = "3.30.0";
const MAX_TERMINAL_WRITE: usize = 64 * 1024;
const MAX_TELNET_LOGIN_WINDOW: usize = 4 * 1024;
const MAX_RDP_UNICODE_INPUT: usize = 4 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtocolRoute {
    CheckedSsh,
    ExplicitTelnet,
    NativeRdp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkspacePhase {
    Starting,
    Authenticating,
    AwaitingUserDecision,
    Connected,
    Reconnecting,
    Disconnected,
    Failed,
    Closed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionStateMachine {
    phase: WorkspacePhase,
}

impl Default for SessionStateMachine {
    fn default() -> Self {
        Self {
            phase: WorkspacePhase::Starting,
        }
    }
}

impl SessionStateMachine {
    pub fn phase(&self) -> WorkspacePhase {
        self.phase
    }

    pub fn transition(&mut self, next: WorkspacePhase) -> bool {
        if allowed_transitions(self.phase).contains(&next) {
            self.phase = next;
            true
        } else {
            false
        }
    }
}

fn allowed_transitions(phase: WorkspacePhase) -> &'static [WorkspacePhase] {
    use WorkspacePhase::{
        Authenticating, AwaitingUserDecision, Closed, Connected, Disconnected, Failed, Reconnecting,
    };
    match phase {
        WorkspacePhase::Starting => &[Authenticating, AwaitingUserDecision, Failed, Closed],
        Authenticating => &[
            AwaitingUserDecision,
            Connected,
            Reconnecting,
            Failed,
            Closed,
        ],
        AwaitingUserDecision => &[Authenticating, Connected, Reconnecting, Failed, Closed],
        Connected => &[Reconnecting, Disconnected, Failed, Closed],
        Reconnecting => &[
            Authenticating,
            AwaitingUserDecision,
            Connected,
            Disconnected,
            Failed,
        ],
        Disconnected | Failed => &[Reconnecting, Closed],
        Closed => &[],
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RdpDamage {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RdpFrame {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub bgra: Vec<u8>,
    pub damage: RdpDamage,
    pub source_updates: u32,
    pub decoded_bytes: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RdpCertificateChallenge {
    pub changed: bool,
    pub host: String,
    pub port: u16,
    pub common_name: String,
    pub subject: String,
    pub issuer: String,
    pub fingerprint: String,
    pub old_fingerprint: String,
    pub flags: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionEventKind {
    Phase(WorkspacePhase),
    Terminal(Vec<u8>),
    RdpFrameReady,
    RdpCertificate(RdpCertificateChallenge),
    Failed { code: u32, reason: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionEvent {
    pub workspace_id: Uuid,
    pub kind: SessionEventKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TelnetProfile {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub columns: u16,
    pub rows: u16,
}

impl TelnetProfile {
    pub fn validate(&self) -> Result<(), SessionError> {
        if self.host.trim().is_empty()
            || self.username.trim().is_empty()
            || self.port == 0
            || !(20..=512).contains(&self.columns)
            || !(8..=256).contains(&self.rows)
            || self.host.contains('\0')
            || self.username.contains('\0')
        {
            Err(SessionError::InvalidProfile)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RdpProfile {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub domain: String,
    pub config_path: String,
    pub desktop_width: u32,
    pub desktop_height: u32,
    pub require_nla: bool,
}

impl RdpProfile {
    pub fn validate(&self) -> Result<(), SessionError> {
        if self.host.trim().is_empty()
            || self.username.trim().is_empty()
            || self.config_path.trim().is_empty()
            || self.port == 0
            || !(320..=8192).contains(&self.desktop_width)
            || !(240..=8192).contains(&self.desktop_height)
            || [
                self.host.as_str(),
                self.username.as_str(),
                self.domain.as_str(),
                self.config_path.as_str(),
            ]
            .iter()
            .any(|value| value.contains('\0'))
        {
            Err(SessionError::InvalidProfile)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FreeRdpRuntimeStatus {
    Available,
    Unavailable,
    VersionMismatch,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FreeRdpRuntimeInfo {
    pub abi_version: u32,
    pub expected_version: String,
    pub actual_version: Option<String>,
    pub status: FreeRdpRuntimeStatus,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SessionError {
    #[error("invalid session profile")]
    InvalidProfile,
    #[error("credential is unavailable")]
    CredentialUnavailable,
    #[error("session engine is unavailable")]
    EngineUnavailable,
    #[error("session is not active")]
    NotActive,
    #[error("session command is too large")]
    CommandTooLarge,
    #[error("text input is invalid")]
    InvalidTextInput,
    #[error("session engine rejected the operation")]
    EngineRejected,
}

fn rdp_unicode_units(text: &str) -> Result<Vec<u16>, SessionError> {
    if text.is_empty() || text.contains('\0') {
        return Err(SessionError::InvalidTextInput);
    }
    let units = text.encode_utf16().collect::<Vec<_>>();
    if units.is_empty() || units.len() > MAX_RDP_UNICODE_INPUT {
        return Err(SessionError::CommandTooLarge);
    }
    Ok(units)
}

enum TelnetCommand {
    Write(Vec<u8>),
    Resize(u16, u16),
    Close,
}

pub struct TelnetSession {
    commands: Sender<TelnetCommand>,
    worker: Option<JoinHandle<()>>,
}

impl TelnetSession {
    pub fn connect(
        workspace_id: Uuid,
        profile: TelnetProfile,
        password: Zeroizing<String>,
        events: Sender<SessionEvent>,
    ) -> Result<Self, SessionError> {
        profile.validate()?;
        if password.is_empty() || password.contains('\0') {
            return Err(SessionError::CredentialUnavailable);
        }
        let (commands, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            run_telnet(workspace_id, profile, password, events, receiver);
        });
        Ok(Self {
            commands,
            worker: Some(worker),
        })
    }

    pub fn write(&self, bytes: Vec<u8>) -> Result<(), SessionError> {
        if bytes.is_empty() || bytes.len() > MAX_TERMINAL_WRITE {
            return Err(SessionError::CommandTooLarge);
        }
        self.commands
            .send(TelnetCommand::Write(bytes))
            .map_err(|_| SessionError::NotActive)
    }

    pub fn resize(&self, columns: u16, rows: u16) -> Result<(), SessionError> {
        if !(20..=512).contains(&columns) || !(8..=256).contains(&rows) {
            return Err(SessionError::InvalidProfile);
        }
        self.commands
            .send(TelnetCommand::Resize(columns, rows))
            .map_err(|_| SessionError::NotActive)
    }

    pub fn close(&self) {
        let _ = self.commands.send(TelnetCommand::Close);
    }
}

impl Drop for TelnetSession {
    fn drop(&mut self) {
        self.close();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run_telnet(
    workspace_id: Uuid,
    profile: TelnetProfile,
    mut password: Zeroizing<String>,
    events: Sender<SessionEvent>,
    commands: Receiver<TelnetCommand>,
) {
    publish(
        &events,
        workspace_id,
        SessionEventKind::Phase(WorkspacePhase::Authenticating),
    );
    let mut stream = match connect_tcp(&profile) {
        Ok(stream) => stream,
        Err(_) => {
            publish_failure(&events, workspace_id, "telnet_connect_failed");
            return;
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(80)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_nodelay(true);
    let _ = stream.write_all(&telnet_window_size(profile.columns, profile.rows));
    publish(
        &events,
        workspace_id,
        SessionEventKind::Phase(WorkspacePhase::Connected),
    );

    let mut decoder = TelnetDecoder::default();
    let mut auto_login = AutoLogin::new(profile.username, password.to_string());
    password.zeroize();
    let mut read_buffer = [0u8; 64 * 1024];
    let mut closed = false;
    while !closed {
        while let Ok(command) = commands.try_recv() {
            match command {
                TelnetCommand::Write(bytes) => {
                    if stream.write_all(&escape_iac(&bytes)).is_err() {
                        publish_failure(&events, workspace_id, "telnet_write_failed");
                        closed = true;
                        break;
                    }
                }
                TelnetCommand::Resize(columns, rows) => {
                    if stream
                        .write_all(&telnet_window_size(columns, rows))
                        .is_err()
                    {
                        publish_failure(&events, workspace_id, "telnet_resize_failed");
                        closed = true;
                        break;
                    }
                }
                TelnetCommand::Close => {
                    closed = true;
                    break;
                }
            }
        }
        if closed {
            break;
        }

        match stream.read(&mut read_buffer) {
            Ok(0) => break,
            Ok(count) => {
                let (content, replies) = decoder.decode(&read_buffer[..count]);
                if !replies.is_empty() && stream.write_all(&replies).is_err() {
                    publish_failure(&events, workspace_id, "telnet_negotiation_failed");
                    break;
                }
                if content.is_empty() {
                    continue;
                }
                publish(
                    &events,
                    workspace_id,
                    SessionEventKind::Terminal(content.clone()),
                );
                if let Some(response) = auto_login.consume(&content) {
                    if stream.write_all(&escape_iac(&response)).is_err() {
                        publish_failure(&events, workspace_id, "telnet_login_failed");
                        break;
                    }
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(_) => {
                publish_failure(&events, workspace_id, "telnet_read_failed");
                break;
            }
        }
    }
    auto_login.clear();
    publish(
        &events,
        workspace_id,
        SessionEventKind::Phase(WorkspacePhase::Disconnected),
    );
}

fn connect_tcp(profile: &TelnetProfile) -> io::Result<TcpStream> {
    let addresses = (profile.host.trim(), profile.port).to_socket_addrs()?;
    let mut last_error = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, Duration::from_secs(8)) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| io::Error::new(io::ErrorKind::AddrNotAvailable, "no address")))
}

fn publish(events: &Sender<SessionEvent>, workspace_id: Uuid, kind: SessionEventKind) {
    let _ = events.send(SessionEvent { workspace_id, kind });
}

fn publish_failure(events: &Sender<SessionEvent>, workspace_id: Uuid, reason: &str) {
    publish(
        events,
        workspace_id,
        SessionEventKind::Failed {
            code: 0,
            reason: reason.to_owned(),
        },
    );
}

#[derive(Default)]
struct TelnetDecoder {
    state: ParserState,
    pending_command: u8,
    subnegotiation: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum ParserState {
    #[default]
    Data,
    Iac,
    Command,
    Subnegotiation,
    SubnegotiationIac,
}

impl TelnetDecoder {
    fn decode(&mut self, input: &[u8]) -> (Vec<u8>, Vec<u8>) {
        const IAC: u8 = 255;
        const WILL: u8 = 251;
        const WONT: u8 = 252;
        const DO: u8 = 253;
        const DONT: u8 = 254;
        const SB: u8 = 250;
        const SE: u8 = 240;
        let mut output = Vec::with_capacity(input.len());
        let mut replies = Vec::new();
        for &value in input {
            match self.state {
                ParserState::Data if value == IAC => self.state = ParserState::Iac,
                ParserState::Data => output.push(value),
                ParserState::Iac if value == IAC => {
                    output.push(IAC);
                    self.state = ParserState::Data;
                }
                ParserState::Iac if matches!(value, WILL | WONT | DO | DONT) => {
                    self.pending_command = value;
                    self.state = ParserState::Command;
                }
                ParserState::Iac if value == SB => {
                    self.subnegotiation.clear();
                    self.state = ParserState::Subnegotiation;
                }
                ParserState::Iac => self.state = ParserState::Data,
                ParserState::Command => {
                    append_negotiation_reply(self.pending_command, value, &mut replies);
                    self.state = ParserState::Data;
                }
                ParserState::Subnegotiation if value == IAC => {
                    self.state = ParserState::SubnegotiationIac;
                }
                ParserState::Subnegotiation => self.subnegotiation.push(value),
                ParserState::SubnegotiationIac if value == SE => {
                    append_subnegotiation_reply(&self.subnegotiation, &mut replies);
                    self.subnegotiation.clear();
                    self.state = ParserState::Data;
                }
                ParserState::SubnegotiationIac => {
                    if value == IAC {
                        self.subnegotiation.push(IAC);
                    }
                    self.state = ParserState::Subnegotiation;
                }
            }
        }
        (output, replies)
    }
}

fn append_negotiation_reply(command: u8, option: u8, replies: &mut Vec<u8>) {
    const IAC: u8 = 255;
    const WILL: u8 = 251;
    const WONT: u8 = 252;
    const DO: u8 = 253;
    const DONT: u8 = 254;
    const ECHO: u8 = 1;
    const SUPPRESS_GO_AHEAD: u8 = 3;
    const TERMINAL_TYPE: u8 = 24;
    const NAWS: u8 = 31;
    let accepted = matches!(option, ECHO | SUPPRESS_GO_AHEAD | TERMINAL_TYPE | NAWS);
    let response = match command {
        WILL => Some(if accepted { DO } else { DONT }),
        DO => Some(if accepted { WILL } else { WONT }),
        _ => None,
    };
    if let Some(response) = response {
        replies.extend_from_slice(&[IAC, response, option]);
    }
}

fn append_subnegotiation_reply(subnegotiation: &[u8], replies: &mut Vec<u8>) {
    const IAC: u8 = 255;
    const SB: u8 = 250;
    const SE: u8 = 240;
    const TERMINAL_TYPE: u8 = 24;
    const SEND: u8 = 1;
    const IS: u8 = 0;
    if subnegotiation.starts_with(&[TERMINAL_TYPE, SEND]) {
        replies.extend_from_slice(&[IAC, SB, TERMINAL_TYPE, IS]);
        replies.extend_from_slice(b"xterm-256color");
        replies.extend_from_slice(&[IAC, SE]);
    }
}

fn telnet_window_size(columns: u16, rows: u16) -> Vec<u8> {
    const IAC: u8 = 255;
    const SB: u8 = 250;
    const SE: u8 = 240;
    const NAWS: u8 = 31;
    vec![
        IAC,
        SB,
        NAWS,
        (columns >> 8) as u8,
        columns as u8,
        (rows >> 8) as u8,
        rows as u8,
        IAC,
        SE,
    ]
}

fn escape_iac(input: &[u8]) -> Vec<u8> {
    let mut escaped = Vec::with_capacity(input.len() + 8);
    for &byte in input {
        escaped.push(byte);
        if byte == 255 {
            escaped.push(byte);
        }
    }
    escaped
}

struct AutoLogin {
    username: String,
    password: String,
    buffer: String,
    username_sent: bool,
    password_sent: bool,
}

impl AutoLogin {
    fn new(username: String, password: String) -> Self {
        Self {
            username,
            password,
            buffer: String::new(),
            username_sent: false,
            password_sent: false,
        }
    }

    fn consume(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        if self.username_sent && self.password_sent {
            return None;
        }
        self.buffer.push_str(&String::from_utf8_lossy(bytes));
        if self.buffer.len() > MAX_TELNET_LOGIN_WINDOW {
            let keep_from = self
                .buffer
                .char_indices()
                .map(|(index, _)| index)
                .rev()
                .take(MAX_TELNET_LOGIN_WINDOW)
                .last()
                .unwrap_or(0);
            self.buffer.drain(..keep_from);
        }
        if !self.username_sent && username_prompt().is_match(&self.buffer) {
            self.username_sent = true;
            return Some(format!("{}\r\n", self.username).into_bytes());
        }
        if !self.password_sent && password_prompt().is_match(&self.buffer) {
            self.password_sent = true;
            let response = format!("{}\r\n", self.password).into_bytes();
            self.password.zeroize();
            return Some(response);
        }
        None
    }

    fn clear(&mut self) {
        self.password.zeroize();
        self.buffer.zeroize();
    }
}

impl Drop for AutoLogin {
    fn drop(&mut self) {
        self.clear();
    }
}

fn username_prompt() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r"(?im)(^|\r|\n)\s*(username|login|user name|user|account|用户名|账号)\s*[:：]\s*$",
        )
        .expect("username prompt regex is static")
    })
}

fn password_prompt() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?im)(^|\r|\n).*?(password|passwd|passcode|口令|密码).*?[:：]\s*$")
            .expect("password prompt regex is static")
    })
}

#[cfg(target_os = "linux")]
mod rdp {
    use super::*;
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::ptr::NonNull;

    const ABI_VERSION: u32 = 2;

    #[repr(C)]
    struct NativeSession {
        _opaque: [u8; 0],
    }

    #[repr(C)]
    struct NativeProfile {
        abi_version: u32,
        host: *const c_char,
        port: u16,
        username: *const c_char,
        password: *const c_char,
        domain: *const c_char,
        config_path: *const c_char,
        desktop_width: u32,
        desktop_height: u32,
        require_nla: u8,
    }

    type StateCallback = unsafe extern "C" fn(*mut c_void, u32, u32, *const c_char);
    type FrameCallback =
        unsafe extern "C" fn(*mut c_void, u32, u32, u32, *const u8, usize, u32, u32, u32, u32);
    type CertificateCallback = unsafe extern "C" fn(
        *mut c_void,
        u8,
        *const c_char,
        u16,
        *const c_char,
        *const c_char,
        *const c_char,
        *const c_char,
        *const c_char,
        u32,
    );
    #[repr(C)]
    struct NativeCallbacks {
        user_data: *mut c_void,
        state: Option<StateCallback>,
        frame: Option<FrameCallback>,
        certificate: Option<CertificateCallback>,
    }

    unsafe extern "C" {
        fn orbit_rdp_linux_abi_version() -> u32;
        fn orbit_rdp_linux_expected_version() -> *const c_char;
        fn orbit_rdp_linux_runtime_probe(version: *mut c_char, capacity: usize) -> c_int;
        fn orbit_rdp_linux_session_create(
            profile: *const NativeProfile,
            callbacks: *const NativeCallbacks,
            out_session: *mut *mut NativeSession,
        ) -> c_int;
        fn orbit_rdp_linux_session_start(session: *mut NativeSession) -> c_int;
        fn orbit_rdp_linux_session_certificate_decision(
            session: *mut NativeSession,
            accept_and_store: u8,
        ) -> c_int;
        fn orbit_rdp_linux_session_send_pointer(
            session: *mut NativeSession,
            flags: u16,
            x: u16,
            y: u16,
        ) -> c_int;
        fn orbit_rdp_linux_session_send_keycode(
            session: *mut NativeSession,
            hardware_keycode: u32,
            down: u8,
        ) -> c_int;
        fn orbit_rdp_linux_session_send_unicode(
            session: *mut NativeSession,
            code_unit: u16,
        ) -> c_int;
        fn orbit_rdp_linux_session_stop(session: *mut NativeSession) -> c_int;
        fn orbit_rdp_linux_session_free(session: *mut NativeSession);
    }

    struct CallbackContext {
        workspace_id: Uuid,
        events: Sender<SessionEvent>,
        frames: FrameMailbox,
    }

    #[derive(Default)]
    struct FrameMailbox {
        state: Mutex<FrameMailboxState>,
    }

    #[derive(Default)]
    struct FrameMailboxState {
        width: u32,
        height: u32,
        stride: u32,
        bgra: Vec<u8>,
        pending_damage: Option<RdpDamage>,
        pending_source_updates: u32,
        pending_decoded_bytes: usize,
        notification_pending: bool,
    }

    impl FrameMailbox {
        fn submit(&self, update: RdpFrame) -> Result<bool, ()> {
            let row_bytes = update.damage.width.checked_mul(4).ok_or(())?;
            let damage_right = update.damage.x.checked_add(update.damage.width).ok_or(())?;
            let damage_bottom = update
                .damage
                .y
                .checked_add(update.damage.height)
                .ok_or(())?;
            if update.width == 0
                || update.height == 0
                || update.damage.width == 0
                || update.damage.height == 0
                || damage_right > update.width
                || damage_bottom > update.height
                || update.stride < row_bytes
            {
                return Err(());
            }
            let required = usize::try_from(update.stride)
                .ok()
                .and_then(|stride| {
                    usize::try_from(update.damage.height)
                        .ok()
                        .and_then(|height| stride.checked_mul(height))
                })
                .ok_or(())?;
            if required > update.bgra.len() {
                return Err(());
            }

            let full_stride = update.width.checked_mul(4).ok_or(())?;
            let full_length = usize::try_from(full_stride)
                .ok()
                .and_then(|stride| {
                    usize::try_from(update.height)
                        .ok()
                        .and_then(|height| stride.checked_mul(height))
                })
                .filter(|length| *length <= 256 * 1024 * 1024)
                .ok_or(())?;
            let mut state = self.state.lock().map_err(|_| ())?;
            let resized = state.width != update.width
                || state.height != update.height
                || state.stride != full_stride
                || state.bgra.len() != full_length;
            if resized {
                state.width = update.width;
                state.height = update.height;
                state.stride = full_stride;
                state.bgra.clear();
                state.bgra.resize(full_length, 0);
                state.pending_damage = Some(RdpDamage {
                    x: 0,
                    y: 0,
                    width: update.width,
                    height: update.height,
                });
            }

            let source_stride = usize::try_from(update.stride).map_err(|_| ())?;
            let destination_stride = usize::try_from(state.stride).map_err(|_| ())?;
            let row_bytes = usize::try_from(row_bytes).map_err(|_| ())?;
            let destination_x = usize::try_from(update.damage.x)
                .ok()
                .and_then(|x| x.checked_mul(4))
                .ok_or(())?;
            for row in 0..usize::try_from(update.damage.height).map_err(|_| ())? {
                let source_start = row.checked_mul(source_stride).ok_or(())?;
                let destination_row = usize::try_from(update.damage.y)
                    .ok()
                    .and_then(|y| y.checked_add(row))
                    .ok_or(())?;
                let destination_start = destination_row
                    .checked_mul(destination_stride)
                    .and_then(|offset| offset.checked_add(destination_x))
                    .ok_or(())?;
                state.bgra[destination_start..destination_start + row_bytes]
                    .copy_from_slice(&update.bgra[source_start..source_start + row_bytes]);
            }

            if !resized {
                state.pending_damage = Some(match state.pending_damage.take() {
                    Some(current) => union_damage(current, update.damage),
                    None => update.damage,
                });
            }
            state.pending_source_updates = state
                .pending_source_updates
                .saturating_add(update.source_updates.max(1));
            state.pending_decoded_bytes = state
                .pending_decoded_bytes
                .saturating_add(update.decoded_bytes);
            let should_notify = !state.notification_pending;
            state.notification_pending = true;
            Ok(should_notify)
        }

        fn take(&self) -> Option<RdpFrame> {
            let mut state = self.state.lock().ok()?;
            let damage = state.pending_damage.take()?;
            let patch_stride = damage.width.checked_mul(4)?;
            let patch_length = usize::try_from(patch_stride)
                .ok()?
                .checked_mul(usize::try_from(damage.height).ok()?)?;
            let mut bgra = vec![0; patch_length];
            let source_stride = usize::try_from(state.stride).ok()?;
            let patch_stride_usize = usize::try_from(patch_stride).ok()?;
            let source_x = usize::try_from(damage.x).ok()?.checked_mul(4)?;
            for row in 0..usize::try_from(damage.height).ok()? {
                let source_row = usize::try_from(damage.y).ok()?.checked_add(row)?;
                let source_start = source_row
                    .checked_mul(source_stride)?
                    .checked_add(source_x)?;
                let destination_start = row.checked_mul(patch_stride_usize)?;
                bgra[destination_start..destination_start + patch_stride_usize]
                    .copy_from_slice(&state.bgra[source_start..source_start + patch_stride_usize]);
            }
            let source_updates = state.pending_source_updates.max(1);
            let decoded_bytes = state.pending_decoded_bytes;
            state.pending_source_updates = 0;
            state.pending_decoded_bytes = 0;
            state.notification_pending = false;
            Some(RdpFrame {
                width: state.width,
                height: state.height,
                stride: patch_stride,
                bgra,
                damage,
                source_updates,
                decoded_bytes,
            })
        }

        fn cancel_notification(&self) {
            if let Ok(mut state) = self.state.lock() {
                state.notification_pending = false;
            }
        }
    }

    fn union_damage(left: RdpDamage, right: RdpDamage) -> RdpDamage {
        let x = left.x.min(right.x);
        let y = left.y.min(right.y);
        let right_edge = left
            .x
            .saturating_add(left.width)
            .max(right.x.saturating_add(right.width));
        let bottom_edge = left
            .y
            .saturating_add(left.height)
            .max(right.y.saturating_add(right.height));
        RdpDamage {
            x,
            y,
            width: right_edge.saturating_sub(x),
            height: bottom_edge.saturating_sub(y),
        }
    }

    pub struct RdpSession {
        native: NonNull<NativeSession>,
        callback: NonNull<CallbackContext>,
    }

    impl RdpSession {
        pub fn connect(
            workspace_id: Uuid,
            profile: RdpProfile,
            password: Zeroizing<String>,
            events: Sender<SessionEvent>,
        ) -> Result<Self, SessionError> {
            profile.validate()?;
            if password.is_empty() || password.contains('\0') {
                return Err(SessionError::CredentialUnavailable);
            }
            if runtime_info().status != FreeRdpRuntimeStatus::Available {
                return Err(SessionError::EngineUnavailable);
            }
            let host = CString::new(profile.host).map_err(|_| SessionError::InvalidProfile)?;
            let username =
                CString::new(profile.username).map_err(|_| SessionError::InvalidProfile)?;
            let password = CString::new(password.as_bytes())
                .map_err(|_| SessionError::CredentialUnavailable)?;
            let domain = CString::new(profile.domain).map_err(|_| SessionError::InvalidProfile)?;
            let config_path =
                CString::new(profile.config_path).map_err(|_| SessionError::InvalidProfile)?;
            let native_profile = NativeProfile {
                abi_version: ABI_VERSION,
                host: host.as_ptr(),
                port: profile.port,
                username: username.as_ptr(),
                password: password.as_ptr(),
                domain: domain.as_ptr(),
                config_path: config_path.as_ptr(),
                desktop_width: profile.desktop_width,
                desktop_height: profile.desktop_height,
                require_nla: u8::from(profile.require_nla),
            };
            let callback = Box::new(CallbackContext {
                workspace_id,
                events,
                frames: FrameMailbox::default(),
            });
            let callback = NonNull::new(Box::into_raw(callback)).expect("Box is non-null");
            let callbacks = NativeCallbacks {
                user_data: callback.as_ptr().cast(),
                state: Some(state_callback),
                frame: Some(frame_callback),
                certificate: Some(certificate_callback),
            };
            let mut native = std::ptr::null_mut();
            let created =
                unsafe { orbit_rdp_linux_session_create(&native_profile, &callbacks, &mut native) };
            let Some(native) = NonNull::new(native) else {
                unsafe { drop(Box::from_raw(callback.as_ptr())) };
                return Err(if created == -1 {
                    SessionError::InvalidProfile
                } else {
                    SessionError::EngineUnavailable
                });
            };
            if unsafe { orbit_rdp_linux_session_start(native.as_ptr()) } != 0 {
                unsafe {
                    orbit_rdp_linux_session_free(native.as_ptr());
                    drop(Box::from_raw(callback.as_ptr()));
                }
                return Err(SessionError::EngineRejected);
            }
            Ok(Self { native, callback })
        }

        pub fn certificate_decision(&self, accept_and_store: bool) -> Result<(), SessionError> {
            let result = unsafe {
                orbit_rdp_linux_session_certificate_decision(
                    self.native.as_ptr(),
                    u8::from(accept_and_store),
                )
            };
            (result == 0).then_some(()).ok_or(SessionError::NotActive)
        }

        pub fn pointer(&self, flags: u16, x: u16, y: u16) -> Result<(), SessionError> {
            let result =
                unsafe { orbit_rdp_linux_session_send_pointer(self.native.as_ptr(), flags, x, y) };
            (result == 0).then_some(()).ok_or(SessionError::NotActive)
        }

        pub fn keycode(&self, hardware_keycode: u32, down: bool) -> Result<(), SessionError> {
            let result = unsafe {
                orbit_rdp_linux_session_send_keycode(
                    self.native.as_ptr(),
                    hardware_keycode,
                    u8::from(down),
                )
            };
            (result == 0).then_some(()).ok_or(SessionError::NotActive)
        }

        pub fn unicode_text(&self, text: &str) -> Result<(), SessionError> {
            for code_unit in rdp_unicode_units(text)? {
                let result = unsafe {
                    orbit_rdp_linux_session_send_unicode(self.native.as_ptr(), code_unit)
                };
                if result != 0 {
                    return Err(SessionError::NotActive);
                }
            }
            Ok(())
        }

        pub fn take_frame(&self) -> Option<RdpFrame> {
            unsafe { self.callback.as_ref() }.frames.take()
        }

        pub fn close(&self) {
            unsafe {
                let _ = orbit_rdp_linux_session_stop(self.native.as_ptr());
            }
        }
    }

    impl Drop for RdpSession {
        fn drop(&mut self) {
            unsafe {
                orbit_rdp_linux_session_free(self.native.as_ptr());
                drop(Box::from_raw(self.callback.as_ptr()));
            }
        }
    }

    pub fn runtime_info() -> FreeRdpRuntimeInfo {
        let mut version = [0i8; 64];
        let status = unsafe { orbit_rdp_linux_runtime_probe(version.as_mut_ptr(), version.len()) };
        let actual_version = if version[0] == 0 {
            None
        } else {
            Some(
                unsafe { CStr::from_ptr(version.as_ptr()) }
                    .to_string_lossy()
                    .into_owned(),
            )
        };
        let expected_version = unsafe { CStr::from_ptr(orbit_rdp_linux_expected_version()) }
            .to_string_lossy()
            .into_owned();
        FreeRdpRuntimeInfo {
            abi_version: unsafe { orbit_rdp_linux_abi_version() },
            expected_version,
            actual_version,
            status: match status {
                1 => FreeRdpRuntimeStatus::Available,
                2 => FreeRdpRuntimeStatus::VersionMismatch,
                _ => FreeRdpRuntimeStatus::Unavailable,
            },
        }
    }

    unsafe extern "C" fn state_callback(
        user_data: *mut c_void,
        state: u32,
        error_code: u32,
        error_name: *const c_char,
    ) {
        let Some(context) = user_data.cast::<CallbackContext>().as_ref() else {
            return;
        };
        let phase = match state {
            1 => WorkspacePhase::Starting,
            2 => WorkspacePhase::Authenticating,
            3 => WorkspacePhase::Connected,
            4 => WorkspacePhase::Disconnected,
            5 => WorkspacePhase::Failed,
            6 => WorkspacePhase::Closed,
            _ => WorkspacePhase::Failed,
        };
        if phase == WorkspacePhase::Failed {
            let reason = c_string(error_name);
            publish(
                &context.events,
                context.workspace_id,
                SessionEventKind::Failed {
                    code: error_code,
                    reason: if reason.is_empty() {
                        "rdp_connection_failed".into()
                    } else {
                        reason
                    },
                },
            );
        } else {
            publish(
                &context.events,
                context.workspace_id,
                SessionEventKind::Phase(phase),
            );
        }
    }

    unsafe extern "C" fn frame_callback(
        user_data: *mut c_void,
        width: u32,
        height: u32,
        stride: u32,
        bytes: *const u8,
        byte_length: usize,
        damage_x: u32,
        damage_y: u32,
        damage_width: u32,
        damage_height: u32,
    ) {
        let Some(context) = user_data.cast::<CallbackContext>().as_ref() else {
            return;
        };
        if bytes.is_null()
            || width == 0
            || height == 0
            || stride < width.saturating_mul(4)
            || damage_width == 0
            || damage_height == 0
            || byte_length > 256 * 1024 * 1024
        {
            return;
        }
        let Some(damage_right) = damage_x.checked_add(damage_width) else {
            return;
        };
        let Some(damage_bottom) = damage_y.checked_add(damage_height) else {
            return;
        };
        if damage_right > width || damage_bottom > height {
            return;
        }
        let required = usize::try_from(stride).ok().and_then(|stride| {
            usize::try_from(height)
                .ok()
                .and_then(|height| stride.checked_mul(height))
        });
        if required.is_none_or(|required| required > byte_length) {
            return;
        }
        let Some(patch_stride) = damage_width.checked_mul(4) else {
            return;
        };
        let Some(patch_length) = usize::try_from(patch_stride).ok().and_then(|stride| {
            usize::try_from(damage_height)
                .ok()
                .and_then(|height| stride.checked_mul(height))
        }) else {
            return;
        };
        let source = std::slice::from_raw_parts(bytes, byte_length);
        let mut bgra = Vec::with_capacity(patch_length);
        let source_stride = usize::try_from(stride).unwrap_or(0);
        let source_x = usize::try_from(damage_x)
            .ok()
            .and_then(|x| x.checked_mul(4))
            .unwrap_or(usize::MAX);
        let patch_stride_usize = usize::try_from(patch_stride).unwrap_or(0);
        for row in 0..usize::try_from(damage_height).unwrap_or(0) {
            let Some(source_row) = usize::try_from(damage_y)
                .ok()
                .and_then(|y| y.checked_add(row))
            else {
                return;
            };
            let Some(start) = source_row
                .checked_mul(source_stride)
                .and_then(|offset| offset.checked_add(source_x))
            else {
                return;
            };
            let Some(end) = start.checked_add(patch_stride_usize) else {
                return;
            };
            let Some(row) = source.get(start..end) else {
                return;
            };
            bgra.extend_from_slice(row);
        }
        let update = RdpFrame {
            width,
            height,
            stride: patch_stride,
            bgra,
            damage: RdpDamage {
                x: damage_x,
                y: damage_y,
                width: damage_width,
                height: damage_height,
            },
            source_updates: 1,
            decoded_bytes: patch_length,
        };
        if context.frames.submit(update) != Ok(true) {
            return;
        }
        if context
            .events
            .send(SessionEvent {
                workspace_id: context.workspace_id,
                kind: SessionEventKind::RdpFrameReady,
            })
            .is_err()
        {
            context.frames.cancel_notification();
        }
    }

    #[allow(clippy::too_many_arguments)]
    unsafe extern "C" fn certificate_callback(
        user_data: *mut c_void,
        changed: u8,
        host: *const c_char,
        port: u16,
        common_name: *const c_char,
        subject: *const c_char,
        issuer: *const c_char,
        fingerprint: *const c_char,
        old_fingerprint: *const c_char,
        flags: u32,
    ) {
        let Some(context) = user_data.cast::<CallbackContext>().as_ref() else {
            return;
        };
        publish(
            &context.events,
            context.workspace_id,
            SessionEventKind::RdpCertificate(RdpCertificateChallenge {
                changed: changed != 0,
                host: c_string(host),
                port,
                common_name: c_string(common_name),
                subject: c_string(subject),
                issuer: c_string(issuer),
                fingerprint: c_string(fingerprint),
                old_fingerprint: c_string(old_fingerprint),
                flags,
            }),
        );
    }

    unsafe fn c_string(value: *const c_char) -> String {
        if value.is_null() {
            String::new()
        } else {
            CStr::from_ptr(value).to_string_lossy().into_owned()
        }
    }

    #[cfg(test)]
    mod frame_tests {
        use super::*;

        fn update(x: u32, y: u32, width: u32, height: u32, value: u8) -> RdpFrame {
            let stride = width * 4;
            let length = usize::try_from(stride * height).expect("small test update");
            RdpFrame {
                width: 4,
                height: 3,
                stride,
                bgra: vec![value; length],
                damage: RdpDamage {
                    x,
                    y,
                    width,
                    height,
                },
                source_updates: 1,
                decoded_bytes: length,
            }
        }

        #[test]
        fn mailbox_coalesces_updates_behind_one_bounded_notification() {
            let mailbox = FrameMailbox::default();
            assert_eq!(mailbox.submit(update(0, 0, 4, 3, 1)), Ok(true));
            assert_eq!(mailbox.submit(update(1, 1, 1, 1, 9)), Ok(false));

            let frame = mailbox.take().expect("coalesced frame");
            assert_eq!(
                frame.damage,
                RdpDamage {
                    x: 0,
                    y: 0,
                    width: 4,
                    height: 3
                }
            );
            assert_eq!(frame.source_updates, 2);
            assert_eq!(frame.decoded_bytes, 52);
            assert_eq!(&frame.bgra[20..24], &[9; 4]);
            assert_eq!(mailbox.submit(update(2, 2, 1, 1, 7)), Ok(true));
        }

        #[test]
        fn mailbox_rejects_out_of_bounds_damage() {
            let mailbox = FrameMailbox::default();
            assert_eq!(mailbox.submit(update(3, 2, 2, 2, 4)), Err(()));
            assert!(mailbox.take().is_none());
        }

        #[test]
        fn mailbox_keeps_ten_thousand_updates_behind_one_notification() {
            let mailbox = FrameMailbox::default();
            for index in 0..10_000u32 {
                let x = index % 4;
                let y = index / 4 % 3;
                assert_eq!(
                    mailbox.submit(update(x, y, 1, 1, (index % 251) as u8)),
                    Ok(index == 0)
                );
            }
            let frame = mailbox.take().expect("bounded coalesced frame");
            assert_eq!(frame.source_updates, 10_000);
            assert_eq!(frame.decoded_bytes, 40_000);
            assert_eq!(
                frame.damage,
                RdpDamage {
                    x: 0,
                    y: 0,
                    width: 4,
                    height: 3
                }
            );
            assert_eq!(frame.bgra.len(), 48);
            assert!(mailbox.take().is_none());
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod rdp {
    use super::*;

    pub struct RdpSession;

    impl RdpSession {
        pub fn connect(
            _workspace_id: Uuid,
            _profile: RdpProfile,
            _password: Zeroizing<String>,
            _events: Sender<SessionEvent>,
        ) -> Result<Self, SessionError> {
            Err(SessionError::EngineUnavailable)
        }

        pub fn certificate_decision(&self, _accept_and_store: bool) -> Result<(), SessionError> {
            Err(SessionError::EngineUnavailable)
        }

        pub fn pointer(&self, _flags: u16, _x: u16, _y: u16) -> Result<(), SessionError> {
            Err(SessionError::EngineUnavailable)
        }

        pub fn keycode(&self, _hardware_keycode: u32, _down: bool) -> Result<(), SessionError> {
            Err(SessionError::EngineUnavailable)
        }

        pub fn unicode_text(&self, _text: &str) -> Result<(), SessionError> {
            Err(SessionError::EngineUnavailable)
        }

        pub fn take_frame(&self) -> Option<RdpFrame> {
            None
        }

        pub fn close(&self) {}
    }

    pub fn runtime_info() -> FreeRdpRuntimeInfo {
        FreeRdpRuntimeInfo {
            abi_version: 2,
            expected_version: EXPECTED_FREERDP_VERSION.into(),
            actual_version: None,
            status: FreeRdpRuntimeStatus::Unavailable,
        }
    }
}

pub use rdp::{runtime_info as freerdp_runtime_info, RdpSession};

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn shared_remote_desktop_state_contract_is_enforced() {
        let mut state = SessionStateMachine::default();
        assert!(state.transition(WorkspacePhase::Authenticating));
        assert!(state.transition(WorkspacePhase::AwaitingUserDecision));
        assert!(state.transition(WorkspacePhase::Connected));
        assert!(!state.transition(WorkspacePhase::Starting));
        assert!(state.transition(WorkspacePhase::Disconnected));
        assert!(state.transition(WorkspacePhase::Reconnecting));
        assert!(state.transition(WorkspacePhase::Failed));
        assert!(state.transition(WorkspacePhase::Closed));
        assert!(!state.transition(WorkspacePhase::Connected));
    }

    #[test]
    fn rdp_profile_requires_nla_ready_dimensions_and_identity() {
        let valid = RdpProfile {
            host: "rdp.example.test".into(),
            port: 3389,
            username: "operator".into(),
            domain: String::new(),
            config_path: "/tmp/orbit-rdp-test".into(),
            desktop_width: 1280,
            desktop_height: 720,
            require_nla: true,
        };
        assert_eq!(valid.validate(), Ok(()));
        assert_eq!(
            RdpProfile {
                host: String::new(),
                ..valid
            }
            .validate(),
            Err(SessionError::InvalidProfile)
        );
    }

    #[test]
    fn rdp_unicode_input_is_bounded_and_preserves_surrogate_pairs() {
        assert_eq!(
            rdp_unicode_units("中文 A").unwrap(),
            vec![0x4e2d, 0x6587, 0x20, 0x41]
        );
        assert_eq!(rdp_unicode_units("😀").unwrap(), vec![0xd83d, 0xde00]);
        assert_eq!(rdp_unicode_units(""), Err(SessionError::InvalidTextInput));
        assert_eq!(
            rdp_unicode_units("a\0b"),
            Err(SessionError::InvalidTextInput)
        );
        assert_eq!(
            rdp_unicode_units(&"a".repeat(MAX_RDP_UNICODE_INPUT + 1)),
            Err(SessionError::CommandTooLarge)
        );
    }

    #[test]
    fn telnet_negotiation_is_removed_from_terminal_output() {
        let mut decoder = TelnetDecoder::default();
        let (output, replies) = decoder.decode(&[255, 251, 1, b'l', b'o', b'g', b'i', b'n', b':']);
        assert_eq!(output, b"login:");
        assert_eq!(replies, vec![255, 253, 1]);
    }

    #[test]
    fn telnet_auto_login_answers_prompts_without_echoing_secret_to_ui() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let port = listener.local_addr().expect("address").port();
        let workspace_id = Uuid::new_v4();
        let (events, receiver) = mpsc::channel();
        let session = TelnetSession::connect(
            workspace_id,
            TelnetProfile {
                host: "127.0.0.1".into(),
                port,
                username: "alice".into(),
                columns: 100,
                rows: 30,
            },
            Zeroizing::new("test-secret".to_owned()),
            events,
        )
        .expect("session");
        let (mut server, _) = listener.accept().expect("accept");
        server
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("timeout");
        let mut initial = [0u8; 9];
        server.read_exact(&mut initial).expect("NAWS");
        server.write_all(b"login: ").expect("login prompt");
        let mut username = [0u8; 7];
        server.read_exact(&mut username).expect("username");
        assert_eq!(&username, b"alice\r\n");
        server.write_all(b"Password: ").expect("password prompt");
        let mut password = [0u8; 13];
        server.read_exact(&mut password).expect("password");
        assert_eq!(&password, b"test-secret\r\n");
        session.close();
        drop(session);

        let visible: Vec<u8> = receiver
            .try_iter()
            .filter_map(|event| match event.kind {
                SessionEventKind::Terminal(bytes) => Some(bytes),
                _ => None,
            })
            .flatten()
            .collect();
        assert!(!String::from_utf8_lossy(&visible).contains("test-secret"));
    }
}
