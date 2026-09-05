use crate::sync_scheduler::SyncSchedulerGate;
use crate::sync_session::SecureSyncSession;
use adw::prelude::*;
use gtk::{Align, Orientation};
use orbit_linux_application::AssetCatalog;
use orbit_linux_bridge::{
    decimal_id, register_terminal_output, BridgeError, CheckedConnectionRequest, CheckedCoreClient,
    CheckedJumpHostRequest, DockerContainer, MonitorSnapshot, RequestId, SftpDirectoryListing,
    SftpEntry, SftpEntrySnapshot,
};
use orbit_linux_domain::{AuthMethod, JumpHostConfiguration, ServerAsset, Transport};
use orbit_linux_platform::{
    asset_sync_fingerprint, current_unix_ms, ensure_known_hosts_parent, ensure_private_directory,
    AppPreferences, AssetSyncState, AuthTokenMaterial, AuthTokenVault, CommandSnippet,
    CredentialMaterial, CredentialVault, JsonAssetRepository, PortForwardProfile,
    PortForwardProfileRepository, PreferencesRepository, QueuedSyncOperation, SnippetAssetScope,
    SnippetRepository, SnippetScopeMode, SyncAuditOutcome, SyncOperationKind,
    SyncOperationRepository, SyncStateRepository, XdgPaths,
};
use orbit_linux_session::{
    freerdp_runtime_info, FreeRdpRuntimeStatus, RdpCertificateChallenge, RdpFrame, RdpProfile,
    RdpSession, SessionEvent, SessionEventKind, TelnetProfile, TelnetSession, WorkspacePhase,
};
use orbit_linux_sync::{
    account_fingerprint, build_pull_preview_with_deferred_for_account, CloudClient,
    KeepLocalAccountContext, RemoteConfig, SyncError, SyncPreview, SyncTokens,
};
use ssh_key::{Algorithm, HashAlg, LineEnding, PrivateKey};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use uuid::Uuid;
use vte::prelude::*;
use zeroize::Zeroizing;

const GTK_TOKENS: &str = include_str!("../../../resources/tokens-gtk.css");
const APP_STYLES: &str = include_str!("../../../resources/orbitterm.css");

type Catalog = AssetCatalog<JsonAssetRepository>;

const MAX_SESSION_BACKLOG: usize = 4 * 1024 * 1024;
const MAX_TERMINAL_PANES: usize = 4;
const SAFE_RDP_DESKTOP_WIDTH: u32 = 1280;
const SAFE_RDP_DESKTOP_HEIGHT: u32 = 720;
const MAX_RDP_RECONNECT_ATTEMPTS: u8 = 8;
const RDP_METRIC_WINDOW: Duration = Duration::from_secs(5);
const RDP_INPUT_FRAME_WINDOW: Duration = Duration::from_secs(5);
const MAX_RDP_CANVAS_BYTES: usize = 256 * 1024 * 1024;
const RDP_PIXEL_PIPELINE_BUFFERS: u64 = 3;
const RDP_WHEEL_DELTA: u16 = 120;
const RDP_PTR_WHEEL_NEGATIVE: u16 = 0x0100;
const RDP_PTR_WHEEL: u16 = 0x0200;
const RDP_PTR_HWHEEL: u16 = 0x0400;
const RDP_PTR_MOVE: u16 = 0x0800;
const RDP_PTR_DOWN: u16 = 0x8000;
const RDP_PTR_LEFT: u16 = 0x1000;
const RDP_PTR_RIGHT: u16 = 0x2000;
const RDP_PTR_MIDDLE: u16 = 0x4000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RdpReconnectState {
    generation: u64,
    attempt: u8,
    active: bool,
}

#[derive(Clone, Debug)]
struct RdpSessionMetrics {
    started_at: Instant,
    connected_at: Option<Instant>,
    last_frame_at: Option<Instant>,
    last_resolution: Option<(u32, u32)>,
    recent_frames: VecDeque<(Instant, u32, usize)>,
    frame_count: u64,
    presentation_count: u64,
    coalesced_update_count: u64,
    decoded_bytes: u64,
    avoided_native_full_frame_bytes: u64,
    canvas_allocation_bytes: u64,
    largest_update_gap: Duration,
    disconnect_count: u32,
    recovery_count: u32,
    last_failure: Option<(u32, String)>,
    pointer_event_count: u64,
    button_event_count: u64,
    scroll_event_count: u64,
    key_event_count: u64,
    key_press_event_count: u64,
    key_release_event_count: u64,
    text_commit_event_count: u64,
    rejected_input_count: u64,
    locally_reserved_shortcut_count: u64,
    focus_enter_count: u64,
    focus_leave_count: u64,
    capture_enable_count: u64,
    capture_release_count: u64,
    modifier_safety_release_count: u64,
    pointer_safety_release_count: u64,
    pending_input_at: Option<Instant>,
    last_input_to_frame: Option<Duration>,
    largest_input_to_frame: Duration,
}

impl Default for RdpSessionMetrics {
    fn default() -> Self {
        Self::new_at(Instant::now())
    }
}

impl RdpSessionMetrics {
    fn new_at(now: Instant) -> Self {
        Self {
            started_at: now,
            connected_at: None,
            last_frame_at: None,
            last_resolution: None,
            recent_frames: VecDeque::new(),
            frame_count: 0,
            presentation_count: 0,
            coalesced_update_count: 0,
            decoded_bytes: 0,
            avoided_native_full_frame_bytes: 0,
            canvas_allocation_bytes: 0,
            largest_update_gap: Duration::ZERO,
            disconnect_count: 0,
            recovery_count: 0,
            last_failure: None,
            pointer_event_count: 0,
            button_event_count: 0,
            scroll_event_count: 0,
            key_event_count: 0,
            key_press_event_count: 0,
            key_release_event_count: 0,
            text_commit_event_count: 0,
            rejected_input_count: 0,
            locally_reserved_shortcut_count: 0,
            focus_enter_count: 0,
            focus_leave_count: 0,
            capture_enable_count: 0,
            capture_release_count: 0,
            modifier_safety_release_count: 0,
            pointer_safety_release_count: 0,
            pending_input_at: None,
            last_input_to_frame: None,
            largest_input_to_frame: Duration::ZERO,
        }
    }

    fn record_frame_at(&mut self, now: Instant, frame: &RdpFrame) {
        if let Some(previous) = self.last_frame_at {
            self.largest_update_gap = self.largest_update_gap.max(now.duration_since(previous));
        }
        let bytes = frame.decoded_bytes;
        let source_updates = frame.source_updates.max(1);
        self.last_frame_at = Some(now);
        if let Some(input_at) = self.pending_input_at.take() {
            let elapsed = now.saturating_duration_since(input_at);
            if elapsed <= RDP_INPUT_FRAME_WINDOW {
                self.last_input_to_frame = Some(elapsed);
                self.largest_input_to_frame = self.largest_input_to_frame.max(elapsed);
            } else {
                self.last_input_to_frame = None;
            }
        }
        self.last_resolution = Some((frame.width, frame.height));
        self.frame_count = self.frame_count.saturating_add(u64::from(source_updates));
        self.presentation_count = self.presentation_count.saturating_add(1);
        self.coalesced_update_count = self
            .coalesced_update_count
            .saturating_add(u64::from(source_updates.saturating_sub(1)));
        self.decoded_bytes = self.decoded_bytes.saturating_add(bytes as u64);
        let full_frame_bytes = u64::from(frame.width)
            .saturating_mul(u64::from(frame.height))
            .saturating_mul(4)
            .saturating_mul(u64::from(source_updates));
        self.avoided_native_full_frame_bytes = self
            .avoided_native_full_frame_bytes
            .saturating_add(full_frame_bytes.saturating_sub(bytes as u64));
        self.recent_frames.push_back((now, source_updates, bytes));
        self.prune_at(now);
    }

    fn prune_at(&mut self, now: Instant) {
        while self
            .recent_frames
            .front()
            .is_some_and(|(seen, _, _)| now.duration_since(*seen) > RDP_METRIC_WINDOW)
        {
            self.recent_frames.pop_front();
        }
    }

    fn snapshot_at(&mut self, now: Instant) -> RdpMetricSnapshot {
        self.prune_at(now);
        let recent_bytes = self
            .recent_frames
            .iter()
            .map(|(_, _, bytes)| *bytes as u64)
            .sum::<u64>();
        let recent_updates = self
            .recent_frames
            .iter()
            .map(|(_, updates, _)| u64::from(*updates))
            .sum::<u64>();
        let seconds = RDP_METRIC_WINDOW.as_secs_f64();
        RdpMetricSnapshot {
            session_age: now.duration_since(self.started_at),
            connected_age: self.connected_at.map(|at| now.duration_since(at)),
            last_frame_age: self.last_frame_at.map(|at| now.duration_since(at)),
            resolution: self.last_resolution,
            frames_per_second: recent_updates as f64 / seconds,
            decoded_bytes_per_second: recent_bytes as f64 / seconds,
            frame_count: self.frame_count,
            presentation_count: self.presentation_count,
            coalesced_update_count: self.coalesced_update_count,
            decoded_bytes: self.decoded_bytes,
            avoided_native_full_frame_bytes: self.avoided_native_full_frame_bytes,
            canvas_allocation_bytes: self.canvas_allocation_bytes,
            largest_update_gap: self.largest_update_gap,
            disconnect_count: self.disconnect_count,
            recovery_count: self.recovery_count,
            last_failure: self.last_failure.clone(),
            pointer_event_count: self.pointer_event_count,
            button_event_count: self.button_event_count,
            scroll_event_count: self.scroll_event_count,
            key_event_count: self.key_event_count,
            key_press_event_count: self.key_press_event_count,
            key_release_event_count: self.key_release_event_count,
            text_commit_event_count: self.text_commit_event_count,
            rejected_input_count: self.rejected_input_count,
            locally_reserved_shortcut_count: self.locally_reserved_shortcut_count,
            focus_enter_count: self.focus_enter_count,
            focus_leave_count: self.focus_leave_count,
            capture_enable_count: self.capture_enable_count,
            capture_release_count: self.capture_release_count,
            modifier_safety_release_count: self.modifier_safety_release_count,
            pointer_safety_release_count: self.pointer_safety_release_count,
            last_input_to_frame: self.last_input_to_frame,
            largest_input_to_frame: self.largest_input_to_frame,
        }
    }

    fn record_input_at(&mut self, now: Instant, kind: RdpInputKind, accepted: bool) {
        if !accepted {
            self.rejected_input_count = self.rejected_input_count.saturating_add(1);
            return;
        }
        match kind {
            RdpInputKind::Pointer => {
                self.pointer_event_count = self.pointer_event_count.saturating_add(1)
            }
            RdpInputKind::Button => {
                self.button_event_count = self.button_event_count.saturating_add(1)
            }
            RdpInputKind::Scroll => {
                self.scroll_event_count = self.scroll_event_count.saturating_add(1)
            }
            RdpInputKind::KeyPress => {
                self.key_event_count = self.key_event_count.saturating_add(1);
                self.key_press_event_count = self.key_press_event_count.saturating_add(1);
            }
            RdpInputKind::KeyRelease => {
                self.key_event_count = self.key_event_count.saturating_add(1);
                self.key_release_event_count = self.key_release_event_count.saturating_add(1);
            }
            RdpInputKind::TextCommit => {
                self.key_event_count = self.key_event_count.saturating_add(1);
                self.text_commit_event_count = self.text_commit_event_count.saturating_add(1);
            }
        }
        self.pending_input_at.get_or_insert(now);
    }

    fn record_control_event(&mut self, event: RdpInputControlEvent) {
        match event {
            RdpInputControlEvent::LocallyReservedShortcut => {
                self.locally_reserved_shortcut_count =
                    self.locally_reserved_shortcut_count.saturating_add(1);
            }
            RdpInputControlEvent::FocusEnter => {
                self.focus_enter_count = self.focus_enter_count.saturating_add(1);
            }
            RdpInputControlEvent::FocusLeave => {
                self.focus_leave_count = self.focus_leave_count.saturating_add(1);
            }
            RdpInputControlEvent::CaptureEnabled => {
                self.capture_enable_count = self.capture_enable_count.saturating_add(1);
            }
            RdpInputControlEvent::CaptureReleased => {
                self.capture_release_count = self.capture_release_count.saturating_add(1);
            }
            RdpInputControlEvent::ModifierSafetyRelease => {
                self.modifier_safety_release_count =
                    self.modifier_safety_release_count.saturating_add(1);
            }
            RdpInputControlEvent::PointerSafetyRelease => {
                self.pointer_safety_release_count =
                    self.pointer_safety_release_count.saturating_add(1);
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RdpInputKind {
    Pointer,
    Button,
    Scroll,
    KeyPress,
    KeyRelease,
    TextCommit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RdpInputControlEvent {
    LocallyReservedShortcut,
    FocusEnter,
    FocusLeave,
    CaptureEnabled,
    CaptureReleased,
    ModifierSafetyRelease,
    PointerSafetyRelease,
}

#[derive(Debug, Default)]
struct RdpCanvas {
    width: u32,
    height: u32,
    stride: u32,
    surface: Option<gtk::cairo::ImageSurface>,
}

impl RdpCanvas {
    fn apply(&mut self, update: &RdpFrame) -> bool {
        if cfg!(target_endian = "big") {
            // Cairo ARgb32 is BGRA in memory on the little-endian Linux
            // architectures supported by the desktop packages. Refuse to
            // reinterpret pixels silently on a future big-endian target.
            return false;
        }
        let Some(full_stride) = update.width.checked_mul(4) else {
            return false;
        };
        let Some(full_length) = usize::try_from(full_stride).ok().and_then(|stride| {
            usize::try_from(update.height)
                .ok()
                .and_then(|height| stride.checked_mul(height))
        }) else {
            return false;
        };
        if full_length > MAX_RDP_CANVAS_BYTES {
            return false;
        }
        if self.width != update.width || self.height != update.height || self.surface.is_none() {
            let (Ok(width), Ok(height)) =
                (i32::try_from(update.width), i32::try_from(update.height))
            else {
                return false;
            };
            let Ok(surface) =
                gtk::cairo::ImageSurface::create(gtk::cairo::Format::ARgb32, width, height)
            else {
                return false;
            };
            let Ok(stride) = u32::try_from(surface.stride()) else {
                return false;
            };
            let Some(surface_length) = usize::try_from(stride)
                .ok()
                .and_then(|stride| stride.checked_mul(height as usize))
            else {
                return false;
            };
            if stride < full_stride || surface_length > MAX_RDP_CANVAS_BYTES {
                return false;
            }
            self.width = update.width;
            self.height = update.height;
            self.stride = stride;
            self.surface = Some(surface);
        }

        let Some(row_bytes) = update.damage.width.checked_mul(4) else {
            return false;
        };
        let Some(right) = update.damage.x.checked_add(update.damage.width) else {
            return false;
        };
        let Some(bottom) = update.damage.y.checked_add(update.damage.height) else {
            return false;
        };
        if update.damage.width == 0
            || update.damage.height == 0
            || right > update.width
            || bottom > update.height
            || update.stride < row_bytes
        {
            return false;
        }
        let source_stride = usize::try_from(update.stride).unwrap_or(0);
        let destination_stride = usize::try_from(self.stride).unwrap_or(0);
        let row_bytes = usize::try_from(row_bytes).unwrap_or(0);
        let destination_x = usize::try_from(update.damage.x)
            .ok()
            .and_then(|x| x.checked_mul(4))
            .unwrap_or(usize::MAX);
        let rows = usize::try_from(update.damage.height).unwrap_or(0);
        let required = source_stride.saturating_mul(rows);
        if row_bytes == 0 || required > update.bgra.len() {
            return false;
        }
        let Some(surface) = self.surface.as_mut() else {
            return false;
        };
        let Ok(mut pixels) = surface.data() else {
            return false;
        };
        for row in 0..rows {
            let source_start = row.saturating_mul(source_stride);
            let destination_row = usize::try_from(update.damage.y)
                .unwrap_or(usize::MAX)
                .saturating_add(row);
            let destination_start = destination_row
                .checked_mul(destination_stride)
                .and_then(|offset| offset.checked_add(destination_x));
            let Some(destination_start) = destination_start else {
                return false;
            };
            let Some(destination_end) = destination_start.checked_add(row_bytes) else {
                return false;
            };
            let Some(source_end) = source_start.checked_add(row_bytes) else {
                return false;
            };
            let (Some(destination), Some(source)) = (
                pixels.get_mut(destination_start..destination_end),
                update.bgra.get(source_start..source_end),
            ) else {
                return false;
            };
            destination.copy_from_slice(source);
        }
        drop(pixels);
        let (Ok(x), Ok(y), Ok(width), Ok(height)) = (
            i32::try_from(update.damage.x),
            i32::try_from(update.damage.y),
            i32::try_from(update.damage.width),
            i32::try_from(update.damage.height),
        ) else {
            return false;
        };
        surface.mark_dirty_rectangle(x, y, width, height);
        true
    }

    fn allocation_bytes(&self) -> u64 {
        u64::from(self.stride).saturating_mul(u64::from(self.height))
    }
}

type SharedRdpCanvas = Rc<RefCell<RdpCanvas>>;

#[derive(Clone, Debug)]
struct RdpMetricSnapshot {
    session_age: Duration,
    connected_age: Option<Duration>,
    last_frame_age: Option<Duration>,
    resolution: Option<(u32, u32)>,
    frames_per_second: f64,
    decoded_bytes_per_second: f64,
    frame_count: u64,
    presentation_count: u64,
    coalesced_update_count: u64,
    decoded_bytes: u64,
    avoided_native_full_frame_bytes: u64,
    canvas_allocation_bytes: u64,
    largest_update_gap: Duration,
    disconnect_count: u32,
    recovery_count: u32,
    last_failure: Option<(u32, String)>,
    pointer_event_count: u64,
    button_event_count: u64,
    scroll_event_count: u64,
    key_event_count: u64,
    key_press_event_count: u64,
    key_release_event_count: u64,
    text_commit_event_count: u64,
    rejected_input_count: u64,
    locally_reserved_shortcut_count: u64,
    focus_enter_count: u64,
    focus_leave_count: u64,
    capture_enable_count: u64,
    capture_release_count: u64,
    modifier_safety_release_count: u64,
    pointer_safety_release_count: u64,
    last_input_to_frame: Option<Duration>,
    largest_input_to_frame: Duration,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RdpLiveInputState {
    focused: bool,
    capture_enabled: bool,
    compositor_capture_granted: bool,
    module_fullscreen: bool,
    pointer_buttons_held: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RdpCapturePolicy {
    windowed_preference: bool,
    fullscreen_suspended: bool,
}

impl RdpCapturePolicy {
    fn should_capture(self, fullscreen: bool, connected: bool, focused: bool) -> bool {
        connected
            && focused
            && if fullscreen {
                !self.fullscreen_suspended
            } else {
                self.windowed_preference
            }
    }

    fn set_explicit(&mut self, fullscreen: bool, enabled: bool) {
        if fullscreen {
            self.fullscreen_suspended = !enabled;
        } else {
            self.windowed_preference = enabled;
        }
    }
}

fn rdp_reconnect_delay(attempt: u8) -> Option<Duration> {
    if attempt == 0 || attempt > MAX_RDP_RECONNECT_ATTEMPTS {
        return None;
    }
    Some(Duration::from_secs(match attempt {
        1 => 1,
        2 => 2,
        3 => 4,
        4 => 8,
        5 => 15,
        _ => 30,
    }))
}

fn workspace_phase_accepts_connect_start(phase: WorkspacePhase) -> bool {
    matches!(
        phase,
        WorkspacePhase::Reconnecting
            | WorkspacePhase::Disconnected
            | WorkspacePhase::Failed
            | WorkspacePhase::Closed
    )
}

fn rdp_scroll_pointer_flags(delta: f64, horizontal: bool) -> Option<u16> {
    if !delta.is_finite() || delta == 0.0 {
        return None;
    }
    let axis = if horizontal {
        RDP_PTR_HWHEEL
    } else {
        RDP_PTR_WHEEL
    };
    // GTK reports positive vertical deltas when scrolling down, while RDP's
    // negative flag represents that backward direction. Horizontal positive
    // deltas point right and therefore remain positive in RDP.
    let negative = if horizontal { delta < 0.0 } else { delta > 0.0 };
    Some(axis | RDP_WHEEL_DELTA | if negative { RDP_PTR_WHEEL_NEGATIVE } else { 0 })
}

fn responsive_workstation_panel_widths(total_width: i32) -> (i32, i32) {
    let asset = ((f64::from(total_width) * 0.234_375).round() as i32).clamp(220, 320);
    let tools = ((f64::from(total_width) * 0.256_25).round() as i32).clamp(280, 420);
    (asset, tools)
}

const ORBIT_LEGAL_TERMS: &str = r#"OrbitTerm 使用条款、免责声明与隐私说明
生效日期：2026-08-21

1. 授权范围：您只能连接和管理自己拥有、管理或已取得明确合法授权的设备、账户、网络及数据。
2. 账户与安全：您负责妥善保管账户密码、主密码、SSH 私钥、令牌和远程凭据；主密码无法代为恢复。
3. 同步与备份：端到端加密同步不等同于完整备份，重要数据仍需保留独立备份。
4. 高风险操作：SSH、Telnet、RDP、SFTP、Docker、批量命令、端口映射及进程操作会直接影响远端系统，执行前应核对目标并准备恢复方案。
5. 隐私与诊断：脱敏诊断不应包含密码、私钥、令牌、命令正文、终端内容或远端文件内容。
6. 第三方服务：系统能力、网络、远端服务和开源组件的可用性与策略由相应提供者负责。
7. 免责声明：在法律允许范围内，本软件按“现状”和“可用状态”提供，监控与验证不能替代专业审计或备份。
8. 责任限制：法律允许范围内，不承担因使用或无法使用产生的间接或后果性损失；不可排除的法定责任不受影响。
9. 更新与终止：功能、协议和条款可因安全、兼容或合规需要更新；严重滥用时服务可被限制。
10. 适用规则：条款应结合用户所在地不可排除的消费者与数据保护法律解释。

继续使用即表示您已阅读并同意上述条款；若不同意，请停止使用相关功能。"#;

struct TerminalSplitRuntime {
    channel_id: u64,
    terminal_size: Option<(u32, u32)>,
    terminal_backlog: Vec<u8>,
}

impl TerminalSplitRuntime {
    fn new(channel_id: u64) -> Self {
        Self {
            channel_id,
            terminal_size: None,
            terminal_backlog: Vec::new(),
        }
    }

    fn append_terminal(&mut self, bytes: &[u8]) {
        append_bounded_terminal(&mut self.terminal_backlog, bytes);
    }
}

struct SessionRuntime {
    asset_id: Uuid,
    name: String,
    transport: Transport,
    phase: WorkspacePhase,
    base_session_id: Option<u64>,
    terminal_channel_id: Option<u64>,
    sftp_session_id: Option<u64>,
    terminal_size: Option<(u32, u32)>,
    monitor_in_flight: bool,
    terminal_backlog: Vec<u8>,
    terminal_splits: Vec<TerminalSplitRuntime>,
    active_terminal_pane: usize,
    command_history: Vec<String>,
    telnet: Option<TelnetSession>,
    rdp: Option<RdpSession>,
    rdp_frame_size: Option<(u32, u32)>,
    rdp_frame: Option<SharedRdpCanvas>,
}

impl SessionRuntime {
    fn new(asset: &ServerAsset) -> Self {
        Self {
            asset_id: asset.id,
            name: asset.name.clone(),
            transport: asset.transport,
            phase: WorkspacePhase::Starting,
            base_session_id: None,
            terminal_channel_id: None,
            sftp_session_id: None,
            terminal_size: None,
            monitor_in_flight: false,
            terminal_backlog: Vec::new(),
            terminal_splits: Vec::new(),
            active_terminal_pane: 0,
            command_history: Vec::new(),
            telnet: None,
            rdp: None,
            rdp_frame_size: None,
            rdp_frame: None,
        }
    }

    fn replacing_for_connect(asset: &ServerAsset, mut previous: Option<Self>) -> Self {
        let mut replacement = Self::new(asset);
        if asset.transport == Transport::Rdp
            && previous
                .as_ref()
                .is_some_and(|runtime| runtime.phase == WorkspacePhase::Reconnecting)
        {
            let previous = previous.as_mut().expect("checked above");
            replacement.rdp_frame = previous.rdp_frame.take();
            replacement.rdp_frame_size = previous.rdp_frame_size;
        }
        replacement
    }

    fn append_terminal(&mut self, bytes: &[u8]) {
        append_bounded_terminal(&mut self.terminal_backlog, bytes);
    }

    fn pane_count(&self) -> usize {
        1 + self.terminal_splits.len()
    }

    fn pane_backlog(&self, pane: usize) -> &[u8] {
        if pane == 0 {
            &self.terminal_backlog
        } else {
            self.terminal_splits
                .get(pane - 1)
                .map(|split| split.terminal_backlog.as_slice())
                .unwrap_or_default()
        }
    }

    fn append_terminal_channel(&mut self, channel_id: u64, bytes: &[u8]) -> Option<usize> {
        if self.terminal_channel_id == Some(channel_id) {
            self.append_terminal(bytes);
            return Some(0);
        }
        let (index, split) = self
            .terminal_splits
            .iter_mut()
            .enumerate()
            .find(|(_, split)| split.channel_id == channel_id)?;
        split.append_terminal(bytes);
        Some(index + 1)
    }

    fn take_terminal_channels(&mut self) -> Vec<u64> {
        let mut channels = self
            .terminal_channel_id
            .take()
            .into_iter()
            .collect::<Vec<_>>();
        channels.extend(self.terminal_splits.drain(..).map(|split| split.channel_id));
        self.active_terminal_pane = 0;
        channels
    }

    fn clear_terminal_pane(&mut self, pane: usize) {
        if pane == 0 {
            self.terminal_backlog.clear();
        } else if let Some(split) = self.terminal_splits.get_mut(pane - 1) {
            split.terminal_backlog.clear();
        }
    }

    fn remember_command(&mut self, command: &str) {
        let command = command.trim();
        if command.is_empty() {
            return;
        }
        self.command_history.retain(|item| item != command);
        self.command_history.insert(0, command.to_owned());
        self.command_history.truncate(50);
    }
}

fn append_bounded_terminal(backlog: &mut Vec<u8>, bytes: &[u8]) {
    backlog.extend_from_slice(bytes);
    if backlog.len() > MAX_SESSION_BACKLOG {
        let remove = backlog.len() - MAX_SESSION_BACKLOG;
        backlog.drain(..remove);
    }
}

#[derive(Default)]
struct SessionRegistry {
    selected_asset_id: Option<Uuid>,
    active_workspace_id: Option<Uuid>,
    sessions: BTreeMap<Uuid, SessionRuntime>,
}

impl SessionRegistry {
    fn owns_input(&self, workspace_id: Uuid) -> bool {
        self.active_workspace_id == Some(workspace_id)
    }

    fn select_for_connect(&mut self, asset_id: Uuid, activate: bool) -> bool {
        if activate {
            self.selected_asset_id = Some(asset_id);
            self.active_workspace_id = Some(asset_id);
        }
        self.active_workspace_id == Some(asset_id)
    }

    fn active(&self) -> Option<&SessionRuntime> {
        self.active_workspace_id
            .and_then(|id| self.sessions.get(&id))
    }

    fn active_mut(&mut self) -> Option<&mut SessionRuntime> {
        self.active_workspace_id
            .and_then(|id| self.sessions.get_mut(&id))
    }
}

#[derive(Clone)]
struct WorkspaceWidgets {
    root: gtk::Box,
    monitor_band: gtk::Box,
    tabs: gtk::Box,
    input_row: gtk::Box,
    heading: gtk::Box,
    tab_hint: gtk::Label,
    content_stack: gtk::Stack,
    empty_title: gtk::Label,
    empty_description: gtk::Label,
    tab_status: gtk::Label,
    title: gtk::Label,
    subtitle: gtk::Label,
    security: gtk::Label,
    edit: gtk::Button,
    connect: gtk::Button,
    disconnect: gtk::Button,
    monitor_connection: gtk::Label,
    monitor_latency: gtk::Label,
    monitor_cpu: gtk::Label,
    monitor_memory: gtk::Label,
    monitor_disk: gtk::Label,
    monitor_download: gtk::Label,
    monitor_upload: gtk::Label,
    monitor_detail: gtk::Button,
    monitor_endpoint: gtk::Label,
    monitor_copy_endpoint: gtk::Button,
    monitor_history: Rc<RefCell<Vec<MonitorSnapshot>>>,
    monitor_graphs: Rc<Vec<gtk::DrawingArea>>,
    terminal_grid: gtk::Grid,
    terminal_frames: Rc<Vec<gtk::Box>>,
    terminals: Rc<Vec<vte::Terminal>>,
    split_menu: gtk::MenuButton,
    split_add: gtk::Button,
    split_remove: gtk::Button,
    split_reset: gtk::Button,
    terminal_fullscreen: gtk::Button,
    rdp_picture: gtk::DrawingArea,
    rdp_canvas: Rc<RefCell<Option<SharedRdpCanvas>>>,
    rdp_state_overlay: gtk::Box,
    rdp_state_title: gtk::Label,
    rdp_state_detail: gtk::Label,
    rdp_controls: gtk::Box,
    rdp_controls_toggle: gtk::ToggleButton,
    rdp_capture_shortcuts: gtk::ToggleButton,
    rdp_secure_attention: gtk::Button,
    rdp_diagnostics: gtk::Button,
    rdp_fullscreen: gtk::Button,
    rdp_input_status: gtk::Label,
    rdp_security_bar: gtk::Label,
    input: gtk::Entry,
    send: gtk::Button,
}

#[derive(Clone)]
struct SidebarWidgets {
    root: gtk::Box,
    collapse: gtk::Button,
    footer: gtk::Box,
    edit: gtk::Button,
}

#[derive(Clone)]
struct ModuleShellWidgets {
    header: adw::HeaderBar,
    expand_left: gtk::Button,
    expand_right: gtk::Button,
}

#[derive(Clone, Copy)]
struct ModuleFullscreenRestore {
    window_was_fullscreen: bool,
    header_visible: bool,
    monitor_visible: bool,
    tabs_visible: bool,
    sidebar_visible: bool,
    footer_visible: bool,
    tools_visible: bool,
    input_visible: bool,
    rdp_security_visible: bool,
    expand_left_visible: bool,
    expand_right_visible: bool,
}

#[derive(Clone)]
struct ToolsWidgets {
    root: gtk::Stack,
    collapse: gtk::Button,
    content_stack: gtk::Stack,
    sftp_path: gtk::Entry,
    sftp_up: gtk::Button,
    sftp_refresh: gtk::Button,
    sftp_upload: gtk::Button,
    sftp_new_directory: gtk::Button,
    sftp_new_file: gtk::Button,
    sftp_download: gtk::Button,
    sftp_rename: gtk::Button,
    sftp_chmod: gtk::Button,
    sftp_delete: gtk::Button,
    sftp_list: gtk::ListBox,
    sftp_status: gtk::Label,
    sftp_entries: Rc<RefCell<Vec<SftpEntry>>>,
    docker_refresh: gtk::Button,
    docker_list: gtk::ListBox,
    docker_status: gtk::Label,
    docker_logs: gtk::Button,
    docker_start: gtk::Button,
    docker_restart: gtk::Button,
    docker_stop: gtk::Button,
    docker_containers: Rc<RefCell<Vec<DockerContainer>>>,
    snippet_search: gtk::SearchEntry,
    snippet_list: gtk::ListBox,
    snippet_add: gtk::Button,
    snippet_edit: gtk::Button,
    snippet_delete: gtk::Button,
    snippet_history: gtk::Button,
    snippet_insert: gtk::Button,
    snippet_run: gtk::Button,
    snippet_status: gtk::Label,
    snippets: Rc<RefCell<Vec<CommandSnippet>>>,
    visible_snippet_ids: Rc<RefCell<Vec<Uuid>>>,
    snippet_repository: SnippetRepository,
    unavailable_title: gtk::Label,
    unavailable_detail: gtk::Label,
}

#[derive(Clone)]
struct UiContext {
    window: adw::ApplicationWindow,
    catalog: Rc<RefCell<Catalog>>,
    vault: CredentialVault,
    known_hosts: PathBuf,
    session: Rc<RefCell<SessionRegistry>>,
    session_events: mpsc::Sender<SessionEvent>,
    rdp_config_path: PathBuf,
    workspace: WorkspaceWidgets,
    sidebar: Rc<RefCell<Option<SidebarWidgets>>>,
    tools: ToolsWidgets,
    status: gtk::Label,
    sync_status: gtk::Label,
    refresh_assets: Rc<dyn Fn()>,
    sync_state: SyncStateRepository,
    sync_operations: SyncOperationRepository,
    sync_scheduler: SyncSchedulerGate,
    sync_session: SecureSyncSession,
    background_pending: Rc<RefCell<Option<PendingSyncRun>>>,
    active_tunnels: Rc<RefCell<Vec<ActiveTunnel>>>,
    tools_collapsed: Rc<Cell<bool>>,
    tools_auto_hidden_for_rdp: Rc<Cell<bool>>,
    tools_expand: Rc<RefCell<Option<gtk::Button>>>,
    rdp_input_capture: Rc<Cell<bool>>,
    rdp_capture_policy: Rc<Cell<RdpCapturePolicy>>,
    rdp_reconnect_states: Rc<RefCell<BTreeMap<Uuid, RdpReconnectState>>>,
    rdp_metrics: Rc<RefCell<BTreeMap<Uuid, RdpSessionMetrics>>>,
    rdp_last_pointer: Rc<Cell<Option<(u16, u16)>>>,
    rdp_pressed_pointer_buttons: Rc<Cell<u16>>,
    rdp_failure_dialogs: Rc<RefCell<HashSet<Uuid>>>,
    module_shell: Rc<RefCell<Option<ModuleShellWidgets>>>,
    module_fullscreen: Rc<Cell<bool>>,
    module_fullscreen_restore: Rc<RefCell<Option<ModuleFullscreenRestore>>>,
    suppress_close_until: Rc<Cell<Option<Instant>>>,
    preferences: Rc<RefCell<AppPreferences>>,
    preferences_repository: PreferencesRepository,
    port_forward_profiles: PortForwardProfileRepository,
    monitor_tick: Rc<Cell<u64>>,
}

#[derive(Clone)]
struct ActiveTunnel {
    id: u64,
    asset_id: Uuid,
    asset_name: String,
    bind_host: String,
    bind_port: u16,
    destination_host: String,
    destination_port: u16,
}

#[derive(Clone, Debug)]
struct RemoteProcess {
    pid: u32,
    parent_pid: u32,
    user: String,
    cpu_percent: f64,
    memory_percent: f64,
    state: String,
    start_identity: i64,
    command: String,
}

enum ConnectWorkerOutcome {
    Connected {
        base_session_id: u64,
        terminal_channel_id: u64,
    },
    Challenge {
        challenge_id: String,
        fingerprint: String,
        algorithm: String,
        request_id: RequestId,
    },
    Blocked(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WorkstationShortcutAction {
    NextSession,
    PreviousSession,
    SelectSession(usize),
    NextPane,
    PreviousPane,
    SelectPane(usize),
    NewSession,
    CloseSession,
    AddPane,
    ClosePane,
    ResetPanes,
    SearchTerminal,
    FocusCommandInput,
    SendCommandInput,
    OpenSettings,
    OpenBatchCommand,
    ToggleAssetSidebar,
    ToggleToolInspector,
    ToggleFullscreen,
    ShowHelp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ShortcutRoutingLayer {
    LocalSystem,
    Application,
    RemoteDesktop,
    FocusedWidget,
}

pub fn install_styles() {
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&format!("{GTK_TOKENS}\n{APP_STYLES}"));
    gtk::style_context_add_provider_for_display(
        &display,
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

pub fn build_application_window(application: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(application)
        .title("OrbitTerm")
        .default_width(1280)
        .default_height(800)
        // The three-pane workbench needs enough room for a useful terminal,
        // a complete asset rail and the three labelled tool tabs.
        .width_request(980)
        .height_request(700)
        .resizable(true)
        .build();
    window.add_css_class("orbitterm-window");

    let paths = match XdgPaths::discover() {
        Ok(paths) => paths,
        Err(error) => {
            window.set_content(Some(&fatal_state(&format!(
                "无法确定安全存储路径：{error}"
            ))));
            window.present();
            return;
        }
    };
    let known_hosts = paths.known_hosts_file();
    if let Err(error) = ensure_known_hosts_parent(&known_hosts) {
        window.set_content(Some(&fatal_state(&format!(
            "无法准备 Host Key 存储：{error}"
        ))));
        window.present();
        return;
    }
    if known_hosts.to_str().is_none() {
        window.set_content(Some(&fatal_state("Host Key 存储路径必须是有效 UTF-8。")));
        window.present();
        return;
    }
    let rdp_config_path = paths.rdp_config_dir();
    if let Err(error) = ensure_private_directory(&rdp_config_path) {
        window.set_content(Some(&fatal_state(&format!(
            "无法准备 RDP 证书信任目录：{error}"
        ))));
        window.present();
        return;
    }
    if rdp_config_path.to_str().is_none() {
        window.set_content(Some(&fatal_state("RDP 证书信任目录必须是有效 UTF-8。")));
        window.present();
        return;
    }

    let repository = JsonAssetRepository::new(paths.assets_file());
    let preferences_repository = PreferencesRepository::new(paths.preferences_file());
    let port_forward_profiles =
        PortForwardProfileRepository::new(paths.port_forward_profiles_file());
    let preferences = Rc::new(RefCell::new(
        preferences_repository.load().unwrap_or_default(),
    ));
    let sync_state = SyncStateRepository::new(paths.sync_state_file());
    let sync_operations = SyncOperationRepository::new(paths.sync_operations_file());
    let snippet_repository = SnippetRepository::new(paths.snippets_file());
    let catalog = match AssetCatalog::open(repository) {
        Ok(catalog) => Rc::new(RefCell::new(catalog)),
        Err(error) => {
            window.set_content(Some(&fatal_state(&format!("无法读取服务器资产：{error}"))));
            window.present();
            return;
        }
    };

    let status_label = gtk::Label::new(Some("未连接 · 所有网络操作将使用受检 Host Key 会话"));
    status_label.set_xalign(0.0);
    status_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let sync_status = gtk::Label::new(Some("未登录 · 本地资产可用"));
    sync_status.add_css_class("caption");
    sync_status.set_xalign(0.0);
    sync_status.set_ellipsize(gtk::pango::EllipsizeMode::End);

    let workspace = build_workspace();
    for terminal in workspace.terminals.iter() {
        apply_preferences(terminal, &preferences.borrow());
    }
    workspace.root.set_size_request(560, -1);
    let tools = build_tools(snippet_repository);
    tools.root.set_size_request(280, -1);
    tools.root.set_visible(true);
    let vault = CredentialVault;
    let session = Rc::new(RefCell::new(SessionRegistry::default()));
    let (session_events, session_event_receiver) = mpsc::channel();

    let (terminal_sender, terminal_receiver) = mpsc::channel();
    if let Err(error) = register_terminal_output(terminal_sender) {
        status_label.set_label(&format!("终端输出回调不可用：{error}"));
    }
    let terminals_for_output = workspace.terminals.clone();
    let session_for_output = session.clone();
    gtk::glib::timeout_add_local(Duration::from_millis(16), move || {
        while let Ok(chunk) = terminal_receiver.try_recv() {
            let visible_pane = {
                let mut registry = session_for_output.borrow_mut();
                let active = registry.active_workspace_id;
                let Some((workspace_id, pane)) =
                    registry
                        .sessions
                        .iter_mut()
                        .find_map(|(workspace_id, runtime)| {
                            let pane =
                                runtime.append_terminal_channel(chunk.channel_id, &chunk.bytes)?;
                            Some((*workspace_id, pane))
                        })
                else {
                    continue;
                };
                (active == Some(workspace_id)).then_some(pane)
            };
            if let Some(pane) = visible_pane {
                // All panes in the active workspace stay live. Feeding VTE
                // does not request focus, so background output can update
                // without stealing keyboard routing from the active pane.
                if let Some(terminal) = terminals_for_output.get(pane) {
                    terminal.feed(&chunk.bytes);
                }
            }
        }
        gtk::glib::ControlFlow::Continue
    });
    let terminals_for_resize = workspace.terminals.clone();
    let session_for_resize = session.clone();
    gtk::glib::timeout_add_local(Duration::from_millis(250), move || {
        let resize = {
            let mut registry = session_for_resize.borrow_mut();
            let Some(runtime) = registry.active_mut() else {
                return gtk::glib::ControlFlow::Continue;
            };
            let mut requests = Vec::new();
            for pane in 0..runtime.pane_count() {
                let Some(terminal) = terminals_for_resize.get(pane) else {
                    continue;
                };
                let (Ok(columns), Ok(rows)) = (
                    u32::try_from(terminal.column_count()),
                    u32::try_from(terminal.row_count()),
                ) else {
                    continue;
                };
                let previous = if pane == 0 {
                    &mut runtime.terminal_size
                } else {
                    &mut runtime.terminal_splits[pane - 1].terminal_size
                };
                if *previous != Some((columns, rows)) {
                    *previous = Some((columns, rows));
                    requests.push((
                        runtime.transport,
                        if pane == 0 {
                            runtime.terminal_channel_id
                        } else {
                            Some(runtime.terminal_splits[pane - 1].channel_id)
                        },
                        columns,
                        rows,
                        pane,
                    ));
                }
            }
            requests
        };
        for (transport, channel_id, columns, rows, pane) in resize {
            match (transport, channel_id) {
                (Transport::Ssh, Some(channel_id)) => {
                    std::thread::spawn(move || {
                        let _ = CheckedCoreClient::new().resize_terminal(channel_id, columns, rows);
                    });
                }
                (Transport::Telnet, _) if pane == 0 => {
                    if let (Ok(columns), Ok(rows)) = (u16::try_from(columns), u16::try_from(rows)) {
                        if let Some(telnet) = session_for_resize
                            .borrow()
                            .active()
                            .and_then(|runtime| runtime.telnet.as_ref())
                        {
                            let _ = telnet.resize(columns, rows);
                        }
                    }
                }
                _ => {}
            }
        }
        gtk::glib::ControlFlow::Continue
    });

    let asset_list = gtk::ListBox::new();
    asset_list.add_css_class("asset-list");
    asset_list.set_selection_mode(gtk::SelectionMode::Single);
    let asset_ids = Rc::new(RefCell::new(Vec::<Option<Uuid>>::new()));
    let asset_stack = gtk::Stack::new();
    asset_stack.set_vexpand(true);
    let search = gtk::SearchEntry::builder()
        .placeholder_text("搜索名称、主机、用户或标签")
        .build();
    search.add_css_class("sidebar-search");
    let asset_count = gtk::Label::new(Some("0 台"));
    asset_count.add_css_class("asset-count");

    let list_for_refresh = asset_list.clone();
    let stack_for_refresh = asset_stack.clone();
    let search_for_refresh = search.clone();
    let ids_for_refresh = asset_ids.clone();
    let catalog_for_refresh = catalog.clone();
    let asset_count_for_refresh = asset_count.clone();
    let refresh: Rc<dyn Fn()> = Rc::new(move || {
        refresh_asset_list(
            &list_for_refresh,
            &stack_for_refresh,
            &catalog_for_refresh.borrow(),
            search_for_refresh.text().as_str(),
            &ids_for_refresh,
            &asset_count_for_refresh,
        );
    });

    let context = UiContext {
        window: window.clone(),
        catalog: catalog.clone(),
        vault: vault.clone(),
        known_hosts,
        session: session.clone(),
        session_events,
        rdp_config_path,
        workspace: workspace.clone(),
        sidebar: Rc::new(RefCell::new(None)),
        tools: tools.clone(),
        status: status_label.clone(),
        sync_status: sync_status.clone(),
        refresh_assets: refresh.clone(),
        sync_state,
        sync_operations,
        sync_scheduler: SyncSchedulerGate::default(),
        sync_session: SecureSyncSession::default(),
        background_pending: Rc::new(RefCell::new(None)),
        active_tunnels: Rc::new(RefCell::new(Vec::new())),
        tools_collapsed: Rc::new(Cell::new(false)),
        tools_auto_hidden_for_rdp: Rc::new(Cell::new(false)),
        tools_expand: Rc::new(RefCell::new(None)),
        rdp_input_capture: Rc::new(Cell::new(false)),
        rdp_capture_policy: Rc::new(Cell::new(RdpCapturePolicy::default())),
        rdp_reconnect_states: Rc::new(RefCell::new(BTreeMap::new())),
        rdp_metrics: Rc::new(RefCell::new(BTreeMap::new())),
        rdp_last_pointer: Rc::new(Cell::new(None)),
        rdp_pressed_pointer_buttons: Rc::new(Cell::new(0)),
        rdp_failure_dialogs: Rc::new(RefCell::new(HashSet::new())),
        module_shell: Rc::new(RefCell::new(None)),
        module_fullscreen: Rc::new(Cell::new(false)),
        module_fullscreen_restore: Rc::new(RefCell::new(None)),
        suppress_close_until: Rc::new(Cell::new(None)),
        preferences: preferences.clone(),
        preferences_repository,
        port_forward_profiles,
        monitor_tick: Rc::new(Cell::new(0)),
    };

    let context_for_events = context.clone();
    gtk::glib::timeout_add_local(Duration::from_millis(16), move || {
        let mut rdp_frames_ready = HashSet::new();
        while let Ok(event) = session_event_receiver.try_recv() {
            if matches!(&event.kind, SessionEventKind::RdpFrameReady) {
                rdp_frames_ready.insert(event.workspace_id);
            } else {
                handle_protocol_session_event(&context_for_events, event);
            }
        }
        for workspace_id in rdp_frames_ready {
            handle_rdp_frame_ready(&context_for_events, workspace_id);
        }
        gtk::glib::ControlFlow::Continue
    });
    install_rdp_input(&context);
    install_rdp_diagnostics(&context);

    if application.lookup_action("open-sync").is_none() {
        let open_sync = gtk::gio::SimpleAction::new("open-sync", None);
        let action_context = context.clone();
        open_sync.connect_activate(move |_, _| present_sync_window(action_context.clone()));
        application.add_action(&open_sync);
    }

    let sidebar = build_sidebar(
        &window,
        catalog.clone(),
        (&search, &asset_list, &asset_stack, &asset_count),
        vault.clone(),
        refresh.clone(),
        &sync_status,
        context.clone(),
    );
    context.sidebar.replace(Some(sidebar.clone()));

    let root = gtk::Box::new(Orientation::Vertical, 0);
    root.add_css_class("app-shell");
    let app_header = build_header(
        &window,
        catalog.clone(),
        vault.clone(),
        refresh.clone(),
        context.clone(),
        &search,
    );
    root.append(&app_header);
    root.append(&workspace.monitor_band);

    let workspace_and_tools = gtk::Paned::new(Orientation::Horizontal);
    workspace_and_tools.set_start_child(Some(&workspace.root));
    workspace_and_tools.set_end_child(Some(&tools.root));
    workspace_and_tools.set_position(680);
    workspace_and_tools.set_resize_start_child(true);
    workspace_and_tools.set_resize_end_child(false);
    workspace_and_tools.set_shrink_start_child(false);
    workspace_and_tools.set_shrink_end_child(false);

    let main_paned = gtk::Paned::new(Orientation::Horizontal);
    main_paned.set_start_child(Some(&sidebar.root));
    main_paned.set_end_child(Some(&workspace_and_tools));
    main_paned.set_position(300);
    main_paned.set_resize_start_child(false);
    main_paned.set_resize_end_child(true);
    main_paned.set_shrink_start_child(false);
    main_paned.set_shrink_end_child(false);
    main_paned.set_vexpand(true);
    let workbench_overlay = gtk::Overlay::new();
    workbench_overlay.set_child(Some(&main_paned));
    let expand_left = gtk::Button::builder()
        .icon_name("sidebar-show-symbolic")
        .tooltip_text("展开服务器资产栏")
        .halign(Align::Start)
        .valign(Align::Center)
        .visible(false)
        .build();
    expand_left.add_css_class("panel-edge-button");
    expand_left.set_margin_start(0);
    workbench_overlay.add_overlay(&expand_left);
    let expand_right = gtk::Button::builder()
        .icon_name("sidebar-show-right-symbolic")
        .tooltip_text("展开会话工具")
        .halign(Align::End)
        .valign(Align::Center)
        .visible(false)
        .build();
    expand_right.add_css_class("panel-edge-button");
    expand_right.set_margin_end(0);
    workbench_overlay.add_overlay(&expand_right);
    context.tools_expand.replace(Some(expand_right.clone()));
    context.module_shell.replace(Some(ModuleShellWidgets {
        header: app_header,
        expand_left: expand_left.clone(),
        expand_right: expand_right.clone(),
    }));
    // Keep sync and pre-input as two precisely-sized overlays instead of a
    // full-width bottom row. The right tools pane can therefore use the full
    // workbench height, including the area beside pre-input, without an empty
    // spacer intercepting its bottom controls.
    sidebar.footer.set_halign(Align::Start);
    sidebar.footer.set_valign(Align::End);
    sidebar.footer.set_size_request(300, 46);
    workbench_overlay.add_overlay(&sidebar.footer);
    workspace.input_row.set_halign(Align::Start);
    workspace.input_row.set_valign(Align::End);
    workspace.input_row.set_size_request(680, -1);
    workbench_overlay.add_overlay(&workspace.input_row);
    root.append(&workbench_overlay);

    let overlay_for_bottom_layout = workbench_overlay.clone();
    let sidebar_for_bottom_layout = sidebar.root.clone();
    let footer_for_bottom_layout = sidebar.footer.clone();
    let workspace_for_bottom_layout = workspace.root.clone();
    let input_for_bottom_layout = workspace.input_row.clone();
    let tools_for_bottom_layout = tools.root.clone();
    let last_sidebar_width = Rc::new(Cell::new(300));
    let last_tools_width = Rc::new(Cell::new(328));
    let last_workbench_width = Rc::new(Cell::new(0));
    let responsive_layout_initialized = Rc::new(Cell::new(false));
    let applying_responsive_layout = Rc::new(Cell::new(false));
    let sidebar_user_sized = Rc::new(Cell::new(false));
    let tools_user_sized = Rc::new(Cell::new(false));
    let tools_automatically_collapsed = Rc::new(Cell::new(false));
    {
        let initialized = responsive_layout_initialized.clone();
        let applying = applying_responsive_layout.clone();
        let user_sized = sidebar_user_sized.clone();
        main_paned.connect_position_notify(move |_| {
            if initialized.get() && !applying.get() {
                user_sized.set(true);
            }
        });
    }
    {
        let initialized = responsive_layout_initialized.clone();
        let applying = applying_responsive_layout.clone();
        let user_sized = tools_user_sized.clone();
        workspace_and_tools.connect_position_notify(move |_| {
            if initialized.get() && !applying.get() {
                user_sized.set(true);
            }
        });
    }
    let main_paned_for_bottom_layout = main_paned.clone();
    let workspace_and_tools_for_bottom_layout = workspace_and_tools.clone();
    let expand_right_for_responsive = expand_right.clone();
    let tools_collapsed_for_responsive = context.tools_collapsed.clone();
    let tools_rdp_hidden_for_responsive = context.tools_auto_hidden_for_rdp.clone();
    let tools_automatically_collapsed_for_responsive = tools_automatically_collapsed.clone();
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        let workbench_width = overlay_for_bottom_layout.width();
        if workbench_width > 0 && workbench_width != last_workbench_width.get() {
            applying_responsive_layout.set(true);
            let (responsive_sidebar, responsive_tools) =
                responsive_workstation_panel_widths(workbench_width);
            if !sidebar_user_sized.get() {
                main_paned_for_bottom_layout.set_position(responsive_sidebar);
            }
            if !tools_user_sized.get() {
                let estimated_inner_width =
                    (workbench_width - main_paned_for_bottom_layout.position() - 6).max(0);
                workspace_and_tools_for_bottom_layout
                    .set_position((estimated_inner_width - responsive_tools).max(560));
            }
            applying_responsive_layout.set(false);
            responsive_layout_initialized.set(true);
            last_workbench_width.set(workbench_width);

            if workbench_width < 1180
                && tools_for_bottom_layout.is_visible()
                && !tools_collapsed_for_responsive.get()
                && !tools_rdp_hidden_for_responsive.get()
            {
                tools_for_bottom_layout.set_visible(false);
                expand_right_for_responsive.set_visible(true);
                tools_automatically_collapsed_for_responsive.set(true);
            } else if workbench_width >= 1180
                && tools_automatically_collapsed_for_responsive.get()
                && !tools_collapsed_for_responsive.get()
                && !tools_rdp_hidden_for_responsive.get()
            {
                tools_for_bottom_layout.set_visible(true);
                expand_right_for_responsive.set_visible(false);
                tools_automatically_collapsed_for_responsive.set(false);
            }
        }
        if sidebar_for_bottom_layout.is_visible() && sidebar_for_bottom_layout.width() > 0 {
            last_sidebar_width.set(sidebar_for_bottom_layout.width());
        }
        if tools_for_bottom_layout.is_visible() && tools_for_bottom_layout.width() > 0 {
            last_tools_width.set(tools_for_bottom_layout.width());
        }
        let left = last_sidebar_width.get();
        let right = if tools_for_bottom_layout.is_visible() {
            last_tools_width.get()
        } else {
            0
        };
        let input_width = (overlay_for_bottom_layout.width() - left - right).max(320);
        input_for_bottom_layout.set_margin_start(left);
        input_for_bottom_layout.set_size_request(input_width, -1);
        let input_height = if input_for_bottom_layout.is_visible() {
            input_for_bottom_layout.height().max(46)
        } else {
            0
        };
        footer_for_bottom_layout.set_size_request(left, 46);
        sidebar_for_bottom_layout.set_margin_bottom(46);
        workspace_for_bottom_layout.set_margin_bottom(input_height);
        gtk::glib::ControlFlow::Continue
    });

    let sidebar_root = sidebar.root.clone();
    let expand_left_for_collapse = expand_left.clone();
    sidebar.collapse.connect_clicked(move |_| {
        sidebar_root.set_visible(false);
        expand_left_for_collapse.set_visible(true);
    });
    let sidebar_root = sidebar.root.clone();
    let tools_root_for_left_expand = tools.root.clone();
    let expand_right_for_left_expand = expand_right.clone();
    let workbench_for_left_expand = workbench_overlay.clone();
    let tools_auto_for_left_expand = tools_automatically_collapsed.clone();
    expand_left.connect_clicked(move |button| {
        if workbench_for_left_expand.width() < 1180 && tools_root_for_left_expand.is_visible() {
            tools_root_for_left_expand.set_visible(false);
            expand_right_for_left_expand.set_visible(true);
            tools_auto_for_left_expand.set(true);
        }
        sidebar_root.set_visible(true);
        button.set_visible(false);
    });
    let tools_root = tools.root.clone();
    let tools_collapsed = context.tools_collapsed.clone();
    let expand_right_for_collapse = expand_right.clone();
    tools.collapse.connect_clicked(move |_| {
        tools_collapsed.set(true);
        tools_root.set_visible(false);
        expand_right_for_collapse.set_visible(true);
    });
    let tools_root = tools.root.clone();
    let tools_collapsed = context.tools_collapsed.clone();
    let sidebar_root_for_right_expand = sidebar.root.clone();
    let expand_left_for_right_expand = expand_left.clone();
    let workbench_for_right_expand = workbench_overlay.clone();
    let tools_auto_for_right_expand = tools_automatically_collapsed.clone();
    expand_right.connect_clicked(move |button| {
        if workbench_for_right_expand.width() < 1180 && sidebar_root_for_right_expand.is_visible() {
            sidebar_root_for_right_expand.set_visible(false);
            expand_left_for_right_expand.set_visible(true);
        }
        tools_collapsed.set(false);
        tools_auto_for_right_expand.set(false);
        tools_root.set_visible(true);
        button.set_visible(false);
    });

    install_workstation_shortcuts(
        &context,
        &sidebar.root,
        &expand_left,
        &tools.root,
        &expand_right,
    );
    install_module_fullscreen_controls(&context);

    let context_for_selection = context.clone();
    let ids_for_selection = asset_ids.clone();
    asset_list.connect_row_selected(move |_, row| {
        let Some(row) = row else {
            return;
        };
        let Some(id) = ids_for_selection
            .borrow()
            .get(row.index() as usize)
            .copied()
            .flatten()
        else {
            return;
        };
        select_asset(&context_for_selection, id);
    });

    let context_for_activation = context.clone();
    let ids_for_activation = asset_ids.clone();
    asset_list.connect_row_activated(move |_, row| {
        let Some(id) = ids_for_activation
            .borrow()
            .get(row.index() as usize)
            .copied()
            .flatten()
        else {
            return;
        };
        begin_connect(context_for_activation.clone(), id);
    });

    let context_for_connect = context.clone();
    workspace.connect.connect_clicked(move |_| {
        let selected = context_for_connect.session.borrow().selected_asset_id;
        if let Some(asset_id) = selected {
            begin_connect(context_for_connect.clone(), asset_id);
        }
    });
    let context_for_edit = context.clone();
    workspace.edit.connect_clicked(move |_| {
        let selected = context_for_edit.session.borrow().selected_asset_id;
        if let Some(asset_id) = selected {
            present_edit_asset_window(
                &context_for_edit.window,
                context_for_edit.catalog.clone(),
                context_for_edit.vault.clone(),
                asset_id,
                context_for_edit.refresh_assets.clone(),
            );
        }
    });

    let context_for_disconnect = context.clone();
    workspace
        .disconnect
        .connect_clicked(move |_| begin_disconnect(context_for_disconnect.clone()));
    let context_for_monitor_detail = context.clone();
    workspace.monitor_detail.connect_clicked(move |_| {
        present_monitor_detail_window(context_for_monitor_detail.clone())
    });

    let context_for_sftp_refresh = context.clone();
    tools.sftp_refresh.connect_clicked(move |_| {
        let path = context_for_sftp_refresh.tools.sftp_path.text().to_string();
        begin_sftp_list(context_for_sftp_refresh.clone(), path);
    });
    let context_for_sftp_path = context.clone();
    tools.sftp_path.connect_activate(move |entry| {
        begin_sftp_list(context_for_sftp_path.clone(), entry.text().to_string());
    });
    let context_for_sftp_up = context.clone();
    tools.sftp_up.connect_clicked(move |_| {
        let path = parent_remote_path(context_for_sftp_up.tools.sftp_path.text().as_str());
        begin_sftp_list(context_for_sftp_up.clone(), path);
    });
    let context_for_sftp_row = context.clone();
    tools.sftp_list.connect_row_activated(move |_, row| {
        activate_sftp_row(context_for_sftp_row.clone(), row.index());
    });
    let tools_for_sftp_selection = tools.clone();
    tools.sftp_list.connect_row_selected(move |_, row| {
        let selected = row.is_some();
        for button in [
            &tools_for_sftp_selection.sftp_download,
            &tools_for_sftp_selection.sftp_rename,
            &tools_for_sftp_selection.sftp_chmod,
            &tools_for_sftp_selection.sftp_delete,
        ] {
            button.set_sensitive(selected);
        }
    });
    let context_for_sftp_upload = context.clone();
    tools
        .sftp_upload
        .connect_clicked(move |_| begin_sftp_upload(context_for_sftp_upload.clone()));
    let context_for_sftp_mkdir = context.clone();
    tools
        .sftp_new_directory
        .connect_clicked(move |_| prompt_sftp_create(context_for_sftp_mkdir.clone(), true));
    let context_for_sftp_file = context.clone();
    tools
        .sftp_new_file
        .connect_clicked(move |_| prompt_sftp_create(context_for_sftp_file.clone(), false));
    let context_for_sftp_download = context.clone();
    tools
        .sftp_download
        .connect_clicked(move |_| begin_sftp_download(context_for_sftp_download.clone()));
    let context_for_sftp_rename = context.clone();
    tools
        .sftp_rename
        .connect_clicked(move |_| prompt_sftp_rename(context_for_sftp_rename.clone()));
    let context_for_sftp_chmod = context.clone();
    tools
        .sftp_chmod
        .connect_clicked(move |_| prompt_sftp_chmod(context_for_sftp_chmod.clone()));
    let context_for_sftp_delete = context.clone();
    tools
        .sftp_delete
        .connect_clicked(move |_| confirm_sftp_delete(context_for_sftp_delete.clone()));

    let context_for_docker_refresh = context.clone();
    tools
        .docker_refresh
        .connect_clicked(move |_| begin_docker_refresh(context_for_docker_refresh.clone()));
    let context_for_docker_logs = context.clone();
    tools
        .docker_logs
        .connect_clicked(move |_| begin_docker_logs(context_for_docker_logs.clone()));
    let context_for_docker_start = context.clone();
    tools
        .docker_start
        .connect_clicked(move |_| confirm_docker_action(context_for_docker_start.clone(), "start"));
    let context_for_docker_restart = context.clone();
    tools.docker_restart.connect_clicked(move |_| {
        confirm_docker_action(context_for_docker_restart.clone(), "restart")
    });
    let context_for_docker_stop = context.clone();
    tools
        .docker_stop
        .connect_clicked(move |_| confirm_docker_action(context_for_docker_stop.clone(), "stop"));

    refresh_snippet_list(&context);
    let snippet_buttons = [
        tools.snippet_edit.clone(),
        tools.snippet_delete.clone(),
        tools.snippet_insert.clone(),
        tools.snippet_run.clone(),
    ];
    tools.snippet_list.connect_row_selected(move |_, row| {
        for button in &snippet_buttons {
            button.set_sensitive(row.is_some());
        }
    });
    let snippet_search_context = context.clone();
    tools
        .snippet_search
        .connect_search_changed(move |_| refresh_snippet_list(&snippet_search_context));
    let snippet_add_context = context.clone();
    tools
        .snippet_add
        .connect_clicked(move |_| present_snippet_editor(snippet_add_context.clone(), None, None));
    let snippet_edit_context = context.clone();
    tools.snippet_edit.connect_clicked(move |_| {
        if let Some(snippet) = selected_snippet(&snippet_edit_context) {
            present_snippet_editor(snippet_edit_context.clone(), Some(snippet.id), None);
        }
    });
    let snippet_delete_context = context.clone();
    tools
        .snippet_delete
        .connect_clicked(move |_| confirm_delete_snippet(snippet_delete_context.clone()));
    let snippet_history_context = context.clone();
    tools
        .snippet_history
        .connect_clicked(move |_| present_snippet_history(snippet_history_context.clone()));
    let snippet_insert_context = context.clone();
    tools.snippet_insert.connect_clicked(move |_| {
        if let Some(snippet) = selected_snippet(&snippet_insert_context) {
            snippet_insert_context
                .workspace
                .input
                .set_text(&snippet.command);
            snippet_insert_context.workspace.input.grab_focus();
        }
    });
    let snippet_run_context = context.clone();
    tools.snippet_run.connect_clicked(move |_| {
        if let Some(snippet) = selected_snippet(&snippet_run_context) {
            let payload = format!("{}\r", snippet.command);
            if let Err(error) = write_active_terminal(&snippet_run_context, payload.as_bytes()) {
                snippet_run_context
                    .status
                    .set_label(&format!("片段发送失败：{error}"));
            } else {
                remember_active_command(&snippet_run_context, &snippet.command);
            }
        }
    });
    let snippet_activate_context = context.clone();
    tools.snippet_list.connect_row_activated(move |_, _| {
        if let Some(snippet) = selected_snippet(&snippet_activate_context) {
            let payload = format!("{}\r", snippet.command);
            if let Err(error) = write_active_terminal(&snippet_activate_context, payload.as_bytes())
            {
                snippet_activate_context
                    .status
                    .set_label(&format!("片段发送失败：{error}"));
            } else {
                remember_active_command(&snippet_activate_context, &snippet.command);
            }
        }
    });

    let send_action: Rc<dyn Fn()> = {
        let context = context.clone();
        Rc::new(move || send_terminal_input(&context))
    };
    let send_from_entry = send_action.clone();
    workspace.input.connect_activate(move |_| send_from_entry());
    workspace.send.connect_clicked(move |_| send_action());
    install_terminal_input(&context);

    let session_for_close = session.clone();
    let sync_session_for_close = context.sync_session.clone();
    let background_pending_for_close = context.background_pending.clone();
    let rdp_capture_for_close = context.clone();
    window.connect_close_request(move |_| {
        let now = Instant::now();
        if close_request_is_suppressed(rdp_capture_for_close.suppress_close_until.get(), now) {
            rdp_capture_for_close
                .status
                .set_label("已拦截退出全屏后的重复指针事件，客户端保持运行。");
            return gtk::glib::Propagation::Stop;
        }
        rdp_capture_for_close.suppress_close_until.set(None);
        set_rdp_system_shortcut_capture(&rdp_capture_for_close, false);
        sync_session_for_close.lock();
        background_pending_for_close.borrow_mut().take();
        let sessions = std::mem::take(&mut session_for_close.borrow_mut().sessions);
        let mut ssh_handles = Vec::new();
        for mut runtime in sessions.into_values() {
            if let Some(telnet) = runtime.telnet.take() {
                telnet.close();
            }
            if let Some(rdp) = runtime.rdp.take() {
                rdp.close();
            }
            ssh_handles.push((
                runtime.take_terminal_channels(),
                runtime.sftp_session_id.take(),
                runtime.base_session_id.take(),
            ));
        }
        if ssh_handles.iter().any(|(terminals, sftp, base)| {
            !terminals.is_empty() || sftp.is_some() || base.is_some()
        }) {
            std::thread::spawn(move || {
                let core = CheckedCoreClient::new();
                for (terminal_ids, sftp_id, base_id) in ssh_handles {
                    for id in terminal_ids {
                        let _ = core.close_terminal(id);
                    }
                    if let Some(id) = sftp_id {
                        let _ = core.close_sftp(id);
                    }
                    if let Some(id) = base_id {
                        let _ = core.disconnect(id);
                    }
                }
            });
        }
        gtk::glib::Propagation::Proceed
    });

    let refresh_for_search = refresh.clone();
    search.connect_search_changed(move |_| {
        refresh_for_search();
    });

    refresh();
    install_monitor_timer(context.clone());
    let window_overlay = gtk::Overlay::new();
    window_overlay.set_child(Some(&root));
    install_window_resize_handles(&window, &window_overlay);
    window.set_content(Some(&window_overlay));
    window.present();
    install_background_sync_scheduler(context);
}

fn build_header(
    window: &adw::ApplicationWindow,
    catalog: Rc<RefCell<Catalog>>,
    vault: CredentialVault,
    refresh: Rc<dyn Fn()>,
    context: UiContext,
    search: &gtk::SearchEntry,
) -> adw::HeaderBar {
    let header = adw::HeaderBar::new();
    header.add_css_class("app-header");
    // Match the current Apple and Windows workbench chrome: the application
    // identity belongs to the native window, not to a branded home-page block.
    // Keep the compositor-provided title buttons while leaving the centre lane
    // available for future session context.
    header.set_show_title(false);

    let start_actions = gtk::Box::new(Orientation::Horizontal, 4);
    start_actions.add_css_class("header-actions");
    let end_actions = gtk::Box::new(Orientation::Horizontal, 4);
    end_actions.add_css_class("header-actions");

    let brand = gtk::Image::from_icon_name("com.orbitterm.Client");
    brand.set_pixel_size(20);
    brand.set_size_request(20, 20);
    brand.add_css_class("header-brand-icon");
    let brand_frame = gtk::Box::new(Orientation::Horizontal, 0);
    brand_frame.add_css_class("header-brand-frame");
    brand_frame.set_size_request(24, 24);
    brand_frame.set_halign(Align::Center);
    brand_frame.set_valign(Align::Center);
    brand_frame.set_overflow(gtk::Overflow::Hidden);
    brand_frame.append(&brand);
    start_actions.append(&brand_frame);

    let account = command_button(
        "登录 / 解锁",
        "avatar-default-symbolic",
        "登录 OrbitTerm 账户或解锁端到端加密同步",
    );
    let account_context = context.clone();
    account.connect_clicked(move |_| present_sync_window(account_context.clone()));
    end_actions.append(&account);

    let add = command_button("添加服务器", "list-add-symbolic", "添加服务器资产");
    add.add_css_class("suggested-action");
    let parent = window.clone();
    add.connect_clicked(move |_| {
        present_add_asset_window(&parent, catalog.clone(), vault.clone(), refresh.clone())
    });
    start_actions.append(&add);

    let edit = command_button(
        "编辑凭据",
        "document-edit-symbolic",
        "编辑当前选中的服务器资产",
    );
    let edit_context = context.clone();
    edit.connect_clicked(move |_| {
        let Some(asset_id) = edit_context.session.borrow().selected_asset_id else {
            edit_context.status.set_label("请先从左侧选择服务器资产");
            return;
        };
        present_edit_asset_window(
            &edit_context.window,
            edit_context.catalog.clone(),
            edit_context.vault.clone(),
            asset_id,
            edit_context.refresh_assets.clone(),
        );
    });
    start_actions.append(&edit);

    let assets = command_button("资产管理", "network-server-symbolic", "管理服务器资产");
    let assets_context = context.clone();
    let search_for_assets = search.clone();
    assets.connect_clicked(move |_| {
        present_asset_manager_window(assets_context.clone(), search_for_assets.clone());
    });
    start_actions.append(&assets);

    let keys = command_button("密钥管理", "dialog-password-symbolic", "管理 SSH 密钥资产");
    let keys_context = context.clone();
    keys.connect_clicked(move |_| present_key_management_window(keys_context.clone()));
    start_actions.append(&keys);

    let tunnels = command_button(
        "端口映射",
        "network-transmit-receive-symbolic",
        "管理本地端口映射",
    );
    let tunnel_context = context.clone();
    tunnels.connect_clicked(move |_| present_port_forwarding_window(tunnel_context.clone()));
    start_actions.append(&tunnels);

    let batch = command_button(
        "批量命令",
        "utilities-terminal-symbolic",
        "向已连接 SSH 会话执行批量命令",
    );
    let batch_context = context.clone();
    batch.connect_clicked(move |_| present_batch_command_window(batch_context.clone()));
    start_actions.append(&batch);

    let settings = command_button("设置", "preferences-system-symbolic", "终端与应用设置");
    let settings_context = context.clone();
    settings.connect_clicked(move |_| present_settings_window(settings_context.clone()));
    start_actions.append(&settings);

    header.pack_start(&start_actions);
    header.pack_end(&end_actions);
    header
}

fn window_resize_handles_visible(maximized: bool, fullscreen: bool) -> bool {
    !maximized && !fullscreen
}

fn install_window_resize_handles(window: &adw::ApplicationWindow, overlay: &gtk::Overlay) {
    use gtk::gdk::prelude::ToplevelExt;
    use gtk::gdk::{SurfaceEdge, Toplevel};

    let add_handle = |edge: SurfaceEdge,
                      cursor: &'static str,
                      halign: Align,
                      valign: Align,
                      width: i32,
                      height: i32| {
        let handle = gtk::Box::new(Orientation::Horizontal, 0);
        handle.add_css_class("window-resize-handle");
        handle.set_halign(halign);
        handle.set_valign(valign);
        handle.set_size_request(width, height);
        handle.set_cursor_from_name(Some(cursor));
        handle.set_tooltip_text(Some("拖动以调整窗口大小"));
        // Ignoring the gesture is not click-through: remove edge hit targets
        // in fullscreen/maximized modes so remote window controls receive input.
        handle.set_visible(window_resize_handles_visible(
            window.is_maximized(),
            window.is_fullscreen(),
        ));
        let weak_handle = handle.downgrade();
        window.connect_maximized_notify(move |window| {
            if let Some(handle) = weak_handle.upgrade() {
                handle.set_visible(window_resize_handles_visible(
                    window.is_maximized(),
                    window.is_fullscreen(),
                ));
            }
        });
        let weak_handle = handle.downgrade();
        window.connect_fullscreened_notify(move |window| {
            if let Some(handle) = weak_handle.upgrade() {
                handle.set_visible(window_resize_handles_visible(
                    window.is_maximized(),
                    window.is_fullscreen(),
                ));
            }
        });

        let gesture = gtk::GestureClick::new();
        gesture.set_button(1);
        let resize_window = window.clone();
        gesture.connect_pressed(move |gesture, _, fallback_x, fallback_y| {
            if resize_window.is_maximized() || resize_window.is_fullscreen() {
                return;
            }
            let Some(event) = gesture.current_event() else {
                return;
            };
            let Some(surface) = event.surface() else {
                return;
            };
            let Ok(toplevel) = surface.downcast::<Toplevel>() else {
                return;
            };
            let (x, y) = event.position().unwrap_or((fallback_x, fallback_y));
            let device = event.device();
            toplevel.begin_resize(edge, device.as_ref(), 1, x, y, event.time());
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        handle.add_controller(gesture);
        overlay.add_overlay(&handle);
    };

    // Twelve-pixel handles are easy to discover on high-DPI displays while
    // remaining visually transparent. Corners are added after edges so their
    // diagonal cursor and resize direction win in the overlapping area.
    add_handle(
        SurfaceEdge::North,
        "n-resize",
        Align::Fill,
        Align::Start,
        -1,
        7,
    );
    add_handle(
        SurfaceEdge::South,
        "s-resize",
        Align::Fill,
        Align::End,
        -1,
        7,
    );
    add_handle(
        SurfaceEdge::West,
        "w-resize",
        Align::Start,
        Align::Fill,
        7,
        -1,
    );
    add_handle(
        SurfaceEdge::East,
        "e-resize",
        Align::End,
        Align::Fill,
        7,
        -1,
    );
    add_handle(
        SurfaceEdge::NorthWest,
        "nw-resize",
        Align::Start,
        Align::Start,
        14,
        14,
    );
    add_handle(
        SurfaceEdge::NorthEast,
        "ne-resize",
        Align::End,
        Align::Start,
        14,
        14,
    );
    add_handle(
        SurfaceEdge::SouthWest,
        "sw-resize",
        Align::Start,
        Align::End,
        14,
        14,
    );
    add_handle(
        SurfaceEdge::SouthEast,
        "se-resize",
        Align::End,
        Align::End,
        14,
        14,
    );
}

fn command_button(label: &str, icon_name: &str, tooltip: &str) -> gtk::Button {
    let content = adw::ButtonContent::builder()
        .label(label)
        .icon_name(icon_name)
        .build();
    let button = gtk::Button::builder()
        .child(&content)
        .tooltip_text(tooltip)
        .build();
    button.add_css_class("top-command");
    button
}

fn build_sidebar(
    window: &adw::ApplicationWindow,
    catalog: Rc<RefCell<Catalog>>,
    widgets: (&gtk::SearchEntry, &gtk::ListBox, &gtk::Stack, &gtk::Label),
    vault: CredentialVault,
    refresh: Rc<dyn Fn()>,
    sync_status: &gtk::Label,
    sync_context: UiContext,
) -> SidebarWidgets {
    let (search, list, stack, asset_count) = widgets;
    let panel_stack = gtk::Stack::new();
    panel_stack.set_hhomogeneous(false);
    panel_stack.set_transition_type(gtk::StackTransitionType::SlideLeftRight);
    let sidebar = gtk::Box::new(Orientation::Vertical, 0);
    sidebar.add_css_class("asset-sidebar");
    let sidebar_root = gtk::Box::new(Orientation::Vertical, 0);
    sidebar_root.add_css_class("asset-sidebar-root");
    sidebar_root.set_size_request(240, -1);

    let heading = gtk::Box::new(Orientation::Horizontal, 8);
    heading.add_css_class("panel-heading");
    let label = gtk::Label::new(Some("服务器"));
    label.add_css_class("heading");
    label.set_xalign(0.0);
    label.set_hexpand(true);
    let edit = gtk::Button::builder()
        .icon_name("document-edit-symbolic")
        .tooltip_text("编辑所选服务器")
        .sensitive(false)
        .build();
    edit.add_css_class("flat");
    let edit_context = sync_context.clone();
    edit.connect_clicked(move |_| {
        let Some(asset_id) = edit_context.session.borrow().selected_asset_id else {
            edit_context.status.set_label("请先选择服务器资产");
            return;
        };
        present_edit_asset_window(
            &edit_context.window,
            edit_context.catalog.clone(),
            edit_context.vault.clone(),
            asset_id,
            edit_context.refresh_assets.clone(),
        );
    });
    let add = gtk::Button::builder()
        .icon_name("list-add-symbolic")
        .tooltip_text("添加服务器")
        .build();
    add.add_css_class("flat");
    let collapse = gtk::Button::builder()
        .icon_name("go-previous-symbolic")
        .tooltip_text("收起服务器资产栏")
        .build();
    collapse.add_css_class("flat");
    let parent = window.clone();
    add.connect_clicked(move |_| {
        present_add_asset_window(&parent, catalog.clone(), vault.clone(), refresh.clone())
    });
    heading.append(&label);
    heading.append(asset_count);
    heading.append(&edit);
    heading.append(&add);
    heading.append(&collapse);
    sidebar.append(&heading);
    sidebar.append(search);

    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(list)
        .build();
    stack.add_named(&scroller, Some("assets"));
    let empty = adw::StatusPage::builder()
        .icon_name("network-server-symbolic")
        .title("还没有服务器")
        .description("添加服务器资产后，可从这里打开经 Host Key 验证的会话。")
        .build();
    empty.add_css_class("compact-status");
    stack.add_named(&empty, Some("empty"));
    sidebar.append(stack);

    let footer = gtk::Box::new(Orientation::Horizontal, 8);
    footer.add_css_class("sidebar-footer");
    // Explicitly opt out of horizontal expansion. Child labels may request
    // expansion internally, but the persistent sync module must retain the
    // last asset-rail width when either upper pane is collapsed.
    footer.set_hexpand(false);
    let dot = gtk::Label::new(Some("●"));
    dot.add_css_class("status-idle");
    footer.append(&dot);
    let sync_copy = gtk::Box::new(Orientation::Vertical, 0);
    let sync_title = gtk::Label::new(Some("同步状态"));
    sync_title.add_css_class("sidebar-footer-title");
    sync_title.set_xalign(0.0);
    sync_copy.append(&sync_title);
    sync_copy.append(sync_status);
    sync_copy.set_hexpand(true);
    footer.append(&sync_copy);
    sync_status.set_hexpand(true);
    let sync = gtk::Button::builder()
        .icon_name("view-refresh-symbolic")
        .tooltip_text("打开账户与同步")
        .build();
    sync.add_css_class("flat");
    let sync_context_for_footer = sync_context.clone();
    sync.connect_clicked(move |_| present_sync_window(sync_context_for_footer.clone()));
    footer.append(&sync);
    panel_stack.add_named(&sidebar, Some("expanded"));
    panel_stack.set_visible_child_name("expanded");
    panel_stack.set_vexpand(true);
    sidebar_root.append(&panel_stack);
    SidebarWidgets {
        root: sidebar_root,
        collapse,
        footer,
        edit,
    }
}

fn build_workspace() -> WorkspaceWidgets {
    let workspace = gtk::Box::new(Orientation::Vertical, 0);
    workspace.add_css_class("workspace");
    workspace.set_hexpand(true);

    let tabs = gtk::Box::new(Orientation::Horizontal, 8);
    tabs.add_css_class("workspace-tabs");
    let tab_status = gtk::Label::new(Some("0 会话"));
    tab_status.add_css_class("tab-status");
    let tab_hint = gtk::Label::new(Some("连接资产后将在这里显示会话标签"));
    tab_hint.add_css_class("tab-hint");
    tab_hint.set_hexpand(true);
    tab_hint.set_xalign(0.0);
    tabs.append(&tab_hint);
    tabs.append(&tab_status);
    let split_menu = gtk::MenuButton::builder()
        .icon_name("view-grid-symbolic")
        .tooltip_text("终端分屏 · Ctrl+Shift+D 添加 · Alt+1…4 切换")
        .sensitive(false)
        .build();
    split_menu.add_css_class("flat");
    let split_popover = gtk::Popover::new();
    split_popover.add_css_class("terminal-split-popover");
    let split_actions = gtk::Box::new(Orientation::Vertical, 4);
    split_actions.set_margin_start(8);
    split_actions.set_margin_end(8);
    split_actions.set_margin_top(8);
    split_actions.set_margin_bottom(8);
    let split_add = gtk::Button::with_label("添加分屏");
    split_add.set_tooltip_text(Some("为当前 SSH 资产打开独立终端通道（最多四个）"));
    let split_remove = gtk::Button::with_label("关闭当前分屏");
    let split_reset = gtk::Button::with_label("恢复单屏");
    split_actions.append(&split_add);
    split_actions.append(&split_remove);
    split_actions.append(&split_reset);
    split_popover.set_child(Some(&split_actions));
    split_menu.set_popover(Some(&split_popover));
    tabs.append(&split_menu);
    workspace.append(&tabs);

    let header = gtk::Box::new(Orientation::Horizontal, 12);
    header.add_css_class("workspace-heading");
    let copy = gtk::Box::new(Orientation::Vertical, 2);
    copy.set_hexpand(true);
    let title = gtk::Label::new(Some("选择服务器以开始"));
    title.add_css_class("heading");
    title.set_xalign(0.0);
    let subtitle = gtk::Label::new(Some(
        "终端、SFTP、Monitor 与 Docker 共用同一个已验证基础会话",
    ));
    subtitle.add_css_class("caption");
    subtitle.set_xalign(0.0);
    subtitle.set_ellipsize(gtk::pango::EllipsizeMode::End);
    copy.append(&title);
    copy.append(&subtitle);
    let security = gtk::Label::new(Some("Host Key 未验证"));
    security.add_css_class("security-chip");
    let edit = command_button("编辑", "document-edit-symbolic", "编辑所选服务器");
    edit.set_sensitive(false);
    let connect = command_button("连接", "network-wired-symbolic", "建立受检 SSH 会话");
    connect.set_sensitive(false);
    connect.add_css_class("suggested-action");
    let disconnect = command_button("断开", "network-offline-symbolic", "安全关闭当前会话");
    disconnect.set_sensitive(false);
    header.append(&copy);
    header.append(&security);
    header.append(&edit);
    header.append(&disconnect);
    header.append(&connect);
    header.set_visible(false);
    workspace.append(&header);

    let monitor = gtk::Box::new(Orientation::Horizontal, 8);
    monitor.add_css_class("monitor-strip");
    monitor.set_size_request(-1, 36);
    monitor.set_vexpand(false);
    let endpoint_card = gtk::Box::new(Orientation::Vertical, 0);
    endpoint_card.add_css_class("monitor-card");
    endpoint_card.add_css_class("endpoint-monitor-card");
    endpoint_card.set_hexpand(true);
    endpoint_card.set_size_request(0, 26);
    let endpoint_header = gtk::Box::new(Orientation::Horizontal, 4);
    let endpoint_caption = gtk::Label::new(Some("当前资产 IP"));
    endpoint_caption.add_css_class("caption");
    endpoint_caption.set_xalign(0.0);
    endpoint_caption.set_hexpand(true);
    let monitor_endpoint = gtk::Label::new(Some("尚未选择"));
    monitor_endpoint.add_css_class("metric");
    monitor_endpoint.add_css_class("endpoint-value");
    monitor_endpoint.set_xalign(1.0);
    monitor_endpoint.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    let monitor_copy_endpoint = gtk::Button::builder()
        .icon_name("edit-copy-symbolic")
        .tooltip_text("复制当前资产 IP")
        .sensitive(false)
        .build();
    monitor_copy_endpoint.add_css_class("flat");
    monitor_copy_endpoint.add_css_class("monitor-copy-button");
    let endpoint_for_copy = monitor_endpoint.clone();
    monitor_copy_endpoint.connect_clicked(move |_| {
        if let Some(display) = gtk::gdk::Display::default() {
            display
                .clipboard()
                .set_text(endpoint_for_copy.text().as_str());
        }
    });
    endpoint_header.append(&endpoint_caption);
    endpoint_header.append(&monitor_endpoint);
    endpoint_header.append(&monitor_copy_endpoint);
    endpoint_card.append(&endpoint_header);
    monitor.append(&endpoint_card);
    let monitor_history = Rc::new(RefCell::new(Vec::<MonitorSnapshot>::new()));
    let mut monitor_values = Vec::new();
    let mut monitor_graphs = Vec::new();
    for (index, label) in ["CPU", "内存", "磁盘", "下载", "上传", "延迟"]
        .into_iter()
        .enumerate()
    {
        let metric = gtk::Box::new(Orientation::Vertical, 0);
        metric.add_css_class("monitor-card");
        metric.set_hexpand(true);
        metric.set_size_request(0, 26);
        let metric_header = gtk::Box::new(Orientation::Horizontal, 4);
        let name = gtk::Label::new(Some(label));
        name.add_css_class("caption");
        name.set_xalign(0.0);
        name.set_hexpand(true);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        let value = gtk::Label::new(Some("—"));
        value.add_css_class("metric");
        value.set_xalign(1.0);
        value.set_ellipsize(gtk::pango::EllipsizeMode::End);
        metric_header.append(&name);
        metric_header.append(&value);
        let graph = gtk::DrawingArea::new();
        graph.set_content_width(0);
        graph.set_content_height(10);
        graph.set_hexpand(true);
        let history = monitor_history.clone();
        graph.set_draw_func(move |_, cairo, width, height| {
            let history = history.borrow();
            if history.len() < 2 {
                return;
            }
            let values = history.iter().map(|snapshot| match index {
                0 => snapshot.stats.cpu_usage_percent,
                1 => snapshot.stats.mem_used_percent,
                2 => snapshot.stats.disk_used_percent,
                3 => snapshot.stats.rx_rate_kbps,
                4 => snapshot.stats.tx_rate_kbps,
                _ => snapshot.stats.ping_latency_ms.unwrap_or(0.0),
            });
            let values = values.collect::<Vec<_>>();
            let maximum = values.iter().copied().fold(1.0_f64, f64::max);
            cairo.set_source_rgba(0.20, 0.50, 0.92, 0.9);
            cairo.set_line_width(1.5);
            for (point, value) in values.iter().enumerate() {
                let x = point as f64 * width as f64 / (values.len() - 1) as f64;
                let y = height as f64 - (value / maximum * (height as f64 - 3.0)) - 1.5;
                if point == 0 {
                    cairo.move_to(x, y);
                } else {
                    cairo.line_to(x, y);
                }
            }
            let _ = cairo.stroke();
        });
        metric.append(&metric_header);
        metric.append(&graph);
        monitor.append(&metric);
        monitor_values.push(value);
        monitor_graphs.push(graph);
    }
    let monitor_detail = command_button("详情", "view-list-symbolic", "查看系统信息与监控详情");
    monitor.append(&monitor_detail);
    let monitor_connection = gtk::Label::new(Some("未连接"));

    let content_stack = gtk::Stack::new();
    content_stack.set_hexpand(true);
    content_stack.set_vexpand(true);
    content_stack.set_transition_type(gtk::StackTransitionType::Crossfade);

    let empty = gtk::Box::new(Orientation::Vertical, 10);
    empty.add_css_class("workspace-empty");
    empty.set_valign(Align::Center);
    empty.set_halign(Align::Center);
    let empty_icon = gtk::Image::from_icon_name("utilities-terminal-symbolic");
    empty_icon.set_pixel_size(42);
    empty_icon.add_css_class("workspace-empty-icon");
    let empty_title = gtk::Label::new(Some("选择一台服务器开始工作"));
    empty_title.add_css_class("workspace-empty-title");
    let empty_description = gtk::Label::new(Some(
        "从左侧资产栏选择服务器，然后建立经 Host Key 验证的安全会话。",
    ));
    empty_description.add_css_class("workspace-empty-description");
    empty_description.set_wrap(true);
    empty_description.set_justify(gtk::Justification::Center);
    empty.append(&empty_icon);
    empty.append(&empty_title);
    empty.append(&empty_description);
    content_stack.add_named(&empty, Some("empty"));

    let terminal_page = gtk::Box::new(Orientation::Vertical, 0);
    let terminal_grid = gtk::Grid::new();
    terminal_grid.add_css_class("terminal-grid");
    terminal_grid.set_hexpand(true);
    terminal_grid.set_vexpand(true);
    terminal_grid.set_row_homogeneous(true);
    terminal_grid.set_column_homogeneous(true);
    terminal_grid.set_row_spacing(6);
    terminal_grid.set_column_spacing(6);
    terminal_grid.set_margin_start(12);
    terminal_grid.set_margin_end(12);
    terminal_grid.set_margin_top(12);
    terminal_grid.set_margin_bottom(12);
    let mut terminals = Vec::new();
    let mut terminal_frames = Vec::new();
    for pane in 0..MAX_TERMINAL_PANES {
        let terminal = vte::Terminal::new();
        terminal.add_css_class("terminal");
        terminal.set_hexpand(true);
        terminal.set_vexpand(true);
        terminal.set_scrollback_lines(20_000);
        terminal.set_focusable(true);
        let frame = gtk::Box::new(Orientation::Vertical, 0);
        frame.add_css_class("terminal-frame");
        frame.set_hexpand(true);
        frame.set_vexpand(true);
        frame.set_tooltip_text(Some(&format!("终端分屏 {}", pane + 1)));
        frame.append(&terminal);
        terminals.push(terminal);
        terminal_frames.push(frame);
    }
    terminal_grid.attach(&terminal_frames[0], 0, 0, 2, 2);
    let terminal_view = gtk::Overlay::new();
    terminal_view.set_child(Some(&terminal_grid));
    let terminal_fullscreen = gtk::Button::with_label("终端全屏");
    terminal_fullscreen.set_icon_name("view-fullscreen-symbolic");
    terminal_fullscreen.set_tooltip_text(Some("让当前终端模块占满屏幕"));
    terminal_fullscreen.add_css_class("module-fullscreen-button");
    terminal_fullscreen.set_halign(Align::End);
    terminal_fullscreen.set_valign(Align::Start);
    terminal_fullscreen.set_margin_top(18);
    terminal_fullscreen.set_margin_end(18);
    terminal_view.add_overlay(&terminal_fullscreen);
    terminal_page.append(&terminal_view);

    let input_row = gtk::Box::new(Orientation::Horizontal, 8);
    input_row.add_css_class("terminal-input-row");
    let prompt = gtk::Label::new(Some("$"));
    prompt.add_css_class("terminal-prompt");
    let input = gtk::Entry::builder()
        .placeholder_text("连接后可输入命令")
        .hexpand(true)
        .sensitive(false)
        .build();
    let send = gtk::Button::with_label("发送");
    send.set_sensitive(false);
    input_row.append(&prompt);
    input_row.append(&input);
    input_row.append(&send);
    content_stack.add_named(&terminal_page, Some("terminal"));

    let rdp_page = gtk::Box::new(Orientation::Vertical, 0);
    rdp_page.add_css_class("rdp-workspace");
    let rdp_picture = gtk::DrawingArea::new();
    rdp_picture.add_css_class("rdp-surface");
    rdp_picture.set_hexpand(true);
    rdp_picture.set_vexpand(true);
    rdp_picture.set_focusable(true);
    let rdp_canvas = Rc::new(RefCell::new(Option::<SharedRdpCanvas>::None));
    let canvas_for_draw = rdp_canvas.clone();
    rdp_picture.set_draw_func(move |_, cairo, viewport_width, viewport_height| {
        let visible_canvas = canvas_for_draw.borrow();
        let Some(canvas) = visible_canvas.as_ref() else {
            return;
        };
        let canvas = canvas.borrow();
        let Some(surface) = canvas.surface.as_ref() else {
            return;
        };
        let Some(geometry) = rdp_viewport_geometry(
            f64::from(viewport_width),
            f64::from(viewport_height),
            canvas.width,
            canvas.height,
        ) else {
            return;
        };
        let _ = cairo.save();
        cairo.translate(geometry.offset_x, geometry.offset_y);
        cairo.scale(geometry.scale, geometry.scale);
        if cairo.set_source_surface(surface, 0.0, 0.0).is_ok() {
            cairo.source().set_filter(gtk::cairo::Filter::Bilinear);
            let _ = cairo.paint();
        }
        let _ = cairo.restore();
    });
    let rdp_view = gtk::Overlay::new();
    rdp_view.set_child(Some(&rdp_picture));
    let rdp_state_overlay = gtk::Box::new(Orientation::Vertical, 6);
    rdp_state_overlay.add_css_class("rdp-state-overlay");
    rdp_state_overlay.set_halign(Align::Center);
    rdp_state_overlay.set_valign(Align::Center);
    let rdp_state_icon = gtk::Image::from_icon_name("network-offline-symbolic");
    rdp_state_icon.set_pixel_size(28);
    let rdp_state_title = gtk::Label::new(Some("正在准备远程桌面"));
    rdp_state_title.add_css_class("heading");
    let rdp_state_detail = gtk::Label::new(Some("连接状态将在这里显示"));
    rdp_state_detail.add_css_class("caption");
    rdp_state_detail.set_wrap(true);
    rdp_state_detail.set_justify(gtk::Justification::Center);
    rdp_state_overlay.append(&rdp_state_icon);
    rdp_state_overlay.append(&rdp_state_title);
    rdp_state_overlay.append(&rdp_state_detail);
    rdp_view.add_overlay(&rdp_state_overlay);
    let rdp_controls = gtk::Box::new(Orientation::Horizontal, 6);
    rdp_controls.add_css_class("rdp-control-bar");
    rdp_controls.set_halign(Align::End);
    rdp_controls.set_valign(Align::Start);
    rdp_controls.set_margin_top(10);
    rdp_controls.set_margin_end(10);
    let rdp_input_status = gtk::Label::new(Some("远端输入"));
    rdp_input_status.add_css_class("caption");
    rdp_input_status.add_css_class("rdp-input-status");
    let rdp_capture_shortcuts = gtk::ToggleButton::with_label("捕获快捷键");
    rdp_capture_shortcuts.set_icon_name("input-keyboard-symbolic");
    rdp_capture_shortcuts.set_focus_on_click(false);
    rdp_capture_shortcuts.set_tooltip_text(Some(
        "全屏时自动捕获 Alt+Tab、Super 等系统快捷键；窗口模式可手动开启。Ctrl+Alt+Shift+Esc 或 Super+Esc 释放，F11 退出全屏",
    ));
    let rdp_secure_attention = gtk::Button::with_label("Ctrl+Alt+Delete");
    rdp_secure_attention.set_icon_name("preferences-system-privacy-symbolic");
    rdp_secure_attention.set_tooltip_text(Some("向远端 Windows 发送安全注意序列"));
    let rdp_diagnostics = gtk::Button::with_label("自适应 · 等待画面");
    rdp_diagnostics.set_icon_name("network-transmit-receive-symbolic");
    rdp_diagnostics.set_tooltip_text(Some("查看 RDP 画面更新、恢复记录与安全协商信息"));
    let rdp_fullscreen = gtk::Button::with_label("RDP 全屏");
    rdp_fullscreen.set_icon_name("view-fullscreen-symbolic");
    rdp_fullscreen.set_tooltip_text(Some("让远程桌面模块占满屏幕"));
    rdp_fullscreen.add_css_class("module-fullscreen-button");
    rdp_controls.append(&rdp_input_status);
    rdp_controls.append(&rdp_capture_shortcuts);
    rdp_controls.append(&rdp_secure_attention);
    rdp_controls.append(&rdp_diagnostics);
    rdp_controls.append(&rdp_fullscreen);
    rdp_view.add_overlay(&rdp_controls);
    // Only this small top-centre handle intercepts input when the fullscreen
    // tools are collapsed. In particular, the remote top-right stays usable.
    let rdp_controls_toggle = gtk::ToggleButton::with_label("显示工具 ▾");
    rdp_controls_toggle.set_halign(Align::Center);
    rdp_controls_toggle.set_valign(Align::Start);
    rdp_controls_toggle.set_margin_top(4);
    rdp_controls_toggle.add_css_class("rdp-tools-toggle");
    rdp_controls_toggle.set_tooltip_text(Some("点击展开或收起远程桌面工具；F11 退出全屏"));
    rdp_controls_toggle.set_visible(false);
    rdp_view.add_overlay(&rdp_controls_toggle);
    rdp_page.append(&rdp_view);
    let rdp_security_bar = gtk::Label::new(Some(
        "自适应网络与仅内存缓存 · NLA 强制开启 · 证书异常必须确认 · 所有本地资源重定向均关闭",
    ));
    rdp_security_bar.add_css_class("rdp-security-bar");
    rdp_security_bar.set_xalign(0.0);
    rdp_page.append(&rdp_security_bar);
    content_stack.add_named(&rdp_page, Some("rdp"));
    content_stack.set_visible_child_name("empty");
    workspace.append(&content_stack);
    WorkspaceWidgets {
        root: workspace,
        monitor_band: monitor,
        tabs,
        input_row,
        heading: header,
        tab_hint,
        content_stack,
        empty_title,
        empty_description,
        tab_status,
        title,
        subtitle,
        security,
        edit,
        connect,
        disconnect,
        monitor_connection,
        monitor_cpu: monitor_values.remove(0),
        monitor_memory: monitor_values.remove(0),
        monitor_disk: monitor_values.remove(0),
        monitor_download: monitor_values.remove(0),
        monitor_upload: monitor_values.remove(0),
        monitor_latency: monitor_values.remove(0),
        monitor_detail,
        monitor_endpoint,
        monitor_copy_endpoint,
        monitor_history,
        monitor_graphs: Rc::new(monitor_graphs),
        terminal_grid,
        terminal_frames: Rc::new(terminal_frames),
        terminals: Rc::new(terminals),
        split_menu,
        split_add,
        split_remove,
        split_reset,
        terminal_fullscreen,
        rdp_picture,
        rdp_canvas,
        rdp_state_overlay,
        rdp_state_title,
        rdp_state_detail,
        rdp_controls,
        rdp_controls_toggle,
        rdp_capture_shortcuts,
        rdp_secure_attention,
        rdp_diagnostics,
        rdp_fullscreen,
        rdp_input_status,
        rdp_security_bar,
        input,
        send,
    }
}

fn build_tools(snippet_repository: SnippetRepository) -> ToolsWidgets {
    let panel_stack = gtk::Stack::new();
    panel_stack.set_hhomogeneous(false);
    panel_stack.set_transition_type(gtk::StackTransitionType::SlideLeftRight);
    let tools = gtk::Box::new(Orientation::Vertical, 0);
    tools.add_css_class("tool-panel");
    tools.set_size_request(328, -1);

    let heading = gtk::Box::new(Orientation::Horizontal, 8);
    heading.add_css_class("panel-heading");
    let heading_label = gtk::Label::new(Some("会话工具"));
    heading_label.add_css_class("heading");
    heading_label.set_xalign(0.0);
    heading_label.set_hexpand(true);
    let collapse = gtk::Button::builder()
        .icon_name("go-next-symbolic")
        .tooltip_text("收起会话工具")
        .build();
    collapse.add_css_class("flat");
    heading.append(&heading_label);
    heading.append(&collapse);
    tools.append(&heading);

    let content_stack = gtk::Stack::new();
    content_stack.set_vexpand(true);
    content_stack.set_transition_type(gtk::StackTransitionType::Crossfade);
    let disconnected = gtk::Box::new(Orientation::Vertical, 0);
    disconnected.set_vexpand(true);
    let disconnected_banner = gtk::Box::new(Orientation::Horizontal, 8);
    disconnected_banner.add_css_class("tool-empty-banner");
    let disconnected_icon = gtk::Image::from_icon_name("network-offline-symbolic");
    disconnected_icon.set_pixel_size(16);
    let disconnected_copy = gtk::Label::new(Some("连接会话后自动显示 SFTP、Docker 与命令片段"));
    disconnected_copy.set_xalign(0.0);
    disconnected_copy.set_wrap(true);
    disconnected_copy.set_hexpand(true);
    disconnected_banner.append(&disconnected_icon);
    disconnected_banner.append(&disconnected_copy);
    disconnected.append(&disconnected_banner);
    content_stack.add_named(&disconnected, Some("empty"));

    let unavailable = gtk::Box::new(Orientation::Vertical, 10);
    unavailable.add_css_class("workspace-empty");
    unavailable.set_valign(Align::Center);
    unavailable.set_halign(Align::Center);
    let unavailable_icon = gtk::Image::from_icon_name("channel-insecure-symbolic");
    unavailable_icon.set_pixel_size(42);
    let unavailable_title = gtk::Label::new(Some("当前协议不提供 SSH 工具"));
    unavailable_title.add_css_class("workspace-empty-title");
    let unavailable_detail = gtk::Label::new(Some(
        "SFTP、Docker、Monitor 与命令片段不会创建旁路 SSH 连接。",
    ));
    unavailable_detail.add_css_class("workspace-empty-description");
    unavailable_detail.set_wrap(true);
    unavailable_detail.set_justify(gtk::Justification::Center);
    unavailable.append(&unavailable_icon);
    unavailable.append(&unavailable_title);
    unavailable.append(&unavailable_detail);
    content_stack.add_named(&unavailable, Some("unsupported"));

    let active_tools = gtk::Box::new(Orientation::Vertical, 0);

    let stack = adw::ViewStack::new();
    stack.set_vexpand(true);

    let sftp_page = gtk::Box::new(Orientation::Vertical, 8);
    sftp_page.add_css_class("tool-page");
    let sftp_toolbar = gtk::Box::new(Orientation::Horizontal, 6);
    let sftp_up = gtk::Button::builder()
        .icon_name("go-up-symbolic")
        .tooltip_text("上级目录")
        .sensitive(false)
        .build();
    let sftp_path = gtk::Entry::builder()
        .text("/")
        .hexpand(true)
        .sensitive(false)
        .build();
    let sftp_refresh = gtk::Button::builder()
        .icon_name("view-refresh-symbolic")
        .tooltip_text("刷新目录")
        .sensitive(false)
        .build();
    let sftp_upload = gtk::Button::builder()
        .icon_name("document-send-symbolic")
        .tooltip_text("上传文件")
        .sensitive(false)
        .build();
    let sftp_new_directory = gtk::Button::builder()
        .icon_name("folder-new-symbolic")
        .tooltip_text("新建目录")
        .sensitive(false)
        .build();
    let sftp_new_file = gtk::Button::builder()
        .icon_name("document-new-symbolic")
        .tooltip_text("新建文件")
        .sensitive(false)
        .build();
    sftp_toolbar.append(&sftp_up);
    sftp_toolbar.append(&sftp_path);
    sftp_toolbar.append(&sftp_refresh);
    sftp_toolbar.append(&sftp_upload);
    sftp_toolbar.append(&sftp_new_directory);
    sftp_toolbar.append(&sftp_new_file);
    sftp_page.append(&sftp_toolbar);

    let sftp_list = gtk::ListBox::new();
    sftp_list.add_css_class("tool-list");
    sftp_list.set_selection_mode(gtk::SelectionMode::Single);
    let sftp_scroller = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .min_content_height(180)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&sftp_list)
        .build();
    sftp_page.append(&sftp_scroller);
    let sftp_status = gtk::Label::new(Some("连接后可浏览远程目录"));
    sftp_status.add_css_class("tool-status");
    sftp_status.set_xalign(0.0);
    sftp_status.set_wrap(true);
    sftp_page.append(&sftp_status);
    let sftp_actions = gtk::Box::new(Orientation::Horizontal, 5);
    sftp_actions.add_css_class("tool-action-strip");
    let sftp_download = gtk::Button::with_label("下载");
    let sftp_rename = gtk::Button::with_label("重命名");
    let sftp_chmod = gtk::Button::with_label("权限");
    let sftp_delete = gtk::Button::with_label("删除");
    sftp_delete.add_css_class("destructive-action");
    for button in [&sftp_download, &sftp_rename, &sftp_chmod, &sftp_delete] {
        button.set_sensitive(false);
        sftp_actions.append(button);
    }
    sftp_page.append(&sftp_actions);
    stack.add_titled_with_icon(&sftp_page, Some("sftp"), "SFTP", "folder-symbolic");

    let docker_page = gtk::Box::new(Orientation::Vertical, 8);
    docker_page.add_css_class("tool-page");
    let docker_toolbar = gtk::Box::new(Orientation::Horizontal, 6);
    let docker_refresh = gtk::Button::builder()
        .label("刷新")
        .icon_name("view-refresh-symbolic")
        .sensitive(false)
        .build();
    let docker_logs = gtk::Button::with_label("日志");
    let docker_start = gtk::Button::with_label("启动");
    let docker_restart = gtk::Button::with_label("重启");
    let docker_stop = gtk::Button::with_label("停止");
    for button in [&docker_logs, &docker_start, &docker_restart, &docker_stop] {
        button.set_sensitive(false);
    }
    docker_toolbar.append(&docker_refresh);
    docker_toolbar.append(&docker_logs);
    docker_toolbar.append(&docker_start);
    docker_toolbar.append(&docker_restart);
    docker_toolbar.append(&docker_stop);
    docker_page.append(&docker_toolbar);
    let docker_list = gtk::ListBox::new();
    docker_list.add_css_class("tool-list");
    docker_list.set_selection_mode(gtk::SelectionMode::Single);
    let docker_scroller = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .min_content_height(180)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&docker_list)
        .build();
    docker_page.append(&docker_scroller);
    let docker_status = gtk::Label::new(Some("连接后可读取 Docker 容器"));
    docker_status.add_css_class("tool-status");
    docker_status.set_xalign(0.0);
    docker_status.set_wrap(true);
    docker_page.append(&docker_status);
    stack.add_titled_with_icon(
        &docker_page,
        Some("docker"),
        "Docker",
        "package-x-generic-symbolic",
    );
    let snippets = Rc::new(RefCell::new(snippet_repository.load().unwrap_or_default()));
    let visible_snippet_ids = Rc::new(RefCell::new(Vec::new()));
    let snippet_page = gtk::Box::new(Orientation::Vertical, 8);
    snippet_page.add_css_class("tool-page");
    let snippet_toolbar = gtk::Box::new(Orientation::Horizontal, 6);
    let snippet_search = gtk::SearchEntry::builder()
        .placeholder_text("搜索名称、命令或分类")
        .hexpand(true)
        .build();
    let snippet_add = gtk::Button::builder()
        .icon_name("list-add-symbolic")
        .tooltip_text("新建命令片段")
        .build();
    let snippet_history = gtk::Button::builder()
        .icon_name("document-open-recent-symbolic")
        .tooltip_text("从最近命令保存片段")
        .build();
    snippet_toolbar.append(&snippet_search);
    snippet_toolbar.append(&snippet_history);
    snippet_toolbar.append(&snippet_add);
    snippet_page.append(&snippet_toolbar);
    let snippet_list = gtk::ListBox::new();
    snippet_list.add_css_class("tool-list");
    snippet_list.set_selection_mode(gtk::SelectionMode::Single);
    snippet_page.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&snippet_list)
            .build(),
    );
    let snippet_status = gtk::Label::new(Some("片段保存在本机安全数据目录"));
    snippet_status.add_css_class("tool-status");
    snippet_status.set_xalign(0.0);
    snippet_status.set_ellipsize(gtk::pango::EllipsizeMode::End);
    snippet_page.append(&snippet_status);
    let snippet_actions = gtk::Box::new(Orientation::Horizontal, 6);
    snippet_actions.add_css_class("tool-action-strip");
    let snippet_edit = gtk::Button::with_label("编辑");
    let snippet_delete = gtk::Button::with_label("删除");
    let snippet_insert = gtk::Button::with_label("插入输入栏");
    let snippet_run = gtk::Button::with_label("立即运行");
    snippet_edit.set_sensitive(false);
    snippet_delete.set_sensitive(false);
    snippet_insert.set_sensitive(false);
    snippet_run.set_sensitive(false);
    snippet_delete.add_css_class("destructive-action");
    snippet_run.add_css_class("suggested-action");
    snippet_actions.append(&snippet_edit);
    snippet_actions.append(&snippet_delete);
    snippet_actions.append(&snippet_insert);
    snippet_actions.append(&snippet_run);
    snippet_page.append(&snippet_actions);
    stack.add_titled_with_icon(
        &snippet_page,
        Some("snippets"),
        "Snippets",
        "text-x-generic-symbolic",
    );
    let switcher = adw::ViewSwitcher::builder()
        .stack(&stack)
        .policy(adw::ViewSwitcherPolicy::Wide)
        .build();
    switcher.add_css_class("tool-switcher");
    active_tools.append(&switcher);
    active_tools.append(&stack);
    content_stack.add_named(&active_tools, Some("active"));
    content_stack.set_visible_child_name("empty");
    tools.append(&content_stack);
    panel_stack.add_named(&tools, Some("expanded"));
    panel_stack.set_visible_child_name("expanded");
    ToolsWidgets {
        root: panel_stack,
        collapse,
        content_stack,
        sftp_path,
        sftp_up,
        sftp_refresh,
        sftp_upload,
        sftp_new_directory,
        sftp_new_file,
        sftp_download,
        sftp_rename,
        sftp_chmod,
        sftp_delete,
        sftp_list,
        sftp_status,
        sftp_entries: Rc::new(RefCell::new(Vec::new())),
        docker_refresh,
        docker_list,
        docker_status,
        docker_logs,
        docker_start,
        docker_restart,
        docker_stop,
        docker_containers: Rc::new(RefCell::new(Vec::new())),
        snippet_search,
        snippet_list,
        snippet_add,
        snippet_edit,
        snippet_delete,
        snippet_history,
        snippet_insert,
        snippet_run,
        snippet_status,
        snippets,
        visible_snippet_ids,
        snippet_repository,
        unavailable_title,
        unavailable_detail,
    }
}

fn refresh_snippet_list(context: &UiContext) {
    while let Some(child) = context.tools.snippet_list.first_child() {
        context.tools.snippet_list.remove(&child);
    }
    context.tools.visible_snippet_ids.borrow_mut().clear();
    let query = context.tools.snippet_search.text().trim().to_lowercase();
    let selected_asset = context.session.borrow().selected_asset_id;
    let snippets = context.tools.snippets.borrow();
    for snippet in snippets.iter().filter(|snippet| {
        let matches_query = query.is_empty()
            || snippet.title.to_lowercase().contains(&query)
            || snippet.command.to_lowercase().contains(&query)
            || snippet.category.to_lowercase().contains(&query);
        let matches_scope = selected_asset.is_none_or(|asset_id| snippet.applies_to(asset_id));
        matches_query && matches_scope
    }) {
        let row = gtk::Box::new(Orientation::Vertical, 3);
        row.add_css_class("tool-row");
        let heading = gtk::Box::new(Orientation::Horizontal, 6);
        let name = gtk::Label::new(Some(&snippet.title));
        name.set_xalign(0.0);
        name.set_hexpand(true);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        name.add_css_class("heading");
        let category = gtk::Label::new(Some(if snippet.category.trim().is_empty() {
            "未分类"
        } else {
            snippet.category.trim()
        }));
        category.add_css_class("protocol-badge");
        heading.append(&name);
        heading.append(&category);
        let command = gtk::Label::new(Some(&snippet.command.replace('\n', " ↵ ")));
        command.set_xalign(0.0);
        command.set_ellipsize(gtk::pango::EllipsizeMode::End);
        command.add_css_class("caption");
        let scope = match snippet.asset_scope.mode {
            SnippetScopeMode::AllAssets => "适用于所有资产".to_owned(),
            SnippetScopeMode::SelectedAssets => {
                format!("限定 {} 项资产", snippet.asset_scope.asset_ids.len())
            }
        };
        let scope = gtk::Label::new(Some(&scope));
        scope.set_xalign(0.0);
        scope.add_css_class("caption");
        row.append(&heading);
        row.append(&command);
        row.append(&scope);
        context.tools.snippet_list.append(&row);
        context
            .tools
            .visible_snippet_ids
            .borrow_mut()
            .push(snippet.id);
    }
    let visible = context.tools.visible_snippet_ids.borrow().len();
    let total = snippets.len();
    let summary = if total == 0 {
        "还没有命令片段；点击 + 新建，或从最近命令保存。".to_owned()
    } else if visible == total {
        format!("共 {total} 条 · 已安全保存在本机")
    } else {
        format!("显示 {visible}/{total} 条 · 已按搜索与资产范围筛选")
    };
    context.tools.snippet_status.set_label(&summary);
}

fn selected_snippet(context: &UiContext) -> Option<CommandSnippet> {
    let index = context
        .tools
        .snippet_list
        .selected_row()
        .and_then(|row| usize::try_from(row.index()).ok())?;
    let id = *context.tools.visible_snippet_ids.borrow().get(index)?;
    context
        .tools
        .snippets
        .borrow()
        .iter()
        .find(|snippet| snippet.id == id)
        .cloned()
}

fn present_snippet_editor(
    context: UiContext,
    snippet_id: Option<Uuid>,
    command_seed: Option<String>,
) {
    let existing = snippet_id.and_then(|id| {
        context
            .tools
            .snippets
            .borrow()
            .iter()
            .find(|snippet| snippet.id == id)
            .cloned()
    });
    let window = gtk::Window::builder()
        .title(if existing.is_some() {
            "编辑命令片段"
        } else {
            "新建命令片段"
        })
        .transient_for(&context.window)
        .modal(true)
        .default_width(620)
        .default_height(620)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 12);
    root.add_css_class("settings-page");
    root.set_margin_start(20);
    root.set_margin_end(20);
    root.set_margin_top(20);
    root.set_margin_bottom(20);
    let title = labeled_entry(&root, "名称", "例如：检查监听端口");
    let category = labeled_entry(&root, "分类", "例如：网络、诊断、部署");
    let command_label = gtk::Label::new(Some("命令"));
    command_label.set_xalign(0.0);
    command_label.add_css_class("field-label");
    root.append(&command_label);
    let command = gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    let command_scroller = gtk::ScrolledWindow::builder()
        .min_content_height(150)
        .vexpand(true)
        .child(&command)
        .build();
    command_scroller.add_css_class("document-editor-surface");
    root.append(&command_scroller);
    let all_assets = gtk::CheckButton::with_label("适用于所有资产");
    all_assets.set_active(true);
    root.append(&all_assets);
    let asset_scope = gtk::Box::new(Orientation::Vertical, 4);
    asset_scope.add_css_class("snippet-asset-scope");
    let asset_checks = Rc::new(
        context
            .catalog
            .borrow()
            .assets()
            .iter()
            .map(|asset| {
                let check = gtk::CheckButton::with_label(&format!(
                    "{} · {} · {}",
                    asset.name,
                    asset.transport.display_name(),
                    asset.endpoint()
                ));
                asset_scope.append(&check);
                (asset.id, check)
            })
            .collect::<Vec<_>>(),
    );
    asset_scope.set_sensitive(false);
    let asset_scope_for_toggle = asset_scope.clone();
    all_assets.connect_toggled(move |button| {
        asset_scope_for_toggle.set_sensitive(!button.is_active());
    });
    let asset_scroller = gtk::ScrolledWindow::builder()
        .min_content_height(100)
        .max_content_height(150)
        .child(&asset_scope)
        .build();
    root.append(&asset_scroller);
    if let Some(existing) = &existing {
        title.set_text(&existing.title);
        category.set_text(&existing.category);
        command.buffer().set_text(&existing.command);
        let global = matches!(existing.asset_scope.mode, SnippetScopeMode::AllAssets);
        all_assets.set_active(global);
        asset_scope.set_sensitive(!global);
        for (asset_id, check) in asset_checks.iter() {
            check.set_active(existing.asset_scope.asset_ids.contains(asset_id));
        }
    } else if let Some(seed) = command_seed {
        command.buffer().set_text(&seed);
    }
    let status = gtk::Label::new(Some("片段仅保存命令正文，不保存密码、令牌或终端输出。"));
    status.add_css_class("caption");
    status.set_xalign(0.0);
    status.set_wrap(true);
    root.append(&status);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let save = gtk::Button::with_label("保存");
    save.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&save);
    root.append(&actions);
    window.set_child(Some(&root));
    let close_window = window.clone();
    cancel.connect_clicked(move |_| close_window.close());
    let save_context = context.clone();
    let save_window = window.clone();
    let created_at = existing.as_ref().map(|item| item.created_at_unix_ms);
    let existing_id = existing.as_ref().map(|item| item.id);
    save.connect_clicked(move |_| {
        let title_value = title.text().trim().to_owned();
        let category_value = category.text().trim().to_owned();
        let buffer = command.buffer();
        let command_value = buffer
            .text(&buffer.start_iter(), &buffer.end_iter(), true)
            .trim()
            .to_owned();
        if title_value.is_empty() || title_value.len() > 128 {
            status.set_label("名称不能为空，且不能超过 128 个字符。");
            return;
        }
        if command_value.is_empty() || command_value.len() > 65_536 || command_value.contains('\0')
        {
            status.set_label("命令不能为空、不能包含 NUL，且不能超过 64 KiB。");
            return;
        }
        let selected_assets = asset_checks
            .iter()
            .filter_map(|(asset_id, check)| check.is_active().then_some(*asset_id))
            .collect::<Vec<_>>();
        if !all_assets.is_active() && selected_assets.is_empty() {
            status.set_label("限定资产时，请至少选择一项资产。");
            return;
        }
        let now = i64::try_from(current_unix_ms().unwrap_or(1)).unwrap_or(i64::MAX);
        let snippet = CommandSnippet {
            id: existing_id.unwrap_or_else(Uuid::new_v4),
            title: title_value,
            command: command_value,
            category: category_value,
            asset_scope: if all_assets.is_active() {
                SnippetAssetScope::default()
            } else {
                SnippetAssetScope {
                    mode: SnippetScopeMode::SelectedAssets,
                    asset_ids: selected_assets,
                }
            },
            created_at_unix_ms: created_at.unwrap_or(now),
            updated_at_unix_ms: now,
        };
        if let Err(error) = save_context.tools.snippet_repository.upsert(snippet) {
            status.set_label(&format!("保存失败：{error}"));
            return;
        }
        match save_context.tools.snippet_repository.load() {
            Ok(snippets) => *save_context.tools.snippets.borrow_mut() = snippets,
            Err(error) => {
                status.set_label(&format!("重新读取片段失败：{error}"));
                return;
            }
        }
        refresh_snippet_list(&save_context);
        save_context.status.set_label("命令片段已安全保存。");
        save_window.close();
    });
    window.present();
}

fn confirm_delete_snippet(context: UiContext) {
    let Some(snippet) = selected_snippet(&context) else {
        return;
    };
    let dialog = adw::AlertDialog::builder()
        .heading("删除命令片段？")
        .body(format!(
            "将从本机片段库删除“{}”。此操作不会在远端执行命令。",
            snippet.title
        ))
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("delete", "删除");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() != "delete" {
            return;
        }
        if let Err(error) = context.tools.snippet_repository.remove(snippet.id) {
            context
                .tools
                .snippet_status
                .set_label(&format!("删除失败：{error}"));
            return;
        }
        match context.tools.snippet_repository.load() {
            Ok(snippets) => *context.tools.snippets.borrow_mut() = snippets,
            Err(error) => {
                context
                    .tools
                    .snippet_status
                    .set_label(&format!("重新读取失败：{error}"));
                return;
            }
        }
        refresh_snippet_list(&context);
        context.status.set_label("命令片段已删除。");
    });
}

fn present_snippet_history(context: UiContext) {
    let history = context
        .session
        .borrow()
        .active()
        .map(|runtime| runtime.command_history.clone())
        .unwrap_or_default();
    if history.is_empty() {
        context
            .tools
            .snippet_status
            .set_label("当前会话还没有通过输入栏或片段执行的最近命令。");
        return;
    }
    let window = gtk::Window::builder()
        .title("从最近命令保存片段")
        .transient_for(&context.window)
        .modal(true)
        .default_width(560)
        .default_height(420)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 10);
    root.set_margin_start(16);
    root.set_margin_end(16);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    for command in &history {
        let label = gtk::Label::new(Some(command));
        label.set_xalign(0.0);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.add_css_class("monospace");
        list.append(&label);
    }
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&list)
            .build(),
    );
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let create = gtk::Button::with_label("保存为片段");
    create.add_css_class("suggested-action");
    create.set_sensitive(false);
    let create_for_selection = create.clone();
    list.connect_row_selected(move |_, row| create_for_selection.set_sensitive(row.is_some()));
    actions.append(&cancel);
    actions.append(&create);
    root.append(&actions);
    window.set_child(Some(&root));
    let close = window.clone();
    cancel.connect_clicked(move |_| close.close());
    let create_context = context.clone();
    let create_window = window.clone();
    create.connect_clicked(move |_| {
        let Some(index) = list
            .selected_row()
            .and_then(|row| usize::try_from(row.index()).ok())
        else {
            return;
        };
        let Some(command) = history.get(index).cloned() else {
            return;
        };
        create_window.close();
        present_snippet_editor(create_context.clone(), None, Some(command));
    });
    window.present();
}

fn tool_empty_state(title: &str, description: &str, icon: &str) -> adw::StatusPage {
    let page = adw::StatusPage::builder()
        .title(title)
        .description(description)
        .icon_name(icon)
        .build();
    page.add_css_class("compact-status");
    page
}

fn apply_tool_panel_visibility(context: &UiContext) {
    let auto_hidden = context.tools_auto_hidden_for_rdp.get();
    let user_collapsed = context.tools_collapsed.get();
    context
        .tools
        .root
        .set_visible(!auto_hidden && !user_collapsed);
    if let Some(expand) = context.tools_expand.borrow().as_ref() {
        // The RDP workspace intentionally has no SSH side tools. Do not leave
        // a misleading restore affordance on the application edge while the
        // remote desktop is active; the user's SSH panel preference is kept
        // and restored on the next non-RDP workspace.
        expand.set_visible(!auto_hidden && user_collapsed);
    }
}

fn set_rdp_tool_autohide(context: &UiContext, hidden: bool) {
    context.tools_auto_hidden_for_rdp.set(hidden);
    apply_tool_panel_visibility(context);
}

fn select_asset(context: &UiContext, asset_id: Uuid) {
    if context.module_fullscreen.get() {
        exit_module_fullscreen(context);
    }
    let asset = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned();
    let Some(asset) = asset else {
        context.status.set_label("所选资产已不存在，请刷新资产栏。");
        return;
    };
    prepare_workspace_input_handoff(context, Some(asset_id));
    context.workspace.heading.set_visible(true);
    {
        let mut registry = context.session.borrow_mut();
        registry.selected_asset_id = Some(asset_id);
        if registry.sessions.contains_key(&asset_id) {
            registry.active_workspace_id = Some(asset_id);
            drop(registry);
            refresh_snippet_list(context);
            render_active_workspace(context);
            refresh_session_tabs(context);
            return;
        }
        registry.active_workspace_id = None;
    }

    refresh_snippet_list(context);

    update_endpoint(context, &asset);
    context.workspace.title.set_label(&asset.name);
    context.workspace.subtitle.set_label(&format!(
        "{} · {}",
        asset.transport.display_name(),
        asset.endpoint()
    ));
    context.workspace.security.remove_css_class("verified");
    context.workspace.security.remove_css_class("insecure");
    context.workspace.security.set_label(match asset.transport {
        Transport::Ssh => "Host Key 未验证",
        Transport::Telnet => "Telnet · 连接前确认",
        Transport::Rdp => "RDP · NLA + 证书确认",
    });
    if asset.transport == Transport::Telnet {
        context.workspace.security.add_css_class("insecure");
    }
    context
        .workspace
        .empty_title
        .set_label(&format!("{} 已准备就绪", asset.name));
    context
        .workspace
        .empty_description
        .set_label(match asset.transport {
            Transport::Ssh => "建立 Host Key 受检连接后，将在这里打开终端工作区。",
            Transport::Telnet => "连接前必须确认明文传输风险；不会提供 SFTP、Docker 或监控旁路。",
            Transport::Rdp => "使用内嵌 FreeRDP 工作区；NLA 强制开启，未知或变化证书必须由你确认。",
        });
    context
        .workspace
        .content_stack
        .set_visible_child_name("empty");
    context
        .workspace
        .input_row
        .set_visible(asset.transport != Transport::Rdp);
    set_rdp_tool_autohide(context, asset.transport == Transport::Rdp);
    context.tools.content_stack.set_visible_child_name("empty");
    context.workspace.edit.set_sensitive(true);
    context.workspace.disconnect.set_sensitive(false);
    context.workspace.input.set_sensitive(false);
    context.workspace.send.set_sensitive(false);
    let (label, sensitive, status) = match asset.transport {
        Transport::Ssh => ("连接", true, "资产已选择 · 可建立受检 SSH 会话".to_owned()),
        Transport::Telnet => (
            "明文连接",
            true,
            "Telnet 资产已选择 · 连接前必须逐目标确认明文风险".to_owned(),
        ),
        Transport::Rdp => {
            let runtime = freerdp_runtime_info();
            match runtime.status {
                FreeRdpRuntimeStatus::Available => (
                    "远程桌面",
                    true,
                    format!(
                        "RDP 资产已选择 · FreeRDP {} · NLA 已强制",
                        runtime.expected_version
                    ),
                ),
                FreeRdpRuntimeStatus::VersionMismatch => (
                    "组件不兼容",
                    false,
                    format!(
                        "RDP 已安全阻止 · 需要 FreeRDP {}，当前为 {}",
                        runtime.expected_version,
                        runtime.actual_version.unwrap_or_else(|| "未知".into())
                    ),
                ),
                FreeRdpRuntimeStatus::Unavailable => (
                    "组件不可用",
                    false,
                    "RDP 已安全阻止 · 未找到内嵌 FreeRDP 运行时".to_owned(),
                ),
            }
        }
    };
    context.workspace.connect.set_label(label);
    context.workspace.connect.set_sensitive(sensitive);
    context.status.set_label(&status);
    refresh_session_tabs(context);
}

fn update_endpoint(context: &UiContext, asset: &ServerAsset) {
    context
        .workspace
        .monitor_endpoint
        .set_label(asset.host.trim());
    context.workspace.monitor_copy_endpoint.set_sensitive(true);
    if let Some(sidebar) = context.sidebar.borrow().as_ref() {
        sidebar.edit.set_sensitive(true);
    }
}

fn refresh_session_tabs(context: &UiContext) {
    while let Some(child) = context.workspace.tabs.first_child() {
        context.workspace.tabs.remove(&child);
    }
    let (sessions, active) = {
        let registry = context.session.borrow();
        (
            registry
                .sessions
                .values()
                .map(|runtime| {
                    (
                        runtime.asset_id,
                        runtime.name.clone(),
                        runtime.transport,
                        runtime.phase,
                    )
                })
                .collect::<Vec<_>>(),
            registry.active_workspace_id,
        )
    };
    for (asset_id, name, transport, phase) in sessions.iter().cloned() {
        let tab_group = gtk::Box::new(Orientation::Horizontal, 0);
        tab_group.add_css_class("session-tab-group");
        let content = gtk::Box::new(Orientation::Horizontal, 6);
        let icon = gtk::Image::from_icon_name(match transport {
            Transport::Rdp => "video-display-symbolic",
            _ => "utilities-terminal-symbolic",
        });
        let label = gtk::Label::new(Some(&name));
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.set_max_width_chars(18);
        let phase_label = gtk::Label::new(Some(workspace_phase_label(phase)));
        phase_label.add_css_class("tab-status");
        if phase == WorkspacePhase::Connected {
            phase_label.add_css_class("connected");
        } else if phase == WorkspacePhase::Failed {
            phase_label.add_css_class("failed");
        }
        content.append(&icon);
        content.append(&label);
        content.append(&phase_label);
        let tab = gtk::ToggleButton::builder().child(&content).build();
        tab.add_css_class("tab-button");
        tab.set_active(active == Some(asset_id));
        let activate_context = context.clone();
        tab.connect_clicked(move |_| activate_workspace(&activate_context, asset_id));
        let menu_context = context.clone();
        let menu_tab = tab.clone();
        let menu_click = gtk::GestureClick::new();
        menu_click.set_button(3);
        menu_click.connect_pressed(move |gesture, _, x, y| {
            present_session_tab_menu(menu_context.clone(), asset_id, &menu_tab, x, y);
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        tab.add_controller(menu_click);
        tab_group.append(&tab);
        context.workspace.tabs.append(&tab_group);
    }
    context
        .workspace
        .tab_hint
        .set_label(if sessions.is_empty() {
            "连接资产后将在这里显示会话标签"
        } else {
            "切换标签时终端与工具上下文会同步切换"
        });
    context.workspace.tabs.append(&context.workspace.tab_hint);
    context
        .workspace
        .tab_status
        .set_label(&format!("{} 会话", sessions.len()));
    context.workspace.tabs.append(&context.workspace.tab_status);
    context.workspace.tabs.append(&context.workspace.split_menu);
}

fn present_session_tab_menu(
    context: UiContext,
    asset_id: Uuid,
    parent: &gtk::ToggleButton,
    x: f64,
    y: f64,
) {
    let phase = context
        .session
        .borrow()
        .sessions
        .get(&asset_id)
        .map(|runtime| runtime.phase);
    let popover = gtk::Popover::new();
    popover.set_parent(parent);
    popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    let actions = gtk::Box::new(Orientation::Vertical, 2);
    actions.set_margin_top(6);
    actions.set_margin_bottom(6);
    actions.set_margin_start(6);
    actions.set_margin_end(6);
    let add = |label: &str, sensitive: bool, action: Rc<dyn Fn()>| {
        let button = gtk::Button::with_label(label);
        button.add_css_class("flat");
        button.set_halign(Align::Fill);
        button.set_sensitive(sensitive);
        let menu = popover.clone();
        button.connect_clicked(move |_| {
            menu.popdown();
            action();
        });
        actions.append(&button);
    };
    let disconnect = context.clone();
    add(
        "断开连接",
        matches!(
            phase,
            Some(
                WorkspacePhase::Connected
                    | WorkspacePhase::Starting
                    | WorkspacePhase::Authenticating
                    | WorkspacePhase::Reconnecting
            )
        ),
        Rc::new(move || disconnect_workspace(disconnect.clone(), asset_id, false)),
    );
    let reconnect = context.clone();
    add(
        "重新连接",
        matches!(
            phase,
            Some(WorkspacePhase::Disconnected | WorkspacePhase::Failed | WorkspacePhase::Closed)
        ),
        Rc::new(move || begin_connect(reconnect.clone(), asset_id)),
    );
    let detached = context.clone();
    add(
        "在新窗口打开",
        phase.is_some(),
        Rc::new(move || present_detached_session_window(detached.clone(), asset_id)),
    );
    let close = context.clone();
    add(
        "关闭标签",
        true,
        Rc::new(move || close_workspace(close.clone(), asset_id)),
    );
    popover.set_child(Some(&actions));
    popover.popup();
}

fn present_detached_session_window(context: UiContext, asset_id: Uuid) {
    let Some((name, transport, backlog)) =
        context
            .session
            .borrow()
            .sessions
            .get(&asset_id)
            .map(|runtime| {
                (
                    runtime.name.clone(),
                    runtime.transport,
                    runtime.terminal_backlog.clone(),
                )
            })
    else {
        return;
    };
    let window = gtk::Window::builder()
        .title(format!("{name} · {}", transport.display_name()))
        .transient_for(&context.window)
        .default_width(900)
        .default_height(620)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 8);
    root.add_css_class("detached-session");
    if transport == Transport::Rdp {
        root.append(&gtk::Label::new(Some(
            "RDP 会话保持在主工作台中；新窗口模式当前仅用于终端会话。",
        )));
    } else {
        let terminal = vte::Terminal::new();
        terminal.set_vexpand(true);
        terminal.set_hexpand(true);
        terminal.set_scrollback_lines(20_000);
        terminal.feed(&backlog);
        root.append(&terminal);
        let input = gtk::Entry::builder()
            .placeholder_text("输入命令并按 Enter")
            .build();
        let send_context = context.clone();
        input.connect_activate(move |entry| {
            let mut bytes = entry.text().as_bytes().to_vec();
            bytes.push(b'\r');
            if write_terminal_for_asset(&send_context, asset_id, &bytes).is_ok() {
                entry.set_text("");
            }
        });
        root.append(&input);
        let observed = Rc::new(Cell::new(backlog.len()));
        let terminal_for_poll = terminal.clone();
        let session_for_poll = context.session.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
            let registry = session_for_poll.borrow();
            let Some(runtime) = registry.sessions.get(&asset_id) else {
                return gtk::glib::ControlFlow::Break;
            };
            let start = observed.get().min(runtime.terminal_backlog.len());
            if start < runtime.terminal_backlog.len() {
                terminal_for_poll.feed(&runtime.terminal_backlog[start..]);
                observed.set(runtime.terminal_backlog.len());
            }
            gtk::glib::ControlFlow::Continue
        });
    }
    window.set_child(Some(&root));
    window.present();
}

fn workspace_phase_label(phase: WorkspacePhase) -> &'static str {
    match phase {
        WorkspacePhase::Starting => "启动中",
        WorkspacePhase::Authenticating => "认证中",
        WorkspacePhase::AwaitingUserDecision => "待确认",
        WorkspacePhase::Connected => "在线",
        WorkspacePhase::Reconnecting => "重连中",
        WorkspacePhase::Disconnected => "已断开",
        WorkspacePhase::Failed => "失败",
        WorkspacePhase::Closed => "已关闭",
    }
}

fn rdp_state_presentation(
    phase: WorkspacePhase,
    reconnect_attempt: u8,
) -> (&'static str, String, bool) {
    if reconnect_attempt > 0
        && matches!(
            phase,
            WorkspacePhase::Starting | WorkspacePhase::Authenticating
        )
    {
        return (
            "正在恢复远程桌面",
            format!(
                "正在执行自动重连（{reconnect_attempt}/{MAX_RDP_RECONNECT_ATTEMPTS}）并重新验证 NLA 与证书。"
            ),
            true,
        );
    }
    match phase {
        WorkspacePhase::Starting => (
            "正在启动远程桌面",
            "正在安全读取凭据并准备 FreeRDP 工作区。".to_owned(),
            true,
        ),
        WorkspacePhase::Authenticating => (
            "正在验证远端身份",
            "正在执行 NLA、安全协商与证书校验。".to_owned(),
            true,
        ),
        WorkspacePhase::AwaitingUserDecision => (
            "等待证书确认",
            "请核对证书指纹后决定是否继续连接。".to_owned(),
            true,
        ),
        WorkspacePhase::Connected => ("", String::new(), false),
        WorkspacePhase::Reconnecting => (
            "远程桌面连接已中断",
            format!(
                "正在执行有限自动重连（{}/{MAX_RDP_RECONNECT_ATTEMPTS}）；可随时使用“断开连接”取消。",
                reconnect_attempt.max(1)
            ),
            true,
        ),
        WorkspacePhase::Disconnected => (
            "远程桌面已断开",
            "可使用会话标签菜单或连接按钮重新连接。".to_owned(),
            true,
        ),
        WorkspacePhase::Failed => (
            "远程桌面连接失败",
            "请查看诊断提示；不会因身份或证书错误反复尝试。".to_owned(),
            true,
        ),
        WorkspacePhase::Closed => (
            "远程桌面会话已关闭",
            "重新连接时会重新执行 NLA 与证书校验。".to_owned(),
            true,
        ),
    }
}

fn activate_workspace(context: &UiContext, asset_id: Uuid) {
    if !context.session.borrow().sessions.contains_key(&asset_id) {
        return;
    }
    if context.module_fullscreen.get() {
        exit_module_fullscreen(context);
    }
    prepare_workspace_input_handoff(context, Some(asset_id));
    {
        let mut registry = context.session.borrow_mut();
        if !registry.sessions.contains_key(&asset_id) {
            return;
        }
        registry.selected_asset_id = Some(asset_id);
        registry.active_workspace_id = Some(asset_id);
    }
    render_active_workspace(context);
    refresh_session_tabs(context);
    let refresh_ssh_tools = context.session.borrow().active().is_some_and(|runtime| {
        runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected
    });
    if refresh_ssh_tools {
        begin_monitor_refresh(context.clone());
        begin_sftp_list(context.clone(), String::new());
        begin_docker_refresh(context.clone());
    }
}

fn render_active_workspace(context: &UiContext) {
    let Some((asset_id, transport, phase, pane_backlogs, active_pane, frame)) = ({
        let registry = context.session.borrow();
        registry.active().map(|runtime| {
            (
                runtime.asset_id,
                runtime.transport,
                runtime.phase,
                (0..runtime.pane_count())
                    .map(|pane| runtime.pane_backlog(pane).to_vec())
                    .collect::<Vec<_>>(),
                runtime.active_terminal_pane,
                runtime.rdp_frame.clone(),
            )
        })
    }) else {
        return;
    };
    let asset = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned();
    let Some(asset) = asset else {
        return;
    };
    update_endpoint(context, &asset);
    context.workspace.title.set_label(&asset.name);
    context.workspace.subtitle.set_label(&format!(
        "{} · {}",
        asset.transport.display_name(),
        asset.endpoint()
    ));
    context.workspace.security.remove_css_class("verified");
    context.workspace.security.remove_css_class("insecure");
    context.workspace.security.set_label(match transport {
        Transport::Ssh if phase == WorkspacePhase::Connected => "Host Key 已验证",
        Transport::Ssh => "Host Key 未验证",
        Transport::Telnet => "Telnet · 明文会话",
        Transport::Rdp if phase == WorkspacePhase::Connected => "RDP · NLA 已连接",
        Transport::Rdp => "RDP · NLA + 证书确认",
    });
    if transport == Transport::Ssh && phase == WorkspacePhase::Connected {
        context.workspace.security.add_css_class("verified");
    }
    if transport == Transport::Telnet {
        context.workspace.security.add_css_class("insecure");
    }
    let connected = phase == WorkspacePhase::Connected;
    let rdp_connected = transport == Transport::Rdp && connected;
    if context.module_fullscreen.get() && !connected {
        exit_module_fullscreen(context);
    }
    context
        .workspace
        .terminal_fullscreen
        .set_sensitive(connected && transport != Transport::Rdp);
    context
        .workspace
        .rdp_capture_shortcuts
        .set_sensitive(rdp_connected);
    context
        .workspace
        .rdp_secure_attention
        .set_sensitive(rdp_connected);
    context
        .workspace
        .rdp_fullscreen
        .set_sensitive(rdp_connected);
    if !rdp_connected && context.rdp_input_capture.get() {
        set_rdp_system_shortcut_capture(context, false);
    }
    set_rdp_tool_autohide(context, transport == Transport::Rdp);
    context.workspace.heading.set_visible(false);
    context.workspace.connect.set_label(match phase {
        WorkspacePhase::Starting | WorkspacePhase::Authenticating => "连接中…",
        WorkspacePhase::AwaitingUserDecision => "等待确认",
        WorkspacePhase::Connected => "已连接",
        WorkspacePhase::Disconnected | WorkspacePhase::Failed => "重新连接",
        WorkspacePhase::Reconnecting => "重连中…",
        WorkspacePhase::Closed => "连接",
    });
    context.workspace.connect.set_sensitive(matches!(
        phase,
        WorkspacePhase::Disconnected | WorkspacePhase::Failed | WorkspacePhase::Closed
    ));
    context.workspace.disconnect.set_sensitive(matches!(
        phase,
        WorkspacePhase::Starting
            | WorkspacePhase::Authenticating
            | WorkspacePhase::AwaitingUserDecision
            | WorkspacePhase::Connected
            | WorkspacePhase::Reconnecting
    ));
    context.workspace.edit.set_sensitive(!connected);
    context
        .workspace
        .monitor_connection
        .set_label(if connected {
            match transport {
                Transport::Ssh => "已验证",
                Transport::Telnet => "明文",
                Transport::Rdp => "NLA",
            }
        } else {
            workspace_phase_label(phase)
        });
    context.workspace.monitor_latency.set_label("—");
    if transport != Transport::Ssh {
        context.workspace.monitor_cpu.set_label("—");
        context.workspace.monitor_memory.set_label("—");
    }

    match transport {
        Transport::Ssh | Transport::Telnet => {
            context.workspace.input_row.set_visible(true);
            context
                .workspace
                .content_stack
                .set_visible_child_name("terminal");
            rebuild_terminal_grid(&context.workspace, pane_backlogs.len(), active_pane);
            render_terminal_backlogs(&context.workspace, &pane_backlogs);
            context
                .workspace
                .split_menu
                .set_sensitive(transport == Transport::Ssh && connected);
            update_split_actions(context);
            context.workspace.input.set_sensitive(connected);
            context.workspace.send.set_sensitive(connected);
            if transport == Transport::Ssh && connected {
                context.tools.content_stack.set_visible_child_name("active");
            } else if transport == Transport::Telnet {
                context
                    .tools
                    .unavailable_title
                    .set_label("Telnet 仅提供明文终端");
                context.tools.unavailable_detail.set_label(
                    "SFTP、Docker、Monitor 与片段执行不会为 Telnet 资产创建旁路 SSH 连接。",
                );
                context
                    .tools
                    .content_stack
                    .set_visible_child_name("unsupported");
            } else {
                context.tools.content_stack.set_visible_child_name("empty");
            }
        }
        Transport::Rdp => {
            context.workspace.input_row.set_visible(false);
            context.workspace.split_menu.set_sensitive(false);
            context
                .workspace
                .content_stack
                .set_visible_child_name("rdp");
            context.workspace.input.set_sensitive(false);
            context.workspace.send.set_sensitive(false);
            context
                .tools
                .unavailable_title
                .set_label("RDP 使用独立远程桌面工作区");
            context.tools.unavailable_detail.set_label(
                "RDP 不提供 SSH 工具；SFTP、Docker、Monitor 与命令片段不会建立旁路连接。",
            );
            context
                .tools
                .content_stack
                .set_visible_child_name("unsupported");
            let reconnect_attempt = context
                .rdp_reconnect_states
                .borrow()
                .get(&asset_id)
                .map(|state| state.attempt)
                .unwrap_or(0);
            let (state_title, state_detail, state_visible) =
                rdp_state_presentation(phase, reconnect_attempt);
            context.workspace.rdp_state_title.set_label(state_title);
            context.workspace.rdp_state_detail.set_label(&state_detail);
            context
                .workspace
                .rdp_state_overlay
                .set_visible(state_visible);
            if let Some(frame) = frame {
                present_rdp_frame(context, frame);
            } else {
                context.workspace.rdp_canvas.replace(None);
                context.workspace.rdp_picture.queue_draw();
            }
        }
    }
    context.status.set_label(&format!(
        "{} · {} · {}",
        asset.name,
        transport.display_name(),
        workspace_phase_label(phase)
    ));
    // RDP-to-RDP selection can reuse an already-focused drawing area, so no
    // focus-enter signal is guaranteed after the outgoing capture is released.
    refresh_rdp_shortcut_capture(context);
}

fn present_rdp_frame(context: &UiContext, frame: SharedRdpCanvas) {
    context.workspace.rdp_canvas.replace(Some(frame));
    context.workspace.rdp_picture.queue_draw();
}

fn rdp_quality_button_label(
    phase: WorkspacePhase,
    reconnect_attempt: u8,
    snapshot: Option<&RdpMetricSnapshot>,
) -> String {
    match phase {
        WorkspacePhase::Connected => match snapshot.and_then(|metric| metric.last_frame_age) {
            Some(age) if age <= Duration::from_secs(2) => format!(
                "自适应 · {:.1} fps",
                snapshot
                    .map(|metric| metric.frames_per_second)
                    .unwrap_or(0.0)
            ),
            Some(_) => "自适应 · 静态画面".to_owned(),
            None => "自适应 · 等待画面".to_owned(),
        },
        WorkspacePhase::Reconnecting => format!(
            "重连 {}/{}",
            reconnect_attempt.max(1),
            MAX_RDP_RECONNECT_ATTEMPTS
        ),
        WorkspacePhase::Starting
        | WorkspacePhase::Authenticating
        | WorkspacePhase::AwaitingUserDecision => "自适应 · 协商中".to_owned(),
        WorkspacePhase::Disconnected | WorkspacePhase::Failed | WorkspacePhase::Closed => {
            "连接诊断".to_owned()
        }
    }
}

fn format_metric_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    if seconds < 60 {
        format!("{seconds} 秒")
    } else if seconds < 3_600 {
        format!("{} 分 {} 秒", seconds / 60, seconds % 60)
    } else {
        format!("{} 小时 {} 分", seconds / 3_600, seconds % 3_600 / 60)
    }
}

fn format_input_latency(duration: Duration) -> String {
    if duration < Duration::from_secs(1) {
        format!("{} ms", duration.as_millis())
    } else {
        format!("{:.2} s", duration.as_secs_f64())
    }
}

fn rdp_diagnostic_report(
    asset: &ServerAsset,
    phase: WorkspacePhase,
    attempt: u8,
    snapshot: &RdpMetricSnapshot,
    viewport: (i32, i32),
    input_state: RdpLiveInputState,
) -> String {
    let runtime = freerdp_runtime_info();
    let resolution = snapshot
        .resolution
        .map(|(width, height)| format!("{width} × {height}"))
        .unwrap_or_else(|| "尚未收到画面".to_owned());
    let last_frame = snapshot
        .last_frame_age
        .map(|age| format!("{}前", format_metric_duration(age)))
        .unwrap_or_else(|| "尚未收到".to_owned());
    let connected = snapshot
        .connected_age
        .map(format_metric_duration)
        .unwrap_or_else(|| "尚未连接".to_owned());
    let last_failure = snapshot
        .last_failure
        .as_ref()
        .map(|(code, reason)| format!("{code} · {reason}"))
        .unwrap_or_else(|| "无".to_owned());
    let pixel_pipeline_budget = snapshot
        .canvas_allocation_bytes
        .saturating_mul(RDP_PIXEL_PIPELINE_BUFFERS);
    let viewport_description = if viewport.0 > 0 && viewport.1 > 0 {
        format!("{} × {} 逻辑像素", viewport.0, viewport.1)
    } else {
        "尚未布局".to_owned()
    };
    let local_scale = snapshot
        .resolution
        .and_then(|(width, height)| {
            rdp_viewport_geometry(f64::from(viewport.0), f64::from(viewport.1), width, height)
        })
        .map(|geometry| format!("{:.1}%", geometry.scale * 100.0))
        .unwrap_or_else(|| "不可用".to_owned());
    let input_to_frame = snapshot
        .last_input_to_frame
        .map(format_input_latency)
        .unwrap_or_else(|| "5 秒关联窗口内尚无画面更新（静态桌面属正常）".to_owned());
    format!(
        "RDP 连接诊断\n\n资产：{}\n端点：{}\n状态：{}\n会话时长：{}\n当前连接时长：{}\n画面尺寸：{}\n本地视口：{}\n本地等比缩放：{}\n近 5 秒画面更新：{:.1} fps\n近 5 秒增量解码：{}/s（非网络吞吐量）\n原生画面更新：{} 次\nUI 合并呈现：{} 次\n已合并更新：{} 次\n累计增量数据：{}\n避免原生整帧复制：{}\n持久画布：{}（单会话）\n像素管线峰值预算：{}（原生帧缓冲 + 在途更新 + GTK 画布，不含 FreeRDP 解码缓存）\n\n输入状态：焦点 {}、系统快捷键捕获 {}、模块全屏 {}、按住的鼠标按钮 {}\n已提交远端输入：指针移动 {}、按钮 {}、滚轮 {}、按键 {} 次\n远端按键细分：按下 {}、释放 {}、组合文本提交 {} 次\n本机保留快捷键：{} 次（从未发送到远端）\n焦点变化：进入 {}、离开 {} 次\n快捷键捕获：启用 {}、释放 {} 次\n失焦安全释放：修饰键 {} 批、鼠标按钮 {} 批\n被拒绝输入：{} 次（边框留白、未连接或原生通道拒绝）\n输入后下一画面参考间隔：{}；历史最大 {}（仅客户端交互参考，不等于网络 RTT）\n最后画面更新：{}（静态桌面可能不产生更新）\n最大画面更新间隔：{}\n意外断开：{} 次\n自动恢复：{} 次\n当前重连：{}/{}\n最后诊断：{}\n引擎：FreeRDP {}\n渲染策略：持久 Cairo 画布、脏矩形原位写入、局部标记重绘、单通知背压\n输入策略：按焦点分配本机/应用/远端快捷键；保留退出通道；失焦时释放按键与鼠标状态\n诊断隐私：仅保留本次会话内的类别、次数和状态；不记录按键、组合文本、凭据或远端内容\n画质策略：网络自动检测、压缩、渐进图形与仅内存缓存\n安全策略：NLA；证书变化必须确认；剪贴板、磁盘、打印机、音频重定向关闭",
        asset.name,
        asset.endpoint(),
        workspace_phase_label(phase),
        format_metric_duration(snapshot.session_age),
        connected,
        resolution,
        viewport_description,
        local_scale,
        snapshot.frames_per_second,
        format_byte_count(snapshot.decoded_bytes_per_second as u64),
        snapshot.frame_count,
        snapshot.presentation_count,
        snapshot.coalesced_update_count,
        format_byte_count(snapshot.decoded_bytes),
        format_byte_count(snapshot.avoided_native_full_frame_bytes),
        format_byte_count(snapshot.canvas_allocation_bytes),
        format_byte_count(pixel_pipeline_budget),
        if input_state.focused { "在远端" } else { "不在远端" },
        match (input_state.capture_enabled, input_state.compositor_capture_granted) {
            (true, true) => "已启用（系统已授权）",
            (true, false) => "已请求（系统尚未授权）",
            (false, _) => "未启用",
        },
        if input_state.module_fullscreen { "是" } else { "否" },
        input_state.pointer_buttons_held,
        snapshot.pointer_event_count,
        snapshot.button_event_count,
        snapshot.scroll_event_count,
        snapshot.key_event_count,
        snapshot.key_press_event_count,
        snapshot.key_release_event_count,
        snapshot.text_commit_event_count,
        snapshot.locally_reserved_shortcut_count,
        snapshot.focus_enter_count,
        snapshot.focus_leave_count,
        snapshot.capture_enable_count,
        snapshot.capture_release_count,
        snapshot.modifier_safety_release_count,
        snapshot.pointer_safety_release_count,
        snapshot.rejected_input_count,
        input_to_frame,
        format_input_latency(snapshot.largest_input_to_frame),
        last_frame,
        format_metric_duration(snapshot.largest_update_gap),
        snapshot.disconnect_count,
        snapshot.recovery_count,
        attempt,
        MAX_RDP_RECONNECT_ATTEMPTS,
        last_failure,
        runtime.actual_version.as_deref().unwrap_or("不可用")
    )
}

fn present_rdp_diagnostics(context: UiContext) {
    let Some((asset_id, phase)) = context.session.borrow().active().and_then(|runtime| {
        (runtime.transport == Transport::Rdp).then_some((runtime.asset_id, runtime.phase))
    }) else {
        context
            .status
            .set_label("请先打开一个 RDP 会话以查看连接诊断。");
        return;
    };
    let Some(asset) = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned()
    else {
        return;
    };
    let attempt = context
        .rdp_reconnect_states
        .borrow()
        .get(&asset_id)
        .map(|state| state.attempt)
        .unwrap_or(0);
    let snapshot = context
        .rdp_metrics
        .borrow_mut()
        .entry(asset_id)
        .or_default()
        .snapshot_at(Instant::now());
    let viewport = (
        context.workspace.rdp_picture.width(),
        context.workspace.rdp_picture.height(),
    );
    let input_state = RdpLiveInputState {
        focused: context.workspace.rdp_picture.has_focus(),
        capture_enabled: context.rdp_input_capture.get(),
        compositor_capture_granted: rdp_compositor_capture_granted(&context),
        module_fullscreen: context.module_fullscreen.get(),
        pointer_buttons_held: context.rdp_pressed_pointer_buttons.get().count_ones(),
    };
    let report = rdp_diagnostic_report(&asset, phase, attempt, &snapshot, viewport, input_state);

    let window = gtk::Window::builder()
        .title("RDP 连接诊断")
        .transient_for(&context.window)
        .modal(true)
        .default_width(600)
        .default_height(560)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 12);
    root.set_margin_top(18);
    root.set_margin_bottom(18);
    root.set_margin_start(18);
    root.set_margin_end(18);
    let heading = gtk::Label::new(Some("连接质量与安全诊断"));
    heading.add_css_class("title-2");
    heading.set_xalign(0.0);
    let description = gtk::Label::new(Some(
        "画面更新率来自客户端渲染事件；静态桌面没有更新并不代表网络异常。",
    ));
    description.add_css_class("caption");
    description.set_xalign(0.0);
    description.set_wrap(true);
    let report_view = gtk::TextView::new();
    report_view.set_editable(false);
    report_view.set_cursor_visible(false);
    report_view.set_monospace(true);
    report_view.buffer().set_text(&report);
    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .child(&report_view)
        .build();
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let copy = gtk::Button::with_label("复制诊断");
    let close = gtk::Button::with_label("关闭");
    close.add_css_class("suggested-action");
    let report_for_copy = report.clone();
    copy.connect_clicked(move |_| {
        if let Some(display) = gtk::gdk::Display::default() {
            display.clipboard().set_text(&report_for_copy);
        }
    });
    let window_for_close = window.clone();
    close.connect_clicked(move |_| window_for_close.close());
    actions.append(&copy);
    actions.append(&close);
    root.append(&heading);
    root.append(&description);
    root.append(&scroll);
    root.append(&actions);
    window.set_child(Some(&root));
    window.present();
}

fn install_rdp_diagnostics(context: &UiContext) {
    let diagnostics_context = context.clone();
    context
        .workspace
        .rdp_diagnostics
        .connect_clicked(move |_| present_rdp_diagnostics(diagnostics_context.clone()));

    let tick_context = context.clone();
    gtk::glib::timeout_add_local(Duration::from_secs(1), move || {
        let active = tick_context.session.borrow().active().and_then(|runtime| {
            (runtime.transport == Transport::Rdp).then_some((runtime.asset_id, runtime.phase))
        });
        let Some((asset_id, phase)) = active else {
            tick_context.workspace.rdp_diagnostics.set_label("自适应");
            tick_context.workspace.rdp_diagnostics.set_sensitive(false);
            return gtk::glib::ControlFlow::Continue;
        };
        let attempt = tick_context
            .rdp_reconnect_states
            .borrow()
            .get(&asset_id)
            .map(|state| state.attempt)
            .unwrap_or(0);
        let snapshot = tick_context
            .rdp_metrics
            .borrow_mut()
            .entry(asset_id)
            .or_default()
            .snapshot_at(Instant::now());
        tick_context
            .workspace
            .rdp_diagnostics
            .set_label(&rdp_quality_button_label(phase, attempt, Some(&snapshot)));
        tick_context.workspace.rdp_diagnostics.set_sensitive(true);
        gtk::glib::ControlFlow::Continue
    });
}

fn active_connected_rdp(context: &UiContext) -> bool {
    context.session.borrow().active().is_some_and(|runtime| {
        runtime.transport == Transport::Rdp && runtime.phase == WorkspacePhase::Connected
    })
}

fn record_active_rdp_control_event(context: &UiContext, event: RdpInputControlEvent) {
    let asset_id = context
        .session
        .borrow()
        .active()
        .and_then(|runtime| (runtime.transport == Transport::Rdp).then_some(runtime.asset_id));
    if let Some(asset_id) = asset_id {
        context
            .rdp_metrics
            .borrow_mut()
            .entry(asset_id)
            .or_default()
            .record_control_event(event);
    }
}

fn release_remote_modifiers(context: &UiContext) {
    // XKB hardware codes for the modifiers that can remain logically pressed
    // if the compositor or the local release chord takes over mid-sequence.
    record_active_rdp_control_event(context, RdpInputControlEvent::ModifierSafetyRelease);
    for keycode in [37, 50, 62, 64, 105, 108, 133, 134] {
        let _ = send_rdp_key(context, keycode, false);
    }
}

fn prepare_workspace_input_handoff(context: &UiContext, next: Option<Uuid>) {
    if context.session.borrow().active_workspace_id == next {
        return;
    }
    // Release against the outgoing session BEFORE changing the registry. The
    // shared drawing area may keep focus when switching between two RDP tabs.
    // Releasing afterwards would send key/button-up to the wrong endpoint.
    release_remote_pointer_buttons(context);
    if context.rdp_input_capture.get() {
        set_rdp_system_shortcut_capture(context, false);
    } else if active_connected_rdp(context) {
        release_remote_modifiers(context);
    }
    context.rdp_last_pointer.set(None);
}

fn set_rdp_system_shortcut_capture(context: &UiContext, enabled: bool) {
    use gtk::gdk::prelude::ToplevelExt;

    let enabled = enabled && active_connected_rdp(context);
    let was_enabled = context.rdp_input_capture.replace(enabled);
    if was_enabled != enabled {
        record_active_rdp_control_event(
            context,
            if enabled {
                RdpInputControlEvent::CaptureEnabled
            } else {
                RdpInputControlEvent::CaptureReleased
            },
        );
    }
    if context.workspace.rdp_capture_shortcuts.is_active() != enabled {
        context.workspace.rdp_capture_shortcuts.set_active(enabled);
    }
    if was_enabled != enabled {
        if let Some(surface) = context.window.surface() {
            if let Ok(toplevel) = surface.downcast::<gtk::gdk::Toplevel>() {
                if enabled {
                    toplevel.inhibit_system_shortcuts(Option::<&gtk::gdk::Event>::None);
                } else {
                    toplevel.restore_system_shortcuts();
                }
            }
        }
    }
    update_rdp_capture_status(context);
    if was_enabled && !enabled {
        release_remote_modifiers(context);
    }
}

fn rdp_compositor_capture_granted(context: &UiContext) -> bool {
    use gtk::gdk::prelude::ToplevelExt;
    context
        .window
        .surface()
        .and_then(|surface| surface.downcast::<gtk::gdk::Toplevel>().ok())
        .is_some_and(|toplevel| toplevel.is_shortcuts_inhibited())
}

fn update_rdp_capture_status(context: &UiContext) {
    let requested = context.rdp_input_capture.get();
    let granted = requested && rdp_compositor_capture_granted(context);
    context.workspace.rdp_input_status.set_label(if granted {
        "快捷键已捕获"
    } else if requested {
        "等待系统授权"
    } else {
        "远端输入"
    });
    if granted {
        context.workspace.rdp_input_status.add_css_class("captured");
    } else {
        context
            .workspace
            .rdp_input_status
            .remove_css_class("captured");
    }
}

fn refresh_rdp_shortcut_capture(context: &UiContext) {
    let enabled = context.rdp_capture_policy.get().should_capture(
        context.module_fullscreen.get(),
        active_connected_rdp(context),
        context.window.is_active() && context.workspace.rdp_picture.has_focus(),
    );
    set_rdp_system_shortcut_capture(context, enabled);
}

fn set_rdp_capture_preference(context: &UiContext, enabled: bool) {
    let mut policy = context.rdp_capture_policy.get();
    policy.set_explicit(context.module_fullscreen.get(), enabled);
    context.rdp_capture_policy.set(policy);
}

fn release_rdp_capture_to_local(context: &UiContext) {
    // Keep an explicit escape suspended through focus/compositor notifications.
    // Only a deliberate desktop click or capture-button activation resumes it.
    set_rdp_capture_preference(context, false);
    set_rdp_system_shortcut_capture(context, false);
}

fn is_rdp_capture_release_shortcut(key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> bool {
    let required = gtk::gdk::ModifierType::CONTROL_MASK
        | gtk::gdk::ModifierType::ALT_MASK
        | gtk::gdk::ModifierType::SHIFT_MASK;
    let compositor_release = modifiers.intersects(
        gtk::gdk::ModifierType::SUPER_MASK
            | gtk::gdk::ModifierType::META_MASK
            | gtk::gdk::ModifierType::HYPER_MASK,
    );
    key == gtk::gdk::Key::Escape && (modifiers.contains(required) || compositor_release)
}

fn rdp_key_event_allows_local_ime(modifiers: gtk::gdk::ModifierType) -> bool {
    !modifiers.intersects(
        gtk::gdk::ModifierType::CONTROL_MASK
            | gtk::gdk::ModifierType::ALT_MASK
            | gtk::gdk::ModifierType::SUPER_MASK
            | gtk::gdk::ModifierType::META_MASK
            | gtk::gdk::ModifierType::HYPER_MASK,
    )
}

fn rdp_surface_reserves_local_key(
    module_fullscreen: bool,
    key: gtk::gdk::Key,
    modifiers: gtk::gdk::ModifierType,
) -> bool {
    is_rdp_capture_release_shortcut(key, modifiers)
        || (module_fullscreen
            && key == gtk::gdk::Key::F11
            && !modifiers.intersects(
                gtk::gdk::ModifierType::CONTROL_MASK
                    | gtk::gdk::ModifierType::SHIFT_MASK
                    | gtk::gdk::ModifierType::ALT_MASK
                    | gtk::gdk::ModifierType::SUPER_MASK
                    | gtk::gdk::ModifierType::META_MASK
                    | gtk::gdk::ModifierType::HYPER_MASK,
            ))
}

fn shortcut_routing_layer(
    rdp_connected: bool,
    rdp_focused: bool,
    rdp_system_capture: bool,
    module_fullscreen: bool,
    key: gtk::gdk::Key,
    modifiers: gtk::gdk::ModifierType,
) -> ShortcutRoutingLayer {
    if rdp_connected && rdp_focused && is_rdp_capture_release_shortcut(key, modifiers) {
        return ShortcutRoutingLayer::Application;
    }
    if module_fullscreen
        && key == gtk::gdk::Key::F11
        && !modifiers.intersects(
            gtk::gdk::ModifierType::CONTROL_MASK
                | gtk::gdk::ModifierType::SHIFT_MASK
                | gtk::gdk::ModifierType::ALT_MASK
                | gtk::gdk::ModifierType::SUPER_MASK
                | gtk::gdk::ModifierType::META_MASK
                | gtk::gdk::ModifierType::HYPER_MASK,
        )
    {
        // Once OrbitTerm owns the whole screen, F11 must remain a reliable
        // escape hatch even if the RDP picture regained keyboard focus.
        return ShortcutRoutingLayer::Application;
    }
    let system = modifiers.intersects(
        gtk::gdk::ModifierType::SUPER_MASK
            | gtk::gdk::ModifierType::META_MASK
            | gtk::gdk::ModifierType::HYPER_MASK,
    );
    if rdp_connected && rdp_focused && (rdp_system_capture || !system) {
        return ShortcutRoutingLayer::RemoteDesktop;
    }
    if system {
        return ShortcutRoutingLayer::LocalSystem;
    }
    if workstation_shortcut_action(key, modifiers).is_some() {
        ShortcutRoutingLayer::Application
    } else {
        ShortcutRoutingLayer::FocusedWidget
    }
}

fn rdp_controls_presentation(fullscreen: bool, expanded: bool) -> (bool, bool) {
    (fullscreen, !fullscreen || expanded)
}

fn set_rdp_controls_expanded(context: &UiContext, expanded: bool) {
    let fullscreen = context.module_fullscreen.get();
    let (handle_visible, controls_visible) = rdp_controls_presentation(fullscreen, expanded);
    let toggle = &context.workspace.rdp_controls_toggle;
    let active = fullscreen && expanded;
    if toggle.is_active() != active {
        toggle.set_active(active);
    }
    toggle.set_label(if active {
        "收起工具 ▴"
    } else {
        "显示工具 ▾"
    });
    toggle.set_visible(handle_visible);
    context.workspace.rdp_controls.set_halign(if fullscreen {
        Align::Center
    } else {
        Align::End
    });
    context
        .workspace
        .rdp_controls
        .set_margin_top(if fullscreen { 42 } else { 10 });
    context
        .workspace
        .rdp_controls
        .set_margin_end(if fullscreen { 0 } else { 10 });
    context.workspace.rdp_controls.set_visible(controls_visible);
}

fn reveal_rdp_fullscreen_controls(context: &UiContext) {
    if !context.module_fullscreen.get() || !active_connected_rdp(context) {
        return;
    }
    set_rdp_controls_expanded(context, true);
}

fn send_rdp_secure_attention(context: &UiContext) -> bool {
    // Left Control + Left Alt + Delete using XKB hardware codes. The explicit
    // action is reliable even when a desktop compositor reserves the same
    // local sequence and never exposes it to the application.
    let mut sent = true;
    for keycode in [37, 64, 119] {
        sent &= send_rdp_key(context, keycode, true);
    }
    for keycode in [119, 64, 37] {
        sent &= send_rdp_key(context, keycode, false);
    }
    sent
}

fn install_rdp_input(context: &UiContext) {
    let im_context = gtk::IMMulticontext::new();
    let ime_consumed_keycodes = Rc::new(RefCell::new(HashSet::<u32>::new()));
    im_context.set_client_widget(Some(&context.workspace.rdp_picture));
    let commit_context = context.clone();
    im_context.connect_commit(move |_, text| {
        if !send_rdp_text(&commit_context, text) {
            commit_context
                .status
                .set_label("远端组合文本未发送：RDP 会话尚未连接。");
        }
    });

    let motion = gtk::EventControllerMotion::new();
    let motion_context = context.clone();
    motion.connect_motion(move |_, x, y| {
        send_rdp_pointer(&motion_context, RDP_PTR_MOVE, x, y);
    });
    context.workspace.rdp_picture.add_controller(motion);

    let click = gtk::GestureClick::new();
    click.set_button(0);
    let press_context = context.clone();
    let press_im_context = im_context.clone();
    click.connect_pressed(move |gesture, _, x, y| {
        press_context.workspace.rdp_picture.grab_focus();
        press_im_context.focus_in();
        press_im_context.set_cursor_location(&gtk::gdk::Rectangle::new(
            x.round() as i32,
            y.round() as i32,
            1,
            1,
        ));
        if press_context.module_fullscreen.get() {
            set_rdp_capture_preference(&press_context, true);
        }
        refresh_rdp_shortcut_capture(&press_context);
        let button = match gesture.current_button() {
            1 => RDP_PTR_LEFT,
            2 => RDP_PTR_MIDDLE,
            3 => RDP_PTR_RIGHT,
            _ => return,
        };
        press_context
            .rdp_pressed_pointer_buttons
            .set(press_context.rdp_pressed_pointer_buttons.get() | button);
        send_rdp_pointer(&press_context, RDP_PTR_DOWN | button, x, y);
    });
    let release_context = context.clone();
    click.connect_released(move |gesture, _, x, y| {
        let button = match gesture.current_button() {
            1 => RDP_PTR_LEFT,
            2 => RDP_PTR_MIDDLE,
            3 => RDP_PTR_RIGHT,
            _ => return,
        };
        release_context
            .rdp_pressed_pointer_buttons
            .set(release_context.rdp_pressed_pointer_buttons.get() & !button);
        send_rdp_pointer(&release_context, button, x, y);
    });
    context.workspace.rdp_picture.add_controller(click);

    let scroll = gtk::EventControllerScroll::new(
        gtk::EventControllerScrollFlags::BOTH_AXES | gtk::EventControllerScrollFlags::DISCRETE,
    );
    let scroll_context = context.clone();
    scroll.connect_scroll(move |_, dx, dy| {
        let vertical = rdp_scroll_pointer_flags(dy, false)
            .is_some_and(|flags| send_rdp_pointer_at_last(&scroll_context, flags));
        let horizontal = rdp_scroll_pointer_flags(dx, true)
            .is_some_and(|flags| send_rdp_pointer_at_last(&scroll_context, flags));
        if vertical || horizontal {
            gtk::glib::Propagation::Stop
        } else {
            gtk::glib::Propagation::Proceed
        }
    });
    context.workspace.rdp_picture.add_controller(scroll);

    let keys = gtk::EventControllerKey::new();
    let key_press_context = context.clone();
    let key_press_im_context = im_context.clone();
    let key_press_consumed = Rc::clone(&ime_consumed_keycodes);
    keys.connect_key_pressed(move |controller, key, keycode, modifiers| {
        // The window capture controller normally owns these escape hatches,
        // but some Wayland/compositor paths deliver a focused drawing-area
        // event directly to this controller. Reserve them again at the RDP
        // surface boundary so they can never be forwarded to FreeRDP.
        if rdp_surface_reserves_local_key(key_press_context.module_fullscreen.get(), key, modifiers)
        {
            record_active_rdp_control_event(
                &key_press_context,
                RdpInputControlEvent::LocallyReservedShortcut,
            );
            key_press_consumed.borrow_mut().insert(keycode);
            if is_rdp_capture_release_shortcut(key, modifiers) {
                release_rdp_capture_to_local(&key_press_context);
                reveal_rdp_fullscreen_controls(&key_press_context);
                key_press_context
                    .workspace
                    .rdp_capture_shortcuts
                    .grab_focus();
                key_press_context.status.set_label(
                    "远端输入已释放到本机；顶部控制条已显示，单击远程桌面可继续远端输入。",
                );
            } else {
                toggle_module_fullscreen(&key_press_context);
            }
            return gtk::glib::Propagation::Stop;
        }
        if rdp_key_event_allows_local_ime(modifiers)
            && controller
                .current_event()
                .is_some_and(|event| key_press_im_context.filter_keypress(&event))
        {
            key_press_consumed.borrow_mut().insert(keycode);
            return gtk::glib::Propagation::Stop;
        }
        if send_rdp_key(&key_press_context, keycode, true) {
            gtk::glib::Propagation::Stop
        } else {
            gtk::glib::Propagation::Proceed
        }
    });
    let key_release_context = context.clone();
    let key_release_im_context = im_context.clone();
    let key_release_consumed = Rc::clone(&ime_consumed_keycodes);
    keys.connect_key_released(move |controller, _, keycode, modifiers| {
        if key_release_consumed.borrow_mut().remove(&keycode) {
            if rdp_key_event_allows_local_ime(modifiers) {
                let _ = controller
                    .current_event()
                    .is_some_and(|event| key_release_im_context.filter_keypress(&event));
            }
            return;
        }
        if rdp_key_event_allows_local_ime(modifiers)
            && controller
                .current_event()
                .is_some_and(|event| key_release_im_context.filter_keypress(&event))
        {
            return;
        }
        let _ = send_rdp_key(&key_release_context, keycode, false);
    });
    context.workspace.rdp_picture.add_controller(keys);

    let focus = gtk::EventControllerFocus::new();
    let focus_enter_context = context.clone();
    let focus_enter_im_context = im_context.clone();
    focus.connect_enter(move |_| {
        record_active_rdp_control_event(&focus_enter_context, RdpInputControlEvent::FocusEnter);
        focus_enter_im_context.focus_in();
        refresh_rdp_shortcut_capture(&focus_enter_context);
    });
    let focus_context = context.clone();
    let focus_leave_im_context = im_context;
    let focus_leave_consumed = ime_consumed_keycodes;
    focus.connect_leave(move |_| {
        record_active_rdp_control_event(&focus_context, RdpInputControlEvent::FocusLeave);
        focus_leave_consumed.borrow_mut().clear();
        focus_leave_im_context.reset();
        focus_leave_im_context.focus_out();
        release_remote_pointer_buttons(&focus_context);
        if focus_context.rdp_input_capture.get() {
            set_rdp_system_shortcut_capture(&focus_context, false);
            focus_context
                .status
                .set_label("焦点已离开远程桌面：系统快捷键已归还本机，远端修饰键状态已释放。");
        } else {
            release_remote_modifiers(&focus_context);
        }
    });
    context.workspace.rdp_picture.add_controller(focus);

    // EventControllerFocus::enter tracks the widget hierarchy and can precede
    // has-focus becoming true. Observe the actual keyboard-focus property too,
    // otherwise collapsing a local toolbar can leave capture disabled even
    // though the canvas subsequently receives ordinary keyboard input.
    let keyboard_focus_context = context.clone();
    context
        .workspace
        .rdp_picture
        .connect_has_focus_notify(move |_| {
            refresh_rdp_shortcut_capture(&keyboard_focus_context);
        });

    // Widget focus can survive the toplevel becoming inactive (dialogs or
    // another local application). Never keep a global capture in that state.
    let active_context = context.clone();
    context.window.connect_is_active_notify(move |window| {
        if !window.is_active() {
            release_remote_pointer_buttons(&active_context);
        }
        refresh_rdp_shortcut_capture(&active_context);
    });
    let realized_context = context.clone();
    context.window.connect_realize(move |window| {
        use gtk::gdk::prelude::ToplevelExt;
        if let Some(toplevel) = window
            .surface()
            .and_then(|surface| surface.downcast::<gtk::gdk::Toplevel>().ok())
        {
            let granted_context = realized_context.clone();
            toplevel.connect_shortcuts_inhibited_notify(move |toplevel| {
                if !toplevel.is_shortcuts_inhibited() && granted_context.rdp_input_capture.get() {
                    // A compositor may deactivate inhibition while moving focus.
                    // Let focus notifications settle before distinguishing that
                    // temporary change from an explicit revocation (Super+Esc).
                    let revoked_context = granted_context.clone();
                    gtk::glib::idle_add_local_once(move || {
                        if revoked_context.rdp_input_capture.get()
                            && !rdp_compositor_capture_granted(&revoked_context)
                            && revoked_context.window.is_active()
                            && revoked_context.workspace.rdp_picture.has_focus()
                        {
                            release_rdp_capture_to_local(&revoked_context);
                            reveal_rdp_fullscreen_controls(&revoked_context);
                            revoked_context.workspace.rdp_capture_shortcuts.grab_focus();
                        }
                    });
                }
                update_rdp_capture_status(&granted_context);
            });
        }
    });

    let toggle_context = context.clone();
    context
        .workspace
        .rdp_controls_toggle
        .connect_toggled(move |button| {
            set_rdp_controls_expanded(&toggle_context, button.is_active());
            // Keep keyboard input on the desktop after explicitly hiding tools.
            if toggle_context.module_fullscreen.get() && !button.is_active() {
                toggle_context.workspace.rdp_picture.grab_focus();
                refresh_rdp_shortcut_capture(&toggle_context);
            }
        });

    let capture_context = context.clone();
    context
        .workspace
        .rdp_capture_shortcuts
        .connect_toggled(move |button| {
            // Programmatic state reflection must not overwrite the user's
            // preference, request focus, or recursively reacquire a capture.
            if button.is_active() == capture_context.rdp_input_capture.get() {
                return;
            }
            set_rdp_capture_preference(&capture_context, button.is_active());
            if button.is_active() {
                capture_context.workspace.rdp_picture.grab_focus();
                capture_context.status.set_label(
                    "已请求远端快捷键捕获；Ctrl+Alt+Shift+Esc 或 Super+Esc 可随时释放到本机。",
                );
            } else {
                capture_context
                    .status
                    .set_label("远端快捷键捕获已关闭；组合键仍会在远程桌面聚焦时优先发往远端。");
            }
            refresh_rdp_shortcut_capture(&capture_context);
        });

    let secure_context = context.clone();
    context
        .workspace
        .rdp_secure_attention
        .connect_clicked(move |_| {
            secure_context.workspace.rdp_picture.grab_focus();
            secure_context
                .status
                .set_label(if send_rdp_secure_attention(&secure_context) {
                    "已向远端发送 Ctrl+Alt+Delete。"
                } else {
                    "Ctrl+Alt+Delete 发送失败：RDP 会话尚未连接。"
                });
        });
}

fn module_fullscreen_available(transport: Transport, phase: WorkspacePhase) -> bool {
    matches!(
        transport,
        Transport::Ssh | Transport::Telnet | Transport::Rdp
    ) && phase == WorkspacePhase::Connected
}

fn update_module_fullscreen_buttons(context: &UiContext, active: bool) {
    if active {
        context.workspace.terminal_fullscreen.set_label("退出全屏");
        context
            .workspace
            .terminal_fullscreen
            .set_icon_name("view-restore-symbolic");
        context
            .workspace
            .terminal_fullscreen
            .set_tooltip_text(Some("退出终端模块全屏"));
        context
            .workspace
            .terminal_fullscreen
            .set_halign(Align::Center);
        context.workspace.terminal_fullscreen.set_margin_end(0);
        context.workspace.rdp_fullscreen.set_label("退出全屏");
        context
            .workspace
            .rdp_fullscreen
            .set_icon_name("view-restore-symbolic");
        context
            .workspace
            .rdp_fullscreen
            .set_tooltip_text(Some("退出远程桌面模块全屏"));
    } else {
        context.workspace.terminal_fullscreen.set_label("终端全屏");
        context
            .workspace
            .terminal_fullscreen
            .set_icon_name("view-fullscreen-symbolic");
        context
            .workspace
            .terminal_fullscreen
            .set_tooltip_text(Some("让当前终端模块占满屏幕"));
        context.workspace.terminal_fullscreen.set_halign(Align::End);
        context.workspace.terminal_fullscreen.set_margin_end(18);
        context.workspace.rdp_fullscreen.set_label("RDP 全屏");
        context
            .workspace
            .rdp_fullscreen
            .set_icon_name("view-fullscreen-symbolic");
        context
            .workspace
            .rdp_fullscreen
            .set_tooltip_text(Some("让远程桌面模块占满屏幕"));
    }
}

fn enter_module_fullscreen(context: &UiContext) {
    if context.module_fullscreen.get() {
        return;
    }
    let Some((transport, phase, active_pane)) = context.session.borrow().active().map(|runtime| {
        (
            runtime.transport,
            runtime.phase,
            runtime.active_terminal_pane,
        )
    }) else {
        context.status.set_label("请先连接终端或 RDP 资产。");
        return;
    };
    if !module_fullscreen_available(transport, phase) {
        context.status.set_label("会话连接成功后才能进入模块全屏。");
        return;
    }
    let Some(shell) = context.module_shell.borrow().clone() else {
        context.status.set_label("模块全屏工作台尚未准备完成。");
        return;
    };
    let Some(sidebar) = context.sidebar.borrow().clone() else {
        return;
    };
    let restore = ModuleFullscreenRestore {
        window_was_fullscreen: context.window.is_fullscreen(),
        header_visible: shell.header.is_visible(),
        monitor_visible: context.workspace.monitor_band.is_visible(),
        tabs_visible: context.workspace.tabs.is_visible(),
        sidebar_visible: sidebar.root.is_visible(),
        footer_visible: sidebar.footer.is_visible(),
        tools_visible: context.tools.root.is_visible(),
        input_visible: context.workspace.input_row.is_visible(),
        rdp_security_visible: context.workspace.rdp_security_bar.is_visible(),
        expand_left_visible: shell.expand_left.is_visible(),
        expand_right_visible: shell.expand_right.is_visible(),
    };
    context.module_fullscreen_restore.replace(Some(restore));
    context.module_fullscreen.set(true);
    let mut capture_policy = context.rdp_capture_policy.get();
    capture_policy.fullscreen_suspended = false;
    context.rdp_capture_policy.set(capture_policy);

    shell.header.set_visible(false);
    context.workspace.monitor_band.set_visible(false);
    context.workspace.tabs.set_visible(false);
    sidebar.root.set_visible(false);
    sidebar.footer.set_visible(false);
    context.tools.root.set_visible(false);
    context.workspace.input_row.set_visible(false);
    context.workspace.rdp_security_bar.set_visible(false);
    shell.expand_left.set_visible(false);
    shell.expand_right.set_visible(false);
    update_module_fullscreen_buttons(context, true);
    if !restore.window_was_fullscreen {
        context.window.fullscreen();
    }

    match transport {
        Transport::Rdp => {
            context.workspace.rdp_picture.grab_focus();
            set_rdp_controls_expanded(context, false);
            refresh_rdp_shortcut_capture(context);
            context.status.set_label(
                "远程桌面已全屏并自动请求快捷键捕获；F11 退出全屏，Ctrl+Alt+Shift+Esc 释放到本机。",
            );
        }
        Transport::Ssh | Transport::Telnet => {
            if let Some(terminal) = context.workspace.terminals.get(active_pane) {
                terminal.grab_focus();
            }
            context
                .status
                .set_label("终端模块已全屏；顶部中央按钮或 F11 可恢复工作台。");
        }
    }
}

fn exit_module_fullscreen(context: &UiContext) {
    if !context.module_fullscreen.replace(false) {
        return;
    }
    set_rdp_system_shortcut_capture(context, false);
    let Some(restore) = context.module_fullscreen_restore.borrow_mut().take() else {
        update_module_fullscreen_buttons(context, false);
        return;
    };
    let Some(shell) = context.module_shell.borrow().clone() else {
        return;
    };
    let Some(sidebar) = context.sidebar.borrow().clone() else {
        return;
    };
    shell.header.set_visible(restore.header_visible);
    context
        .workspace
        .monitor_band
        .set_visible(restore.monitor_visible);
    context.workspace.tabs.set_visible(restore.tabs_visible);
    sidebar.root.set_visible(restore.sidebar_visible);
    sidebar.footer.set_visible(restore.footer_visible);
    context.tools.root.set_visible(restore.tools_visible);
    context
        .workspace
        .input_row
        .set_visible(restore.input_visible);
    context
        .workspace
        .rdp_security_bar
        .set_visible(restore.rdp_security_visible);
    shell.expand_left.set_visible(restore.expand_left_visible);
    shell.expand_right.set_visible(restore.expand_right_visible);
    set_rdp_controls_expanded(context, false);
    update_module_fullscreen_buttons(context, false);
    if !restore.window_was_fullscreen {
        context.window.unfullscreen();
    }

    // Keep the RefCell borrow strictly outside focus restoration. Calling
    // grab_focus() emits the terminal focus controller synchronously, and that
    // callback updates the active pane through a mutable session borrow.
    // Holding this immutable borrow across grab_focus() therefore aborts the
    // GTK process with `RefCell already borrowed`.
    let active_terminal = {
        let registry = context.session.borrow();
        registry
            .active()
            .map(|runtime| (runtime.transport, runtime.active_terminal_pane))
    };
    if let Some((transport, pane)) = active_terminal {
        match transport {
            Transport::Rdp => {
                context.workspace.rdp_picture.grab_focus();
            }
            Transport::Ssh | Transport::Telnet => {
                if let Some(terminal) = context.workspace.terminals.get(pane) {
                    terminal.grab_focus();
                }
            }
        }
    }
    context
        .status
        .set_label("已退出模块全屏并恢复原工作台布局。");
    refresh_rdp_shortcut_capture(context);
}

fn toggle_module_fullscreen(context: &UiContext) {
    if context.module_fullscreen.get() {
        exit_module_fullscreen(context);
    } else {
        enter_module_fullscreen(context);
    }
}

fn close_request_is_suppressed(deadline: Option<Instant>, now: Instant) -> bool {
    deadline.is_some_and(|deadline| now < deadline)
}

fn module_fullscreen_button_available_for(
    transport: Transport,
    phase: WorkspacePhase,
    rdp_button: bool,
) -> bool {
    module_fullscreen_available(transport, phase) && (rdp_button == (transport == Transport::Rdp))
}

fn module_fullscreen_button_available(context: &UiContext, rdp_button: bool) -> bool {
    context.session.borrow().active().is_some_and(|runtime| {
        module_fullscreen_button_available_for(runtime.transport, runtime.phase, rdp_button)
    })
}

fn toggle_module_fullscreen_from_pointer(
    context: UiContext,
    trigger: gtk::Button,
    rdp_button: bool,
) {
    if !context.module_fullscreen.get() {
        enter_module_fullscreen(&context);
        return;
    }

    // The terminal restore control is deliberately centred while fullscreen,
    // away from the title-bar close button revealed after restoration. The
    // close-request guard is a second line of defence for touchpads/compositors
    // that replay a release gesture after the fullscreen surface is removed.
    trigger.set_sensitive(false);
    if !rdp_button {
        trigger.set_visible(false);
        context
            .suppress_close_until
            .set(Some(Instant::now() + Duration::from_millis(1_200)));
    }
    gtk::glib::timeout_add_local_once(Duration::from_millis(220), move || {
        exit_module_fullscreen(&context);
        trigger.set_visible(true);
        trigger.set_sensitive(module_fullscreen_button_available(&context, rdp_button));
    });
}

fn install_module_fullscreen_controls(context: &UiContext) {
    let terminal_context = context.clone();
    context
        .workspace
        .terminal_fullscreen
        .connect_clicked(move |button| {
            toggle_module_fullscreen_from_pointer(terminal_context.clone(), button.clone(), false)
        });
    let rdp_context = context.clone();
    context
        .workspace
        .rdp_fullscreen
        .connect_clicked(move |button| {
            toggle_module_fullscreen_from_pointer(rdp_context.clone(), button.clone(), true)
        });
    update_module_fullscreen_buttons(context, false);
}

fn rdp_pointer_input_kind(flags: u16) -> RdpInputKind {
    if flags & (RDP_PTR_WHEEL | RDP_PTR_HWHEEL) != 0 {
        RdpInputKind::Scroll
    } else if flags & RDP_PTR_MOVE != 0 {
        RdpInputKind::Pointer
    } else {
        RdpInputKind::Button
    }
}

fn record_rdp_input(context: &UiContext, asset_id: Uuid, kind: RdpInputKind, accepted: bool) {
    context
        .rdp_metrics
        .borrow_mut()
        .entry(asset_id)
        .or_default()
        .record_input_at(Instant::now(), kind, accepted);
}

fn send_rdp_pointer(context: &UiContext, flags: u16, x: f64, y: f64) -> bool {
    let picture_width = f64::from(context.workspace.rdp_picture.width());
    let picture_height = f64::from(context.workspace.rdp_picture.height());
    let kind = rdp_pointer_input_kind(flags);
    let (asset_id, accepted, position) = {
        let registry = context.session.borrow();
        let Some(runtime) = registry.active().filter(|runtime| {
            runtime.transport == Transport::Rdp && runtime.phase == WorkspacePhase::Connected
        }) else {
            return false;
        };
        let (Some(session), Some((frame_width, frame_height))) =
            (runtime.rdp.as_ref(), runtime.rdp_frame_size)
        else {
            return false;
        };
        let Some((remote_x, remote_y)) = rdp_pointer_coordinates(
            picture_width,
            picture_height,
            frame_width,
            frame_height,
            x,
            y,
        ) else {
            record_rdp_input(context, runtime.asset_id, kind, false);
            return false;
        };
        (
            runtime.asset_id,
            session.pointer(flags, remote_x, remote_y).is_ok(),
            (remote_x, remote_y),
        )
    };
    if accepted {
        context.rdp_last_pointer.set(Some(position));
    }
    record_rdp_input(context, asset_id, kind, accepted);
    accepted
}

fn send_rdp_pointer_at_last(context: &UiContext, flags: u16) -> bool {
    let registry = context.session.borrow();
    let Some(runtime) = registry.active().filter(|runtime| {
        runtime.transport == Transport::Rdp && runtime.phase == WorkspacePhase::Connected
    }) else {
        return false;
    };
    let Some(session) = runtime.rdp.as_ref() else {
        return false;
    };
    let position = context.rdp_last_pointer.get().or_else(|| {
        runtime.rdp_frame_size.map(|(width, height)| {
            (
                u16::try_from(width.saturating_sub(1) / 2).unwrap_or(u16::MAX),
                u16::try_from(height.saturating_sub(1) / 2).unwrap_or(u16::MAX),
            )
        })
    });
    let Some((x, y)) = position else {
        record_rdp_input(
            context,
            runtime.asset_id,
            rdp_pointer_input_kind(flags),
            false,
        );
        return false;
    };
    let asset_id = runtime.asset_id;
    let accepted = session.pointer(flags, x, y).is_ok();
    drop(registry);
    record_rdp_input(context, asset_id, rdp_pointer_input_kind(flags), accepted);
    accepted
}

fn release_remote_pointer_buttons(context: &UiContext) {
    let pressed = context.rdp_pressed_pointer_buttons.replace(0);
    if pressed != 0 {
        record_active_rdp_control_event(context, RdpInputControlEvent::PointerSafetyRelease);
    }
    for button in [RDP_PTR_LEFT, RDP_PTR_MIDDLE, RDP_PTR_RIGHT] {
        if pressed & button != 0 {
            let _ = send_rdp_pointer_at_last(context, button);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct RdpViewportGeometry {
    scale: f64,
    content_width: f64,
    content_height: f64,
    offset_x: f64,
    offset_y: f64,
}

fn rdp_viewport_geometry(
    viewport_width: f64,
    viewport_height: f64,
    frame_width: u32,
    frame_height: u32,
) -> Option<RdpViewportGeometry> {
    if viewport_width <= 0.0
        || viewport_height <= 0.0
        || !viewport_width.is_finite()
        || !viewport_height.is_finite()
        || frame_width == 0
        || frame_height == 0
    {
        return None;
    }
    let frame_width = f64::from(frame_width);
    let frame_height = f64::from(frame_height);
    let scale = (viewport_width / frame_width).min(viewport_height / frame_height);
    if !scale.is_finite() || scale <= 0.0 {
        return None;
    }
    let content_width = frame_width * scale;
    let content_height = frame_height * scale;
    Some(RdpViewportGeometry {
        scale,
        content_width,
        content_height,
        offset_x: (viewport_width - content_width) / 2.0,
        offset_y: (viewport_height - content_height) / 2.0,
    })
}

fn rdp_pointer_coordinates(
    picture_width: f64,
    picture_height: f64,
    frame_width: u32,
    frame_height: u32,
    x: f64,
    y: f64,
) -> Option<(u16, u16)> {
    if !x.is_finite() || !y.is_finite() {
        return None;
    }
    let geometry = rdp_viewport_geometry(picture_width, picture_height, frame_width, frame_height)?;
    let frame_width_f = f64::from(frame_width);
    let frame_height_f = f64::from(frame_height);
    if x < geometry.offset_x
        || y < geometry.offset_y
        || x >= geometry.offset_x + geometry.content_width
        || y >= geometry.offset_y + geometry.content_height
    {
        return None;
    }
    let remote_x =
        ((x - geometry.offset_x) / geometry.scale).clamp(0.0, frame_width_f - 1.0) as u16;
    let remote_y =
        ((y - geometry.offset_y) / geometry.scale).clamp(0.0, frame_height_f - 1.0) as u16;
    Some((remote_x, remote_y))
}

fn send_rdp_key(context: &UiContext, hardware_keycode: u32, down: bool) -> bool {
    let outcome = {
        let registry = context.session.borrow();
        registry
            .active()
            .filter(|runtime| {
                runtime.transport == Transport::Rdp && runtime.phase == WorkspacePhase::Connected
            })
            .and_then(|runtime| {
                runtime.rdp.as_ref().map(|session| {
                    (
                        runtime.asset_id,
                        session.keycode(hardware_keycode, down).is_ok(),
                    )
                })
            })
    };
    let Some((asset_id, accepted)) = outcome else {
        return false;
    };
    record_rdp_input(
        context,
        asset_id,
        if down {
            RdpInputKind::KeyPress
        } else {
            RdpInputKind::KeyRelease
        },
        accepted,
    );
    accepted
}

fn send_rdp_text(context: &UiContext, text: &str) -> bool {
    let outcome = {
        let registry = context.session.borrow();
        registry
            .active()
            .filter(|runtime| {
                runtime.transport == Transport::Rdp && runtime.phase == WorkspacePhase::Connected
            })
            .and_then(|runtime| {
                runtime
                    .rdp
                    .as_ref()
                    .map(|session| (runtime.asset_id, session.unicode_text(text).is_ok()))
            })
    };
    let Some((asset_id, accepted)) = outcome else {
        return false;
    };
    // Record only the input category and outcome. The composed text may
    // contain credentials and must never enter diagnostics or persistence.
    record_rdp_input(context, asset_id, RdpInputKind::TextCommit, accepted);
    accepted
}

fn refresh_asset_list(
    list: &gtk::ListBox,
    stack: &gtk::Stack,
    catalog: &Catalog,
    query: &str,
    ids: &Rc<RefCell<Vec<Option<Uuid>>>>,
    asset_count: &gtk::Label,
) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
    ids.borrow_mut().clear();
    let filtered = catalog.filtered(query);
    asset_count.set_label(&format!("{} 台", filtered.len()));
    if filtered.is_empty() {
        stack.set_visible_child_name("empty");
        return;
    }

    let mut groups = BTreeMap::<String, Vec<&ServerAsset>>::new();
    for asset in filtered {
        let group = if asset.group.trim().is_empty() {
            "未分组".to_owned()
        } else {
            asset.group.trim().to_owned()
        };
        groups.entry(group).or_default().push(asset);
    }

    for (group, assets) in groups {
        let header_row = gtk::ListBoxRow::new();
        header_row.set_activatable(false);
        header_row.set_selectable(false);
        header_row.add_css_class("asset-group-row");
        let header = gtk::Button::new();
        header.add_css_class("flat");
        header.add_css_class("asset-group-header");
        header.set_tooltip_text(Some("展开或收起资产分组"));
        let header_body = gtk::Box::new(Orientation::Horizontal, 7);
        let disclosure = gtk::Image::from_icon_name("pan-end-symbolic");
        let group_label = gtk::Label::new(Some(&group));
        group_label.set_xalign(0.0);
        group_label.set_hexpand(true);
        let count = gtk::Label::new(Some(&assets.len().to_string()));
        count.add_css_class("asset-group-count");
        header_body.append(&disclosure);
        header_body.append(&group_label);
        header_body.append(&count);
        header.set_child(Some(&header_body));
        header_row.set_child(Some(&header));
        list.append(&header_row);
        ids.borrow_mut().push(None);

        let mut group_rows = Vec::new();
        for asset in assets {
            ids.borrow_mut().push(Some(asset.id));
            let row = gtk::ListBoxRow::new();
            row.set_activatable(true);
            row.set_visible(false);
            row.add_css_class("asset-row");
            let body = gtk::Box::new(Orientation::Horizontal, 9);
            let dot = gtk::Label::new(Some("●"));
            dot.add_css_class("status-idle");
            dot.add_css_class("asset-status-dot");
            let details = gtk::Box::new(Orientation::Vertical, 3);
            details.set_hexpand(true);
            let title_line = gtk::Box::new(Orientation::Horizontal, 6);
            let name = gtk::Label::new(Some(&asset.name));
            name.set_xalign(0.0);
            name.set_hexpand(true);
            name.set_ellipsize(gtk::pango::EllipsizeMode::End);
            let transport = gtk::Label::new(Some(asset.transport.display_name()));
            transport.add_css_class("transport-badge");
            transport.add_css_class(match asset.transport {
                Transport::Ssh => "transport-ssh",
                Transport::Telnet => "transport-telnet",
                Transport::Rdp => "transport-rdp",
            });
            title_line.append(&name);
            title_line.append(&transport);
            let endpoint = gtk::Label::new(Some(&asset.endpoint()));
            endpoint.add_css_class("caption");
            endpoint.set_xalign(0.0);
            endpoint.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            details.append(&title_line);
            details.append(&endpoint);
            if !asset.tags.is_empty() {
                let tags = gtk::Label::new(Some(&asset.tags.join(" · ")));
                tags.add_css_class("asset-tags");
                tags.set_xalign(0.0);
                tags.set_ellipsize(gtk::pango::EllipsizeMode::End);
                details.append(&tags);
            }
            body.append(&dot);
            body.append(&details);
            row.set_child(Some(&body));
            list.append(&row);
            group_rows.push(row);
        }

        let collapsed = Rc::new(Cell::new(true));
        let rows_for_toggle = Rc::new(group_rows);
        let disclosure_for_toggle = disclosure.clone();
        header.connect_clicked(move |_| {
            let hide = !collapsed.get();
            collapsed.set(hide);
            disclosure_for_toggle.set_icon_name(Some(if hide {
                "pan-end-symbolic"
            } else {
                "pan-down-symbolic"
            }));
            for row in rows_for_toggle.iter() {
                row.set_visible(!hide);
            }
        });
    }
    stack.set_visible_child_name("assets");
}

fn begin_connect(context: UiContext, asset_id: Uuid) {
    cancel_rdp_auto_reconnect(&context, asset_id);
    let is_rdp = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .any(|asset| asset.id == asset_id && asset.transport == Transport::Rdp);
    if is_rdp {
        context
            .rdp_metrics
            .borrow_mut()
            .insert(asset_id, RdpSessionMetrics::default());
    }
    begin_connect_internal(context, asset_id, true);
}

fn begin_connect_internal(context: UiContext, asset_id: Uuid, activate: bool) {
    let asset = {
        let catalog = context.catalog.borrow();
        catalog
            .assets()
            .iter()
            .find(|asset| asset.id == asset_id)
            .cloned()
    };
    let Some(asset) = asset else {
        context.status.set_label("所选资产已不存在，请重新选择。");
        return;
    };
    if activate {
        if context.module_fullscreen.get()
            && context.session.borrow().active_workspace_id != Some(asset_id)
        {
            exit_module_fullscreen(&context);
        }
        prepare_workspace_input_handoff(&context, Some(asset_id));
    }
    let render_current;
    {
        let mut registry = context.session.borrow_mut();
        if let Some(runtime) = registry.sessions.get(&asset_id) {
            if !workspace_phase_accepts_connect_start(runtime.phase) {
                let render_current = registry.select_for_connect(asset_id, activate);
                drop(registry);
                if render_current {
                    render_active_workspace(&context);
                }
                refresh_session_tabs(&context);
                return;
            }
        }
        let previous = registry.sessions.remove(&asset_id);
        registry.sessions.insert(
            asset_id,
            SessionRuntime::replacing_for_connect(&asset, previous),
        );
        render_current = registry.select_for_connect(asset_id, activate);
    }
    refresh_session_tabs(&context);
    if render_current {
        render_active_workspace(&context);
    }
    match asset.transport {
        Transport::Ssh => begin_ssh_connect(context, asset),
        Transport::Telnet => prompt_telnet_risk(context, asset),
        Transport::Rdp => begin_rdp_connect(context, asset),
    }
}

fn begin_ssh_connect(context: UiContext, asset: ServerAsset) {
    let asset_id = asset.id;
    set_session_phase(&context, asset.id, WorkspacePhase::Authenticating);
    context
        .status
        .set_label("正在从系统密钥环读取凭据并建立受检 SSH 会话…");
    let context_for_lookup = context.clone();
    gtk::glib::spawn_future_local(async move {
        let credential = match context_for_lookup.vault.lookup(asset.credential_id).await {
            Ok(Some(credential)) => credential,
            Ok(None) => {
                show_session_error(
                    &context_for_lookup,
                    asset.id,
                    "系统密钥环中没有该资产的凭据。",
                );
                return;
            }
            Err(error) => {
                show_session_error(
                    &context_for_lookup,
                    asset.id,
                    &format!("无法读取系统密钥环：{error}"),
                );
                return;
            }
        };
        let jump_credential = if let Some(jump) = &asset.jump_host {
            match context_for_lookup.vault.lookup(jump.credential_id).await {
                Ok(Some(credential)) => Some(credential),
                Ok(None) => {
                    show_session_error(
                        &context_for_lookup,
                        asset.id,
                        "系统密钥环中没有跳板机凭据。",
                    );
                    return;
                }
                Err(error) => {
                    show_session_error(
                        &context_for_lookup,
                        asset.id,
                        &format!("无法读取跳板机凭据：{error}"),
                    );
                    return;
                }
            }
        } else {
            None
        };
        let Some(known_hosts) = context_for_lookup.known_hosts.to_str().map(str::to_owned) else {
            show_session_error(
                &context_for_lookup,
                asset.id,
                "Host Key 存储路径不是有效 UTF-8。",
            );
            return;
        };
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result =
                connect_worker(&asset, &credential, jump_credential.as_ref(), &known_hosts);
            let _ = sender.send(result);
        });
        poll_connect_result(context_for_lookup, asset_id, receiver);
    });
}

fn set_session_phase(context: &UiContext, asset_id: Uuid, phase: WorkspacePhase) {
    let is_active = context.session.borrow().owns_input(asset_id);
    if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&asset_id) {
        runtime.phase = phase;
        if is_active && runtime.transport == Transport::Rdp && phase != WorkspacePhase::Connected {
            context.rdp_last_pointer.set(None);
            context.rdp_pressed_pointer_buttons.set(0);
        }
    }
    refresh_session_tabs(context);
    if context.session.borrow().active_workspace_id == Some(asset_id) {
        render_active_workspace(context);
    }
}

fn cancel_rdp_auto_reconnect(context: &UiContext, asset_id: Uuid) -> bool {
    let mut states = context.rdp_reconnect_states.borrow_mut();
    let state = states.entry(asset_id).or_default();
    let was_active = state.active;
    state.generation = state.generation.wrapping_add(1);
    state.attempt = 0;
    state.active = false;
    was_active
}

fn rdp_auto_reconnect_is_active(context: &UiContext, asset_id: Uuid) -> bool {
    context
        .rdp_reconnect_states
        .borrow()
        .get(&asset_id)
        .is_some_and(|state| state.active)
}

fn schedule_rdp_auto_reconnect(context: UiContext, asset_id: Uuid) -> bool {
    let valid_workspace = context
        .session
        .borrow()
        .sessions
        .get(&asset_id)
        .is_some_and(|runtime| runtime.transport == Transport::Rdp);
    if !valid_workspace {
        return false;
    }
    let Some((attempt, generation, delay)) = ({
        let mut states = context.rdp_reconnect_states.borrow_mut();
        let state = states.entry(asset_id).or_default();
        let next_attempt = state.attempt.saturating_add(1);
        rdp_reconnect_delay(next_attempt).map(|delay| {
            state.attempt = next_attempt;
            state.generation = state.generation.wrapping_add(1);
            state.active = true;
            (next_attempt, state.generation, delay)
        })
    }) else {
        if let Some(state) = context.rdp_reconnect_states.borrow_mut().get_mut(&asset_id) {
            state.active = false;
        }
        return false;
    };

    set_session_phase(&context, asset_id, WorkspacePhase::Reconnecting);
    context.status.set_label(&format!(
        "RDP 连接已中断；{} 秒后自动重连（{attempt}/{MAX_RDP_RECONNECT_ATTEMPTS}）。",
        delay.as_secs()
    ));
    gtk::glib::timeout_add_local_once(delay, move || {
        let still_current = context
            .rdp_reconnect_states
            .borrow()
            .get(&asset_id)
            .is_some_and(|state| {
                state.active && state.generation == generation && state.attempt == attempt
            });
        let workspace_still_available = context
            .session
            .borrow()
            .sessions
            .get(&asset_id)
            .is_some_and(|runtime| {
                runtime.transport == Transport::Rdp
                    && matches!(
                        runtime.phase,
                        WorkspacePhase::Reconnecting
                            | WorkspacePhase::Disconnected
                            | WorkspacePhase::Failed
                    )
            });
        if !still_current || !workspace_still_available {
            return;
        }
        context.status.set_label(&format!(
            "正在自动重连 RDP（{attempt}/{MAX_RDP_RECONNECT_ATTEMPTS}）…"
        ));
        begin_connect_internal(context, asset_id, false);
    });
    true
}

fn prompt_telnet_risk(context: UiContext, asset: ServerAsset) {
    if !context.preferences.borrow().telnet_enabled {
        context
            .status
            .set_label("Telnet 默认关闭；请先在设置中阅读风险并明确启用。");
        present_settings_window(context);
        return;
    }
    set_session_phase(&context, asset.id, WorkspacePhase::AwaitingUserDecision);
    let dialog = adw::AlertDialog::builder()
        .heading("确认明文 Telnet 连接")
        .body(format!(
            "{}（{}）不会加密登录凭据、命令或会话内容。请仅在可信隔离网络中使用。\n\n本次确认只对当前连接有效；SFTP、Docker 和 Monitor 将保持禁用。",
            asset.name,
            asset.endpoint()
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("connect", "仅本次连接");
    dialog.set_response_appearance("connect", adw::ResponseAppearance::Destructive);
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() != "connect" {
            show_session_error(&context, asset.id, "已取消明文 Telnet 连接。");
            return;
        }
        set_session_phase(&context, asset.id, WorkspacePhase::Authenticating);
        let mut credential = match context.vault.lookup(asset.credential_id).await {
            Ok(Some(credential)) => credential,
            Ok(None) => {
                show_session_error(&context, asset.id, "系统密钥环中没有该 Telnet 资产的凭据。");
                return;
            }
            Err(error) => {
                show_session_error(&context, asset.id, &format!("无法读取系统密钥环：{error}"));
                return;
            }
        };
        let profile = TelnetProfile {
            host: asset.host.clone(),
            port: asset.port,
            username: asset.username.clone(),
            columns: 120,
            rows: 32,
        };
        match TelnetSession::connect(
            asset.id,
            profile,
            Zeroizing::new(std::mem::take(&mut credential.password)),
            context.session_events.clone(),
        ) {
            Ok(session) => {
                if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&asset.id) {
                    runtime.telnet = Some(session);
                    runtime.append_terminal(
                        b"\r\n[OrbitTerm security warning] Telnet traffic is not encrypted.\r\n\r\n",
                    );
                }
                context
                    .status
                    .set_label("Telnet 明文会话正在建立 · 安全工具旁路已禁用");
            }
            Err(error) => {
                show_session_error(&context, asset.id, &format!("Telnet 会话无法启动：{error}"))
            }
        }
    });
}

fn begin_rdp_connect(context: UiContext, asset: ServerAsset) {
    let runtime = freerdp_runtime_info();
    if runtime.status != FreeRdpRuntimeStatus::Available {
        show_session_error(
            &context,
            asset.id,
            &format!(
                "RDP 已安全阻止：需要 FreeRDP {}，当前运行时为 {}。",
                runtime.expected_version,
                runtime.actual_version.unwrap_or_else(|| "不可用".into())
            ),
        );
        return;
    }
    set_session_phase(&context, asset.id, WorkspacePhase::Authenticating);
    gtk::glib::spawn_future_local(async move {
        let mut credential = match context.vault.lookup(asset.credential_id).await {
            Ok(Some(credential)) => credential,
            Ok(None) => {
                show_session_error(&context, asset.id, "系统密钥环中没有该 RDP 资产的凭据。");
                return;
            }
            Err(error) => {
                show_session_error(&context, asset.id, &format!("无法读取系统密钥环：{error}"));
                return;
            }
        };
        let Some(config_path) = context.rdp_config_path.to_str().map(str::to_owned) else {
            show_session_error(&context, asset.id, "RDP 证书信任目录不是有效 UTF-8。");
            return;
        };
        let (domain, username) = split_rdp_identity(&asset.username);
        let profile = RdpProfile {
            host: asset.host.clone(),
            port: asset.port,
            username,
            domain,
            config_path,
            // A conservative 16:9 desktop is broadly accepted by supported
            // Windows RDP servers. The GTK picture scales it locally, so the
            // UI never asks an older server to switch to an unsupported mode.
            desktop_width: SAFE_RDP_DESKTOP_WIDTH,
            desktop_height: SAFE_RDP_DESKTOP_HEIGHT,
            require_nla: true,
        };
        match RdpSession::connect(
            asset.id,
            profile,
            Zeroizing::new(std::mem::take(&mut credential.password)),
            context.session_events.clone(),
        ) {
            Ok(session) => {
                if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&asset.id) {
                    runtime.rdp = Some(session);
                }
                context.status.set_label("RDP 正在进行 NLA 与证书验证…");
            }
            Err(error) => {
                show_session_error(&context, asset.id, &format!("RDP 工作区无法启动：{error}"))
            }
        }
    });
}

fn split_rdp_identity(identity: &str) -> (String, String) {
    identity
        .split_once('\\')
        .map(|(domain, username)| (domain.to_owned(), username.to_owned()))
        .unwrap_or_else(|| (String::new(), identity.to_owned()))
}

fn handle_protocol_session_event(context: &UiContext, event: SessionEvent) {
    match event.kind {
        SessionEventKind::Phase(phase) => {
            let is_rdp = context
                .session
                .borrow()
                .sessions
                .get(&event.workspace_id)
                .is_some_and(|runtime| runtime.transport == Transport::Rdp);
            if is_rdp && phase == WorkspacePhase::Connected {
                let recovered = cancel_rdp_auto_reconnect(context, event.workspace_id);
                let mut metrics = context.rdp_metrics.borrow_mut();
                let metric = metrics.entry(event.workspace_id).or_default();
                metric.connected_at = Some(Instant::now());
                if recovered {
                    metric.recovery_count = metric.recovery_count.saturating_add(1);
                }
                drop(metrics);
                set_session_phase(context, event.workspace_id, phase);
                if recovered {
                    context
                        .status
                        .set_label("RDP 已自动重连；NLA、证书与输入通道已重新建立。");
                }
            } else if is_rdp && phase == WorkspacePhase::Disconnected {
                let mut metrics = context.rdp_metrics.borrow_mut();
                let metric = metrics.entry(event.workspace_id).or_default();
                metric.disconnect_count = metric.disconnect_count.saturating_add(1);
                drop(metrics);
                set_session_phase(context, event.workspace_id, phase);
                if !schedule_rdp_auto_reconnect(context.clone(), event.workspace_id) {
                    context
                        .status
                        .set_label("RDP 已断开；自动重连已停止，可从会话标签手动重试。");
                }
            } else {
                set_session_phase(context, event.workspace_id, phase);
            }
        }
        SessionEventKind::Terminal(bytes) => {
            let is_active = {
                let mut registry = context.session.borrow_mut();
                let is_active = registry.active_workspace_id == Some(event.workspace_id);
                if let Some(runtime) = registry.sessions.get_mut(&event.workspace_id) {
                    runtime.append_terminal(&bytes);
                }
                is_active
            };
            if is_active {
                context.workspace.terminals[0].feed(&bytes);
            }
        }
        SessionEventKind::RdpFrameReady => {}
        SessionEventKind::RdpCertificate(challenge) => {
            set_session_phase(
                context,
                event.workspace_id,
                WorkspacePhase::AwaitingUserDecision,
            );
            prompt_rdp_certificate(context.clone(), event.workspace_id, challenge);
        }
        SessionEventKind::Failed { code, reason } => {
            let (is_rdp, was_connected) = context
                .session
                .borrow()
                .sessions
                .get(&event.workspace_id)
                .map(|runtime| {
                    (
                        runtime.transport == Transport::Rdp,
                        runtime.phase == WorkspacePhase::Connected,
                    )
                })
                .unwrap_or((false, false));
            if is_rdp {
                let presentation = classify_rdp_failure(&reason);
                let reconnecting = rdp_auto_reconnect_is_active(context, event.workspace_id);
                {
                    let mut metrics = context.rdp_metrics.borrow_mut();
                    let metric = metrics.entry(event.workspace_id).or_default();
                    if was_connected {
                        metric.disconnect_count = metric.disconnect_count.saturating_add(1);
                    }
                    metric.last_failure = Some((code, safe_session_failure(&reason).to_owned()));
                }
                show_session_error(
                    context,
                    event.workspace_id,
                    &format!("会话失败（{code}）：{}", safe_session_failure(&reason)),
                );
                if (was_connected || reconnecting)
                    && rdp_failure_allows_auto_reconnect(presentation.kind)
                {
                    if schedule_rdp_auto_reconnect(context.clone(), event.workspace_id) {
                        return;
                    }
                    cancel_rdp_auto_reconnect(context, event.workspace_id);
                    context
                        .status
                        .set_label("RDP 自动重连达到上限；请检查网络或远端服务后手动重试。");
                    present_rdp_connection_failure(
                        context.clone(),
                        event.workspace_id,
                        code,
                        reason,
                        true,
                    );
                    return;
                }
                let stopped_automatic_reconnect =
                    reconnecting && cancel_rdp_auto_reconnect(context, event.workspace_id);
                present_rdp_connection_failure(
                    context.clone(),
                    event.workspace_id,
                    code,
                    reason,
                    stopped_automatic_reconnect,
                );
            } else {
                show_session_error(
                    context,
                    event.workspace_id,
                    &format!("会话失败（{code}）：{}", safe_session_failure(&reason)),
                );
            }
        }
    }
}

fn handle_rdp_frame_ready(context: &UiContext, workspace_id: Uuid) {
    let update = {
        let registry = context.session.borrow();
        registry
            .sessions
            .get(&workspace_id)
            .and_then(|runtime| runtime.rdp.as_ref())
            .and_then(RdpSession::take_frame)
    };
    let Some(update) = update else {
        return;
    };
    context
        .rdp_metrics
        .borrow_mut()
        .entry(workspace_id)
        .or_default()
        .record_frame_at(Instant::now(), &update);
    let (visible_frame, canvas_allocation_bytes) = {
        let mut registry = context.session.borrow_mut();
        let is_active = registry.active_workspace_id == Some(workspace_id);
        let Some(runtime) = registry.sessions.get_mut(&workspace_id) else {
            return;
        };
        runtime.rdp_frame_size = Some((update.width, update.height));
        let canvas = runtime
            .rdp_frame
            .get_or_insert_with(|| Rc::new(RefCell::new(RdpCanvas::default())));
        if !canvas.borrow_mut().apply(&update) {
            context
                .status
                .set_label("RDP 已忽略一条越界的画面增量；连接保持安全运行。");
            return;
        }
        let canvas_allocation_bytes = canvas.borrow().allocation_bytes();
        (
            is_active.then(|| Rc::clone(canvas)),
            canvas_allocation_bytes,
        )
    };
    if let Some(metrics) = context.rdp_metrics.borrow_mut().get_mut(&workspace_id) {
        metrics.canvas_allocation_bytes = canvas_allocation_bytes;
    }
    if let Some(frame) = visible_frame {
        present_rdp_frame(context, frame);
    }
}

fn safe_session_failure(reason: &str) -> &'static str {
    match reason {
        "telnet_connect_failed" => "无法连接 Telnet 目标",
        "telnet_write_failed" | "telnet_read_failed" => "Telnet 连接已中断",
        "telnet_negotiation_failed" => "Telnet 协商失败",
        "telnet_login_failed" => "Telnet 登录交互失败",
        value if value.contains("AUTHENTICATION") || value.contains("LOGON") => {
            "远程桌面身份验证失败"
        }
        value if value.contains("CONNECT") || value.contains("TRANSPORT") => "远程桌面网络连接失败",
        value if value.contains("CERT") => "远程桌面证书验证失败",
        _ => "远程会话未能建立或已异常结束",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RdpFailureKind {
    Authentication,
    ServiceUnavailable,
    NameResolution,
    Certificate,
    TimedOut,
    Cancelled,
    Protocol,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RdpFailurePresentation {
    kind: RdpFailureKind,
    heading: &'static str,
    explanation: &'static str,
}

fn classify_rdp_failure(reason: &str) -> RdpFailurePresentation {
    let reason = reason.to_ascii_uppercase();
    if [
        "AUTHENTICATION",
        "LOGON",
        "CREDENTIAL",
        "PASSWORD",
        "ACCOUNT_RESTRICTION",
        "NLA",
    ]
    .iter()
    .any(|token| reason.contains(token))
    {
        return RdpFailurePresentation {
            kind: RdpFailureKind::Authentication,
            heading: "RDP 身份验证失败",
            explanation: "远端 RDP 服务已经响应，但没有接受当前凭据。请检查用户名、域、密码、账户锁定状态以及远端是否要求 NLA。",
        };
    }
    if reason.contains("DNS") || reason.contains("NAME_NOT_FOUND") {
        return RdpFailurePresentation {
            kind: RdpFailureKind::NameResolution,
            heading: "找不到 RDP 主机",
            explanation: "无法解析资产中的主机名。请检查主机地址、DNS 或 VPN；使用 IP 地址可帮助排除名称解析问题。",
        };
    }
    if reason.contains("TIMEOUT") || reason.contains("TIMED_OUT") {
        return RdpFailurePresentation {
            kind: RdpFailureKind::TimedOut,
            heading: "RDP 连接超时",
            explanation: "目标在等待时间内没有完成响应。请检查网络、VPN、防火墙、3389 端口以及远端系统的远程桌面服务。",
        };
    }
    if reason.contains("CERT") {
        return RdpFailurePresentation {
            kind: RdpFailureKind::Certificate,
            heading: "RDP 证书验证失败",
            explanation: "远端证书未通过验证或证书发生变化。请核对目标身份和证书指纹，不要在无法确认时继续连接。",
        };
    }
    if reason.contains("CANCEL") {
        return RdpFailurePresentation {
            kind: RdpFailureKind::Cancelled,
            heading: "RDP 连接已取消",
            explanation: "连接被用户、系统或远端中止。您可以确认没有待处理的证书提示后重新连接。",
        };
    }
    if reason.contains("SECURITY") || reason.contains("PROTOCOL") || reason.contains("NEGO") {
        return RdpFailurePresentation {
            kind: RdpFailureKind::Protocol,
            heading: "RDP 安全协商失败",
            explanation: "客户端与远端未能协商共同支持的安全协议。请检查远端 RDP/NLA 策略和系统更新，不会自动降低安全级别重试。",
        };
    }
    if [
        "CONNECT_FAILED",
        "TRANSPORT",
        "TLS_CONNECT",
        "HOST_NOT_FOUND",
        "CONNECTION_REFUSED",
    ]
    .iter()
    .any(|token| reason.contains(token))
    {
        return RdpFailurePresentation {
            kind: RdpFailureKind::ServiceUnavailable,
            heading: "无法到达远端 RDP 服务",
            explanation: "没有收到可用的 RDP 服务响应。这通常表示远端未开启远程桌面、端口配置错误、防火墙拦截，或当前网络/VPN 无法到达目标；它不同于凭据错误。",
        };
    }
    RdpFailurePresentation {
        kind: RdpFailureKind::Unknown,
        heading: "RDP 连接失败",
        explanation: "连接未能完成。请先检查资产地址、网络、远端 RDP 服务和凭据，再尝试重新连接。",
    }
}

fn rdp_failure_allows_auto_reconnect(kind: RdpFailureKind) -> bool {
    matches!(
        kind,
        RdpFailureKind::ServiceUnavailable
            | RdpFailureKind::NameResolution
            | RdpFailureKind::TimedOut
            | RdpFailureKind::Unknown
    )
}

fn present_rdp_connection_failure(
    context: UiContext,
    asset_id: Uuid,
    code: u32,
    reason: String,
    automatic_reconnect_stopped: bool,
) {
    if !context.rdp_failure_dialogs.borrow_mut().insert(asset_id) {
        return;
    }
    let presentation = classify_rdp_failure(&reason);
    let reconnect_note = if automatic_reconnect_stopped {
        "\n\n自动重连已停止，避免无上限重试或在身份、证书、安全策略异常时继续尝试。"
    } else {
        ""
    };
    let dialog = adw::AlertDialog::builder()
        .heading(presentation.heading)
        .body(format!(
            "{}{}\n\n诊断代码：{code}。该代码不包含用户名、密码或远端桌面内容。",
            presentation.explanation, reconnect_note
        ))
        .close_response("close")
        .build();
    dialog.add_response("close", "知道了");
    dialog.add_response("retry", "重新连接");
    dialog.set_default_response(Some("retry"));
    gtk::glib::spawn_future_local(async move {
        let response = dialog.choose_future(Some(&context.window)).await;
        context.rdp_failure_dialogs.borrow_mut().remove(&asset_id);
        if response.as_str() == "retry" {
            begin_connect(context, asset_id);
        }
    });
}

fn prompt_rdp_certificate(context: UiContext, asset_id: Uuid, challenge: RdpCertificateChallenge) {
    let changed_warning = if challenge.changed {
        format!(
            "\n\n警告：证书已变化。\n旧指纹：{}\n新指纹：{}",
            challenge.old_fingerprint, challenge.fingerprint
        )
    } else {
        format!("\n\n指纹：{}", challenge.fingerprint)
    };
    let dialog = adw::AlertDialog::builder()
        .heading(if challenge.changed {
            "远程桌面证书已变化"
        } else {
            "验证远程桌面证书"
        })
        .body(format!(
            "目标：{}:{}\n主题：{}\n签发者：{}{}\n\n请通过可信渠道核对后再保存信任。",
            challenge.host, challenge.port, challenge.subject, challenge.issuer, changed_warning
        ))
        .close_response("reject")
        .build();
    dialog.add_response("reject", "拒绝连接");
    dialog.add_response("trust", "信任并保存");
    dialog.set_response_appearance(
        "trust",
        if challenge.changed {
            adw::ResponseAppearance::Destructive
        } else {
            adw::ResponseAppearance::Suggested
        },
    );
    gtk::glib::spawn_future_local(async move {
        let accept = dialog.choose_future(Some(&context.window)).await.as_str() == "trust";
        let result = context
            .session
            .borrow()
            .sessions
            .get(&asset_id)
            .and_then(|runtime| runtime.rdp.as_ref())
            .map(|session| session.certificate_decision(accept));
        match result {
            Some(Ok(())) if accept => {
                set_session_phase(&context, asset_id, WorkspacePhase::Authenticating);
                context
                    .status
                    .set_label("证书信任已保存，正在继续 NLA 连接…");
            }
            Some(Ok(())) => show_session_error(&context, asset_id, "已拒绝远程桌面证书。"),
            _ => show_session_error(&context, asset_id, "远程桌面证书确认通道已失效。"),
        }
    });
}

fn connect_worker(
    asset: &ServerAsset,
    credential: &CredentialMaterial,
    jump_credential: Option<&CredentialMaterial>,
    known_hosts: &str,
) -> Result<ConnectWorkerOutcome, BridgeError> {
    let core = CheckedCoreClient::new();
    let request_id = RequestId::new();
    let jump_host = match (&asset.jump_host, jump_credential) {
        (Some(jump), Some(credential)) => Some(CheckedJumpHostRequest {
            host: &jump.host,
            port: jump.port,
            username: &jump.username,
            password: &credential.password,
            private_key: &credential.private_key,
            private_key_passphrase: &credential.private_key_passphrase,
            allow_password_fallback: jump.allow_password_fallback,
        }),
        (None, None) => None,
        _ => return Err(BridgeError::InvalidInput("jump_host_credential")),
    };
    let request = CheckedConnectionRequest {
        host: &asset.host,
        port: asset.port,
        username: &asset.username,
        password: &credential.password,
        private_key: &credential.private_key,
        private_key_passphrase: &credential.private_key_passphrase,
        allow_password_fallback: asset.allow_password_fallback,
        jump_host,
        known_hosts_path: known_hosts,
    };
    let envelope = core.connect(&request, &request_id)?;
    match envelope.kind.as_str() {
        "connected" => {
            let connected = envelope.require_kind("connected")?;
            let base_session_id = decimal_id(connected, "session_id")?;
            let terminal_request = RequestId::new();
            let opened = match core.open_terminal(base_session_id, 120, 32, &terminal_request) {
                Ok(opened) => opened,
                Err(error) => {
                    let _ = core.disconnect(base_session_id);
                    return Err(error);
                }
            };
            let terminal_channel_id = match opened
                .require_kind("terminal_channel_opened")
                .and_then(|terminal| decimal_id(terminal, "terminal_channel_id"))
            {
                Ok(id) => id,
                Err(error) => {
                    let _ = core.disconnect(base_session_id);
                    return Err(error);
                }
            };
            Ok(ConnectWorkerOutcome::Connected {
                base_session_id,
                terminal_channel_id,
            })
        }
        "host_key_challenge" => {
            let challenge = envelope.require_kind("host_key_challenge")?;
            if challenge
                .get("can_trust")
                .and_then(serde_json::Value::as_bool)
                != Some(true)
            {
                return Ok(ConnectWorkerOutcome::Blocked(
                    "服务器 Host Key 不允许建立信任。".into(),
                ));
            }
            let challenge_id = required_string(challenge, "challenge_id")?;
            let fingerprint = required_string(challenge, "fingerprint_sha256")?;
            let algorithm = required_string(challenge, "key_algorithm")?;
            Ok(ConnectWorkerOutcome::Challenge {
                challenge_id,
                fingerprint,
                algorithm,
                request_id,
            })
        }
        "host_key_blocked" => {
            let blocked = envelope.require_kind("host_key_blocked")?;
            let reason = blocked
                .get("reason_code")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown");
            Ok(ConnectWorkerOutcome::Blocked(format!(
                "Host Key 被安全策略阻止：{reason}"
            )))
        }
        _ => {
            let _ = envelope.require_kind("connected")?;
            unreachable!()
        }
    }
}

fn required_string(value: &serde_json::Value, field: &'static str) -> Result<String, BridgeError> {
    value
        .get(field)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or(BridgeError::InvalidIdentifier(field))
}

fn poll_connect_result(
    context: UiContext,
    asset_id: Uuid,
    receiver: mpsc::Receiver<Result<ConnectWorkerOutcome, BridgeError>>,
) {
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(ConnectWorkerOutcome::Connected {
                base_session_id,
                terminal_channel_id,
            })) => {
                {
                    let mut registry = context.session.borrow_mut();
                    let Some(runtime) = registry.sessions.get_mut(&asset_id) else {
                        let core = CheckedCoreClient::new();
                        let _ = core.close_terminal(terminal_channel_id);
                        let _ = core.disconnect(base_session_id);
                        return gtk::glib::ControlFlow::Break;
                    };
                    runtime.base_session_id = Some(base_session_id);
                    runtime.terminal_channel_id = Some(terminal_channel_id);
                    runtime.terminal_size = None;
                    runtime.phase = WorkspacePhase::Connected;
                    runtime.append_terminal(
                        b"OrbitTerm checked SSH session established.\r\nHost Key verified.\r\n\r\n",
                    );
                }
                refresh_session_tabs(&context);
                render_active_workspace(&context);
                context
                    .status
                    .set_label("已连接 · Host Key 已验证 · 终端通道已打开");
                begin_monitor_refresh(context.clone());
                begin_sftp_list(context.clone(), String::new());
                begin_docker_refresh(context.clone());
                gtk::glib::ControlFlow::Break
            }
            Ok(Ok(ConnectWorkerOutcome::Challenge {
                challenge_id,
                fingerprint,
                algorithm,
                request_id,
            })) => {
                prompt_host_key(
                    context.clone(),
                    asset_id,
                    challenge_id,
                    fingerprint,
                    algorithm,
                    request_id,
                );
                gtk::glib::ControlFlow::Break
            }
            Ok(Ok(ConnectWorkerOutcome::Blocked(reason))) => {
                show_session_error(&context, asset_id, &reason);
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                show_session_error(&context, asset_id, &format!("连接失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_session_error(&context, asset_id, "连接工作线程意外退出。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn prompt_host_key(
    context: UiContext,
    asset_id: Uuid,
    challenge_id: String,
    fingerprint: String,
    algorithm: String,
    request_id: RequestId,
) {
    set_session_phase(&context, asset_id, WorkspacePhase::AwaitingUserDecision);
    context.status.set_label("需要验证服务器 Host Key 指纹。");
    let dialog = adw::AlertDialog::builder()
        .heading("验证服务器身份")
        .body(format!(
            "算法：{algorithm}\n指纹：{fingerprint}\n\n请通过可信的带外渠道核对指纹。确认后将写入 OrbitTerm 专用 known_hosts。"
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("trust", "指纹一致，信任");
    dialog.set_response_appearance("trust", adw::ResponseAppearance::Suggested);
    let context_for_choice = context.clone();
    gtk::glib::spawn_future_local(async move {
        let response = dialog.choose_future(Some(&context_for_choice.window)).await;
        if response.as_str() != "trust" {
            show_session_error(&context_for_choice, asset_id, "已取消 Host Key 信任。");
            return;
        }
        set_session_phase(
            &context_for_choice,
            asset_id,
            WorkspacePhase::Authenticating,
        );
        let Some(known_hosts) = context_for_choice.known_hosts.to_str().map(str::to_owned) else {
            show_session_error(
                &context_for_choice,
                asset_id,
                "Host Key 存储路径不是有效 UTF-8。",
            );
            return;
        };
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let core = CheckedCoreClient::new();
            let result = core
                .accept_and_persist_host_key(
                    &challenge_id,
                    &known_hosts,
                    "OrbitTerm Linux",
                    &request_id,
                )
                .and_then(|envelope| {
                    envelope
                        .require_kind("host_key_trust_persisted")
                        .map(|_| ())
                });
            let _ = sender.send(result);
        });
        poll_trust_result(context_for_choice, asset_id, receiver);
    });
}

fn poll_trust_result(
    context: UiContext,
    asset_id: Uuid,
    receiver: mpsc::Receiver<Result<(), BridgeError>>,
) {
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(())) => {
                context
                    .status
                    .set_label("Host Key 已安全保存，正在重新建立会话…");
                let asset = context
                    .catalog
                    .borrow()
                    .assets()
                    .iter()
                    .find(|asset| asset.id == asset_id)
                    .cloned();
                if let Some(asset) = asset {
                    begin_ssh_connect(context.clone(), asset);
                } else {
                    show_session_error(&context, asset_id, "资产已被删除，无法继续连接。");
                }
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                show_session_error(&context, asset_id, &format!("保存 Host Key 失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_session_error(&context, asset_id, "Host Key 工作线程意外退出。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn send_terminal_input(context: &UiContext) {
    let command = context.workspace.input.text();
    if command.is_empty() {
        return;
    }
    let mut bytes = command.as_bytes().to_vec();
    bytes.push(b'\r');
    let result = write_active_terminal(context, &bytes);
    match result {
        Ok(()) => {
            remember_active_command(context, command.as_str());
            context.workspace.input.set_text("");
        }
        Err(error) => context.status.set_label(&format!("发送失败：{error}")),
    }
}

fn remember_active_command(context: &UiContext, command: &str) {
    if let Some(runtime) = context.session.borrow_mut().active_mut() {
        runtime.remember_command(command);
    }
}

fn write_active_terminal(context: &UiContext, bytes: &[u8]) -> Result<(), String> {
    let registry = context.session.borrow();
    let asset_id = registry
        .active_workspace_id
        .ok_or_else(|| "当前没有活动终端。".to_owned())?;
    let pane = registry
        .active()
        .map_or(0, |runtime| runtime.active_terminal_pane);
    drop(registry);
    write_terminal_for_pane(context, asset_id, pane, bytes)
}

fn write_terminal_for_asset(
    context: &UiContext,
    asset_id: Uuid,
    bytes: &[u8],
) -> Result<(), String> {
    write_terminal_for_pane(context, asset_id, 0, bytes)
}

fn write_terminal_for_pane(
    context: &UiContext,
    asset_id: Uuid,
    pane: usize,
    bytes: &[u8],
) -> Result<(), String> {
    if bytes.is_empty() {
        return Ok(());
    }
    let registry = context.session.borrow();
    let runtime = registry
        .sessions
        .get(&asset_id)
        .ok_or_else(|| "会话已关闭。".to_owned())?;
    if runtime.phase != WorkspacePhase::Connected {
        return Err("终端尚未连接。".to_owned());
    }
    match runtime.transport {
        Transport::Ssh => (if pane == 0 {
            runtime.terminal_channel_id
        } else {
            runtime
                .terminal_splits
                .get(pane - 1)
                .map(|split| split.channel_id)
        })
        .ok_or_else(|| "SSH 终端尚未就绪。".to_owned())
        .and_then(|channel_id| {
            CheckedCoreClient::new()
                .write_terminal(channel_id, bytes)
                .map_err(|error| error.to_string())
        }),
        Transport::Telnet => runtime
            .telnet
            .as_ref()
            .ok_or_else(|| "Telnet 终端尚未就绪。".to_owned())
            .and_then(|session| {
                session
                    .write(bytes.to_vec())
                    .map_err(|error| error.to_string())
            }),
        Transport::Rdp => Err("RDP 工作区不接受终端输入。".to_owned()),
    }
}

fn workstation_shortcut_action(
    key: gtk::gdk::Key,
    modifiers: gtk::gdk::ModifierType,
) -> Option<WorkstationShortcutAction> {
    let control = modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK);
    let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);
    let alt = modifiers.contains(gtk::gdk::ModifierType::ALT_MASK);
    let system = modifiers.intersects(
        gtk::gdk::ModifierType::SUPER_MASK
            | gtk::gdk::ModifierType::META_MASK
            | gtk::gdk::ModifierType::HYPER_MASK,
    );
    if system {
        return None;
    }
    let digit = match key {
        gtk::gdk::Key::_1 | gtk::gdk::Key::KP_1 => Some(0),
        gtk::gdk::Key::_2 | gtk::gdk::Key::KP_2 => Some(1),
        gtk::gdk::Key::_3 | gtk::gdk::Key::KP_3 => Some(2),
        gtk::gdk::Key::_4 | gtk::gdk::Key::KP_4 => Some(3),
        gtk::gdk::Key::_5 | gtk::gdk::Key::KP_5 => Some(4),
        gtk::gdk::Key::_6 | gtk::gdk::Key::KP_6 => Some(5),
        gtk::gdk::Key::_7 | gtk::gdk::Key::KP_7 => Some(6),
        gtk::gdk::Key::_8 | gtk::gdk::Key::KP_8 => Some(7),
        gtk::gdk::Key::_9 | gtk::gdk::Key::KP_9 => Some(8),
        _ => None,
    };
    if control && !shift && !alt {
        if let Some(index) = digit {
            return Some(WorkstationShortcutAction::SelectSession(index));
        }
        return match key {
            gtk::gdk::Key::Tab | gtk::gdk::Key::Page_Down => {
                Some(WorkstationShortcutAction::NextSession)
            }
            gtk::gdk::Key::Page_Up => Some(WorkstationShortcutAction::PreviousSession),
            gtk::gdk::Key::t | gtk::gdk::Key::T => Some(WorkstationShortcutAction::NewSession),
            gtk::gdk::Key::f | gtk::gdk::Key::F => Some(WorkstationShortcutAction::SearchTerminal),
            gtk::gdk::Key::comma => Some(WorkstationShortcutAction::OpenSettings),
            _ => None,
        };
    }
    if control && shift && !alt {
        return match key {
            gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab | gtk::gdk::Key::Page_Up => {
                Some(WorkstationShortcutAction::PreviousSession)
            }
            gtk::gdk::Key::Page_Down => Some(WorkstationShortcutAction::NextSession),
            gtk::gdk::Key::w | gtk::gdk::Key::W => Some(WorkstationShortcutAction::CloseSession),
            gtk::gdk::Key::d | gtk::gdk::Key::D => Some(WorkstationShortcutAction::AddPane),
            gtk::gdk::Key::e | gtk::gdk::Key::E => Some(WorkstationShortcutAction::ClosePane),
            gtk::gdk::Key::m | gtk::gdk::Key::M => Some(WorkstationShortcutAction::ResetPanes),
            gtk::gdk::Key::b | gtk::gdk::Key::B => {
                Some(WorkstationShortcutAction::OpenBatchCommand)
            }
            gtk::gdk::Key::l | gtk::gdk::Key::L => {
                Some(WorkstationShortcutAction::ToggleAssetSidebar)
            }
            gtk::gdk::Key::r | gtk::gdk::Key::R => {
                Some(WorkstationShortcutAction::ToggleToolInspector)
            }
            gtk::gdk::Key::slash | gtk::gdk::Key::question => {
                Some(WorkstationShortcutAction::ShowHelp)
            }
            _ => None,
        };
    }
    if alt && !control && !shift {
        if let Some(index) = digit.filter(|index| *index < MAX_TERMINAL_PANES) {
            return Some(WorkstationShortcutAction::SelectPane(index));
        }
        return match key {
            gtk::gdk::Key::i | gtk::gdk::Key::I => {
                Some(WorkstationShortcutAction::FocusCommandInput)
            }
            gtk::gdk::Key::s | gtk::gdk::Key::S => {
                Some(WorkstationShortcutAction::SendCommandInput)
            }
            _ => None,
        };
    }
    if alt && shift && !control {
        return match key {
            gtk::gdk::Key::Right | gtk::gdk::Key::Down => Some(WorkstationShortcutAction::NextPane),
            gtk::gdk::Key::Left | gtk::gdk::Key::Up => {
                Some(WorkstationShortcutAction::PreviousPane)
            }
            _ => None,
        };
    }
    if !control && !shift && !alt && key == gtk::gdk::Key::F11 {
        return Some(WorkstationShortcutAction::ToggleFullscreen);
    }
    None
}

fn install_workstation_shortcuts(
    context: &UiContext,
    sidebar_root: &gtk::Box,
    expand_left: &gtk::Button,
    tools_root: &gtk::Stack,
    expand_right: &gtk::Button,
) {
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let shortcut_context = context.clone();
    let shortcut_sidebar = sidebar_root.clone();
    let shortcut_expand_left = expand_left.clone();
    let shortcut_tools = tools_root.clone();
    let shortcut_expand_right = expand_right.clone();
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let rdp_connected = active_connected_rdp(&shortcut_context);
        let rdp_focused = shortcut_context.workspace.rdp_picture.has_focus();
        match shortcut_routing_layer(
            rdp_connected,
            rdp_focused,
            shortcut_context.rdp_input_capture.get(),
            shortcut_context.module_fullscreen.get(),
            key,
            modifiers,
        ) {
            ShortcutRoutingLayer::RemoteDesktop => {
                // Remote focus owns ordinary and application-colliding keys.
                // When explicit system capture is enabled, compositor-level
                // combinations are forwarded as well.
                return gtk::glib::Propagation::Proceed;
            }
            ShortcutRoutingLayer::LocalSystem | ShortcutRoutingLayer::FocusedWidget => {
                return gtk::glib::Propagation::Proceed;
            }
            ShortcutRoutingLayer::Application => {}
        }
        if rdp_connected && rdp_focused {
            record_active_rdp_control_event(
                &shortcut_context,
                RdpInputControlEvent::LocallyReservedShortcut,
            );
        }
        if rdp_connected && rdp_focused && is_rdp_capture_release_shortcut(key, modifiers) {
            release_rdp_capture_to_local(&shortcut_context);
            reveal_rdp_fullscreen_controls(&shortcut_context);
            shortcut_context
                .workspace
                .rdp_capture_shortcuts
                .grab_focus();
            shortcut_context
                .status
                .set_label("远端输入已释放到本机；顶部控制条已显示，单击远程桌面可继续远端输入。");
            return gtk::glib::Propagation::Stop;
        }
        let Some(action) = workstation_shortcut_action(key, modifiers) else {
            return gtk::glib::Propagation::Proceed;
        };
        perform_workstation_shortcut(
            shortcut_context.clone(),
            action,
            &shortcut_sidebar,
            &shortcut_expand_left,
            &shortcut_tools,
            &shortcut_expand_right,
        );
        gtk::glib::Propagation::Stop
    });
    context.window.add_controller(keys);
}

fn perform_workstation_shortcut(
    context: UiContext,
    action: WorkstationShortcutAction,
    sidebar_root: &gtk::Box,
    expand_left: &gtk::Button,
    tools_root: &gtk::Stack,
    expand_right: &gtk::Button,
) {
    match action {
        WorkstationShortcutAction::NextSession => switch_workspace_relative(&context, 1),
        WorkstationShortcutAction::PreviousSession => switch_workspace_relative(&context, -1),
        WorkstationShortcutAction::SelectSession(index) => select_workspace_index(&context, index),
        WorkstationShortcutAction::NextPane => switch_terminal_pane_relative(&context, 1),
        WorkstationShortcutAction::PreviousPane => switch_terminal_pane_relative(&context, -1),
        WorkstationShortcutAction::SelectPane(index) => select_terminal_pane_index(&context, index),
        WorkstationShortcutAction::NewSession => {
            let asset_id = context.session.borrow().selected_asset_id;
            if let Some(asset_id) = asset_id {
                begin_connect(context, asset_id);
            } else {
                context
                    .status
                    .set_label("请先在服务器栏选择资产，再新建会话标签。");
            }
        }
        WorkstationShortcutAction::CloseSession => {
            let asset_id = context.session.borrow().active_workspace_id;
            if let Some(asset_id) = asset_id {
                close_workspace(context, asset_id);
            } else {
                context.status.set_label("当前没有可关闭的会话标签。");
            }
        }
        WorkstationShortcutAction::AddPane => {
            context.workspace.split_menu.popdown();
            begin_add_terminal_split(context);
        }
        WorkstationShortcutAction::ClosePane => {
            context.workspace.split_menu.popdown();
            close_terminal_split(context, None);
        }
        WorkstationShortcutAction::ResetPanes => {
            context.workspace.split_menu.popdown();
            reset_terminal_splits(context);
        }
        WorkstationShortcutAction::SearchTerminal => {
            let pane = context
                .session
                .borrow()
                .active()
                .map(|runtime| runtime.active_terminal_pane);
            if let Some(pane) = pane {
                present_terminal_search_window(context.clone(), &context.workspace.terminals[pane]);
            } else {
                context.status.set_label("当前没有可搜索的终端输出。");
            }
        }
        WorkstationShortcutAction::FocusCommandInput => {
            if context.workspace.input.is_sensitive() {
                let _ = context.workspace.input.grab_focus();
                context.status.set_label("命令预输入栏已获得焦点。");
            } else {
                context.status.set_label("连接终端后才能使用命令预输入栏。");
            }
        }
        WorkstationShortcutAction::SendCommandInput => send_terminal_input(&context),
        WorkstationShortcutAction::OpenSettings => present_settings_window(context),
        WorkstationShortcutAction::OpenBatchCommand => present_batch_command_window(context),
        WorkstationShortcutAction::ToggleAssetSidebar => {
            let collapse = sidebar_root.is_visible();
            sidebar_root.set_visible(!collapse);
            expand_left.set_visible(collapse);
            context.status.set_label(if collapse {
                "服务器栏已收起；同步状态和命令输入宽度保持不变。"
            } else {
                "服务器栏已展开。"
            });
        }
        WorkstationShortcutAction::ToggleToolInspector => {
            if context.tools_auto_hidden_for_rdp.get() {
                context
                    .status
                    .set_label("RDP 会话工具已自动收起；远程桌面不建立 SSH 旁路工具连接。");
                return;
            }
            let collapse = tools_root.is_visible();
            context.tools_collapsed.set(collapse);
            tools_root.set_visible(!collapse);
            expand_right.set_visible(collapse);
            context.status.set_label(if collapse {
                "会话工具已收起；命令预输入栏已向右扩展。"
            } else {
                "会话工具已展开。"
            });
        }
        WorkstationShortcutAction::ToggleFullscreen => {
            toggle_module_fullscreen(&context);
        }
        WorkstationShortcutAction::ShowHelp => present_shortcut_help(context),
    }
}

fn switch_workspace_relative(context: &UiContext, offset: isize) {
    let (ids, active) = {
        let registry = context.session.borrow();
        (
            registry.sessions.keys().copied().collect::<Vec<_>>(),
            registry.active_workspace_id,
        )
    };
    if ids.len() < 2 {
        context
            .status
            .set_label("至少打开两个资产会话后才能循环切换标签。");
        return;
    }
    let current = active
        .and_then(|active| ids.iter().position(|id| *id == active))
        .unwrap_or(0);
    let next = (current as isize + offset).rem_euclid(ids.len() as isize) as usize;
    activate_workspace(context, ids[next]);
    context
        .status
        .set_label(&format!("已切换到会话标签 {} / {}。", next + 1, ids.len()));
}

fn select_workspace_index(context: &UiContext, index: usize) {
    let ids = context
        .session
        .borrow()
        .sessions
        .keys()
        .copied()
        .collect::<Vec<_>>();
    let Some(asset_id) = ids.get(index).copied() else {
        context
            .status
            .set_label(&format!("当前没有第 {} 个会话标签。", index + 1));
        return;
    };
    activate_workspace(context, asset_id);
    context
        .status
        .set_label(&format!("已切换到会话标签 {} / {}。", index + 1, ids.len()));
}

fn switch_terminal_pane_relative(context: &UiContext, offset: isize) {
    let (pane_count, active) = context
        .session
        .borrow()
        .active()
        .map(|runtime| (runtime.pane_count(), runtime.active_terminal_pane))
        .unwrap_or((0, 0));
    if pane_count < 2 {
        context
            .status
            .set_label("至少生成两个终端分屏后才能循环切换。");
        return;
    }
    let next = (active as isize + offset).rem_euclid(pane_count as isize) as usize;
    activate_terminal_pane(context, next, true);
    context.status.set_label(&format!(
        "终端焦点已切换到分屏 {} / {}。",
        next + 1,
        pane_count
    ));
}

fn select_terminal_pane_index(context: &UiContext, index: usize) {
    let pane_count = context
        .session
        .borrow()
        .active()
        .map(SessionRuntime::pane_count)
        .unwrap_or(0);
    if index >= pane_count {
        context
            .status
            .set_label(&format!("当前没有第 {} 个终端分屏。", index + 1));
        return;
    }
    activate_terminal_pane(context, index, true);
    context.status.set_label(&format!(
        "终端焦点已切换到分屏 {} / {}。",
        index + 1,
        pane_count
    ));
}

const WORKSTATION_SHORTCUTS: &[(&str, &str)] = &[
    (
        "会话标签",
        "Ctrl+Tab / Ctrl+PageDown 下一个 · Ctrl+Shift+Tab / Ctrl+PageUp 上一个",
    ),
    ("直接切换会话", "Ctrl+1…9"),
    ("终端分屏", "Alt+Shift+方向键循环 · Alt+1…4 直接切换"),
    (
        "分屏管理",
        "Ctrl+Shift+D 添加 · Ctrl+Shift+E 关闭 · Ctrl+Shift+M 恢复单屏",
    ),
    (
        "会话管理",
        "Ctrl+T 新建或打开所选资产 · Ctrl+Shift+W 断开并关闭当前标签",
    ),
    (
        "终端操作",
        "Ctrl+F 搜索输出 · Alt+I 聚焦预输入栏 · Alt+S 发送",
    ),
    (
        "工作站",
        "Ctrl+Shift+L 服务器栏 · Ctrl+Shift+R 会话工具 · F11 当前模块全屏",
    ),
    (
        "功能入口",
        "Ctrl+Shift+B 批量命令 · Ctrl+, 设置 · Ctrl+Shift+/ 快捷键说明",
    ),
    (
        "终端保留",
        "Ctrl+C 等组合键继续发送远端；Ctrl+Shift+C/V 用于本地复制与粘贴",
    ),
    (
        "RDP 远端输入",
        "远程画面聚焦：普通组合键发往远端 · 控制条聚焦：OrbitTerm 快捷键生效",
    ),
    (
        "本机系统快捷键",
        "默认由 Linux 桌面处理；开启“捕获快捷键”后才尝试发往远端",
    ),
    (
        "强制释放远端",
        "Ctrl+Alt+Shift+Esc / Super+Esc 归还本机快捷键并显示全屏控制条",
    ),
];

fn present_shortcut_help(context: UiContext) {
    let (window, root) = utility_window(&context.window, "工作站快捷键", 680, 540);
    let title = gtk::Label::new(Some("工作站快捷键"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let note = gtk::Label::new(Some(
        "快捷键按焦点分层：Linux 系统保留键 → OrbitTerm 控件/工作台 → 已聚焦的终端或远程桌面。远程捕获必须由用户明确开启。",
    ));
    note.add_css_class("caption");
    note.set_xalign(0.0);
    note.set_wrap(true);
    root.append(&note);
    let list = gtk::Box::new(Orientation::Vertical, 0);
    list.add_css_class("settings-section");
    for (group, shortcut) in WORKSTATION_SHORTCUTS {
        let row = gtk::Box::new(Orientation::Horizontal, 14);
        row.add_css_class("management-row");
        let group = gtk::Label::new(Some(group));
        group.add_css_class("heading");
        group.set_xalign(0.0);
        group.set_size_request(112, -1);
        let shortcut = gtk::Label::new(Some(shortcut));
        shortcut.add_css_class("caption");
        shortcut.set_xalign(0.0);
        shortcut.set_wrap(true);
        shortcut.set_hexpand(true);
        row.append(&group);
        row.append(&shortcut);
        list.append(&row);
    }
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&list)
            .build(),
    );
    let close = gtk::Button::with_label("知道了");
    close.set_halign(Align::End);
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    root.append(&close);
    window.set_child(Some(&root));
    window.present();
}

fn install_terminal_input(context: &UiContext) {
    for (pane, terminal) in context.workspace.terminals.iter().enumerate() {
        let commit_context = context.clone();
        terminal.connect_commit(move |_, text, _| {
            activate_terminal_pane(&commit_context, pane, false);
            if let Err(error) = write_active_terminal(&commit_context, text.as_bytes()) {
                commit_context
                    .status
                    .set_label(&format!("终端输入失败：{error}"));
            }
        });

        let focus = gtk::EventControllerFocus::new();
        let focus_context = context.clone();
        focus.connect_enter(move |_| activate_terminal_pane(&focus_context, pane, false));
        terminal.add_controller(focus);

        let click = gtk::GestureClick::new();
        click.set_button(3);
        let click_context = context.clone();
        let click_terminal = terminal.clone();
        click.connect_pressed(move |gesture, _, x, y| {
            activate_terminal_pane(&click_context, pane, true);
            present_terminal_split_menu(click_context.clone(), pane, &click_terminal, x, y);
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        terminal.add_controller(click);

        let terminal_keys = gtk::EventControllerKey::new();
        let key_context = context.clone();
        let terminal_for_clipboard = terminal.clone();
        terminal_keys.connect_key_pressed(move |_, key, _, modifiers| {
            activate_terminal_pane(&key_context, pane, false);
            let control = modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK);
            let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);
            if control && shift && matches!(key, gtk::gdk::Key::c | gtk::gdk::Key::C) {
                terminal_for_clipboard.copy_clipboard_format(vte::Format::Text);
                return gtk::glib::Propagation::Stop;
            }
            if control && shift && matches!(key, gtk::gdk::Key::v | gtk::gdk::Key::V) {
                terminal_for_clipboard.paste_clipboard();
                return gtk::glib::Propagation::Stop;
            }
            let Some(bytes) = terminal_key_sequence(key, modifiers) else {
                return gtk::glib::Propagation::Proceed;
            };
            if let Err(error) = write_active_terminal(&key_context, &bytes) {
                key_context
                    .status
                    .set_label(&format!("快捷键发送失败：{error}"));
            }
            gtk::glib::Propagation::Stop
        });
        terminal.add_controller(terminal_keys);
    }

    let preinput_keys = gtk::EventControllerKey::new();
    // Capture before GtkEntry's clipboard handler so Ctrl+C reaches the
    // active terminal pane. Keep Ctrl+Shift+C/V reserved for local clipboard.
    preinput_keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let preinput_context = context.clone();
    preinput_keys.connect_key_pressed(move |_, key, _, modifiers| {
        if is_local_preinput_clipboard_shortcut(key, modifiers) {
            return gtk::glib::Propagation::Proceed;
        }
        let direct = modifiers
            .intersects(gtk::gdk::ModifierType::CONTROL_MASK | gtk::gdk::ModifierType::ALT_MASK);
        if !direct {
            return gtk::glib::Propagation::Proceed;
        }
        let Some(bytes) = terminal_key_sequence(key, modifiers) else {
            return gtk::glib::Propagation::Proceed;
        };
        if let Err(error) = write_active_terminal(&preinput_context, &bytes) {
            preinput_context
                .status
                .set_label(&format!("组合键发送失败：{error}"));
        }
        gtk::glib::Propagation::Stop
    });
    context.workspace.input.add_controller(preinput_keys);

    let add_context = context.clone();
    context.workspace.split_add.connect_clicked(move |_| {
        add_context.workspace.split_menu.popdown();
        begin_add_terminal_split(add_context.clone());
    });
    let remove_context = context.clone();
    context.workspace.split_remove.connect_clicked(move |_| {
        remove_context.workspace.split_menu.popdown();
        close_terminal_split(remove_context.clone(), None);
    });
    let reset_context = context.clone();
    context.workspace.split_reset.connect_clicked(move |_| {
        reset_context.workspace.split_menu.popdown();
        reset_terminal_splits(reset_context.clone());
    });
}

fn terminal_pane_layout(pane_count: usize) -> Vec<(i32, i32, i32, i32)> {
    match pane_count.clamp(1, MAX_TERMINAL_PANES) {
        1 => vec![(0, 0, 2, 2)],
        2 => vec![(0, 0, 2, 1), (0, 1, 2, 1)],
        3 => vec![(0, 0, 2, 1), (0, 1, 1, 1), (1, 1, 1, 1)],
        _ => vec![(0, 0, 1, 1), (1, 0, 1, 1), (0, 1, 1, 1), (1, 1, 1, 1)],
    }
}

fn present_terminal_split_menu(
    context: UiContext,
    pane: usize,
    parent: &vte::Terminal,
    x: f64,
    y: f64,
) {
    let popover = gtk::Popover::new();
    popover.set_parent(parent);
    popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    let actions = gtk::Box::new(Orientation::Vertical, 2);
    actions.set_margin_top(6);
    actions.set_margin_bottom(6);
    actions.set_margin_start(6);
    actions.set_margin_end(6);
    let title = gtk::Label::new(Some(&format!("终端分屏 {}", pane + 1)));
    title.add_css_class("caption");
    title.set_xalign(0.0);
    actions.append(&title);

    let copy = gtk::Button::with_label("复制所选内容");
    copy.add_css_class("flat");
    copy.set_sensitive(parent.has_selection());
    let copy_terminal = parent.clone();
    let copy_popover = popover.clone();
    copy.connect_clicked(move |_| {
        copy_terminal.copy_clipboard_format(vte::Format::Text);
        copy_popover.popdown();
    });
    actions.append(&copy);
    let paste = gtk::Button::with_label("粘贴到当前终端");
    paste.add_css_class("flat");
    let paste_terminal = parent.clone();
    let paste_popover = popover.clone();
    paste.connect_clicked(move |_| {
        paste_terminal.paste_clipboard();
        paste_popover.popdown();
    });
    actions.append(&paste);
    let select_all = gtk::Button::with_label("全选终端内容");
    select_all.add_css_class("flat");
    let select_terminal = parent.clone();
    let select_popover = popover.clone();
    select_all.connect_clicked(move |_| {
        select_terminal.select_all();
        select_popover.popdown();
    });
    actions.append(&select_all);
    actions.append(&gtk::Separator::new(Orientation::Horizontal));
    let search = gtk::Button::with_label("搜索终端输出…");
    search.add_css_class("flat");
    let search_context = context.clone();
    let search_terminal = parent.clone();
    let search_popover = popover.clone();
    search.connect_clicked(move |_| {
        search_popover.popdown();
        present_terminal_search_window(search_context.clone(), &search_terminal);
    });
    actions.append(&search);
    let copy_all = gtk::Button::with_label("复制全部会话记录");
    copy_all.add_css_class("flat");
    let copy_all_context = context.clone();
    let copy_all_popover = popover.clone();
    copy_all.connect_clicked(move |_| {
        if let Some(text) = copy_terminal_backlog(&copy_all_context, pane) {
            if let Some(display) = gtk::gdk::Display::default() {
                display.clipboard().set_text(&text);
                copy_all_context
                    .status
                    .set_label("当前分屏的会话记录已复制。");
            }
        }
        copy_all_popover.popdown();
    });
    actions.append(&copy_all);
    let clear = gtk::Button::with_label("清除本地显示");
    clear.add_css_class("flat");
    let clear_context = context.clone();
    let clear_terminal = parent.clone();
    let clear_popover = popover.clone();
    clear.connect_clicked(move |_| {
        if let Some(runtime) = clear_context.session.borrow_mut().active_mut() {
            runtime.clear_terminal_pane(pane);
        }
        clear_terminal.reset(true, true);
        clear_context
            .status
            .set_label("仅清除了本地终端显示，远端会话保持连接。");
        clear_popover.popdown();
    });
    actions.append(&clear);
    let settings = gtk::Button::with_label("终端外观与字体…");
    settings.add_css_class("flat");
    let settings_context = context.clone();
    let settings_popover = popover.clone();
    settings.connect_clicked(move |_| {
        settings_popover.popdown();
        present_settings_window(settings_context.clone());
    });
    actions.append(&settings);
    actions.append(&gtk::Separator::new(Orientation::Horizontal));
    let close = gtk::Button::with_label("关闭此分屏");
    close.add_css_class("flat");
    close.set_sensitive(pane > 0);
    let close_context = context.clone();
    let close_popover = popover.clone();
    close.connect_clicked(move |_| {
        close_popover.popdown();
        close_terminal_split(close_context.clone(), Some(pane));
    });
    actions.append(&close);
    let restore = gtk::Button::with_label("恢复单屏");
    restore.add_css_class("flat");
    restore.set_sensitive(
        context
            .session
            .borrow()
            .active()
            .is_some_and(|runtime| runtime.pane_count() > 1),
    );
    let restore_context = context.clone();
    let restore_popover = popover.clone();
    restore.connect_clicked(move |_| {
        restore_popover.popdown();
        reset_terminal_splits(restore_context.clone());
    });
    actions.append(&restore);
    popover.set_child(Some(&actions));
    popover.popup();
}

fn copy_terminal_backlog(context: &UiContext, pane: usize) -> Option<String> {
    context
        .session
        .borrow()
        .active()
        .filter(|runtime| pane < runtime.pane_count())
        .map(|runtime| String::from_utf8_lossy(runtime.pane_backlog(pane)).into_owned())
}

fn escape_terminal_search(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        if matches!(
            character,
            '\\' | '.' | '^' | '$' | '|' | '?' | '*' | '+' | '(' | ')' | '[' | ']' | '{' | '}'
        ) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn present_terminal_search_window(context: UiContext, terminal: &vte::Terminal) {
    let window = gtk::Window::builder()
        .title("搜索终端输出")
        .transient_for(&context.window)
        .modal(true)
        .default_width(480)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 10);
    root.set_margin_start(16);
    root.set_margin_end(16);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    let entry = gtk::SearchEntry::builder()
        .placeholder_text("输入要查找的文本")
        .build();
    root.append(&entry);
    let status = gtk::Label::new(Some("按 Enter 查找下一处，Shift+Enter 查找上一处。"));
    status.add_css_class("caption");
    status.set_xalign(0.0);
    root.append(&status);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let previous = gtk::Button::with_label("上一处");
    let next = gtk::Button::with_label("下一处");
    let close = gtk::Button::with_label("关闭");
    actions.append(&previous);
    actions.append(&next);
    actions.append(&close);
    root.append(&actions);
    window.set_child(Some(&root));
    let install_search = {
        let terminal = terminal.clone();
        let entry = entry.clone();
        let status = status.clone();
        Rc::new(move || {
            let query = entry.text();
            if query.is_empty() {
                terminal.search_set_regex(None, 0);
                status.set_label("请输入要查找的文本。");
                return false;
            }
            match vte::Regex::for_search(&escape_terminal_search(query.as_str()), 0) {
                Ok(regex) => {
                    terminal.search_set_regex(Some(&regex), 0);
                    true
                }
                Err(error) => {
                    status.set_label(&format!("无法创建搜索条件：{error}"));
                    false
                }
            }
        })
    };
    let next_search = install_search.clone();
    let next_terminal = terminal.clone();
    let next_status = status.clone();
    next.connect_clicked(move |_| {
        if next_search() {
            next_status.set_label(if next_terminal.search_find_next() {
                "已定位下一处匹配。"
            } else {
                "未找到下一处匹配。"
            });
        }
    });
    let previous_search = install_search.clone();
    let previous_terminal = terminal.clone();
    let previous_status = status.clone();
    previous.connect_clicked(move |_| {
        if previous_search() {
            previous_status.set_label(if previous_terminal.search_find_previous() {
                "已定位上一处匹配。"
            } else {
                "未找到上一处匹配。"
            });
        }
    });
    let activate_search = install_search.clone();
    let activate_terminal = terminal.clone();
    let activate_status = status.clone();
    entry.connect_activate(move |_| {
        if activate_search() {
            activate_status.set_label(if activate_terminal.search_find_next() {
                "已定位下一处匹配。"
            } else {
                "未找到下一处匹配。"
            });
        }
    });
    let close_window = window.clone();
    let close_terminal = terminal.clone();
    close.connect_clicked(move |_| {
        close_terminal.search_set_regex(None, 0);
        close_window.close();
    });
    window.present();
    entry.grab_focus();
}

fn rebuild_terminal_grid(workspace: &WorkspaceWidgets, pane_count: usize, active_pane: usize) {
    while let Some(child) = workspace.terminal_grid.first_child() {
        workspace.terminal_grid.remove(&child);
    }
    for (pane, (column, row, width, height)) in
        terminal_pane_layout(pane_count).into_iter().enumerate()
    {
        workspace.terminal_grid.attach(
            &workspace.terminal_frames[pane],
            column,
            row,
            width,
            height,
        );
    }
    refresh_terminal_focus_style(&workspace.terminal_frames, active_pane);
}

fn render_terminal_backlogs(workspace: &WorkspaceWidgets, backlogs: &[Vec<u8>]) {
    // Reset every reusable VTE, including currently hidden panes. When a
    // middle split closes, later channels shift left and must never inherit
    // the old pane's screen contents or parser state.
    for (pane, terminal) in workspace.terminals.iter().enumerate() {
        terminal.reset(true, true);
        if let Some(backlog) = backlogs.get(pane) {
            terminal.feed(backlog);
        }
    }
}

fn remove_terminal_split(
    runtime: &mut SessionRuntime,
    pane: usize,
) -> Option<TerminalSplitRuntime> {
    if pane == 0 || pane >= runtime.pane_count() {
        return None;
    }
    let removed = runtime.terminal_splits.remove(pane - 1);
    runtime.active_terminal_pane = if runtime.active_terminal_pane == pane {
        pane.saturating_sub(1)
    } else if runtime.active_terminal_pane > pane {
        runtime.active_terminal_pane - 1
    } else {
        runtime.active_terminal_pane
    };
    Some(removed)
}

fn refresh_terminal_focus_style(frames: &[gtk::Box], active_pane: usize) {
    for (pane, frame) in frames.iter().enumerate() {
        if pane == active_pane {
            frame.add_css_class("active");
        } else {
            frame.remove_css_class("active");
        }
    }
}

fn activate_terminal_pane(context: &UiContext, pane: usize, grab_focus: bool) {
    let changed = {
        let mut registry = context.session.borrow_mut();
        let Some(runtime) = registry.active_mut() else {
            return;
        };
        if pane >= runtime.pane_count() {
            return;
        }
        let changed = runtime.active_terminal_pane != pane;
        runtime.active_terminal_pane = pane;
        changed
    };
    if changed {
        refresh_terminal_focus_style(&context.workspace.terminal_frames, pane);
        update_split_actions(context);
    }
    if grab_focus {
        let _ = context.workspace.terminals[pane].grab_focus();
    }
}

fn update_split_actions(context: &UiContext) {
    let (can_add, can_close, can_reset) = context
        .session
        .borrow()
        .active()
        .map(|runtime| {
            let ready = runtime.transport == Transport::Ssh
                && runtime.phase == WorkspacePhase::Connected
                && runtime.base_session_id.is_some();
            (
                ready && runtime.pane_count() < MAX_TERMINAL_PANES,
                ready && runtime.active_terminal_pane > 0,
                ready && runtime.pane_count() > 1,
            )
        })
        .unwrap_or((false, false, false));
    context.workspace.split_add.set_sensitive(can_add);
    context.workspace.split_remove.set_sensitive(can_close);
    context.workspace.split_reset.set_sensitive(can_reset);
}

fn begin_add_terminal_split(context: UiContext) {
    let (asset_id, base_session_id, columns, rows) = {
        let registry = context.session.borrow();
        let Some(runtime) = registry.active() else {
            context.status.set_label("请先连接 SSH 资产。");
            return;
        };
        if runtime.transport != Transport::Ssh || runtime.phase != WorkspacePhase::Connected {
            context
                .status
                .set_label("终端分屏仅适用于已连接的 SSH 资产。");
            return;
        }
        if runtime.pane_count() >= MAX_TERMINAL_PANES {
            context.status.set_label("每个会话最多支持四个终端分屏。");
            return;
        }
        let Some(base_session_id) = runtime.base_session_id else {
            context.status.set_label("SSH 基础会话尚未就绪。");
            return;
        };
        let active = runtime.active_terminal_pane;
        let terminal = &context.workspace.terminals[active];
        (
            runtime.asset_id,
            base_session_id,
            u32::try_from(terminal.column_count()).unwrap_or(120).max(1),
            u32::try_from(terminal.row_count()).unwrap_or(32).max(1),
        )
    };
    context.workspace.split_add.set_sensitive(false);
    context.status.set_label("正在打开独立终端分屏…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let core = CheckedCoreClient::new();
        let request_id = RequestId::new();
        let result = core
            .open_terminal(base_session_id, columns, rows, &request_id)
            .and_then(|opened| {
                opened
                    .require_kind("terminal_channel_opened")
                    .and_then(|value| decimal_id(value, "terminal_channel_id"))
            });
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(channel_id)) => {
                let pane = {
                    let mut registry = context.session.borrow_mut();
                    let Some(runtime) = registry.sessions.get_mut(&asset_id) else {
                        let _ = CheckedCoreClient::new().close_terminal(channel_id);
                        return gtk::glib::ControlFlow::Break;
                    };
                    if runtime.base_session_id != Some(base_session_id)
                        || runtime.phase != WorkspacePhase::Connected
                        || runtime.pane_count() >= MAX_TERMINAL_PANES
                    {
                        let _ = CheckedCoreClient::new().close_terminal(channel_id);
                        return gtk::glib::ControlFlow::Break;
                    }
                    runtime
                        .terminal_splits
                        .push(TerminalSplitRuntime::new(channel_id));
                    runtime.active_terminal_pane = runtime.pane_count() - 1;
                    runtime.active_terminal_pane
                };
                rebuild_terminal_grid(&context.workspace, pane + 1, pane);
                context.workspace.terminals[pane].reset(true, true);
                let _ = context.workspace.terminals[pane].grab_focus();
                update_split_actions(&context);
                context
                    .status
                    .set_label(&format!("终端分屏 {} 已打开并获得焦点。", pane + 1));
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context
                    .status
                    .set_label(&format!("无法打开终端分屏：{error}"));
                update_split_actions(&context);
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.status.set_label("终端分屏工作线程意外退出。");
                update_split_actions(&context);
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn close_terminal_split(context: UiContext, requested_pane: Option<usize>) {
    let (channel_id, pane_backlogs, next_active) = {
        let mut registry = context.session.borrow_mut();
        let Some(runtime) = registry.active_mut() else {
            return;
        };
        let pane = requested_pane.unwrap_or(runtime.active_terminal_pane);
        if pane == 0 || pane >= runtime.pane_count() {
            context
                .status
                .set_label("主终端不能单独关闭；可关闭其他分屏或恢复单屏。");
            return;
        }
        let Some(removed) = remove_terminal_split(runtime, pane) else {
            return;
        };
        (
            removed.channel_id,
            (0..runtime.pane_count())
                .map(|index| runtime.pane_backlog(index).to_vec())
                .collect::<Vec<_>>(),
            runtime.active_terminal_pane,
        )
    };
    rebuild_terminal_grid(&context.workspace, pane_backlogs.len(), next_active);
    render_terminal_backlogs(&context.workspace, &pane_backlogs);
    let _ = context.workspace.terminals[next_active].grab_focus();
    update_split_actions(&context);
    context.status.set_label("终端分屏已安全关闭。");
    std::thread::spawn(move || {
        let _ = CheckedCoreClient::new().close_terminal(channel_id);
    });
}

fn reset_terminal_splits(context: UiContext) {
    let channels = {
        let mut registry = context.session.borrow_mut();
        let Some(runtime) = registry.active_mut() else {
            return;
        };
        runtime.active_terminal_pane = 0;
        runtime
            .terminal_splits
            .drain(..)
            .map(|split| split.channel_id)
            .collect::<Vec<_>>()
    };
    if channels.is_empty() {
        return;
    }
    rebuild_terminal_grid(&context.workspace, 1, 0);
    let backlog = context
        .session
        .borrow()
        .active()
        .map(|runtime| runtime.terminal_backlog.clone())
        .unwrap_or_default();
    render_terminal_backlogs(&context.workspace, &[backlog]);
    let _ = context.workspace.terminals[0].grab_focus();
    update_split_actions(&context);
    context
        .status
        .set_label("已恢复单屏，其他终端通道已安全关闭。");
    std::thread::spawn(move || {
        let core = CheckedCoreClient::new();
        for channel_id in channels {
            let _ = core.close_terminal(channel_id);
        }
    });
}

fn terminal_key_sequence(key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> Option<Vec<u8>> {
    let control = modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK);
    let alt = modifiers.contains(gtk::gdk::ModifierType::ALT_MASK);
    let special: Option<&[u8]> = match key {
        gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => Some(b"\r"),
        gtk::gdk::Key::BackSpace => Some(b"\x7f"),
        gtk::gdk::Key::Tab => Some(b"\t"),
        gtk::gdk::Key::Escape => Some(b"\x1b"),
        gtk::gdk::Key::Up => Some(b"\x1b[A"),
        gtk::gdk::Key::Down => Some(b"\x1b[B"),
        gtk::gdk::Key::Right => Some(b"\x1b[C"),
        gtk::gdk::Key::Left => Some(b"\x1b[D"),
        gtk::gdk::Key::Home => Some(b"\x1b[H"),
        gtk::gdk::Key::End => Some(b"\x1b[F"),
        gtk::gdk::Key::Insert => Some(b"\x1b[2~"),
        gtk::gdk::Key::Delete => Some(b"\x1b[3~"),
        gtk::gdk::Key::Page_Up => Some(b"\x1b[5~"),
        gtk::gdk::Key::Page_Down => Some(b"\x1b[6~"),
        _ => None,
    };
    if let Some(sequence) = special {
        return Some(sequence.to_vec());
    }
    let character = key.to_unicode()?;
    let mut bytes = Vec::with_capacity(5);
    if alt {
        bytes.push(0x1b);
    }
    if control {
        let upper = character.to_ascii_uppercase();
        if upper == ' ' || upper == '@' {
            bytes.push(0);
            return Some(bytes);
        }
        if upper.is_ascii_uppercase() {
            bytes.push((upper as u8) - b'A' + 1);
            return Some(bytes);
        }
        return None;
    }
    if alt {
        let mut encoded = [0; 4];
        bytes.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
        Some(bytes)
    } else {
        None
    }
}

fn is_local_preinput_clipboard_shortcut(
    key: gtk::gdk::Key,
    modifiers: gtk::gdk::ModifierType,
) -> bool {
    modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
        && modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK)
        && matches!(
            key,
            gtk::gdk::Key::c | gtk::gdk::Key::C | gtk::gdk::Key::v | gtk::gdk::Key::V
        )
}

fn show_session_error(context: &UiContext, asset_id: Uuid, message: &str) {
    set_session_phase(context, asset_id, WorkspacePhase::Failed);
    context.status.set_label(message);
}

fn begin_disconnect(context: UiContext) {
    let Some(asset_id) = context.session.borrow().active_workspace_id else {
        return;
    };
    disconnect_workspace(context, asset_id, false);
}

fn close_workspace(context: UiContext, asset_id: Uuid) {
    disconnect_workspace(context, asset_id, true);
}

fn disconnect_workspace(context: UiContext, asset_id: Uuid, remove_tab: bool) {
    cancel_rdp_auto_reconnect(&context, asset_id);
    let was_active = context.session.borrow().active_workspace_id == Some(asset_id);
    if was_active && context.module_fullscreen.get() {
        exit_module_fullscreen(&context);
    }
    if was_active {
        prepare_workspace_input_handoff(&context, None);
    }
    context
        .active_tunnels
        .borrow_mut()
        .retain(|tunnel| tunnel.asset_id != asset_id);
    let (terminal_ids, sftp_id, base_id) = {
        let mut registry = context.session.borrow_mut();
        let Some(runtime) = registry.sessions.get_mut(&asset_id) else {
            return;
        };
        if let Some(telnet) = runtime.telnet.take() {
            telnet.close();
        }
        if let Some(rdp) = runtime.rdp.take() {
            rdp.close();
        }
        runtime.rdp_frame = None;
        runtime.rdp_frame_size = None;
        runtime.terminal_size = None;
        runtime.monitor_in_flight = false;
        runtime.phase = WorkspacePhase::Disconnected;
        (
            runtime.take_terminal_channels(),
            runtime.sftp_session_id.take(),
            runtime.base_session_id.take(),
        )
    };
    if remove_tab {
        let mut registry = context.session.borrow_mut();
        registry.sessions.remove(&asset_id);
        if registry.active_workspace_id == Some(asset_id) {
            registry.active_workspace_id = registry.sessions.keys().next().copied();
        }
        context.rdp_metrics.borrow_mut().remove(&asset_id);
    }
    refresh_session_tabs(&context);
    if was_active {
        let (active, selected) = {
            let registry = context.session.borrow();
            (registry.active_workspace_id, registry.selected_asset_id)
        };
        if active.is_some() {
            render_active_workspace(&context);
        } else if let Some(selected) = selected {
            select_asset(&context, selected);
        }
    }
    if terminal_ids.is_empty() && sftp_id.is_none() && base_id.is_none() {
        context.status.set_label(if remove_tab {
            "会话标签已关闭。"
        } else {
            "会话已断开。"
        });
        return;
    }
    context.status.set_label("正在安全关闭 SSH 会话与工具通道…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let core = CheckedCoreClient::new();
        let mut errors = Vec::new();
        for id in terminal_ids {
            if let Err(error) = core.close_terminal(id) {
                errors.push(error.to_string());
            }
        }
        if let Some(id) = sftp_id {
            if let Err(error) = core.close_sftp(id) {
                errors.push(error.to_string());
            }
        }
        if let Some(id) = base_id {
            if let Err(error) = core.disconnect(id) {
                errors.push(error.to_string());
            }
        }
        let _ = sender.send(errors);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(errors) => {
                if errors.is_empty() {
                    context.status.set_label(if remove_tab {
                        "会话已安全关闭。"
                    } else {
                        "会话已安全断开，可重新连接。"
                    });
                } else {
                    context.status.set_label(&format!(
                        "会话已在本地关闭；远端关闭返回：{}",
                        errors.join("；")
                    ));
                }
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context
                    .status
                    .set_label("关闭工作线程意外退出，本地会话已释放。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn install_monitor_timer(context: UiContext) {
    gtk::glib::timeout_add_local(Duration::from_secs(1), move || {
        let preferences = context.preferences.borrow();
        let next = context.monitor_tick.get().saturating_add(1);
        context.monitor_tick.set(next);
        if preferences.monitor_auto_refresh
            && next.is_multiple_of(preferences.monitor_refresh_seconds)
        {
            drop(preferences);
            begin_monitor_refresh(context.clone());
        }
        gtk::glib::ControlFlow::Continue
    });
}

fn install_background_sync_scheduler(context: UiContext) {
    let timer_context = context.clone();
    gtk::glib::timeout_add_local(Duration::from_secs(5), move || {
        trigger_background_sync(timer_context.clone());
        gtk::glib::ControlFlow::Continue
    });

    let network_monitor = gtk::gio::NetworkMonitor::default();
    let network_context = context.clone();
    network_monitor.connect_network_changed(move |_, available| {
        if available {
            trigger_background_sync(network_context.clone());
        }
    });
    trigger_background_sync(context);
}

fn trigger_background_sync(context: UiContext) {
    if !context.sync_scheduler.try_begin_background() {
        return;
    }
    gtk::glib::spawn_future_local(async move {
        let material = match AuthTokenVault.lookup().await {
            Ok(Some(material)) => material,
            Ok(None) => {
                context.sync_status.set_label("登录后可自动同步");
                context.sync_scheduler.finish_background();
                return;
            }
            Err(_) => {
                context.sync_status.set_label("无法读取同步登录");
                context.sync_scheduler.finish_background();
                return;
            }
        };
        let tokens = SyncTokens {
            access_token: material.access_token.clone(),
            refresh_token: material.refresh_token.clone(),
            account_scope: material.account_scope.clone(),
        };
        let account = match account_fingerprint(&tokens.access_token) {
            Ok(account) => account,
            Err(_) => {
                context.sync_status.set_label("同步登录已失效");
                context.sync_scheduler.finish_background();
                return;
            }
        };
        let now = match current_unix_ms() {
            Ok(now) => now,
            Err(_) => {
                context.sync_status.set_label("系统时间异常 · 自动同步暂停");
                context.sync_scheduler.finish_background();
                return;
            }
        };
        let pending = match context.sync_operations.pending(&account) {
            Ok(pending) => pending,
            Err(_) => {
                context.sync_status.set_label("离线队列状态不可用");
                context.sync_scheduler.finish_background();
                return;
            }
        };
        if pending.is_empty() {
            if context.background_pending.borrow().is_some() {
                context.sync_status.set_label("需要人工处理 · 后台增量暂停");
                context.sync_scheduler.finish_background();
                return;
            }
            let Some(master_password) = context.sync_session.password_for(&account, now) else {
                context.sync_status.set_label("已登录 · 主密码已锁定");
                context.sync_scheduler.finish_background();
                return;
            };
            if !context.sync_session.pull_is_due(now, 30_000) {
                context.sync_status.set_label("云同步健康 · 后台增量已启用");
                context.sync_scheduler.finish_background();
                return;
            }
            context.sync_session.record_pull(now);
            context.sync_status.set_label("正在后台拉取增量…");
            start_background_pull_worker(context, tokens, account, master_password);
            return;
        }
        let due = context
            .sync_operations
            .next_due(&account, now)
            .ok()
            .flatten()
            .is_some();
        if !due {
            let wait_seconds = pending[0]
                .next_retry_at_unix_ms
                .saturating_sub(now)
                .saturating_add(999)
                / 1_000;
            context.sync_status.set_label(&format!(
                "离线队列 {} 项 · {} 秒后重试",
                pending.len(),
                wait_seconds
            ));
            context.sync_scheduler.finish_background();
            return;
        }
        context.sync_status.set_label("正在自动恢复离线同步…");
        start_background_queue_worker(context, tokens, account);
    });
}

fn start_background_pull_worker(
    context: UiContext,
    mut tokens: SyncTokens,
    account: String,
    master_password: zeroize::Zeroizing<String>,
) {
    let local_assets = context.catalog.borrow().assets().to_vec();
    let sync_state = context.sync_state.clone();
    let sync_operations = context.sync_operations.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| {
            let cursor = sync_state
                .cursor(&account)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let device_id = sync_state
                .device_id()
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let applied_revisions = sync_state
                .applied_revisions(&account, &local_assets)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let deferred_assets: HashSet<_> = sync_operations
                .pending(&account)
                .map_err(|error| SyncError::LocalState(error.to_string()))?
                .into_iter()
                .map(|item| item.asset_id)
                .collect();
            let batch = client.pull_changes(&mut tokens, cursor)?;
            let checkpoint = SyncCheckpoint {
                revision: batch.next_cursor,
                reset_recovered: batch.reset_recovered,
            };
            let preview = build_pull_preview_with_deferred_for_account(
                batch.items,
                &local_assets,
                &applied_revisions,
                &deferred_assets,
                &master_password,
                &tokens.account_scope,
            )?;
            Ok(PendingSyncRun {
                preview,
                tokens,
                checkpoint: Some(checkpoint),
                account_fingerprint: account,
                device_id,
                master_password,
            })
        });
        let _ = sender.send(BackgroundPullOutcome { result });
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(BackgroundPullOutcome {
                result: Ok(pending),
            }) => {
                if pending.preview.unresolved_count() > 0 {
                    let count = pending.preview.unresolved_count();
                    let notification_key = format!(
                        "{}:{}:{}",
                        pending.account_fingerprint,
                        pending
                            .checkpoint
                            .as_ref()
                            .map_or(0, |checkpoint| checkpoint.revision),
                        count
                    );
                    let material = AuthTokenMaterial {
                        access_token: pending.tokens.access_token.clone(),
                        refresh_token: pending.tokens.refresh_token.clone(),
                        account_scope: pending.tokens.account_scope.clone(),
                    };
                    context.background_pending.replace(Some(pending));
                    context
                        .sync_status
                        .set_label(&format!("需要人工处理 · {count} 项未解决"));
                    if context.sync_session.should_notify(notification_key) {
                        send_manual_sync_notification(&context, count);
                    }
                    let completion_context = context.clone();
                    gtk::glib::spawn_future_local(async move {
                        let _ = AuthTokenVault.store(&material).await;
                        completion_context.sync_scheduler.finish_background();
                    });
                } else {
                    apply_background_preview(context.clone(), pending);
                }
                gtk::glib::ControlFlow::Break
            }
            Ok(BackgroundPullOutcome { result: Err(error) }) => {
                context.sync_scheduler.finish_background();
                context
                    .sync_status
                    .set_label(&format!("后台增量暂停 · {error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.sync_scheduler.finish_background();
                context
                    .sync_status
                    .set_label("后台增量线程退出 · 游标未推进");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn send_manual_sync_notification(context: &UiContext, count: usize) {
    let notification = gtk::gio::Notification::new("OrbitTerm 同步需要处理");
    notification.set_body(Some(&format!(
        "检测到 {count} 项冲突、删除或同步失败。确认前不会推进云端游标。"
    )));
    notification.set_default_action("app.open-sync");
    if let Some(application) = context.window.application() {
        application.send_notification(Some("sync-action-required"), &notification);
    }
}

fn apply_background_preview(context: UiContext, mut pending: PendingSyncRun) {
    gtk::glib::spawn_future_local(async move {
        let mut imported = 0usize;
        let mut failed = 0usize;
        for remote in std::mem::take(&mut pending.preview.satisfied) {
            if save_background_remote(&context, &pending, &remote, None).is_err() {
                failed += 1;
            }
        }
        for candidate in std::mem::take(&mut pending.preview.candidates) {
            if context
                .catalog
                .borrow()
                .assets()
                .iter()
                .any(|asset| asset.id == candidate.asset.id)
            {
                failed += 1;
                continue;
            }
            if context
                .vault
                .store(
                    candidate.asset.credential_id,
                    &candidate.asset.name,
                    &candidate.credential,
                )
                .await
                .is_err()
            {
                failed += 1;
                continue;
            }
            let credential_id = candidate.asset.credential_id;
            let asset = candidate.asset.clone();
            if context
                .catalog
                .borrow_mut()
                .upsert(candidate.asset)
                .is_err()
            {
                let _ = context.vault.clear(credential_id).await;
                failed += 1;
                continue;
            }
            if save_background_remote(&context, &pending, &candidate.remote, Some(&asset)).is_err()
            {
                let _ = context.catalog.borrow_mut().remove(asset.id);
                let _ = context.vault.clear(credential_id).await;
                failed += 1;
                continue;
            }
            imported += 1;
        }
        (context.refresh_assets)();
        if failed > 0 {
            context.sync_scheduler.finish_background();
            context
                .sync_status
                .set_label(&format!("后台写入失败 {failed} 项 · 游标未推进"));
            if context
                .sync_session
                .should_notify(format!("local-write-failed:{failed}"))
            {
                send_manual_sync_notification(&context, failed);
            }
            return;
        }
        let Some(checkpoint) = pending.checkpoint.take() else {
            context.sync_scheduler.finish_background();
            context
                .sync_status
                .set_label("后台全量兼容导入完成 · 游标未确认");
            return;
        };
        start_background_ack(
            context,
            pending.tokens,
            pending.account_fingerprint,
            pending.device_id,
            checkpoint,
            imported,
        );
    });
}

fn save_background_remote(
    context: &UiContext,
    pending: &PendingSyncRun,
    remote: &RemoteConfig,
    local_asset: Option<&ServerAsset>,
) -> Result<(), String> {
    let local_fingerprint = local_asset
        .map(asset_sync_fingerprint)
        .transpose()
        .map_err(|error| error.to_string())?;
    save_remote_state(
        &context.sync_state,
        &pending.account_fingerprint,
        remote,
        local_fingerprint,
    )
}

fn start_background_ack(
    context: UiContext,
    mut tokens: SyncTokens,
    account: String,
    device_id: Uuid,
    checkpoint: SyncCheckpoint,
    imported: usize,
) {
    let state = context.sync_state.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| {
            let revision = client.acknowledge(&mut tokens, device_id, checkpoint.revision)?;
            state
                .save_cursor(&account, revision)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            Ok::<_, SyncError>((tokens, revision))
        });
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok((tokens, revision))) => {
                let material = AuthTokenMaterial {
                    access_token: tokens.access_token.clone(),
                    refresh_token: tokens.refresh_token.clone(),
                    account_scope: tokens.account_scope.clone(),
                };
                let completion_context = context.clone();
                gtk::glib::spawn_future_local(async move {
                    let stored = AuthTokenVault.store(&material).await.is_ok();
                    completion_context.sync_scheduler.finish_background();
                    completion_context.sync_session.clear_notification();
                    let label = if stored {
                        format!("同步健康 · 导入 {imported} 项 · 修订 {revision}")
                    } else {
                        "同步已确认 · 刷新后的登录令牌未保存".to_owned()
                    };
                    completion_context.sync_status.set_label(&label);
                });
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context.sync_scheduler.finish_background();
                context
                    .sync_status
                    .set_label(&format!("后台确认失败 · 游标未推进 · {error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.sync_scheduler.finish_background();
                context
                    .sync_status
                    .set_label("后台确认线程退出 · 游标未推进");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn start_background_queue_worker(context: UiContext, mut tokens: SyncTokens, account: String) {
    let operations = context.sync_operations.clone();
    let state = context.sync_state.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| {
            process_due_sync_queue(&client, &mut tokens, &operations, &state, &account)
        });
        let remaining = operations
            .pending(&account)
            .map_err(|error| error.to_string());
        let _ = sender.send(BackgroundQueueOutcome {
            tokens,
            result,
            remaining,
        });
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(outcome) => {
                let label = match (&outcome.result, &outcome.remaining) {
                    (Ok(completed), Ok(remaining)) if remaining.is_empty() => {
                        if *completed == 0 {
                            "云同步就绪".to_owned()
                        } else {
                            format!("后台同步完成 · 已恢复 {completed} 项")
                        }
                    }
                    (Ok(completed), Ok(remaining)) if *completed > 0 => {
                        format!("后台已恢复 {completed} 项 · 仍待 {} 项", remaining.len())
                    }
                    (Ok(_), Ok(remaining)) => {
                        format!("自动重试未完成 · 队列保留 {} 项", remaining.len())
                    }
                    (Err(_), _) => "自动重试暂停 · 队列已安全保留".to_owned(),
                    (_, Err(_)) => "离线队列状态不可用".to_owned(),
                };
                let material = AuthTokenMaterial {
                    access_token: outcome.tokens.access_token.clone(),
                    refresh_token: outcome.tokens.refresh_token.clone(),
                    account_scope: outcome.tokens.account_scope.clone(),
                };
                let completion_context = context.clone();
                gtk::glib::spawn_future_local(async move {
                    let stored = AuthTokenVault.store(&material).await.is_ok();
                    completion_context.sync_scheduler.finish_background();
                    completion_context.sync_status.set_label(if stored {
                        &label
                    } else {
                        "队列已处理 · 刷新后的登录令牌未保存"
                    });
                });
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.sync_scheduler.finish_background();
                context
                    .sync_status
                    .set_label("自动重试线程退出 · 队列保持不变");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn begin_monitor_refresh(context: UiContext) {
    let (workspace_id, base_session_id) = {
        let mut registry = context.session.borrow_mut();
        let Some(runtime) = registry.active_mut() else {
            return;
        };
        if runtime.transport != Transport::Ssh || runtime.monitor_in_flight {
            return;
        }
        let Some(id) = runtime.base_session_id else {
            return;
        };
        runtime.monitor_in_flight = true;
        (runtime.asset_id, id)
    };
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CheckedCoreClient::new().monitor(base_session_id);
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(snapshot)) => {
                if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&workspace_id)
                {
                    runtime.monitor_in_flight = false;
                }
                if context.session.borrow().active_workspace_id == Some(workspace_id) {
                    render_monitor(&context, &snapshot);
                }
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&workspace_id)
                {
                    runtime.monitor_in_flight = false;
                }
                context.workspace.monitor_latency.set_label("不可用");
                context
                    .status
                    .set_label(&format!("Monitor 采样失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                if let Some(runtime) = context.session.borrow_mut().sessions.get_mut(&workspace_id)
                {
                    runtime.monitor_in_flight = false;
                }
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn render_monitor(context: &UiContext, snapshot: &MonitorSnapshot) {
    let stats = &snapshot.stats;
    {
        let mut history = context.workspace.monitor_history.borrow_mut();
        history.push(snapshot.clone());
        let limit = context.preferences.borrow().monitor_history_samples;
        if history.len() > limit {
            history.remove(0);
        }
    }
    context.workspace.monitor_connection.set_label("已验证");
    context.workspace.monitor_latency.set_label(
        &stats
            .ping_latency_ms
            .map(|value| format!("{value:.0} ms"))
            .unwrap_or_else(|| "不可用".into()),
    );
    context
        .workspace
        .monitor_cpu
        .set_label(&format!("{:.1}%", stats.cpu_usage_percent));
    context
        .workspace
        .monitor_memory
        .set_label(&format!("{:.1}%", stats.mem_used_percent));
    context
        .workspace
        .monitor_disk
        .set_label(&format!("{:.1}%", stats.disk_used_percent));
    context
        .workspace
        .monitor_download
        .set_label(&format!("{:.1} KB/s", stats.rx_rate_kbps));
    context
        .workspace
        .monitor_upload
        .set_label(&format!("{:.1} KB/s", stats.tx_rate_kbps));
    for graph in context.workspace.monitor_graphs.iter() {
        graph.queue_draw();
    }
}

fn present_monitor_detail_window(context: UiContext) {
    let latest = context.workspace.monitor_history.borrow().last().cloned();
    let window = gtk::Window::builder()
        .title("系统监控详情")
        .transient_for(&context.window)
        .modal(false)
        .default_width(860)
        .default_height(760)
        .resizable(true)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 12);
    root.add_css_class("asset-dialog");
    let title = gtk::Label::new(Some("监控详情"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let subtitle = gtk::Label::new(Some("当前已验证 SSH 会话的趋势历史与实时进程"));
    subtitle.add_css_class("caption");
    subtitle.set_xalign(0.0);
    root.append(&subtitle);
    if let Some(snapshot) = latest {
        let info = &snapshot.stats.system_info;
        let summary = gtk::Grid::builder()
            .column_spacing(18)
            .row_spacing(10)
            .build();
        for (row, (name, value)) in [
            ("操作系统", info.os_name.clone()),
            (
                "CPU",
                format!(
                    "{} 核 / {} 线程",
                    info.cpu_core_count, info.cpu_thread_count
                ),
            ),
            (
                "内存",
                format!(
                    "{} MB 总计 · {} MB 可用",
                    info.memory_total_mb, snapshot.stats.mem_available_mb
                ),
            ),
            (
                "交换空间",
                format!("{} / {} MB", info.swap_used_mb, info.swap_total_mb),
            ),
            (
                "磁盘",
                format!("{} / {} MB", info.disk_used_mb, info.disk_total_mb),
            ),
            (
                "采样",
                format!("Unix {} · Host Key 已验证", snapshot.stats.sampled_at_unix),
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let key = gtk::Label::new(Some(name));
            key.add_css_class("caption");
            key.set_xalign(0.0);
            let value = gtk::Label::new(Some(&value));
            value.set_xalign(0.0);
            value.set_selectable(true);
            summary.attach(&key, 0, row as i32, 1, 1);
            summary.attach(&value, 1, row as i32, 1, 1);
        }
        root.append(&summary);
        let metrics = gtk::FlowBox::new();
        metrics.set_selection_mode(gtk::SelectionMode::None);
        metrics.set_min_children_per_line(2);
        metrics.set_max_children_per_line(2);
        metrics.set_column_spacing(10);
        metrics.set_row_spacing(10);
        let mut detail_graphs = Vec::new();
        for (index, (name, value)) in [
            ("CPU", format!("{:.1}%", snapshot.stats.cpu_usage_percent)),
            ("内存", format!("{:.1}%", snapshot.stats.mem_used_percent)),
            ("磁盘", format!("{:.1}%", snapshot.stats.disk_used_percent)),
            ("下载", format!("{:.1} KB/s", snapshot.stats.rx_rate_kbps)),
            ("上传", format!("{:.1} KB/s", snapshot.stats.tx_rate_kbps)),
            (
                "延迟",
                snapshot
                    .stats
                    .ping_latency_ms
                    .map(|v| format!("{v:.0} ms"))
                    .unwrap_or_else(|| "不可用".into()),
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let card = gtk::Box::new(Orientation::Vertical, 4);
            card.add_css_class("monitor-detail-card");
            card.set_size_request(330, 104);
            let heading = gtk::Box::new(Orientation::Horizontal, 6);
            let name_label = gtk::Label::new(Some(name));
            name_label.add_css_class("heading");
            name_label.set_xalign(0.0);
            name_label.set_hexpand(true);
            let value_label = gtk::Label::new(Some(&value));
            value_label.add_css_class("metric");
            heading.append(&name_label);
            heading.append(&value_label);
            card.append(&heading);
            let graph = gtk::DrawingArea::new();
            graph.set_content_height(58);
            graph.set_hexpand(true);
            let history = context.workspace.monitor_history.clone();
            graph.set_draw_func(move |_, cairo, width, height| {
                draw_monitor_history(cairo, width, height, &history.borrow(), index);
            });
            detail_graphs.push(graph.clone());
            card.append(&graph);
            metrics.insert(&card, -1);
        }
        root.append(&metrics);
        let detail_graphs = Rc::new(detail_graphs);
        let weak_window = window.downgrade();
        gtk::glib::timeout_add_local(Duration::from_secs(1), move || {
            if weak_window
                .upgrade()
                .is_none_or(|window| !window.is_visible())
            {
                return gtk::glib::ControlFlow::Break;
            }
            for graph in detail_graphs.iter() {
                graph.queue_draw();
            }
            gtk::glib::ControlFlow::Continue
        });
        root.append(&build_process_monitor(context.clone(), &window));
    } else {
        root.append(&tool_empty_state(
            "暂无监控数据",
            "连接 SSH 资产后将自动采样系统指标。",
            "utilities-system-monitor-symbolic",
        ));
    }
    let close = gtk::Button::with_label("完成");
    close.set_halign(Align::End);
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    root.append(&close);
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&root)
        .build();
    window.set_child(Some(&scroll));
    window.present();
}

fn monitor_history_value(snapshot: &MonitorSnapshot, index: usize) -> f64 {
    match index {
        0 => snapshot.stats.cpu_usage_percent,
        1 => snapshot.stats.mem_used_percent,
        2 => snapshot.stats.disk_used_percent,
        3 => snapshot.stats.rx_rate_kbps,
        4 => snapshot.stats.tx_rate_kbps,
        _ => snapshot.stats.ping_latency_ms.unwrap_or(0.0),
    }
}

fn draw_monitor_history(
    cairo: &gtk::cairo::Context,
    width: i32,
    height: i32,
    history: &[MonitorSnapshot],
    index: usize,
) {
    if history.len() < 2 || width <= 0 || height <= 0 {
        return;
    }
    cairo.set_source_rgba(0.34, 0.65, 1.0, 0.10);
    cairo.set_line_width(1.0);
    for step in 1..4 {
        let y = f64::from(height) * f64::from(step) / 4.0;
        cairo.move_to(0.0, y);
        cairo.line_to(f64::from(width), y);
    }
    let _ = cairo.stroke();
    let values = history
        .iter()
        .map(|snapshot| monitor_history_value(snapshot, index))
        .collect::<Vec<_>>();
    let maximum = values.iter().copied().fold(1.0_f64, f64::max);
    cairo.set_source_rgba(0.20, 0.50, 0.92, 0.95);
    cairo.set_line_width(1.8);
    for (point, value) in values.iter().enumerate() {
        let x = point as f64 * f64::from(width) / (values.len() - 1) as f64;
        let y = f64::from(height) - (value / maximum * (f64::from(height) - 5.0)) - 2.5;
        if point == 0 {
            cairo.move_to(x, y);
        } else {
            cairo.line_to(x, y);
        }
    }
    let _ = cairo.stroke();
}

fn draw_process_history(
    cairo: &gtk::cairo::Context,
    width: i32,
    height: i32,
    history: &[(u32, i64, f64, f64)],
    memory: bool,
) {
    if history.len() < 2 || width <= 0 || height <= 0 {
        return;
    }
    cairo.set_source_rgba(0.34, 0.65, 1.0, 0.10);
    cairo.set_line_width(1.0);
    for step in 1..4 {
        let y = f64::from(height) * f64::from(step) / 4.0;
        cairo.move_to(0.0, y);
        cairo.line_to(f64::from(width), y);
    }
    let _ = cairo.stroke();
    let values = history
        .iter()
        .map(|entry| if memory { entry.3 } else { entry.2 })
        .collect::<Vec<_>>();
    let maximum = values.iter().copied().fold(1.0_f64, f64::max);
    cairo.set_source_rgba(0.20, 0.50, 0.92, 0.95);
    cairo.set_line_width(1.8);
    for (point, value) in values.iter().enumerate() {
        let x = point as f64 * f64::from(width) / (values.len() - 1) as f64;
        let y = f64::from(height) - (value / maximum * (f64::from(height) - 5.0)) - 2.5;
        if point == 0 {
            cairo.move_to(x, y);
        } else {
            cairo.line_to(x, y);
        }
    }
    let _ = cairo.stroke();
}

fn build_process_monitor(context: UiContext, parent: &gtk::Window) -> gtk::Box {
    let section = gtk::Box::new(Orientation::Vertical, 8);
    section.add_css_class("process-monitor-card");
    let heading = gtk::Box::new(Orientation::Horizontal, 8);
    let title = gtk::Label::new(Some("实时进程"));
    title.add_css_class("heading");
    title.set_xalign(0.0);
    title.set_hexpand(true);
    let refresh = gtk::Button::with_label("刷新");
    heading.append(&title);
    heading.append(&refresh);
    section.append(&heading);
    let tools = gtk::Box::new(Orientation::Horizontal, 8);
    let search = gtk::SearchEntry::builder()
        .placeholder_text("搜索 PID、用户或进程")
        .hexpand(true)
        .build();
    let sort =
        gtk::DropDown::from_strings(&["CPU 从高到低", "内存从高到低", "PID 从小到大", "名称 A–Z"]);
    tools.append(&search);
    tools.append(&sort);
    section.append(&tools);
    let header = gtk::Label::new(Some(
        "PID      用户            CPU      内存      状态       进程",
    ));
    header.add_css_class("process-table-header");
    header.set_xalign(0.0);
    section.append(&header);
    let list = gtk::ListBox::new();
    list.add_css_class("process-list");
    list.set_selection_mode(gtk::SelectionMode::Single);
    let scroll = gtk::ScrolledWindow::builder()
        .min_content_height(240)
        .max_content_height(320)
        .child(&list)
        .build();
    section.append(&scroll);
    let selected = gtk::Label::new(Some("选择进程后可查看完整命令与资源信息。"));
    selected.add_css_class("process-selection");
    selected.set_xalign(0.0);
    selected.set_wrap(true);
    selected.set_selectable(true);
    section.append(&selected);
    let process_history = Rc::new(RefCell::new(Vec::<(u32, i64, f64, f64)>::new()));
    let history_row = gtk::Box::new(Orientation::Horizontal, 8);
    for (label, memory) in [("所选进程 CPU", false), ("所选进程内存", true)] {
        let card = gtk::Box::new(Orientation::Vertical, 3);
        card.add_css_class("process-history-card");
        card.set_hexpand(true);
        let caption = gtk::Label::new(Some(label));
        caption.add_css_class("caption");
        caption.set_xalign(0.0);
        let graph = gtk::DrawingArea::new();
        graph.set_content_height(48);
        graph.set_hexpand(true);
        let history = process_history.clone();
        graph.set_draw_func(move |_, cairo, width, height| {
            draw_process_history(cairo, width, height, &history.borrow(), memory);
        });
        card.append(&caption);
        card.append(&graph);
        history_row.append(&card);
    }
    section.append(&history_row);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    let parent_process = gtk::Button::with_label("转到父进程");
    let children = gtk::Button::with_label("查看子进程");
    let terminate = gtk::Button::with_label("结束进程");
    let force = gtk::Button::with_label("强制终止");
    force.add_css_class("destructive-action");
    for button in [&parent_process, &children, &terminate, &force] {
        button.set_sensitive(false);
        actions.append(button);
    }
    section.append(&actions);
    let status = gtk::Label::new(Some(
        "每 2 秒通过当前 Host Key 已验证会话采样；不会建立旁路连接。",
    ));
    status.add_css_class("caption");
    status.set_xalign(0.0);
    status.set_wrap(true);
    section.append(&status);

    let processes = Rc::new(RefCell::new(Vec::<RemoteProcess>::new()));
    let visible = Rc::new(RefCell::new(Vec::<RemoteProcess>::new()));
    let selected_process = Rc::new(RefCell::new(None::<RemoteProcess>));
    let render: Rc<dyn Fn()> = {
        let list = list.clone();
        let processes = processes.clone();
        let visible = visible.clone();
        let search = search.clone();
        let sort = sort.clone();
        let selected_process = selected_process.clone();
        Rc::new(move || {
            let selected_identity = selected_process
                .borrow()
                .as_ref()
                .map(|process| (process.pid, process.start_identity));
            let query = search.text().trim().to_lowercase();
            let mut filtered = processes
                .borrow()
                .iter()
                .filter(|process| {
                    query.is_empty()
                        || process.pid.to_string().contains(&query)
                        || process.user.to_lowercase().contains(&query)
                        || process.command.to_lowercase().contains(&query)
                        || process.state.to_lowercase().contains(&query)
                })
                .cloned()
                .collect::<Vec<_>>();
            match sort.selected() {
                1 => filtered.sort_by(|left, right| {
                    right
                        .memory_percent
                        .total_cmp(&left.memory_percent)
                        .then_with(|| right.cpu_percent.total_cmp(&left.cpu_percent))
                }),
                2 => filtered.sort_by_key(|process| process.pid),
                3 => filtered.sort_by_cached_key(|process| process.command.to_lowercase()),
                _ => filtered.sort_by(|left, right| {
                    right
                        .cpu_percent
                        .total_cmp(&left.cpu_percent)
                        .then_with(|| right.memory_percent.total_cmp(&left.memory_percent))
                }),
            }
            let mut selected_index = None;
            for (index, process) in filtered.iter().enumerate() {
                let text = format!(
                    "{:<8} {:<15.15} {:>6.1}% {:>7.1}%  {:<9.9}  {}",
                    process.pid,
                    process.user,
                    process.cpu_percent,
                    process.memory_percent,
                    process.state,
                    process.command
                );
                if let Some(label) = list
                    .row_at_index(index as i32)
                    .and_then(|row| row.child())
                    .and_then(|child| child.downcast::<gtk::Label>().ok())
                {
                    if label.text().as_str() != text {
                        label.set_label(&text);
                    }
                } else {
                    let label = gtk::Label::new(Some(&text));
                    label.add_css_class("process-row");
                    label.set_xalign(0.0);
                    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    list.append(&label);
                }
                if selected_identity == Some((process.pid, process.start_identity)) {
                    selected_index = Some(index as i32);
                }
            }
            while let Some(row) = list.row_at_index(filtered.len() as i32) {
                list.remove(&row);
            }
            visible.replace(filtered);
            if let Some(index) = selected_index {
                if let Some(row) = list.row_at_index(index) {
                    if list
                        .selected_row()
                        .as_ref()
                        .map(|selected| selected.index())
                        != Some(index)
                    {
                        list.select_row(Some(&row));
                    }
                }
            } else if list.selected_row().is_some() {
                list.unselect_all();
            }
        })
    };
    let search_render = render.clone();
    search.connect_search_changed(move |_| search_render());
    let sort_render = render.clone();
    sort.connect_selected_notify(move |_| sort_render());

    let selection_visible = visible.clone();
    let selection_process = selected_process.clone();
    let selection_label = selected.clone();
    let selection_parent = parent_process.clone();
    let selection_children = children.clone();
    let selection_terminate = terminate.clone();
    let selection_force = force.clone();
    let selection_history = process_history.clone();
    let selection_history_row = history_row.clone();
    list.connect_row_selected(move |_, row| {
        let process = row.and_then(|row| {
            selection_visible
                .borrow()
                .get(row.index() as usize)
                .cloned()
        });
        selection_process.replace(process.clone());
        if let Some(process) = process {
            let identity_changed = selection_history
                .borrow()
                .last()
                .is_some_and(|entry| (entry.0, entry.1) != (process.pid, process.start_identity));
            if identity_changed {
                selection_history.borrow_mut().clear();
            }
            let protected = is_protected_process(&process);
            selection_label.set_label(&format!(
                "{} · PID {} · 父进程 {} · CPU {:.1}% · 内存 {:.1}% · 启动身份 {}\n{}",
                process.command.split_whitespace().next().unwrap_or("进程"),
                process.pid,
                process.parent_pid,
                process.cpu_percent,
                process.memory_percent,
                process.start_identity,
                process.command
            ));
            selection_parent.set_sensitive(process.parent_pid > 0);
            selection_children.set_sensitive(true);
            selection_terminate.set_sensitive(!protected);
            selection_force.set_sensitive(!protected);
            selection_history_row.queue_draw();
        } else {
            selection_label.set_label("选择进程后可查看完整命令与资源信息。");
            for button in [
                &selection_parent,
                &selection_children,
                &selection_terminate,
                &selection_force,
            ] {
                button.set_sensitive(false);
            }
        }
    });

    let parent_list = list.clone();
    let parent_visible = visible.clone();
    let parent_selected = selected_process.clone();
    parent_process.connect_clicked(move |_| {
        let Some(pid) = parent_selected
            .borrow()
            .as_ref()
            .map(|process| process.parent_pid)
        else {
            return;
        };
        if let Some(index) = parent_visible
            .borrow()
            .iter()
            .position(|process| process.pid == pid)
        {
            if let Some(row) = parent_list.row_at_index(index as i32) {
                parent_list.select_row(Some(&row));
            }
        }
    });
    let child_parent = parent.clone();
    let child_processes = processes.clone();
    let child_selected = selected_process.clone();
    children.connect_clicked(move |_| {
        let Some(pid) = child_selected.borrow().as_ref().map(|process| process.pid) else {
            return;
        };
        let names = child_processes
            .borrow()
            .iter()
            .filter(|process| process.parent_pid == pid)
            .map(|process| format!("{} · PID {}", process.command, process.pid))
            .collect::<Vec<_>>();
        let dialog = adw::AlertDialog::builder()
            .heading(format!("PID {pid} 的子进程"))
            .body(if names.is_empty() {
                "当前快照没有子进程。".into()
            } else {
                names.join("\n")
            })
            .close_response("close")
            .build();
        dialog.add_response("close", "完成");
        dialog.present(Some(&child_parent));
    });

    let process_refresh_in_flight = Rc::new(Cell::new(false));
    let refresh_processes: Rc<dyn Fn()> = {
        let context = context.clone();
        let processes = processes.clone();
        let render = render.clone();
        let status = status.clone();
        let refresh = refresh.clone();
        let selected_process = selected_process.clone();
        let process_history = process_history.clone();
        let history_row = history_row.clone();
        let in_flight = process_refresh_in_flight.clone();
        Rc::new(move || {
            if in_flight.replace(true) {
                return;
            }
            let base = context.session.borrow().active().and_then(|runtime| {
                (runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected)
                    .then_some(runtime.base_session_id)
                    .flatten()
            });
            let Some(base_id) = base else {
                status.set_label("当前会话不支持 SSH 进程监控。");
                in_flight.set(false);
                return;
            };
            refresh.set_sensitive(false);
            let (sender, receiver) = mpsc::channel();
            std::thread::spawn(move || {
                let command = "LC_ALL=C ps -eo pid=,ppid=,user=,pcpu=,pmem=,stat=,etimes=,args= --sort=-pcpu 2>/dev/null | head -n 512 | awk 'BEGIN { now=systime() } NF>=8 { command=$8; for(i=9;i<=NF;i++) command=command \" \" $i; printf \"%s %s %s %s %s %s %.0f %s\\n\",$1,$2,$3,$4,$5,$6,now-$7,substr(command,1,1024) }'";
                let result = CheckedCoreClient::new()
                    .exec_output(base_id, command)
                    .and_then(|output| parse_remote_processes(&output.stdout));
                let _ = sender.send(result);
            });
            let processes = processes.clone();
            let render = render.clone();
            let status = status.clone();
            let refresh = refresh.clone();
            let in_flight = in_flight.clone();
            let selected_process = selected_process.clone();
            let process_history = process_history.clone();
            let history_row = history_row.clone();
            gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
                match receiver.try_recv() {
                    Ok(Ok(next)) => {
                        let count = next.len();
                        if let Some(selected) = selected_process.borrow().as_ref() {
                            if let Some(current) = next.iter().find(|process| {
                                process.pid == selected.pid
                                    && process.start_identity == selected.start_identity
                            }) {
                                let mut history = process_history.borrow_mut();
                                history.push((
                                    current.pid,
                                    current.start_identity,
                                    current.cpu_percent,
                                    current.memory_percent,
                                ));
                                if history.len() > 120 {
                                    history.remove(0);
                                }
                            }
                        }
                        processes.replace(next);
                        render();
                        history_row.queue_draw();
                        status.set_label(&format!("实时更新 · 已采集 {count} 个进程"));
                        refresh.set_sensitive(true);
                        in_flight.set(false);
                        gtk::glib::ControlFlow::Break
                    }
                    Ok(Err(error)) => {
                        status.set_label(&format!("进程采样失败，已保留上一次数据：{error}"));
                        refresh.set_sensitive(true);
                        in_flight.set(false);
                        gtk::glib::ControlFlow::Break
                    }
                    Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                    Err(_) => {
                        refresh.set_sensitive(true);
                        in_flight.set(false);
                        gtk::glib::ControlFlow::Break
                    }
                }
            });
        })
    };
    let manual_refresh = refresh_processes.clone();
    refresh.connect_clicked(move |_| manual_refresh());
    let action_refresh = refresh_processes.clone();
    let terminate_context = context.clone();
    let terminate_parent = parent.clone();
    let terminate_selected = selected_process.clone();
    let terminate_status = status.clone();
    terminate.connect_clicked(move |_| {
        if let Some(process) = terminate_selected.borrow().clone() {
            confirm_remote_process_action(
                terminate_context.clone(),
                &terminate_parent,
                process,
                false,
                terminate_status.clone(),
                action_refresh.clone(),
            );
        }
    });
    let action_refresh = refresh_processes.clone();
    let force_context = context.clone();
    let force_parent = parent.clone();
    let force_selected = selected_process.clone();
    let force_status = status.clone();
    force.connect_clicked(move |_| {
        if let Some(process) = force_selected.borrow().clone() {
            confirm_remote_process_action(
                force_context.clone(),
                &force_parent,
                process,
                true,
                force_status.clone(),
                action_refresh.clone(),
            );
        }
    });
    refresh_processes();
    let automatic = refresh_processes.clone();
    let weak_window = parent.downgrade();
    gtk::glib::timeout_add_local(Duration::from_secs(2), move || {
        if weak_window
            .upgrade()
            .is_none_or(|window| !window.is_visible())
        {
            return gtk::glib::ControlFlow::Break;
        }
        automatic();
        gtk::glib::ControlFlow::Continue
    });
    section
}

fn parse_remote_processes(output: &str) -> Result<Vec<RemoteProcess>, BridgeError> {
    let mut processes = Vec::new();
    for line in output.lines().take(512) {
        let mut fields = line.split_whitespace();
        let Some(pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let Some(parent_pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let Some(user) = fields.next() else {
            continue;
        };
        let Some(cpu_percent) = fields.next().and_then(|value| value.parse::<f64>().ok()) else {
            continue;
        };
        let Some(memory_percent) = fields.next().and_then(|value| value.parse::<f64>().ok()) else {
            continue;
        };
        let Some(state) = fields.next() else {
            continue;
        };
        let Some(start_identity) = fields.next().and_then(|value| value.parse::<i64>().ok()) else {
            continue;
        };
        let command = fields.collect::<Vec<_>>().join(" ");
        if pid == 0
            || start_identity <= 0
            || !cpu_percent.is_finite()
            || !(0.0..=10_000.0).contains(&cpu_percent)
            || !memory_percent.is_finite()
            || !(0.0..=100.0).contains(&memory_percent)
            || user.is_empty()
            || user.len() > 64
            || state.is_empty()
            || state.len() > 16
            || command.is_empty()
            || command.len() > 1024
            || user.chars().any(char::is_control)
            || state.chars().any(char::is_control)
            || command.chars().any(char::is_control)
        {
            continue;
        }
        processes.push(RemoteProcess {
            pid,
            parent_pid,
            user: user.into(),
            cpu_percent,
            memory_percent,
            state: state.into(),
            start_identity,
            command,
        });
    }
    if !output.trim().is_empty() && processes.is_empty() {
        return Err(BridgeError::InvalidPayloadShape);
    }
    Ok(processes)
}

fn is_protected_process(process: &RemoteProcess) -> bool {
    let name = process.command.split_whitespace().next().unwrap_or("");
    process.pid <= 1
        || matches!(
            name.rsplit('/')
                .next()
                .unwrap_or(name)
                .to_lowercase()
                .as_str(),
            "init" | "systemd" | "sshd" | "kernel_task" | "launchd"
        )
}

fn confirm_remote_process_action(
    context: UiContext,
    parent: &gtk::Window,
    process: RemoteProcess,
    force: bool,
    status: gtk::Label,
    refresh: Rc<dyn Fn()>,
) {
    if is_protected_process(&process) {
        status.set_label("系统关键进程受保护，OrbitTerm 不允许终止。");
        return;
    }
    let action = if force {
        "强制终止"
    } else {
        "结束进程"
    };
    let dialog = adw::AlertDialog::builder()
        .heading(format!("{action} {}？", process.pid))
        .body(format!(
            "将先核对 PID 的启动身份，防止 PID 复用后误操作。\n\n{}",
            process.command
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("confirm", action);
    dialog.set_response_appearance("confirm", adw::ResponseAppearance::Destructive);
    let parent = parent.clone();
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&parent)).await.as_str() != "confirm" {
            return;
        }
        let base = context.session.borrow().active().and_then(|runtime| {
            (runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected)
                .then_some(runtime.base_session_id)
                .flatten()
        });
        let Some(base_id) = base else {
            status.set_label("会话已断开，进程操作未执行。");
            return;
        };
        status.set_label(&format!("正在{action} PID {}…", process.pid));
        let signal = if force { "KILL" } else { "TERM" };
        let command = format!(
            "pid={}; expected={}; now=$(date +%s 2>/dev/null); elapsed=$(LC_ALL=C ps -p \"$pid\" -o etimes= 2>/dev/null | tr -d '[:space:]'); result=not_found; case \"$elapsed\" in ''|*[!0-9]*) result=not_found ;; *) current=$((now-elapsed)); delta=$((current-expected)); [ \"$delta\" -lt 0 ] && delta=$((-delta)); if [ \"$pid\" -le 1 ]; then result=protected; elif [ \"$delta\" -gt 2 ]; then result=identity_changed; elif kill -{} \"$pid\" 2>/dev/null; then result=completed; else result=permission_denied; fi ;; esac; printf '__ORBIT_PROCESS_ACTION__:%s\\n' \"$result\"",
            process.pid, process.start_identity, signal
        );
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result = CheckedCoreClient::new().exec_output(base_id, &command);
            let _ = sender.send(result);
        });
        gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
            match receiver.try_recv() {
                Ok(Ok(output)) => {
                    let outcome = output
                        .stdout
                        .lines()
                        .find_map(|line| line.strip_prefix("__ORBIT_PROCESS_ACTION__:"))
                        .unwrap_or("invalid");
                    status.set_label(match outcome {
                        "completed" => "进程操作已完成。",
                        "not_found" => "进程已经结束或不存在。",
                        "identity_changed" => "PID 身份已经变化，操作已安全取消。",
                        "protected" => "系统关键进程受保护，操作已拒绝。",
                        "permission_denied" => "远端权限不足，进程未被终止。",
                        _ => "远端返回无法验证，进程状态请手动复核。",
                    });
                    refresh();
                    gtk::glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    status.set_label(&format!("进程操作失败：{error}"));
                    gtk::glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                Err(_) => gtk::glib::ControlFlow::Break,
            }
        });
    });
}

fn begin_sftp_list(context: UiContext, path: String) {
    let requested_path = path.trim().to_owned();
    let (base_id, sftp_id) = {
        let registry = context.session.borrow();
        let Some(runtime) = registry.active() else {
            context.tools.sftp_status.set_label("请先连接服务器。");
            return;
        };
        if runtime.transport != Transport::Ssh {
            context.tools.sftp_status.set_label("此协议不提供 SFTP。");
            return;
        }
        (runtime.base_session_id, runtime.sftp_session_id)
    };
    let Some(base_id) = base_id else {
        context.tools.sftp_status.set_label("请先连接服务器。");
        return;
    };
    context.tools.sftp_refresh.set_sensitive(false);
    context.tools.sftp_status.set_label("正在读取远程目录…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let core = CheckedCoreClient::new();
        let result = (|| {
            let (session_id, home_path) = match sftp_id {
                Some(id) => (id, None),
                None => {
                    let session = core.open_sftp_session(base_id)?;
                    (session.id, Some(session.home_path))
                }
            };
            let worker_path =
                if requested_path.is_empty() || (sftp_id.is_none() && requested_path == "/") {
                    home_path.unwrap_or_else(|| "/".to_owned())
                } else {
                    normalize_remote_path(&requested_path)
                };
            let listing = core.list_sftp_directory(session_id, &worker_path)?;
            Ok::<_, BridgeError>((session_id, listing))
        })();
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok((session_id, listing))) => {
                let active_id = context.session.borrow().active_workspace_id;
                let owns_session = active_id.and_then(|id| {
                    context
                        .session
                        .borrow()
                        .sessions
                        .get(&id)
                        .map(|runtime| runtime.base_session_id == Some(base_id))
                }) == Some(true);
                if owns_session {
                    if let Some(runtime) = context.session.borrow_mut().active_mut() {
                        runtime.sftp_session_id = Some(session_id);
                    }
                    render_sftp_listing(&context, listing);
                }
                context.tools.sftp_refresh.set_sensitive(true);
                context.tools.sftp_upload.set_sensitive(owns_session);
                context.tools.sftp_new_directory.set_sensitive(owns_session);
                context.tools.sftp_new_file.set_sensitive(owns_session);
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context.tools.sftp_refresh.set_sensitive(true);
                context
                    .tools
                    .sftp_status
                    .set_label(&format!("SFTP 读取失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.tools.sftp_refresh.set_sensitive(true);
                context
                    .tools
                    .sftp_status
                    .set_label("SFTP 工作线程意外退出。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn render_sftp_listing(context: &UiContext, mut listing: SftpDirectoryListing) {
    listing.entries.sort_by(|left, right| {
        right
            .is_directory()
            .cmp(&left.is_directory())
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });
    clear_list(&context.tools.sftp_list);
    for entry in &listing.entries {
        let row = gtk::ListBoxRow::new();
        row.set_activatable(true);
        row.add_css_class("tool-row");
        let body = gtk::Box::new(Orientation::Horizontal, 8);
        let icon = gtk::Image::from_icon_name(if entry.is_directory() {
            "folder-symbolic"
        } else {
            "text-x-generic-symbolic"
        });
        let copy = gtk::Box::new(Orientation::Vertical, 1);
        copy.set_hexpand(true);
        let name = gtk::Label::new(Some(&entry.name));
        name.set_xalign(0.0);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        let detail = gtk::Label::new(Some(&format!(
            "{} · {}",
            entry.permissions,
            format_byte_count(entry.size)
        )));
        detail.add_css_class("caption");
        detail.set_xalign(0.0);
        copy.append(&name);
        copy.append(&detail);
        body.append(&icon);
        body.append(&copy);
        row.set_child(Some(&body));
        let click = gtk::GestureClick::new();
        click.set_button(3);
        let menu_context = context.clone();
        let menu_row = row.clone();
        click.connect_pressed(move |gesture, _, x, y| {
            menu_context.tools.sftp_list.select_row(Some(&menu_row));
            present_sftp_context_menu(menu_context.clone(), &menu_row, x, y);
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        row.add_controller(click);
        context.tools.sftp_list.append(&row);
    }
    context.tools.sftp_path.set_text(&listing.path);
    context.tools.sftp_up.set_sensitive(listing.path != "/");
    context.tools.sftp_entries.replace(listing.entries);
    context.tools.sftp_status.set_label(&format!(
        "{} · {} 项 · Host Key 已验证",
        listing.path,
        context.tools.sftp_entries.borrow().len()
    ));
}

fn present_sftp_context_menu(context: UiContext, row: &gtk::ListBoxRow, x: f64, y: f64) {
    let Some((entry, _)) = selected_sftp_entry(&context) else {
        return;
    };
    let popover = gtk::Popover::new();
    popover.add_css_class("sftp-context-menu");
    popover.set_parent(row);
    popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(
        x.round() as i32,
        y.round() as i32,
        1,
        1,
    )));
    let actions = gtk::Box::new(Orientation::Vertical, 2);
    actions.set_margin_top(6);
    actions.set_margin_bottom(6);
    actions.set_margin_start(6);
    actions.set_margin_end(6);

    let add_action = |label: &str, icon: &str, action: Rc<dyn Fn()>| {
        let button = command_button(label, icon, label);
        button.add_css_class("flat");
        button.set_halign(Align::Fill);
        let menu = popover.clone();
        button.connect_clicked(move |_| {
            menu.popdown();
            action();
        });
        actions.append(&button);
    };

    let row_index = row.index();
    let open_context = context.clone();
    add_action(
        if entry.is_directory() {
            "打开目录"
        } else {
            "预览与编辑"
        },
        if entry.is_directory() {
            "folder-open-symbolic"
        } else {
            "document-edit-symbolic"
        },
        Rc::new(move || activate_sftp_row(open_context.clone(), row_index)),
    );
    if entry.is_directory() {
        let create_dir = context.clone();
        add_action(
            "新建目录",
            "folder-new-symbolic",
            Rc::new(move || {
                prompt_sftp_create(create_dir.clone(), true);
            }),
        );
        let create_file = context.clone();
        add_action(
            "新建文件",
            "document-new-symbolic",
            Rc::new(move || {
                prompt_sftp_create(create_file.clone(), false);
            }),
        );
    } else {
        let download = context.clone();
        add_action(
            "下载…",
            "document-save-symbolic",
            Rc::new(move || begin_sftp_download(download.clone())),
        );
    }
    let rename = context.clone();
    add_action(
        "重命名…",
        "document-edit-symbolic",
        Rc::new(move || prompt_sftp_rename(rename.clone())),
    );
    let chmod = context.clone();
    add_action(
        "修改权限…",
        "changes-prevent-symbolic",
        Rc::new(move || prompt_sftp_chmod(chmod.clone())),
    );
    let delete = context.clone();
    add_action(
        "删除…",
        "user-trash-symbolic",
        Rc::new(move || confirm_sftp_delete(delete.clone())),
    );
    popover.set_child(Some(&actions));
    popover.popup();
}

fn activate_sftp_row(context: UiContext, index: i32) {
    let Some(entry) = usize::try_from(index)
        .ok()
        .and_then(|index| context.tools.sftp_entries.borrow().get(index).cloned())
    else {
        return;
    };
    let path = join_remote_path(context.tools.sftp_path.text().as_str(), &entry.name);
    if entry.is_directory() {
        begin_sftp_list(context, path);
        return;
    }
    let Some(sftp_id) = context
        .session
        .borrow()
        .active()
        .and_then(|runtime| runtime.sftp_session_id)
    else {
        return;
    };
    context.tools.sftp_status.set_label("正在读取文本预览…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CheckedCoreClient::new().read_sftp_text(sftp_id, &path);
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(file)) => {
                context.tools.sftp_status.set_label(&format!(
                    "{} · {}",
                    file.path,
                    format_byte_count(file.byte_length)
                ));
                present_sftp_editor(context.clone(), entry.clone(), file.path, file.content);
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context
                    .tools
                    .sftp_status
                    .set_label(&format!("无法预览文件：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => gtk::glib::ControlFlow::Break,
        }
    });
}

fn selected_sftp_entry(context: &UiContext) -> Option<(SftpEntry, String)> {
    let index = usize::try_from(context.tools.sftp_list.selected_row()?.index()).ok()?;
    let entry = context.tools.sftp_entries.borrow().get(index)?.clone();
    let path = join_remote_path(context.tools.sftp_path.text().as_str(), &entry.name);
    Some((entry, path))
}

fn active_sftp_session(context: &UiContext) -> Option<u64> {
    context
        .session
        .borrow()
        .active()
        .filter(|runtime| {
            runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected
        })
        .and_then(|runtime| runtime.sftp_session_id)
}

fn run_sftp_mutation<F>(context: UiContext, progress: &'static str, operation: F)
where
    F: FnOnce(&CheckedCoreClient, u64) -> Result<(), BridgeError> + Send + 'static,
{
    let Some(sftp_id) = active_sftp_session(&context) else {
        context.tools.sftp_status.set_label("SFTP 会话尚未就绪。");
        return;
    };
    context.tools.sftp_status.set_label(progress);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = operation(&CheckedCoreClient::new(), sftp_id);
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(())) => {
                let path = context.tools.sftp_path.text().to_string();
                context
                    .tools
                    .sftp_status
                    .set_label("操作完成，正在刷新目录…");
                begin_sftp_list(context.clone(), path);
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context
                    .tools
                    .sftp_status
                    .set_label(&format!("SFTP 操作失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context
                    .tools
                    .sftp_status
                    .set_label("SFTP 操作线程意外退出。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn prompt_sftp_text<F>(
    context: UiContext,
    title: &str,
    initial: &str,
    confirm_label: &str,
    action: F,
) where
    F: FnOnce(UiContext, String) + 'static,
{
    let entry = gtk::Entry::builder()
        .text(initial)
        .activates_default(true)
        .build();
    entry.set_margin_top(8);
    entry.set_margin_bottom(4);
    let dialog = adw::AlertDialog::builder()
        .heading(title)
        .body("目标必须位于当前目录；现有文件不会被覆盖。")
        .extra_child(&entry)
        .close_response("cancel")
        .default_response("confirm")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("confirm", confirm_label);
    dialog.set_response_appearance("confirm", adw::ResponseAppearance::Suggested);
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() != "confirm" {
            return;
        }
        let value = entry.text().trim().to_owned();
        action(context, value);
    });
}

fn valid_sftp_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && value != "."
        && value != ".."
        && !value.contains('/')
        && !value.contains('\\')
        && !value.chars().any(char::is_control)
}

fn prompt_sftp_create(context: UiContext, directory: bool) {
    let title = if directory {
        "新建目录"
    } else {
        "新建文件"
    };
    prompt_sftp_text(context, title, "", "创建", move |context, name| {
        if !valid_sftp_name(&name) {
            context
                .tools
                .sftp_status
                .set_label("名称无效：不能包含路径分隔符或控制字符。");
            return;
        }
        let path = join_remote_path(context.tools.sftp_path.text().as_str(), &name);
        run_sftp_mutation(context, "正在创建…", move |core, sftp_id| {
            if directory {
                core.create_sftp_directory(sftp_id, &path)
            } else {
                core.create_sftp_file(sftp_id, &path)
            }
        });
    });
}

fn prompt_sftp_rename(context: UiContext) {
    let Some((entry, old_path)) = selected_sftp_entry(&context) else {
        return;
    };
    let initial = entry.name.clone();
    prompt_sftp_text(
        context,
        "重命名",
        &initial,
        "重命名",
        move |context, name| {
            if !valid_sftp_name(&name) {
                context
                    .tools
                    .sftp_status
                    .set_label("名称无效：不能包含路径分隔符或控制字符。");
                return;
            }
            let new_path = join_remote_path(context.tools.sftp_path.text().as_str(), &name);
            let snapshot = SftpEntrySnapshot::from(&entry);
            run_sftp_mutation(
                context,
                "正在核对快照并重命名…",
                move |core, sftp_id| {
                    core.rename_sftp_entry(sftp_id, &old_path, &new_path, &snapshot)
                },
            );
        },
    );
}

fn prompt_sftp_chmod(context: UiContext) {
    let Some((entry, path)) = selected_sftp_entry(&context) else {
        return;
    };
    let initial = format!("{:o}", entry.permissions_octal & 0o7777);
    prompt_sftp_text(
        context,
        "修改权限",
        &initial,
        "应用",
        move |context, mode| {
            let Ok(mode) = u32::from_str_radix(mode.trim(), 8) else {
                context
                    .tools
                    .sftp_status
                    .set_label("权限必须是 0000–7777 的八进制数字。");
                return;
            };
            if mode > 0o7777 {
                context
                    .tools
                    .sftp_status
                    .set_label("权限必须是 0000–7777 的八进制数字。");
                return;
            }
            let snapshot = SftpEntrySnapshot::from(&entry);
            run_sftp_mutation(
                context,
                "正在核对快照并修改权限…",
                move |core, sftp_id| core.chmod_sftp_entry(sftp_id, &path, mode, &snapshot),
            );
        },
    );
}

fn confirm_sftp_delete(context: UiContext) {
    let Some((entry, path)) = selected_sftp_entry(&context) else {
        return;
    };
    let dialog = adw::AlertDialog::builder()
        .heading(format!("删除 {}？", entry.name))
        .body(if entry.is_directory() {
            "仅允许删除空目录；删除前会重新核对目录快照。"
        } else {
            "删除前会重新核对文件大小、权限和修改时间。此操作无法撤销。"
        })
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("delete", "删除");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() != "delete" {
            return;
        }
        let snapshot = SftpEntrySnapshot::from(&entry);
        run_sftp_mutation(
            context,
            "正在核对快照并删除…",
            move |core, sftp_id| core.remove_sftp_entry(sftp_id, &path, &snapshot),
        );
    });
}

fn begin_sftp_upload(context: UiContext) {
    let dialog = gtk::FileDialog::builder().title("选择要上传的文件").build();
    gtk::glib::spawn_future_local(async move {
        let Ok(file) = dialog.open_future(Some(&context.window)).await else {
            return;
        };
        let Some(path) = file.path() else {
            context.tools.sftp_status.set_label("无法访问所选文件。");
            return;
        };
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            context
                .tools
                .sftp_status
                .set_label("文件名不是有效 UTF-8。");
            return;
        };
        if !valid_sftp_name(name) {
            context
                .tools
                .sftp_status
                .set_label("文件名不适合远程路径。");
            return;
        }
        let local = path.to_string_lossy().into_owned();
        let remote = join_remote_path(context.tools.sftp_path.text().as_str(), name);
        run_sftp_mutation(
            context,
            "正在安全上传文件…",
            move |core, sftp_id| core.upload_sftp_file(sftp_id, &local, &remote),
        );
    });
}

fn begin_sftp_download(context: UiContext) {
    let Some((entry, remote)) = selected_sftp_entry(&context) else {
        return;
    };
    if entry.is_directory() {
        context
            .tools
            .sftp_status
            .set_label("目录下载请先进入目录并选择文件。");
        return;
    }
    let dialog = gtk::FileDialog::builder()
        .title("保存远程文件")
        .initial_name(&entry.name)
        .build();
    gtk::glib::spawn_future_local(async move {
        let Ok(file) = dialog.save_future(Some(&context.window)).await else {
            return;
        };
        let Some(path) = file.path() else {
            context.tools.sftp_status.set_label("无法访问目标路径。");
            return;
        };
        if path.exists() {
            context
                .tools
                .sftp_status
                .set_label("为防止覆盖本地文件，请选择一个尚不存在的文件名。");
            return;
        }
        let local = path.to_string_lossy().into_owned();
        run_sftp_mutation(
            context,
            "正在安全下载文件…",
            move |core, sftp_id| core.download_sftp_file(sftp_id, &remote, &local),
        );
    });
}

fn present_sftp_editor(context: UiContext, entry: SftpEntry, path: String, content: String) {
    let window = gtk::Window::builder()
        .title(format!("编辑 {}", entry.name))
        .transient_for(&context.window)
        .modal(true)
        .default_width(760)
        .default_height(560)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 10);
    root.add_css_class("document-editor");
    let heading = gtk::Label::new(Some(&path));
    heading.set_xalign(0.0);
    heading.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    heading.add_css_class("field-label");
    root.append(&heading);
    let editor = gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::None)
        .build();
    editor.buffer().set_text(&content);
    let scroller = gtk::ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .child(&editor)
        .build();
    scroller.add_css_class("document-editor-surface");
    root.append(&scroller);
    let footer = gtk::Box::new(Orientation::Horizontal, 8);
    let status = gtk::Label::new(Some("UTF-8 文本 · 最大 2 MiB · 保存时重新核对远端快照"));
    status.set_xalign(0.0);
    status.set_hexpand(true);
    status.add_css_class("caption");
    let cancel = gtk::Button::with_label("取消");
    let save = gtk::Button::with_label("保存");
    save.add_css_class("suggested-action");
    footer.append(&status);
    footer.append(&cancel);
    footer.append(&save);
    root.append(&footer);
    window.set_child(Some(&root));
    let close_target = window.clone();
    cancel.connect_clicked(move |_| close_target.close());
    let save_context = context.clone();
    let save_window = window.clone();
    save.connect_clicked(move |button| {
        let buffer = editor.buffer();
        let content = buffer
            .text(&buffer.start_iter(), &buffer.end_iter(), true)
            .to_string();
        if content.len() > 2 * 1024 * 1024 || content.as_bytes().contains(&0) {
            status.set_label("文件必须是不超过 2 MiB 且不含 NUL 的 UTF-8 文本。");
            return;
        }
        let Some(sftp_id) = active_sftp_session(&save_context) else {
            status.set_label("SFTP 会话已经关闭，请取消后重新打开文件。");
            return;
        };
        button.set_sensitive(false);
        status.set_label("正在核对远端快照并保存…");
        let snapshot = SftpEntrySnapshot::from(&entry);
        let remote = path.clone();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result =
                CheckedCoreClient::new().write_sftp_text(sftp_id, &remote, &content, &snapshot);
            let _ = sender.send(result);
        });
        let completion_context = save_context.clone();
        let completion_window = save_window.clone();
        let completion_status = status.clone();
        let completion_button = button.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
            match receiver.try_recv() {
                Ok(Ok(())) => {
                    let current = completion_context.tools.sftp_path.text().to_string();
                    completion_window.close();
                    begin_sftp_list(completion_context.clone(), current);
                    gtk::glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    completion_status.set_label(&format!("保存失败：{error}"));
                    completion_button.set_sensitive(true);
                    gtk::glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                Err(mpsc::TryRecvError::Disconnected) => {
                    completion_status.set_label("保存线程意外退出。");
                    completion_button.set_sensitive(true);
                    gtk::glib::ControlFlow::Break
                }
            }
        });
    });
    window.present();
}

fn begin_docker_refresh(context: UiContext) {
    let Some(base_id) = context
        .session
        .borrow()
        .active()
        .filter(|runtime| runtime.transport == Transport::Ssh)
        .and_then(|runtime| runtime.base_session_id)
    else {
        context.tools.docker_status.set_label("请先连接服务器。");
        return;
    };
    context.tools.docker_refresh.set_sensitive(false);
    context
        .tools
        .docker_status
        .set_label("正在读取容器与资源统计…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let core = CheckedCoreClient::new();
        let result = core
            .docker_containers(base_id)
            .and_then(|containers| core.docker_stats(base_id).map(|stats| (containers, stats)));
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok((containers, stats))) => {
                clear_list(&context.tools.docker_list);
                for container in &containers {
                    let stat = stats.iter().find(|item| item.id == container.id);
                    let row = gtk::ListBoxRow::new();
                    row.add_css_class("tool-row");
                    let body = gtk::Box::new(Orientation::Vertical, 2);
                    let title = gtk::Box::new(Orientation::Horizontal, 6);
                    let name = gtk::Label::new(Some(&container.name));
                    name.set_xalign(0.0);
                    name.set_hexpand(true);
                    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    let state = gtk::Label::new(Some(&container.state));
                    state.add_css_class("docker-state-badge");
                    if container.state.eq_ignore_ascii_case("running") {
                        state.add_css_class("running");
                    }
                    title.append(&name);
                    title.append(&state);
                    let detail = gtk::Label::new(Some(&match stat {
                        Some(stat) => format!(
                            "{} · CPU {:.1}% · MEM {:.1}% · {}",
                            container.image, stat.cpu_percent, stat.mem_percent, stat.mem_usage
                        ),
                        None => format!("{} · {}", container.image, container.status),
                    }));
                    detail.add_css_class("caption");
                    detail.set_xalign(0.0);
                    detail.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    let io = gtk::Label::new(Some(&match stat {
                        Some(stat) => format!(
                            "NET {} · BLOCK {} · {} PIDs",
                            stat.net_io, stat.block_io, stat.pids
                        ),
                        None => format!("{} · {}", container.running_for, &container.id[..12]),
                    }));
                    io.add_css_class("caption");
                    io.set_xalign(0.0);
                    io.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    body.append(&title);
                    body.append(&detail);
                    body.append(&io);
                    row.set_child(Some(&body));
                    context.tools.docker_list.append(&row);
                }
                context.tools.docker_containers.replace(containers);
                if let Some(row) = context.tools.docker_list.row_at_index(0) {
                    context.tools.docker_list.select_row(Some(&row));
                }
                let has_selection = !context.tools.docker_containers.borrow().is_empty();
                context.tools.docker_logs.set_sensitive(has_selection);
                context.tools.docker_start.set_sensitive(has_selection);
                context.tools.docker_restart.set_sensitive(has_selection);
                context.tools.docker_stop.set_sensitive(has_selection);
                context.tools.docker_refresh.set_sensitive(true);
                context.tools.docker_status.set_label(&format!(
                    "{} 个容器 · Host Key 已验证",
                    context.tools.docker_containers.borrow().len()
                ));
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context.tools.docker_refresh.set_sensitive(true);
                context
                    .tools
                    .docker_status
                    .set_label(&format!("Docker 读取失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                context.tools.docker_refresh.set_sensitive(true);
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn selected_docker_container(context: &UiContext) -> Option<DockerContainer> {
    let index = usize::try_from(context.tools.docker_list.selected_row()?.index()).ok()?;
    context.tools.docker_containers.borrow().get(index).cloned()
}

fn begin_docker_logs(context: UiContext) {
    let (Some(base_id), Some(container)) = (
        context
            .session
            .borrow()
            .active()
            .filter(|runtime| runtime.transport == Transport::Ssh)
            .and_then(|runtime| runtime.base_session_id),
        selected_docker_container(&context),
    ) else {
        return;
    };
    context.tools.docker_status.set_label("正在读取容器日志…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CheckedCoreClient::new().docker_logs(base_id, &container.id, 200);
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(result)) => {
                context
                    .tools
                    .docker_status
                    .set_label("已读取最近 200 行日志。");
                present_docker_logs_window(&context.window, &container.name, &result.logs);
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context
                    .tools
                    .docker_status
                    .set_label(&format!("日志读取失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => gtk::glib::ControlFlow::Break,
        }
    });
}

fn confirm_docker_action(context: UiContext, action: &'static str) {
    let Some(container) = selected_docker_container(&context) else {
        return;
    };
    let (verb, detail) = match action {
        "start" => ("启动", "容器服务将开始运行。"),
        "restart" => ("重启", "容器会短暂中断服务。"),
        "stop" => ("停止", "容器内服务将停止，直到再次启动。"),
        _ => return,
    };
    let dialog = adw::AlertDialog::builder()
        .heading(format!("{verb}容器 {}？", container.name))
        .body(format!(
            "{detail}\n\n该操作通过当前 Host Key 已验证会话执行。"
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("confirm", verb);
    dialog.set_response_appearance(
        "confirm",
        if action == "start" {
            adw::ResponseAppearance::Suggested
        } else {
            adw::ResponseAppearance::Destructive
        },
    );
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() == "confirm" {
            begin_docker_action(context, action);
        }
    });
}

fn begin_docker_action(context: UiContext, action: &'static str) {
    let (Some(base_id), Some(container)) = (
        context
            .session
            .borrow()
            .active()
            .filter(|runtime| runtime.transport == Transport::Ssh)
            .and_then(|runtime| runtime.base_session_id),
        selected_docker_container(&context),
    ) else {
        return;
    };
    context
        .tools
        .docker_status
        .set_label("正在执行受检 Docker 操作…");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CheckedCoreClient::new().docker_action(base_id, &container.id, action);
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(())) => {
                context
                    .tools
                    .docker_status
                    .set_label("Docker 操作已完成，正在刷新…");
                begin_docker_refresh(context.clone());
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                context
                    .tools
                    .docker_status
                    .set_label(&format!("Docker 操作失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => gtk::glib::ControlFlow::Break,
        }
    });
}

fn clear_list(list: &gtk::ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}

fn normalize_remote_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() || !trimmed.starts_with('/') {
        "/".into()
    } else if trimmed.len() > 1 {
        trimmed.trim_end_matches('/').to_owned()
    } else {
        "/".into()
    }
}

fn join_remote_path(parent: &str, name: &str) -> String {
    if parent == "/" {
        format!("/{name}")
    } else {
        format!("{}/{name}", parent.trim_end_matches('/'))
    }
}

fn parent_remote_path(path: &str) -> String {
    let path = normalize_remote_path(path);
    path.rsplit_once('/')
        .map(|(parent, _)| if parent.is_empty() { "/" } else { parent })
        .unwrap_or("/")
        .to_owned()
}

fn format_byte_count(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;
    let bytes_f = bytes as f64;
    if bytes_f >= GIB {
        format!("{:.1} GiB", bytes_f / GIB)
    } else if bytes_f >= MIB {
        format!("{:.1} MiB", bytes_f / MIB)
    } else if bytes_f >= KIB {
        format!("{:.1} KiB", bytes_f / KIB)
    } else {
        format!("{bytes} B")
    }
}

fn present_docker_logs_window(parent: &adw::ApplicationWindow, name: &str, logs: &str) {
    let window = gtk::Window::builder()
        .title(format!("Docker 日志 · {name}"))
        .transient_for(parent)
        .modal(true)
        .default_width(820)
        .default_height(560)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 10);
    root.add_css_class("document-window");
    let heading = gtk::Label::new(Some(&format!("{name} · 最近 200 行")));
    heading.add_css_class("dialog-title");
    heading.set_xalign(0.0);
    let text = gtk::TextView::new();
    text.set_editable(false);
    text.set_cursor_visible(false);
    text.set_monospace(true);
    text.buffer().set_text(logs);
    let scroll = gtk::ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .child(&text)
        .build();
    let close = gtk::Button::with_label("关闭");
    close.set_halign(Align::End);
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    root.append(&heading);
    root.append(&scroll);
    root.append(&close);
    window.set_child(Some(&root));
    window.present();
}

fn utility_window(
    parent: &adw::ApplicationWindow,
    title: &str,
    width: i32,
    height: i32,
) -> (gtk::Window, gtk::Box) {
    let window = gtk::Window::builder()
        .title(title)
        .transient_for(parent)
        .modal(true)
        .default_width(width)
        .default_height(height)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 14);
    root.add_css_class("asset-dialog");
    (window, root)
}

fn present_asset_manager_window(context: UiContext, search: gtk::SearchEntry) {
    let (window, root) = utility_window(&context.window, "资产管理", 720, 620);
    let header = gtk::Box::new(Orientation::Horizontal, 8);
    let title = gtk::Label::new(Some("服务器资产"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    title.set_hexpand(true);
    let add = gtk::Button::with_label("添加服务器");
    add.add_css_class("suggested-action");
    header.append(&title);
    header.append(&add);
    root.append(&header);
    let filter = gtk::SearchEntry::builder()
        .placeholder_text("搜索名称、地址、分组或标签")
        .build();
    root.append(&filter);
    let bulk = gtk::Box::new(Orientation::Horizontal, 6);
    let select_all = gtk::Button::with_label("全选结果");
    let select_none = gtk::Button::with_label("清空选择");
    let delete_selected = gtk::Button::with_label("批量删除资产");
    delete_selected.add_css_class("destructive-action");
    let group_model = gtk::StringList::new(&[]);
    let groups = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .map(|asset| {
            if asset.group.trim().is_empty() {
                "未分组".to_owned()
            } else {
                asset.group.trim().to_owned()
            }
        })
        .collect::<std::collections::BTreeSet<_>>();
    for group in groups {
        group_model.append(&group);
    }
    let group_selector = gtk::DropDown::builder().model(&group_model).build();
    group_selector.set_hexpand(true);
    let delete_group = gtk::Button::with_label("删除整个分组");
    delete_group.add_css_class("destructive-action");
    bulk.append(&select_all);
    bulk.append(&select_none);
    bulk.append(&delete_selected);
    bulk.append(&group_selector);
    bulk.append(&delete_group);
    root.append(&bulk);
    let status = gtk::Label::new(Some(
        "批量删除会先检查活动会话，并在一次原子写入中提交资产变更。",
    ));
    status.add_css_class("caption");
    status.set_xalign(0.0);
    status.set_wrap(true);
    root.append(&status);
    let list = gtk::ListBox::new();
    list.add_css_class("management-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .child(&list)
        .build();
    root.append(&scroll);
    let close = gtk::Button::with_label("关闭");
    close.set_halign(Align::End);
    root.append(&close);
    window.set_child(Some(&root));

    let selected_assets = Rc::new(RefCell::new(Vec::<(Uuid, String, gtk::CheckButton)>::new()));
    let render: Rc<dyn Fn()> = {
        let list = list.clone();
        let catalog = context.catalog.clone();
        let filter = filter.clone();
        let context = context.clone();
        let selected_assets = selected_assets.clone();
        Rc::new(move || {
            clear_list(&list);
            selected_assets.borrow_mut().clear();
            let query = filter.text().trim().to_lowercase();
            for asset in catalog.borrow().assets().iter().filter(|asset| {
                query.is_empty()
                    || format!(
                        "{} {} {} {}",
                        asset.name,
                        asset.host,
                        asset.group,
                        asset.tags.join(" ")
                    )
                    .to_lowercase()
                    .contains(&query)
            }) {
                let row = gtk::Box::new(Orientation::Horizontal, 10);
                row.add_css_class("management-row");
                let check = gtk::CheckButton::new();
                let identity = gtk::Box::new(Orientation::Vertical, 2);
                identity.set_hexpand(true);
                let name = gtk::Label::new(Some(&format!(
                    "{}  ·  {}",
                    asset.name,
                    asset.transport.display_name()
                )));
                name.set_xalign(0.0);
                name.add_css_class("heading");
                let endpoint = gtk::Label::new(Some(&asset.endpoint()));
                endpoint.set_xalign(0.0);
                endpoint.add_css_class("caption");
                identity.append(&name);
                identity.append(&endpoint);
                let edit = gtk::Button::with_label("编辑");
                let asset_id = asset.id;
                let edit_context = context.clone();
                edit.connect_clicked(move |_| {
                    present_edit_asset_window(
                        &edit_context.window,
                        edit_context.catalog.clone(),
                        edit_context.vault.clone(),
                        asset_id,
                        edit_context.refresh_assets.clone(),
                    );
                });
                row.append(&check);
                row.append(&identity);
                row.append(&edit);
                list.append(&row);
                selected_assets
                    .borrow_mut()
                    .push((asset.id, asset.name.clone(), check));
            }
        })
    };
    let render_for_filter = render.clone();
    filter.connect_search_changed(move |_| render_for_filter());
    let add_context = context.clone();
    add.connect_clicked(move |_| {
        present_add_asset_window(
            &add_context.window,
            add_context.catalog.clone(),
            add_context.vault.clone(),
            add_context.refresh_assets.clone(),
        );
    });
    let checks = selected_assets.clone();
    select_all.connect_clicked(move |_| {
        for (_, _, check) in checks.borrow().iter() {
            check.set_active(true);
        }
    });
    let checks = selected_assets.clone();
    select_none.connect_clicked(move |_| {
        for (_, _, check) in checks.borrow().iter() {
            check.set_active(false);
        }
    });
    let delete_context = context.clone();
    let delete_checks = selected_assets.clone();
    let delete_status = status.clone();
    let delete_render = render.clone();
    delete_selected.connect_clicked(move |_| {
        let targets = delete_checks
            .borrow()
            .iter()
            .filter_map(|(id, name, check)| check.is_active().then_some((*id, name.clone())))
            .collect::<Vec<_>>();
        confirm_asset_batch_delete(
            delete_context.clone(),
            targets,
            delete_status.clone(),
            delete_render.clone(),
            "删除所选资产",
        );
    });
    let group_context = context.clone();
    let group_status = status.clone();
    let group_render = render.clone();
    delete_group.connect_clicked(move |_| {
        let Some(group_name) = group_selector
            .selected_item()
            .and_downcast::<gtk::StringObject>()
        else {
            group_status.set_label("没有可删除的分组。");
            return;
        };
        let group_name = group_name.string().to_string();
        let targets = group_context
            .catalog
            .borrow()
            .assets()
            .iter()
            .filter(|asset| {
                let actual = if asset.group.trim().is_empty() {
                    "未分组"
                } else {
                    asset.group.trim()
                };
                actual == group_name
            })
            .map(|asset| (asset.id, asset.name.clone()))
            .collect::<Vec<_>>();
        confirm_asset_batch_delete(
            group_context.clone(),
            targets,
            group_status.clone(),
            group_render.clone(),
            &format!("删除分组“{group_name}”"),
        );
    });
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    search.set_text("");
    render();
    window.present();
}

fn confirm_asset_batch_delete(
    context: UiContext,
    targets: Vec<(Uuid, String)>,
    status: gtk::Label,
    rerender: Rc<dyn Fn()>,
    heading: &str,
) {
    if targets.is_empty() {
        status.set_label("请先选择至少一项资产或分组。");
        return;
    }
    let active = targets
        .iter()
        .filter(|(id, _)| context.session.borrow().sessions.contains_key(id))
        .map(|(_, name)| name.clone())
        .collect::<Vec<_>>();
    if !active.is_empty() {
        status.set_label(&format!(
            "以下资产仍有会话，批量删除已阻止：{}。请先关闭对应标签。",
            active.join("、")
        ));
        return;
    }
    let heading = heading.to_owned();
    let names = targets
        .iter()
        .map(|(_, name)| name.as_str())
        .collect::<Vec<_>>()
        .join("、");
    let dialog = adw::AlertDialog::builder()
        .heading(heading)
        .body(format!(
            "将删除 {} 项本机资产：{}。该操作不会直接删除云端记录；同步中心仍会要求明确处理冲突或墓碑。",
            targets.len(),
            names
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("delete", "确认删除");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&context.window)).await.as_str() != "delete" {
            return;
        }
        let ids = targets.iter().map(|(id, _)| *id).collect::<HashSet<_>>();
        let removed = match context.catalog.borrow_mut().remove_many(&ids) {
            Ok(removed) => removed,
            Err(error) => {
                status.set_label(&format!("批量删除失败，资产库保持不变：{error}"));
                return;
            }
        };
        let mut keyring_failures = 0usize;
        for asset in &removed {
            if context.vault.clear(asset.credential_id).await.is_err() {
                keyring_failures += 1;
            }
            if let Some(jump) = &asset.jump_host {
                if context.vault.clear(jump.credential_id).await.is_err() {
                    keyring_failures += 1;
                }
            }
        }
        (context.refresh_assets)();
        rerender();
        status.set_label(&if keyring_failures == 0 {
            format!(
                "已原子删除 {} 项资产，并清理对应系统密钥环凭据。",
                removed.len()
            )
        } else {
            format!(
                "已删除 {} 项资产；有 {keyring_failures} 条密钥环凭据未能清理，可稍后重试。",
                removed.len()
            )
        });
    });
}

fn present_key_management_window(context: UiContext) {
    let (window, root) = utility_window(&context.window, "密钥管理", 880, 640);
    let title = gtk::Label::new(Some("SSH 密钥资产"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let note = gtk::Label::new(Some(
        "仅列出 SSH 资产。可生成、导入、替换、移除和调整密钥应用范围；私钥与口令保存在系统“密码与密钥”（libsecret）中，不会生成可浏览的明文私钥文件。",
    ));
    note.add_css_class("security-note");
    note.set_xalign(0.0);
    note.set_wrap(true);
    root.append(&note);
    let ssh_assets = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .filter(|asset| asset.transport == Transport::Ssh)
        .cloned()
        .collect::<Vec<_>>();
    let selector_model = gtk::StringList::new(&[]);
    for asset in &ssh_assets {
        selector_model.append(&format!("{} · {}", asset.name, asset.endpoint()));
    }
    let selector = gtk::DropDown::builder().model(&selector_model).build();
    selector.set_hexpand(true);
    let key_actions = gtk::Box::new(Orientation::Horizontal, 6);
    let generate = gtk::Button::with_label("生成密钥对");
    generate.add_css_class("suggested-action");
    let custom_sync = gtk::Button::with_label("自定义应用与同步");
    let sync_center = gtk::Button::with_label("同步中心");
    key_actions.append(&selector);
    key_actions.append(&generate);
    key_actions.append(&custom_sync);
    key_actions.append(&sync_center);
    root.append(&key_actions);
    generate.set_sensitive(!ssh_assets.is_empty());
    custom_sync.set_sensitive(
        ssh_assets
            .iter()
            .any(|asset| asset.auth_method == AuthMethod::Key),
    );
    let assets_for_generate = Rc::new(ssh_assets.clone());
    let generate_context = context.clone();
    let selector_for_generate = selector.clone();
    generate.connect_clicked(move |_| {
        if let Some(asset) = assets_for_generate.get(selector_for_generate.selected() as usize) {
            present_key_setup_window(generate_context.clone(), asset.id);
        }
    });
    let assets_for_sync = Rc::new(ssh_assets);
    let custom_context = context.clone();
    let selector_for_sync = selector.clone();
    custom_sync.connect_clicked(move |_| {
        let selected = assets_for_sync.get(selector_for_sync.selected() as usize);
        let source = selected
            .filter(|asset| asset.auth_method == AuthMethod::Key)
            .or_else(|| {
                assets_for_sync
                    .iter()
                    .find(|asset| asset.auth_method == AuthMethod::Key)
            });
        if let Some(source) = source {
            present_key_custom_sync_window(custom_context.clone(), source.id);
        }
    });
    let sync_context = context.clone();
    sync_center.connect_clicked(move |_| present_sync_window(sync_context.clone()));
    let list = gtk::ListBox::new();
    list.add_css_class("management-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    for asset in context
        .catalog
        .borrow()
        .assets()
        .iter()
        .filter(|asset| asset.transport == Transport::Ssh)
    {
        let row = gtk::Box::new(Orientation::Horizontal, 10);
        row.add_css_class("management-row");
        let configured = asset.auth_method == AuthMethod::Key && !asset.key_reference.is_empty();
        let label = gtk::Label::new(Some(&format!(
            "{}\n{} · {}\n{}",
            asset.name,
            asset.endpoint(),
            if configured {
                "已配置密钥"
            } else {
                "密码认证 · 未配置密钥"
            },
            if configured {
                format!("指纹 {}", asset.key_reference)
            } else {
                "私钥位置：系统密钥环（尚无记录）".into()
            },
        )));
        label.set_xalign(0.0);
        label.set_hexpand(true);
        label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        let edit = gtk::Button::with_label(if configured {
            "替换 / 导入"
        } else {
            "配置"
        });
        let asset_id = asset.id;
        let edit_context = context.clone();
        edit.connect_clicked(move |_| present_key_setup_window(edit_context.clone(), asset_id));
        let scope = gtk::Button::with_label("应用范围");
        scope.set_sensitive(configured);
        let scope_context = context.clone();
        scope.connect_clicked(move |_| {
            present_key_custom_sync_window(scope_context.clone(), asset_id)
        });
        let remove = gtk::Button::with_label("移除");
        remove.add_css_class("destructive-action");
        remove.set_sensitive(configured);
        let remove_context = context.clone();
        let remove_asset = asset.clone();
        let remove_window = window.clone();
        remove.connect_clicked(move |_| {
            let dialog = adw::AlertDialog::builder()
                .heading(format!("移除 {} 的 SSH 密钥？", remove_asset.name))
                .body("只移除系统密钥环中的私钥与资产指纹；若同一凭据还保存了密码，密码会继续保留。远端 authorized_keys 不会自动修改。")
                .close_response("cancel")
                .build();
            dialog.add_response("cancel", "取消");
            dialog.add_response("remove", "确认移除");
            dialog.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
            let context = remove_context.clone();
            let mut asset = remove_asset.clone();
            let parent = remove_window.clone();
            gtk::glib::spawn_future_local(async move {
                if dialog.choose_future(Some(&parent)).await.as_str() != "remove" {
                    return;
                }
                let existing = context.vault.lookup(asset.credential_id).await.ok().flatten();
                let result = if let Some(mut credential) = existing {
                    credential.private_key.clear();
                    credential.private_key_passphrase.clear();
                    if credential.password.is_empty() {
                        context.vault.clear(asset.credential_id).await
                    } else {
                        context.vault.store(asset.credential_id, &asset.name, &credential).await
                    }
                } else {
                    Ok(())
                };
                if let Err(error) = result {
                    context.status.set_label(&format!("密钥移除失败：{error}"));
                    return;
                }
                asset.auth_method = AuthMethod::Password;
                asset.allow_password_fallback = false;
                asset.key_reference.clear();
                match context.catalog.borrow_mut().upsert(asset) {
                    Ok(()) => {
                        (context.refresh_assets)();
                        context.status.set_label("SSH 密钥已从系统密钥环移除；远端公钥保持不变。");
                        parent.close();
                    }
                    Err(error) => context.status.set_label(&format!("资产元数据更新失败：{error}")),
                }
            });
        });
        row.append(&label);
        row.append(&edit);
        row.append(&scope);
        row.append(&remove);
        list.append(&row);
    }
    if list.first_child().is_none() {
        list.append(&gtk::Label::new(Some("暂无 SSH 资产。")));
    }
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&list)
            .build(),
    );
    let close = gtk::Button::with_label("关闭");
    close.set_halign(Align::End);
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    root.append(&close);
    window.set_child(Some(&root));
    window.present();
}

fn present_key_custom_sync_window(context: UiContext, source_id: Uuid) {
    let assets = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .filter(|asset| asset.transport == Transport::Ssh)
        .cloned()
        .collect::<Vec<_>>();
    let Some(source) = assets.iter().find(|asset| asset.id == source_id).cloned() else {
        return;
    };
    let (window, root) = utility_window(&context.window, "自定义密钥应用与同步", 620, 640);
    let title = gtk::Label::new(Some(&format!("{} · 自定义密钥范围", source.name)));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let note = gtk::Label::new(Some(
        "选择要复用此密钥的 SSH 资产。OrbitTerm 会把私钥写入每个目标资产的系统密钥环；目标资产参与账户同步时，密钥只进入主密码端到端加密信封。",
    ));
    note.add_css_class("security-note");
    note.set_xalign(0.0);
    note.set_wrap(true);
    root.append(&note);
    let list = gtk::ListBox::new();
    list.add_css_class("management-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    let mut checks = Vec::new();
    for asset in &assets {
        let row = gtk::Box::new(Orientation::Horizontal, 8);
        row.add_css_class("management-row");
        let check = gtk::CheckButton::new();
        check.set_active(asset.id == source_id || asset.key_reference == source.key_reference);
        check.set_sensitive(asset.id != source_id);
        let label = gtk::Label::new(Some(&format!("{}\n{}", asset.name, asset.endpoint())));
        label.set_xalign(0.0);
        label.set_hexpand(true);
        row.append(&check);
        row.append(&label);
        list.append(&row);
        checks.push((asset.clone(), check));
    }
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&list)
            .build(),
    );
    let status = gtk::Label::new(Some("源密钥只会在明确确认后读取；不会显示在界面或日志中。"));
    status.add_css_class("caption");
    status.set_xalign(0.0);
    status.set_wrap(true);
    root.append(&status);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let apply = gtk::Button::with_label("应用到所选资产");
    apply.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&apply);
    root.append(&actions);
    window.set_child(Some(&root));
    let close = window.clone();
    cancel.connect_clicked(move |_| close.close());
    let checks = Rc::new(checks);
    let apply_context = context.clone();
    let apply_source = source.clone();
    let apply_status = status.clone();
    let apply_window = window.clone();
    apply.connect_clicked(move |button| {
        let targets = checks
            .iter()
            .filter_map(|(asset, check)| {
                (asset.id != source_id && check.is_active()).then_some(asset.clone())
            })
            .collect::<Vec<_>>();
        if targets.is_empty() {
            apply_status.set_label("没有新增目标；源资产的密钥配置保持不变。");
            return;
        }
        button.set_sensitive(false);
        let context = apply_context.clone();
        let source = apply_source.clone();
        let status = apply_status.clone();
        let window = apply_window.clone();
        gtk::glib::spawn_future_local(async move {
            let source_credential = match context.vault.lookup(source.credential_id).await {
                Ok(Some(credential)) if !credential.private_key.is_empty() => credential,
                Ok(_) => {
                    status.set_label("源资产没有可用私钥；请先生成或导入密钥对。");
                    return;
                }
                Err(error) => {
                    status.set_label(&format!("无法读取源密钥：{error}"));
                    return;
                }
            };
            let mut completed = 0usize;
            let mut failed = Vec::new();
            for mut target in targets {
                let mut credential = context
                    .vault
                    .lookup(target.credential_id)
                    .await
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                credential.private_key = source_credential.private_key.clone();
                credential.private_key_passphrase =
                    source_credential.private_key_passphrase.clone();
                target.auth_method = AuthMethod::Key;
                target.allow_password_fallback = !credential.password.is_empty();
                target.key_reference = source.key_reference.clone();
                if context
                    .vault
                    .store(target.credential_id, &target.name, &credential)
                    .await
                    .is_ok()
                    && context.catalog.borrow_mut().upsert(target.clone()).is_ok()
                {
                    completed += 1;
                } else {
                    failed.push(target.name);
                }
            }
            (context.refresh_assets)();
            if failed.is_empty() {
                context.status.set_label(&format!(
                    "密钥已应用到 {completed} 项资产；其同步仍遵循各资产的端到端同步决策。"
                ));
                window.close();
            } else {
                status.set_label(&format!(
                    "已应用 {completed} 项；以下目标失败：{}。失败目标不会切换认证方式。",
                    failed.join("、")
                ));
            }
        });
    });
    window.present();
}

fn generated_ed25519_key(asset_id: Uuid) -> Result<(String, String, String), String> {
    let mut rng = rand::rng();
    let mut key = PrivateKey::random(&mut rng, Algorithm::Ed25519)
        .map_err(|_| "无法生成 Ed25519 密钥".to_owned())?;
    key.set_comment(format!("orbitterm-{asset_id}"));
    let private = key
        .to_openssh(LineEnding::LF)
        .map_err(|_| "无法编码 OpenSSH 私钥".to_owned())?
        .to_string();
    let public = key
        .public_key()
        .to_openssh()
        .map_err(|_| "无法编码 OpenSSH 公钥".to_owned())?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    Ok((private, public, fingerprint))
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn present_key_setup_window(context: UiContext, asset_id: Uuid) {
    let Some(asset) = context
        .catalog
        .borrow()
        .assets()
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned()
    else {
        return;
    };
    let (window, root) = utility_window(&context.window, "配置 SSH 密钥", 700, 680);
    let title = gtk::Label::new(Some(&format!("{} · SSH 密钥配置", asset.name)));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let mode = gtk::Label::new(Some(
        "生成新的 Ed25519 密钥，或粘贴/导入现有 OpenSSH 私钥。部署动作只复用当前已验证连接。",
    ));
    mode.add_css_class("security-note");
    mode.set_xalign(0.0);
    mode.set_wrap(true);
    root.append(&mode);
    let key_text = gtk::TextView::new();
    key_text.set_monospace(true);
    key_text.set_wrap_mode(gtk::WrapMode::None);
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .min_content_height(220)
            .child(&key_text)
            .build(),
    );
    let passphrase = gtk::PasswordEntry::builder()
        .placeholder_text("私钥口令（可选）")
        .show_peek_icon(true)
        .build();
    root.append(&passphrase);
    let fingerprint = gtk::Label::new(Some("尚未载入密钥"));
    fingerprint.add_css_class("caption");
    fingerprint.set_xalign(0.0);
    fingerprint.set_selectable(true);
    root.append(&fingerprint);
    let status = gtk::Label::new(Some("保存前会解析私钥格式；不会显示或记录私钥正文。"));
    status.add_css_class("security-note");
    status.set_xalign(0.0);
    status.set_wrap(true);
    root.append(&status);
    let tools = gtk::Box::new(Orientation::Horizontal, 6);
    let generate = gtk::Button::with_label("生成 Ed25519");
    let import = gtk::Button::with_label("导入私钥…");
    let connect = gtk::Button::with_label("连接并准备部署");
    tools.append(&generate);
    tools.append(&import);
    tools.append(&connect);
    root.append(&tools);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let save = gtk::Button::with_label("保存并应用");
    let deploy = gtk::Button::with_label("部署公钥并应用");
    deploy.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&save);
    actions.append(&deploy);
    root.append(&actions);
    window.set_child(Some(&root));

    let buffer = key_text.buffer();
    let fingerprint_for_generate = fingerprint.clone();
    let status_for_generate = status.clone();
    generate.connect_clicked(move |_| match generated_ed25519_key(asset_id) {
        Ok((private, _, fp)) => {
            buffer.set_text(&private);
            fingerprint_for_generate.set_label(&fp);
            status_for_generate
                .set_label("Ed25519 密钥已在本机内存中生成；请部署并应用，或仅保存到系统密钥环。");
        }
        Err(reason) => status_for_generate.set_label(&reason),
    });
    let import_parent = window.clone();
    let import_buffer = key_text.buffer();
    let import_status = status.clone();
    let import_fingerprint = fingerprint.clone();
    import.connect_clicked(move |_| {
        let chooser = gtk::FileDialog::builder().title("选择 SSH 私钥").build();
        let buffer = import_buffer.clone();
        let status = import_status.clone();
        let fingerprint = import_fingerprint.clone();
        chooser.open(
            Some(&import_parent),
            gtk::gio::Cancellable::NONE,
            move |result| {
                if let Ok(path) = result.and_then(|file| {
                    file.path().ok_or(gtk::glib::Error::new(
                        gtk::gio::IOErrorEnum::InvalidArgument,
                        "invalid path",
                    ))
                }) {
                    match std::fs::read_to_string(path) {
                        Ok(value) => match PrivateKey::from_openssh(&value) {
                            Ok(key) => {
                                fingerprint
                                    .set_label(&key.fingerprint(HashAlg::Sha256).to_string());
                                buffer.set_text(&value);
                                status.set_label("私钥已载入并通过格式校验。");
                            }
                            Err(_) => status.set_label("私钥格式无效或需要先解密。"),
                        },
                        Err(_) => status.set_label("无法读取私钥文件。"),
                    }
                }
            },
        );
    });
    let connect_context = context.clone();
    connect.connect_clicked(move |_| begin_connect(connect_context.clone(), asset_id));
    let close_target = window.clone();
    cancel.connect_clicked(move |_| close_target.close());

    for (button, should_deploy) in [(save, false), (deploy, true)] {
        let action_context = context.clone();
        let action_asset = asset.clone();
        let action_key = key_text.buffer();
        let action_passphrase = passphrase.clone();
        let action_status = status.clone();
        let action_window = window.clone();
        button.connect_clicked(move |button| {
            let private_text = action_key.text(&action_key.start_iter(), &action_key.end_iter(), true).to_string();
            let parsed = match PrivateKey::from_openssh(&private_text) {
                Ok(value) => value,
                Err(_) => { action_status.set_label("私钥格式无效；加密私钥请先填写正确口令或导入已解密的 OpenSSH 格式。"); return; }
            };
            let public = match parsed.public_key().to_openssh() { Ok(value) => value, Err(_) => { action_status.set_label("无法派生公钥。"); return; } };
            if should_deploy {
                let base = action_context.session.borrow().sessions.get(&asset_id).and_then(|runtime| (runtime.phase == WorkspacePhase::Connected).then_some(runtime.base_session_id).flatten());
                let Some(base) = base else { action_status.set_label("请先点击“连接并准备部署”，完成 Host Key 验证后再部署。"); return; };
                let quoted = shell_single_quote(&public);
                let command = format!("umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF {quoted} ~/.ssh/authorized_keys || printf '%s\\n' {quoted} >> ~/.ssh/authorized_keys) && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys");
                if CheckedCoreClient::new().exec(base, &command, &RequestId::new()).is_err() { action_status.set_label("公钥部署失败；资产认证方式保持不变。"); return; }
            }
            button.set_sensitive(false);
            let vault = action_context.vault.clone();
            let catalog = action_context.catalog.clone();
            let refresh = action_context.refresh_assets.clone();
            let app_status = action_context.status.clone();
            let mut updated = action_asset.clone();
            updated.auth_method = AuthMethod::Key;
            updated.key_reference = parsed.fingerprint(HashAlg::Sha256).to_string();
            let passphrase_value = action_passphrase.text().to_string();
            let completion_window = action_window.clone();
            gtk::glib::spawn_future_local(async move {
                let mut credential = vault.lookup(updated.credential_id).await.ok().flatten().unwrap_or_default();
                credential.private_key = private_text;
                credential.private_key_passphrase = passphrase_value;
                match vault.store(updated.credential_id, &updated.name, &credential).await {
                    Ok(()) => match catalog.borrow_mut().upsert(updated.clone()) {
                        Ok(()) => {
                            refresh();
                            app_status.set_label(&format!(
                                "{} 的 SSH 私钥已保存到系统密钥环；可在“密钥管理”中替换、移除或调整应用范围。",
                                updated.name
                            ));
                            completion_window.close();
                        }
                        Err(error) => app_status.set_label(&format!("密钥已写入系统密钥环，但资产元数据保存失败：{error}")),
                    },
                    Err(error) => app_status.set_label(&format!("密钥保存失败：{error}")),
                }
            });
        });
    }
    window.present();
}

fn present_port_forwarding_window(context: UiContext) {
    let (window, root) = utility_window(&context.window, "端口映射", 700, 620);
    let title = gtk::Label::new(Some("本地端口映射"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let form = gtk::Grid::builder()
        .column_spacing(10)
        .row_spacing(8)
        .build();
    let bind_host = gtk::DropDown::from_strings(&["127.0.0.1", "::1"]);
    let bind_port = gtk::SpinButton::with_range(0.0, 65535.0, 1.0);
    let destination_host = gtk::Entry::builder()
        .placeholder_text("127.0.0.1")
        .text("127.0.0.1")
        .build();
    let destination_port = gtk::SpinButton::with_range(1.0, 65535.0, 1.0);
    destination_port.set_value(22.0);
    let profile_name = gtk::Entry::builder()
        .placeholder_text("例如：本地数据库")
        .build();
    let profile_sync = gtk::Switch::builder().active(true).build();
    for (row, label, widget) in [
        (0, "本机绑定", bind_host.clone().upcast::<gtk::Widget>()),
        (1, "本机端口（0 自动分配）", bind_port.clone().upcast()),
        (2, "目标主机", destination_host.clone().upcast()),
        (3, "目标端口", destination_port.clone().upcast()),
        (4, "配置名称", profile_name.clone().upcast()),
        (5, "端到端同步配置", profile_sync.clone().upcast()),
    ] {
        let caption = gtk::Label::new(Some(label));
        caption.set_xalign(0.0);
        form.attach(&caption, 0, row, 1, 1);
        form.attach(&widget, 1, row, 1, 1);
    }
    root.append(&form);
    let status = gtk::Label::new(Some(
        "端口映射只监听本机回环地址，并依附于当前 Host Key 已验证 SSH 会话。",
    ));
    status.add_css_class("security-note");
    status.set_xalign(0.0);
    status.set_wrap(true);
    root.append(&status);
    let saved_heading = gtk::Label::new(Some("保存的配置"));
    saved_heading.add_css_class("heading");
    saved_heading.set_xalign(0.0);
    root.append(&saved_heading);
    let saved_list = gtk::ListBox::new();
    saved_list.add_css_class("management-list");
    saved_list.set_selection_mode(gtk::SelectionMode::None);
    root.append(
        &gtk::ScrolledWindow::builder()
            .min_content_height(130)
            .child(&saved_list)
            .build(),
    );
    let active_heading = gtk::Label::new(Some("运行中的映射"));
    active_heading.add_css_class("heading");
    active_heading.set_xalign(0.0);
    root.append(&active_heading);
    let list = gtk::ListBox::new();
    list.add_css_class("management-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&list)
            .build(),
    );
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let close = gtk::Button::with_label("关闭");
    let save = gtk::Button::with_label("保存配置");
    let start = gtk::Button::with_label("启动映射");
    start.add_css_class("suggested-action");
    actions.append(&close);
    actions.append(&save);
    actions.append(&start);
    root.append(&actions);
    window.set_child(Some(&root));

    let render: Rc<dyn Fn()> = {
        let list = list.clone();
        let context = context.clone();
        Rc::new(move || {
            clear_list(&list);
            for tunnel in context.active_tunnels.borrow().iter().cloned() {
                let row = gtk::Box::new(Orientation::Horizontal, 10);
                row.add_css_class("management-row");
                let label = gtk::Label::new(Some(&format!(
                    "{} · {}:{}  →  {}:{}",
                    tunnel.asset_name,
                    tunnel.bind_host,
                    tunnel.bind_port,
                    tunnel.destination_host,
                    tunnel.destination_port
                )));
                label.set_xalign(0.0);
                label.set_hexpand(true);
                let stop = gtk::Button::with_label("停止");
                stop.add_css_class("destructive-action");
                let stop_context = context.clone();
                let stop_list = list.clone();
                let stop_row = row.clone();
                stop.connect_clicked(move |button| {
                    button.set_sensitive(false);
                    let (sender, receiver) = mpsc::channel();
                    std::thread::spawn(move || {
                        let _ = sender.send(CheckedCoreClient::new().stop_local_tunnel(tunnel.id));
                    });
                    let stop_context = stop_context.clone();
                    let stop_list = stop_list.clone();
                    let stop_row = stop_row.clone();
                    gtk::glib::timeout_add_local(Duration::from_millis(30), move || match receiver
                        .try_recv()
                    {
                        Ok(Ok(())) => {
                            stop_context
                                .active_tunnels
                                .borrow_mut()
                                .retain(|item| item.id != tunnel.id);
                            stop_list.remove(&stop_row);
                            gtk::glib::ControlFlow::Break
                        }
                        Ok(Err(error)) => {
                            stop_context
                                .status
                                .set_label(&format!("停止端口映射失败：{error}"));
                            gtk::glib::ControlFlow::Break
                        }
                        Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                        Err(_) => gtk::glib::ControlFlow::Break,
                    });
                });
                row.append(&label);
                row.append(&stop);
                list.append(&row);
            }
        })
    };
    render();
    render_port_forward_profiles(
        context.clone(),
        saved_list.clone(),
        status.clone(),
        render.clone(),
    );
    let save_context = context.clone();
    let save_status = status.clone();
    let save_list = saved_list.clone();
    let save_render = render.clone();
    let save_destination_host = destination_host.clone();
    let save_destination_port = destination_port.clone();
    let save_bind_host = bind_host.clone();
    let save_bind_port = bind_port.clone();
    save.connect_clicked(move |_| {
        let registry = save_context.session.borrow();
        let Some(runtime) = registry.active().filter(|runtime| {
            runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected
        }) else {
            save_status.set_label("请先连接一个 SSH 资产，再保存端口映射配置。");
            return;
        };
        let asset_id = runtime.asset_id;
        drop(registry);
        let destination_host_value = save_destination_host.text().trim().to_owned();
        let name = profile_name.text().trim().to_owned();
        if name.is_empty() {
            save_status.set_label("请填写配置名称。");
            return;
        }
        let profile = PortForwardProfile {
            id: Uuid::new_v4(),
            asset_id,
            name,
            bind_host: if save_bind_host.selected() == 1 {
                "::1"
            } else {
                "127.0.0.1"
            }
            .into(),
            bind_port: save_bind_port.value_as_int() as u16,
            destination_host: destination_host_value,
            destination_port: save_destination_port.value_as_int() as u16,
            end_to_end_sync: profile_sync.is_active(),
        };
        match save_context.port_forward_profiles.upsert(profile) {
            Ok(()) => {
                save_status.set_label("端口映射配置已安全保存；运行态隧道不会写入配置库。");
                render_port_forward_profiles(
                    save_context.clone(),
                    save_list.clone(),
                    save_status.clone(),
                    save_render.clone(),
                );
            }
            Err(error) => save_status.set_label(&format!("配置保存失败：{error}")),
        }
    });
    let start_context = context.clone();
    let start_status = status.clone();
    let start_render = render.clone();
    start.connect_clicked(move |button| {
        let active = start_context.session.borrow();
        let Some(runtime) = active.active().filter(|runtime| {
            runtime.transport == Transport::Ssh && runtime.phase == WorkspacePhase::Connected
        }) else {
            start_status.set_label("请先连接一个 SSH 资产，再启动端口映射。");
            return;
        };
        let Some(base_id) = runtime.base_session_id else {
            return;
        };
        let asset_name = runtime.name.clone();
        let asset_id = runtime.asset_id;
        drop(active);
        let bind_host_value = if bind_host.selected() == 1 {
            "::1"
        } else {
            "127.0.0.1"
        }
        .to_owned();
        let bind_port_value = bind_port.value_as_int() as u16;
        let destination_host_value = destination_host.text().trim().to_owned();
        let destination_port_value = destination_port.value_as_int() as u16;
        button.set_sensitive(false);
        start_status.set_label("正在建立受检端口映射…");
        let (sender, receiver) = mpsc::channel();
        let thread_host = bind_host_value.clone();
        let thread_destination = destination_host_value.clone();
        std::thread::spawn(move || {
            let _ = sender.send(CheckedCoreClient::new().start_local_tunnel(
                base_id,
                &thread_host,
                bind_port_value,
                &thread_destination,
                destination_port_value,
            ));
        });
        let completion_context = start_context.clone();
        let completion_status = start_status.clone();
        let completion_button = button.clone();
        let completion_render = start_render.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
            match receiver.try_recv() {
                Ok(Ok((id, actual_host, actual_port))) => {
                    completion_context
                        .active_tunnels
                        .borrow_mut()
                        .push(ActiveTunnel {
                            id,
                            asset_id,
                            asset_name: asset_name.clone(),
                            bind_host: actual_host.clone(),
                            bind_port: actual_port,
                            destination_host: destination_host_value.clone(),
                            destination_port: destination_port_value,
                        });
                    completion_status
                        .set_label(&format!("映射已启动：{actual_host}:{actual_port}"));
                    completion_button.set_sensitive(true);
                    completion_render();
                    gtk::glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    completion_status.set_label(&format!("启动失败：{error}"));
                    completion_button.set_sensitive(true);
                    gtk::glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                Err(_) => {
                    completion_button.set_sensitive(true);
                    gtk::glib::ControlFlow::Break
                }
            }
        });
    });
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    window.present();
}

fn render_port_forward_profiles(
    context: UiContext,
    list: gtk::ListBox,
    status: gtk::Label,
    refresh_active: Rc<dyn Fn()>,
) {
    clear_list(&list);
    let profiles = match context.port_forward_profiles.load() {
        Ok(profiles) => profiles,
        Err(error) => {
            status.set_label(&format!("无法读取端口映射配置：{error}"));
            return;
        }
    };
    if profiles.is_empty() {
        let empty = gtk::Label::new(Some("暂无保存的端口映射配置。"));
        empty.add_css_class("caption");
        empty.set_margin_top(12);
        empty.set_margin_bottom(12);
        list.append(&empty);
        return;
    }
    for profile in profiles {
        let asset_name = context
            .catalog
            .borrow()
            .assets()
            .iter()
            .find(|asset| asset.id == profile.asset_id)
            .map(|asset| asset.name.clone())
            .unwrap_or_else(|| "资产已删除".into());
        let row = gtk::Box::new(Orientation::Horizontal, 8);
        row.add_css_class("management-row");
        let label = gtk::Label::new(Some(&format!(
            "{} · {}\n{}:{} → {}:{} · {}",
            profile.name,
            asset_name,
            profile.bind_host,
            profile.bind_port,
            profile.destination_host,
            profile.destination_port,
            if profile.end_to_end_sync {
                "加密同步"
            } else {
                "仅本机"
            }
        )));
        label.set_xalign(0.0);
        label.set_hexpand(true);
        let start = gtk::Button::with_label("启动");
        let remove = gtk::Button::with_label("删除");
        remove.add_css_class("destructive-action");
        let start_context = context.clone();
        let start_status = status.clone();
        let start_refresh = refresh_active.clone();
        let start_profile = profile.clone();
        let start_asset_name = asset_name.clone();
        start.connect_clicked(move |button| {
            let registry = start_context.session.borrow();
            let base = registry
                .sessions
                .get(&start_profile.asset_id)
                .and_then(|runtime| {
                    (runtime.phase == WorkspacePhase::Connected)
                        .then_some(runtime.base_session_id)
                        .flatten()
                });
            let Some(base_id) = base else {
                start_status.set_label("请先连接此配置对应的 SSH 资产，再启动映射。");
                return;
            };
            drop(registry);
            button.set_sensitive(false);
            let (sender, receiver) = mpsc::channel();
            let profile = start_profile.clone();
            std::thread::spawn(move || {
                let result = CheckedCoreClient::new().start_local_tunnel(
                    base_id,
                    &profile.bind_host,
                    profile.bind_port,
                    &profile.destination_host,
                    profile.destination_port,
                );
                let _ = sender.send((profile, result));
            });
            let context = start_context.clone();
            let status = start_status.clone();
            let refresh = start_refresh.clone();
            let button = button.clone();
            let asset_name = start_asset_name.clone();
            gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
                match receiver.try_recv() {
                    Ok((profile, Ok((id, actual_host, actual_port)))) => {
                        context.active_tunnels.borrow_mut().push(ActiveTunnel {
                            id,
                            asset_id: profile.asset_id,
                            asset_name: asset_name.clone(),
                            bind_host: actual_host.clone(),
                            bind_port: actual_port,
                            destination_host: profile.destination_host,
                            destination_port: profile.destination_port,
                        });
                        status.set_label(&format!("保存的映射已启动：{actual_host}:{actual_port}"));
                        button.set_sensitive(true);
                        refresh();
                        gtk::glib::ControlFlow::Break
                    }
                    Ok((_, Err(error))) => {
                        status.set_label(&format!("启动保存的映射失败：{error}"));
                        button.set_sensitive(true);
                        gtk::glib::ControlFlow::Break
                    }
                    Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                    Err(_) => {
                        button.set_sensitive(true);
                        gtk::glib::ControlFlow::Break
                    }
                }
            });
        });
        let remove_context = context.clone();
        let remove_list = list.clone();
        let remove_status = status.clone();
        let remove_refresh = refresh_active.clone();
        remove.connect_clicked(move |_| {
            match remove_context.port_forward_profiles.remove(profile.id) {
                Ok(()) => {
                    remove_status.set_label("保存的端口映射配置已删除；运行中的隧道不受影响。");
                    render_port_forward_profiles(
                        remove_context.clone(),
                        remove_list.clone(),
                        remove_status.clone(),
                        remove_refresh.clone(),
                    );
                }
                Err(error) => remove_status.set_label(&format!("删除配置失败：{error}")),
            }
        });
        row.append(&label);
        row.append(&start);
        row.append(&remove);
        list.append(&row);
    }
}

fn present_batch_command_window(context: UiContext) {
    let (window, root) = utility_window(&context.window, "批量命令", 840, 680);
    let title = gtk::Label::new(Some("批量执行命令"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let target = gtk::Label::new(Some(
        "可按资产与分组选择目标；未连接资产将使用系统密钥环中的已保存凭据建立受检连接，Host Key 未确认时仍会要求人工确认。",
    ));
    target.add_css_class("security-note");
    target.set_xalign(0.0);
    root.append(&target);
    let target_list = gtk::ListBox::new();
    target_list.add_css_class("management-list");
    target_list.set_selection_mode(gtk::SelectionMode::None);
    let mut target_checks = Vec::new();
    for asset in context
        .catalog
        .borrow()
        .assets()
        .iter()
        .filter(|asset| asset.transport == Transport::Ssh)
    {
        let row = gtk::Box::new(Orientation::Horizontal, 8);
        row.add_css_class("management-row");
        let check = gtk::CheckButton::new();
        check.set_active(
            context
                .session
                .borrow()
                .sessions
                .get(&asset.id)
                .is_some_and(|runtime| runtime.phase == WorkspacePhase::Connected),
        );
        let label = gtk::Label::new(Some(&format!(
            "{}  ·  {}  ·  {}",
            asset.name,
            asset.endpoint(),
            if asset.group.is_empty() {
                "未分组"
            } else {
                &asset.group
            }
        )));
        label.set_xalign(0.0);
        label.set_hexpand(true);
        row.append(&check);
        row.append(&label);
        target_list.append(&row);
        target_checks.push((
            asset.id,
            if asset.group.is_empty() {
                "未分组".to_owned()
            } else {
                asset.group.clone()
            },
            check,
        ));
    }
    let target_checks = Rc::new(target_checks);
    let target_toolbar = gtk::Box::new(Orientation::Horizontal, 6);
    let select_all = gtk::Button::with_label("全选");
    let select_none = gtk::Button::with_label("清空");
    let mut groups = target_checks
        .iter()
        .map(|(_, group, _)| group.clone())
        .collect::<Vec<_>>();
    groups.sort();
    groups.dedup();
    groups.insert(0, "选择分组…".into());
    let group_refs = groups.iter().map(String::as_str).collect::<Vec<_>>();
    let group_selector = gtk::DropDown::from_strings(&group_refs);
    let select_group = gtk::Button::with_label("选择分组");
    target_toolbar.append(&select_all);
    target_toolbar.append(&select_none);
    target_toolbar.append(&group_selector);
    target_toolbar.append(&select_group);
    root.append(&target_toolbar);
    root.append(
        &gtk::ScrolledWindow::builder()
            .min_content_height(150)
            .child(&target_list)
            .build(),
    );
    let command = gtk::Entry::builder()
        .placeholder_text("输入要执行的单行命令")
        .build();
    root.append(&command);
    let execution_options = gtk::Box::new(Orientation::Horizontal, 8);
    let execution_mode = gtk::DropDown::from_strings(&["单次执行", "持续执行"]);
    let interval = gtk::SpinButton::with_range(2.0, 300.0, 1.0);
    interval.set_value(10.0);
    interval.set_tooltip_text(Some("持续任务的执行间隔（秒）"));
    interval.set_sensitive(false);
    let interval_for_mode = interval.clone();
    execution_mode.connect_selected_notify(move |mode| {
        interval_for_mode.set_sensitive(mode.selected() == 1);
    });
    execution_options.append(&execution_mode);
    execution_options.append(&interval);
    root.append(&execution_options);
    let result_filter = gtk::SearchEntry::builder()
        .placeholder_text("筛选结果")
        .build();
    root.append(&result_filter);
    let output = gtk::TextView::new();
    output.set_editable(false);
    output.set_monospace(true);
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&output)
            .build(),
    );
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let close = gtk::Button::with_label("关闭");
    let copy_results = gtk::Button::with_label("复制结果");
    let stop = gtk::Button::with_label("停止任务");
    stop.set_sensitive(false);
    let run = gtk::Button::with_label("执行");
    run.add_css_class("suggested-action");
    run.set_sensitive(!target_checks.is_empty());
    actions.append(&close);
    actions.append(&copy_results);
    actions.append(&stop);
    actions.append(&run);
    root.append(&actions);
    window.set_child(Some(&root));
    let checks = target_checks.clone();
    select_all.connect_clicked(move |_| {
        for (_, _, check) in checks.iter() {
            check.set_active(true);
        }
    });
    let checks = target_checks.clone();
    select_none.connect_clicked(move |_| {
        for (_, _, check) in checks.iter() {
            check.set_active(false);
        }
    });
    let checks = target_checks.clone();
    select_group.connect_clicked(move |_| {
        let selected = group_selector.selected() as usize;
        if selected == 0 {
            return;
        }
        let Some(group) = groups.get(selected) else {
            return;
        };
        for (_, asset_group, check) in checks.iter() {
            check.set_active(asset_group == group);
        }
    });
    let report_store = Rc::new(RefCell::new(String::new()));
    let filter_store = report_store.clone();
    let filter_output = output.clone();
    result_filter.connect_search_changed(move |search| {
        let query = search.text().trim().to_lowercase();
        let report = filter_store.borrow();
        if query.is_empty() {
            filter_output.buffer().set_text(&report);
        } else {
            let filtered = report
                .split("\n\n")
                .filter(|block| block.to_lowercase().contains(&query))
                .collect::<Vec<_>>()
                .join("\n\n");
            filter_output.buffer().set_text(&filtered);
        }
    });
    let copy_output = output.clone();
    copy_results.connect_clicked(move |_| {
        let buffer = copy_output.buffer();
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
        if let Some(display) = gtk::gdk::Display::default() {
            display.clipboard().set_text(&text);
        }
    });
    let batch_active = Rc::new(Cell::new(false));
    let stop_active = batch_active.clone();
    let stop_run = run.clone();
    let stop_button = stop.clone();
    stop.connect_clicked(move |_| {
        stop_active.set(false);
        stop_button.set_sensitive(false);
        stop_run.set_sensitive(true);
    });
    let run_context = context.clone();
    let run_checks = target_checks.clone();
    let run_mode = execution_mode.clone();
    let run_interval = interval.clone();
    let run_stop = stop.clone();
    let run_active = batch_active.clone();
    let run_report_store = report_store.clone();
    run.connect_clicked(move |button| {
        let command_value = command.text().trim().to_owned();
        if command_value.is_empty() || command_value.chars().any(char::is_control) {
            output.buffer().set_text("命令必须是非空单行文本。");
            return;
        }
        let selected = run_checks
            .iter()
            .filter_map(|(id, _, check)| check.is_active().then_some(*id))
            .collect::<Vec<_>>();
        if selected.is_empty() {
            output.buffer().set_text("请至少选择一项 SSH 资产。");
            return;
        }
        let continuous = run_mode.selected() == 1;
        let interval_seconds = run_interval.value_as_int().clamp(2, 300) as u64;
        run_active.set(true);
        run_stop.set_sensitive(continuous);
        button.set_sensitive(false);
        output
            .buffer()
            .set_text("正在连接所选资产；首次或变化的 Host Key 会单独请求确认…");
        for asset_id in &selected {
            let connected = run_context
                .session
                .borrow()
                .sessions
                .get(asset_id)
                .is_some_and(|runtime| runtime.phase == WorkspacePhase::Connected);
            if !connected {
                begin_connect(run_context.clone(), *asset_id);
            }
        }
        let started = std::time::Instant::now();
        let completion_output = output.clone();
        let completion_button = button.clone();
        let completion_context = run_context.clone();
        let command_for_poll = command_value.clone();
        let completion_active = run_active.clone();
        let completion_stop = run_stop.clone();
        let completion_store = run_report_store.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
            let registry = completion_context.session.borrow();
            let waiting = selected.iter().any(|id| {
                registry.sessions.get(id).is_some_and(|runtime| {
                    matches!(
                        runtime.phase,
                        WorkspacePhase::Starting
                            | WorkspacePhase::Authenticating
                            | WorkspacePhase::AwaitingUserDecision
                            | WorkspacePhase::Reconnecting
                    )
                })
            });
            if waiting && started.elapsed() < Duration::from_secs(120) {
                return gtk::glib::ControlFlow::Continue;
            }
            let jobs = selected
                .iter()
                .map(|id| {
                    let name = completion_context
                        .catalog
                        .borrow()
                        .assets()
                        .iter()
                        .find(|asset| asset.id == *id)
                        .map(|asset| asset.name.clone())
                        .unwrap_or_else(|| id.to_string());
                    let base = registry.sessions.get(id).and_then(|runtime| {
                        (runtime.phase == WorkspacePhase::Connected)
                            .then_some(runtime.base_session_id)
                            .flatten()
                    });
                    (name, base)
                })
                .collect::<Vec<_>>();
            drop(registry);
            let (sender, receiver) = mpsc::channel();
            let command = command_for_poll.clone();
            std::thread::spawn(move || {
                let core = CheckedCoreClient::new();
                let mut report = String::new();
                for (name, base) in jobs {
                    let Some(base_id) = base else {
                        report.push_str(&format!(
                            "[{name}] 跳过：连接失败、被取消或等待 Host Key 确认超时\n\n"
                        ));
                        continue;
                    };
                    match core.exec_output(base_id, &command) {
                        Ok(result) => {
                            let outcome = if result.exit_status == 0 {
                                "成功"
                            } else {
                                "失败"
                            };
                            report.push_str(&format!(
                                "[{name}] {outcome} · exit {}\n{}{}\n\n",
                                result.exit_status, result.stdout, result.stderr
                            ));
                        }
                        Err(error) => report.push_str(&format!("[{name}] 失败：{error}\n\n")),
                    }
                }
                let _ = sender.send(report);
            });
            let output = completion_output.clone();
            let button = completion_button.clone();
            let active = completion_active.clone();
            let stop = completion_stop.clone();
            let store = completion_store.clone();
            gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
                match receiver.try_recv() {
                    Ok(report) => {
                        {
                            let mut accumulated = store.borrow_mut();
                            if !accumulated.is_empty() {
                                accumulated.push_str("\n────────────────────────────────\n\n");
                            }
                            accumulated.push_str(&report);
                            output.buffer().set_text(&accumulated);
                        }
                        if continuous && active.get() {
                            let next_button = button.clone();
                            let next_active = active.clone();
                            gtk::glib::timeout_add_local_once(
                                Duration::from_secs(interval_seconds),
                                move || {
                                    if next_active.get() {
                                        next_button.set_sensitive(true);
                                        next_button.emit_by_name::<()>("clicked", &[]);
                                    }
                                },
                            );
                        } else {
                            active.set(false);
                            stop.set_sensitive(false);
                            button.set_sensitive(true);
                        }
                        gtk::glib::ControlFlow::Break
                    }
                    Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                    Err(_) => {
                        active.set(false);
                        stop.set_sensitive(false);
                        button.set_sensitive(true);
                        gtk::glib::ControlFlow::Break
                    }
                }
            });
            gtk::glib::ControlFlow::Break
        });
    });
    let target = window.clone();
    let close_active = batch_active.clone();
    close.connect_clicked(move |_| {
        close_active.set(false);
        target.close();
    });
    window.present();
}

fn present_settings_window(context: UiContext) {
    let (window, root) = utility_window(&context.window, "设置", 620, 720);
    root.add_css_class("settings-window");
    let title = gtk::Label::new(Some("设置"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let intro = gtk::Label::new(Some(
        "界面、终端和监控偏好仅保存在当前 Linux 用户；安全同步仍由账户与同步中心管理。",
    ));
    intro.add_css_class("caption");
    intro.set_xalign(0.0);
    intro.set_wrap(true);
    root.append(&intro);

    let current = context.preferences.borrow().clone();
    let content = gtk::Box::new(Orientation::Vertical, 12);
    content.add_css_class("settings-content");

    let appearance = settings_section("应用外观");
    let app_theme = gtk::DropDown::from_strings(&["跟随系统", "浅色", "深色"]);
    app_theme.set_selected(match current.application_theme.as_str() {
        "light" => 1,
        "dark" => 2,
        _ => 0,
    });
    append_labeled_widget(&appearance, "应用外观模式", &app_theme);
    let palette_heading = gtk::Label::new(Some("界面配色"));
    palette_heading.set_xalign(0.0);
    palette_heading.add_css_class("settings-row-label");
    appearance.append(&palette_heading);
    let palette_choices = gtk::FlowBox::new();
    palette_choices.add_css_class("palette-choices");
    palette_choices.set_selection_mode(gtk::SelectionMode::None);
    palette_choices.set_max_children_per_line(3);
    palette_choices.set_min_children_per_line(2);
    let sky = gtk::ToggleButton::with_label("天空糖果");
    sky.add_css_class("palette-sky");
    let emerald = gtk::ToggleButton::with_label("翡翠流光");
    emerald.set_group(Some(&sky));
    emerald.add_css_class("palette-emerald");
    let peach = gtk::ToggleButton::with_label("蜜桃晨光");
    peach.set_group(Some(&sky));
    peach.add_css_class("palette-peach");
    let lavender = gtk::ToggleButton::with_label("薰衣草雾");
    lavender.set_group(Some(&sky));
    lavender.add_css_class("palette-lavender");
    let glacier = gtk::ToggleButton::with_label("冰川薄荷");
    glacier.set_group(Some(&sky));
    glacier.add_css_class("palette-glacier");
    for choice in [&sky, &emerald, &peach, &lavender, &glacier] {
        choice.add_css_class("palette-choice");
        palette_choices.insert(choice, -1);
    }
    match current.application_palette.as_str() {
        "sky" => sky.set_active(true),
        "peach" => peach.set_active(true),
        "lavender" => lavender.set_active(true),
        "glacier" => glacier.set_active(true),
        _ => emerald.set_active(true),
    }
    let palette_note = gtk::Label::new(Some("与 Windows 端一致的五套配色；明暗模式独立控制。"));
    palette_note.add_css_class("caption");
    palette_note.set_xalign(0.0);
    palette_note.set_wrap(true);
    appearance.append(&palette_choices);
    appearance.append(&palette_note);

    let terminal_section = settings_section("终端外观");
    let follow_theme = gtk::Switch::builder()
        .active(current.terminal_follows_application_theme)
        .build();
    append_labeled_widget(&terminal_section, "终端跟随应用主题", &follow_theme);
    let terminal_theme =
        gtk::DropDown::from_strings(&["Dracula", "Solarized Dark", "Nord", "Homebrew"]);
    terminal_theme.set_selected(match current.terminal_theme.as_str() {
        "solarized-dark" => 1,
        "nord" => 2,
        "homebrew" => 3,
        _ => 0,
    });
    terminal_theme.set_sensitive(!current.terminal_follows_application_theme);
    let terminal_theme_for_toggle = terminal_theme.clone();
    follow_theme.connect_active_notify(move |toggle| {
        terminal_theme_for_toggle.set_sensitive(!toggle.is_active());
    });
    append_labeled_widget(&terminal_section, "终端主题", &terminal_theme);
    let font_size = gtk::SpinButton::with_range(9.0, 28.0, 1.0);
    font_size.set_value(f64::from(current.terminal_font_size));
    append_labeled_widget(&terminal_section, "终端字号", &font_size);
    let scrollback = gtk::SpinButton::with_range(1000.0, 200000.0, 1000.0);
    scrollback.set_value(current.terminal_scrollback_lines as f64);
    append_labeled_widget(&terminal_section, "终端回滚行数", &scrollback);
    let cursor_blink = gtk::Switch::builder().active(current.cursor_blink).build();
    append_labeled_widget(&terminal_section, "光标闪烁", &cursor_blink);

    let monitor = settings_section("系统监控");
    let auto_refresh = gtk::Switch::builder()
        .active(current.monitor_auto_refresh)
        .build();
    append_labeled_widget(&monitor, "自动刷新资源趋势", &auto_refresh);
    let interval = gtk::DropDown::from_strings(&["1 秒", "2 秒", "5 秒"]);
    interval.set_selected(match current.monitor_refresh_seconds {
        1 => 0,
        5 => 2,
        _ => 1,
    });
    append_labeled_widget(&monitor, "监控刷新间隔", &interval);
    let history = gtk::DropDown::from_strings(&["最近 120 次", "最近 300 次", "最近 600 次"]);
    history.set_selected(match current.monitor_history_samples {
        120 => 0,
        600 => 2,
        _ => 1,
    });
    append_labeled_widget(&monitor, "趋势保留范围", &history);

    let connection = settings_section("终端与连接");
    let telnet = gtk::Switch::builder()
        .active(current.telnet_enabled)
        .build();
    append_labeled_widget(&connection, "启用 Telnet（明文）", &telnet);
    let telnet_warning = gtk::Label::new(Some(
        "Telnet 不加密登录信息、命令或终端内容，且不能验证远端身份；SSH 失败时绝不会自动降级为 Telnet。",
    ));
    telnet_warning.add_css_class("security-note");
    telnet_warning.set_xalign(0.0);
    telnet_warning.set_wrap(true);
    connection.append(&telnet_warning);

    let keyboard = settings_section("键盘与工作站");
    let shortcuts = gtk::Label::new(Some(
        "Ctrl+1…9  切换会话标签\nAlt+1…4  切换终端分屏\nCtrl+Tab  下一个会话\nAlt+Shift+方向键  循环切换分屏\nCtrl+Shift+D / E  添加或关闭分屏",
    ));
    shortcuts.add_css_class("shortcut-summary");
    shortcuts.set_xalign(0.0);
    shortcuts.set_selectable(true);
    keyboard.append(&shortcuts);
    let shortcut_help = gtk::Button::with_label("查看全部工作站快捷键…");
    shortcut_help.set_halign(Align::Start);
    let shortcut_context = context.clone();
    shortcut_help.connect_clicked(move |_| present_shortcut_help(shortcut_context.clone()));
    keyboard.append(&shortcut_help);

    let security = settings_section("安全与同步");
    let key_sync = gtk::Switch::builder()
        .active(current.synchronize_key_library)
        .build();
    append_labeled_widget(&security, "新密钥默认随已同步资产加密同步", &key_sync);
    let sync_note = gtk::Label::new(Some(
        "私钥仅随明确选择的 SSH 资产进入主密码端到端加密信封；系统密钥环中的明文不会直接上传。",
    ));
    sync_note.add_css_class("caption");
    sync_note.set_xalign(0.0);
    sync_note.set_wrap(true);
    security.append(&sync_note);
    let open_sync = gtk::Button::with_label("打开账户与同步中心");
    open_sync.set_halign(Align::Start);
    let sync_context = context.clone();
    open_sync.connect_clicked(move |_| present_sync_window(sync_context.clone()));
    security.append(&open_sync);

    let backup = settings_section("备份与恢复");
    let backup_note = gtk::Label::new(Some(
        "批量添加可从受控清单恢复资产；密码、私钥、令牌和 Host Key 信任不会写入明文导出。",
    ));
    backup_note.add_css_class("caption");
    backup_note.set_xalign(0.0);
    backup_note.set_wrap(true);
    backup.append(&backup_note);
    let import_assets = gtk::Button::with_label("从资产清单批量导入…");
    import_assets.set_halign(Align::Start);
    let import_context = context.clone();
    import_assets.connect_clicked(move |_| {
        let parent: gtk::Window = import_context.window.clone().upcast();
        present_bulk_import_window(
            &parent,
            import_context.catalog.clone(),
            import_context.vault.clone(),
            import_context.refresh_assets.clone(),
        );
    });
    backup.append(&import_assets);

    let help = settings_section("帮助与版本");
    let help_actions = gtk::Box::new(Orientation::Horizontal, 8);
    let terms = gtk::Button::with_label("使用条款");
    let about = gtk::Button::with_label("关于 OrbitTerm");
    let update = gtk::Button::with_label("检查更新");
    help_actions.append(&terms);
    help_actions.append(&about);
    help_actions.append(&update);
    help.append(&help_actions);
    let help_status = gtk::Label::new(Some("Linux 客户端 0.1.0 · Flatpak 自动更新由软件中心管理"));
    help_status.add_css_class("caption");
    help_status.set_xalign(0.0);
    help.append(&help_status);
    let legal_parent = window.clone();
    terms.connect_clicked(move |_| {
        let accepted = gtk::CheckButton::new();
        present_legal_terms_window(&legal_parent, accepted);
    });
    let about_status = help_status.clone();
    about.connect_clicked(move |_| {
        about_status
            .set_label("OrbitTerm Linux 0.1.0 · 原生 GTK 4 / libadwaita · 受检 orbit-core 会话");
    });
    let update_status = help_status.clone();
    update.connect_clicked(move |_| {
        update_status.set_label("当前由 Flatpak 软件源管理更新；未发现应用内旁路更新通道。");
    });
    for section in [
        &appearance,
        &terminal_section,
        &connection,
        &monitor,
        &keyboard,
        &security,
        &backup,
        &help,
    ] {
        content.append(section);
    }

    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&content)
        .build();
    root.append(&scroll);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let close = gtk::Button::with_label("取消");
    let apply = gtk::Button::with_label("应用");
    apply.add_css_class("suggested-action");
    actions.append(&close);
    actions.append(&apply);
    root.append(&actions);
    window.set_child(Some(&root));
    let apply_terminals = context.workspace.terminals.clone();
    let apply_window = window.clone();
    let apply_context = context.clone();
    apply.connect_clicked(move |_| {
        let preferences = AppPreferences {
            terminal_font_size: font_size.value_as_int().clamp(8, 24),
            terminal_scrollback_lines: i64::from(scrollback.value_as_int()),
            cursor_blink: cursor_blink.is_active(),
            application_theme: match app_theme.selected() {
                1 => "light",
                2 => "dark",
                _ => "system",
            }
            .into(),
            application_palette: if sky.is_active() {
                "sky"
            } else if peach.is_active() {
                "peach"
            } else if lavender.is_active() {
                "lavender"
            } else if glacier.is_active() {
                "glacier"
            } else {
                "emerald"
            }
            .into(),
            terminal_theme: match terminal_theme.selected() {
                1 => "solarized-dark",
                2 => "nord",
                3 => "homebrew",
                _ => "dracula",
            }
            .into(),
            terminal_follows_application_theme: follow_theme.is_active(),
            monitor_auto_refresh: auto_refresh.is_active(),
            monitor_refresh_seconds: match interval.selected() {
                0 => 1,
                2 => 5,
                _ => 2,
            },
            monitor_history_samples: match history.selected() {
                0 => 120,
                2 => 600,
                _ => 300,
            },
            telnet_enabled: telnet.is_active(),
            synchronize_key_library: key_sync.is_active(),
        };
        match apply_context.preferences_repository.save(&preferences) {
            Ok(()) => {
                for terminal in apply_terminals.iter() {
                    apply_preferences(terminal, &preferences);
                }
                apply_context.preferences.replace(preferences);
                apply_window.close();
            }
            Err(error) => apply_context
                .status
                .set_label(&format!("设置保存失败：{error}")),
        }
    });
    let target = window.clone();
    close.connect_clicked(move |_| target.close());
    window.present();
}

fn settings_section(title: &str) -> gtk::Box {
    let section = gtk::Box::new(Orientation::Vertical, 9);
    section.add_css_class("settings-section");
    let heading = gtk::Label::new(Some(title));
    heading.add_css_class("heading");
    heading.set_xalign(0.0);
    section.append(&heading);
    section
}

fn apply_preferences(terminal: &vte::Terminal, preferences: &AppPreferences) {
    let font = gtk::pango::FontDescription::from_string(&format!(
        "JetBrains Mono {}",
        preferences.terminal_font_size
    ));
    terminal.set_font(Some(&font));
    terminal.set_scrollback_lines(preferences.terminal_scrollback_lines);
    terminal.set_cursor_blink_mode(if preferences.cursor_blink {
        vte::CursorBlinkMode::On
    } else {
        vte::CursorBlinkMode::Off
    });
    let style = adw::StyleManager::default();
    style.set_color_scheme(match preferences.application_theme.as_str() {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    });
    install_application_palette(preferences.application_palette.as_str(), style.is_dark());
    let (background, foreground, cursor) = if preferences.terminal_follows_application_theme {
        if style.is_dark() {
            ("#101216", "#F5F7FA", "#58A6FF")
        } else {
            ("#F8FAFC", "#1B1F24", "#2563EB")
        }
    } else {
        match preferences.terminal_theme.as_str() {
            "solarized-dark" => ("#002B36", "#839496", "#B58900"),
            "nord" => ("#2E3440", "#D8DEE9", "#88C0D0"),
            "homebrew" => ("#000000", "#28FE14", "#FFFFFF"),
            _ => ("#282A36", "#F8F8F2", "#BD93F9"),
        }
    };
    if let (Ok(background), Ok(foreground), Ok(cursor)) = (
        gtk::gdk::RGBA::parse(background),
        gtk::gdk::RGBA::parse(foreground),
        gtk::gdk::RGBA::parse(cursor),
    ) {
        terminal.set_color_background(&background);
        terminal.set_color_foreground(&foreground);
        terminal.set_color_cursor(Some(&cursor));
    }
}

fn install_application_palette(palette: &str, dark: bool) {
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    // Values mirror the semantic palette families used by the Windows client.
    // Only application surfaces are overridden; Adwaita keeps ownership of
    // focus, disabled and accessibility states.
    let (accent, paper, paper_2, surface, metric, rule) = match (palette, dark) {
        ("sky", false) => (
            "#1261c2", "#e2effc", "#cfe4f9", "#f1f8ff", "#daebfb", "#93b9de",
        ),
        ("sky", true) => (
            "#6cb6ff", "#0a161f", "#0e222f", "#142a38", "#1a3342", "#315165",
        ),
        ("peach", false) => (
            "#9c3333", "#fce7db", "#f7d6c5", "#fff4ed", "#f9ded0", "#d6a48d",
        ),
        ("peach", true) => (
            "#f2a07a", "#1b1310", "#2a1c17", "#33231d", "#3d2b23", "#644336",
        ),
        ("lavender", false) => (
            "#613894", "#ede5f8", "#e0d3f3", "#f9f4fe", "#e5daf6", "#b89fd7",
        ),
        ("lavender", true) => (
            "#b49aeb", "#171220", "#231b31", "#2c233e", "#352b49", "#54466c",
        ),
        ("glacier", false) => (
            "#056373", "#e0f1f4", "#cde7eb", "#f0f9fa", "#d6ecef", "#8fbec5",
        ),
        ("glacier", true) => (
            "#62c4d2", "#0a171a", "#0f252a", "#162f35", "#1c3940", "#34585f",
        ),
        (_, true) => (
            "#5fd09a", "#0b1812", "#10261b", "#172f23", "#1d392a", "#355b45",
        ),
        _ => (
            "#08664d", "#e2f2e9", "#d0e8da", "#f2faf6", "#d9eee1", "#93c0a6",
        ),
    };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&format!(
        "@define-color orbit_accent {accent};\n\
         @define-color orbit_focus {accent};\n\
         @define-color orbit_paper {paper};\n\
         @define-color orbit_paper_2 {paper_2};\n\
         @define-color orbit_surface {surface};\n\
         @define-color orbit_metric {metric};\n\
         @define-color orbit_rule {rule};\n{APP_STYLES}"
    ));
    gtk::style_context_add_provider_for_display(
        &display,
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
}

#[derive(Clone)]
struct SyncDialogContext {
    window: gtk::Window,
    catalog: Rc<RefCell<Catalog>>,
    credential_vault: CredentialVault,
    token_vault: AuthTokenVault,
    sync_state: SyncStateRepository,
    sync_operations: SyncOperationRepository,
    sync_scheduler: SyncSchedulerGate,
    sync_session: SecureSyncSession,
    background_pending: Rc<RefCell<Option<PendingSyncRun>>>,
    refresh_assets: Rc<dyn Fn()>,
    app_status: gtk::Label,
    pending: Rc<RefCell<Option<PendingSyncRun>>>,
    summary: gtk::Label,
    detail: gtk::Label,
    conflicts: gtk::ListBox,
    timeline: gtk::ListBox,
    resolution_buttons: Rc<RefCell<Vec<gtk::Button>>>,
    retry_buttons: Rc<RefCell<Vec<gtk::Button>>>,
    spinner: gtk::Spinner,
    login: gtk::Button,
    saved_login: gtk::Button,
    import: gtk::Button,
    retry_all: gtk::Button,
    page_stack: gtk::Stack,
}

struct PendingSyncRun {
    preview: SyncPreview,
    tokens: SyncTokens,
    checkpoint: Option<SyncCheckpoint>,
    account_fingerprint: String,
    device_id: Uuid,
    master_password: zeroize::Zeroizing<String>,
}

struct SyncCheckpoint {
    revision: u64,
    reset_recovered: bool,
}

#[derive(Clone, Copy)]
enum SyncResolutionAction {
    KeepLocal,
    UseCloud,
    AcceptDeletion,
    RestoreCloud,
}

enum SyncAuthInput {
    Login { username: String, password: String },
    Saved(SyncTokens),
}

enum QueuedNetworkOutcome {
    Completed {
        remote: RemoteConfig,
        operation: QueuedSyncOperation,
    },
    Deferred {
        operation: QueuedSyncOperation,
        reason: String,
    },
}

struct BackgroundQueueOutcome {
    tokens: SyncTokens,
    result: Result<usize, SyncError>,
    remaining: Result<Vec<QueuedSyncOperation>, String>,
}

struct BackgroundPullOutcome {
    result: Result<PendingSyncRun, SyncError>,
}

fn present_sync_window(context: UiContext) {
    if context.sync_scheduler.background_busy() {
        context
            .sync_status
            .set_label("后台同步正在收尾 · 请稍后打开同步中心");
        return;
    }
    if !context.sync_scheduler.try_open_dialog() {
        context.sync_status.set_label("同步中心已打开");
        return;
    }
    let window = gtk::Window::builder()
        .title("账户与同步")
        .transient_for(&context.window)
        .modal(true)
        .default_width(620)
        .default_height(600)
        .resizable(true)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 8);
    root.add_css_class("asset-dialog");
    root.add_css_class("sync-dialog");
    root.add_css_class("auth-shell");

    let heading = gtk::Label::new(Some("OrbitTerm"));
    heading.add_css_class("auth-brand-title");
    heading.set_xalign(0.5);
    root.append(&heading);
    let intro = gtk::Label::new(Some("欢迎回来，继续你的终端旅程"));
    intro.set_xalign(0.5);
    intro.set_wrap(true);
    intro.add_css_class("caption");
    root.append(&intro);

    let page_stack = gtk::Stack::new();
    page_stack.set_transition_type(gtk::StackTransitionType::SlideLeftRight);
    page_stack.set_vexpand(true);
    let auth_card = gtk::Box::new(Orientation::Vertical, 8);
    auth_card.add_css_class("auth-card");
    auth_card.set_size_request(480, -1);
    auth_card.set_halign(Align::Center);
    let mode = gtk::Box::new(Orientation::Horizontal, 4);
    mode.add_css_class("auth-mode-switch");
    let login_mode = gtk::ToggleButton::with_label("登录");
    login_mode.set_active(true);
    let register_mode = gtk::ToggleButton::with_label("注册");
    register_mode.set_group(Some(&login_mode));
    mode.append(&login_mode);
    mode.append(&register_mode);
    auth_card.append(&mode);
    let username = labeled_entry(&auth_card, "OrbitTerm 账户", "邮箱地址");
    let login_password = gtk::PasswordEntry::builder()
        .placeholder_text("登录密码")
        .show_peek_icon(true)
        .build();
    append_labeled_widget(&auth_card, "登录密码", &login_password);
    let master_password = gtk::PasswordEntry::builder()
        .placeholder_text("用于解密配置，不会保存")
        .show_peek_icon(true)
        .build();
    let register_fields = gtk::Box::new(Orientation::Vertical, 8);
    let invite_code = labeled_entry(&register_fields, "邀请码", "管理员提供的邀请码");
    let terms = gtk::CheckButton::new();
    register_fields.set_visible(false);
    auth_card.append(&register_fields);
    let legal_row = gtk::Box::new(Orientation::Horizontal, 6);
    let view_terms = gtk::Button::with_label("我已阅读并同意《使用条款、免责声明与隐私说明》");
    view_terms.add_css_class("flat");
    legal_row.append(&terms);
    legal_row.append(&view_terms);
    auth_card.append(&legal_row);

    page_stack.add_named(&auth_card, Some("auth"));

    let unlock_card = gtk::Box::new(Orientation::Vertical, 8);
    unlock_card.add_css_class("auth-card");
    unlock_card.set_size_request(520, -1);
    unlock_card.set_halign(Align::Center);
    let unlock_title = gtk::Label::new(Some("解锁端到端加密"));
    unlock_title.add_css_class("auth-card-title");
    unlock_title.set_xalign(0.0);
    unlock_card.append(&unlock_title);
    let unlock_note = gtk::Label::new(Some(
        "账户认证已完成。请输入独立主密码解密同步数据；主密码不会上传或保存。",
    ));
    unlock_note.add_css_class("security-note");
    unlock_note.set_xalign(0.0);
    unlock_note.set_wrap(true);
    unlock_card.append(&unlock_note);
    append_labeled_widget(&unlock_card, "主密码", &master_password);
    let unlock_actions = gtk::Box::new(Orientation::Horizontal, 8);
    unlock_actions.set_halign(Align::End);
    let auth_back = gtk::Button::with_label("返回");
    let unlock = gtk::Button::with_label("解锁并检查同步");
    unlock.add_css_class("suggested-action");
    unlock_actions.append(&auth_back);
    unlock_actions.append(&unlock);
    unlock_card.append(&unlock_actions);
    page_stack.add_named(&unlock_card, Some("unlock"));

    let sync_panel = gtk::Box::new(Orientation::Vertical, 12);
    sync_panel.add_css_class("sync-workspace-card");

    let progress = gtk::Box::new(Orientation::Horizontal, 8);
    let spinner = gtk::Spinner::new();
    spinner.set_visible(false);
    let summary = gtk::Label::new(Some("尚未检查云端"));
    summary.set_xalign(0.0);
    summary.set_hexpand(true);
    summary.add_css_class("heading");
    progress.append(&spinner);
    progress.append(&summary);
    sync_panel.append(&progress);
    let detail = gtk::Label::new(Some(
        "登录后会先生成只读预览；只有再次确认才会写入本地资产与系统密钥环。",
    ));
    detail.set_xalign(0.0);
    detail.set_wrap(true);
    detail.add_css_class("sync-summary");
    sync_panel.append(&detail);

    let conflict_heading = gtk::Label::new(Some("待处理记录"));
    conflict_heading.set_xalign(0.0);
    conflict_heading.add_css_class("field-label");
    sync_panel.append(&conflict_heading);
    let conflicts = gtk::ListBox::new();
    conflicts.add_css_class("sync-conflict-list");
    conflicts.set_selection_mode(gtk::SelectionMode::None);
    let conflict_scroll = gtk::ScrolledWindow::builder()
        .min_content_height(140)
        .max_content_height(380)
        .vexpand(true)
        .child(&conflicts)
        .build();
    conflict_scroll.add_css_class("sync-conflict-scroll");
    sync_panel.append(&conflict_scroll);

    let timeline_heading = gtk::Box::new(Orientation::Horizontal, 8);
    let timeline_title = gtk::Label::new(Some("离线队列与操作时间线"));
    timeline_title.set_xalign(0.0);
    timeline_title.set_hexpand(true);
    timeline_title.add_css_class("field-label");
    let retry_all = gtk::Button::with_label("重试全部");
    retry_all.set_sensitive(false);
    timeline_heading.append(&timeline_title);
    timeline_heading.append(&retry_all);
    sync_panel.append(&timeline_heading);
    let timeline = gtk::ListBox::new();
    timeline.add_css_class("sync-timeline-list");
    timeline.set_selection_mode(gtk::SelectionMode::None);
    let timeline_scroll = gtk::ScrolledWindow::builder()
        .min_content_height(112)
        .max_content_height(220)
        .vexpand(false)
        .child(&timeline)
        .build();
    timeline_scroll.add_css_class("sync-timeline-scroll");
    sync_panel.append(&timeline_scroll);

    let auth_actions = gtk::Box::new(Orientation::Vertical, 6);
    auth_actions.set_halign(Align::Fill);
    let saved_login = gtk::Button::with_label("使用已保存账户");
    saved_login.add_css_class("flat");
    let login = gtk::Button::with_label("登录");
    login.add_css_class("suggested-action");
    login.set_hexpand(true);
    let register = gtk::Button::with_label("创建账户");
    register.add_css_class("suggested-action");
    register.set_hexpand(true);
    register.set_visible(false);
    auth_actions.append(&login);
    auth_actions.append(&register);
    auth_actions.append(&saved_login);
    auth_card.append(&auth_actions);

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("关闭");
    let lock_master = gtk::Button::with_label("锁定主密码");
    let logout = gtk::Button::with_label("退出 / 切换账户");
    let import = gtk::Button::with_label("确认导入");
    import.add_css_class("suggested-action");
    import.set_sensitive(false);
    actions.append(&cancel);
    actions.append(&lock_master);
    actions.append(&logout);
    actions.append(&import);
    let sync_page = gtk::Box::new(Orientation::Vertical, 12);
    sync_page.append(&sync_panel);
    sync_page.append(&actions);
    page_stack.add_named(&sync_page, Some("sync"));
    page_stack.set_visible_child_name("auth");
    root.append(&page_stack);
    let page_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .child(&root)
        .build();
    window.set_child(Some(&page_scroll));

    let intro_for_mode = intro.clone();
    let register_fields_for_mode = register_fields.clone();
    let login_for_mode = login.clone();
    let saved_for_mode = saved_login.clone();
    let register_for_mode = register.clone();
    register_mode.connect_toggled(move |button| {
        let registering = button.is_active();
        intro_for_mode.set_label(if registering {
            "创建账号，开启安全终端工作台"
        } else {
            "欢迎回来，继续你的终端旅程"
        });
        register_fields_for_mode.set_visible(registering);
        login_for_mode.set_visible(!registering);
        saved_for_mode.set_visible(!registering);
        register_for_mode.set_visible(registering);
    });

    let close_context = context.clone();
    window.connect_close_request(move |_| {
        close_context.sync_scheduler.close_dialog();
        trigger_background_sync(close_context.clone());
        gtk::glib::Propagation::Proceed
    });

    let dialog_context = SyncDialogContext {
        window: window.clone(),
        catalog: context.catalog.clone(),
        credential_vault: context.vault.clone(),
        token_vault: AuthTokenVault,
        sync_state: context.sync_state.clone(),
        sync_operations: context.sync_operations.clone(),
        sync_scheduler: context.sync_scheduler.clone(),
        sync_session: context.sync_session.clone(),
        background_pending: context.background_pending.clone(),
        refresh_assets: context.refresh_assets.clone(),
        app_status: context.status.clone(),
        pending: Rc::new(RefCell::new(None)),
        summary,
        detail,
        conflicts,
        timeline,
        resolution_buttons: Rc::new(RefCell::new(Vec::new())),
        retry_buttons: Rc::new(RefCell::new(Vec::new())),
        spinner,
        login,
        saved_login,
        import,
        retry_all,
        page_stack: page_stack.clone(),
    };
    let pending_auth = Rc::new(RefCell::new(None::<SyncAuthInput>));
    let close_target = window.clone();
    cancel.connect_clicked(move |_| close_target.close());

    let lock_context = dialog_context.clone();
    lock_master.connect_clicked(move |_| {
        lock_context.sync_session.lock();
        lock_context.background_pending.borrow_mut().take();
        lock_context.pending.borrow_mut().take();
        lock_context.summary.set_label("主密码已锁定");
        lock_context
            .detail
            .set_label("后台增量拉取已暂停；离线密文队列仍可按期重试。重新输入主密码即可解锁。");
        lock_context.app_status.set_label("已登录 · 主密码已锁定");
    });

    let logout_context = dialog_context.clone();
    logout.connect_clicked(move |_| {
        logout_context.sync_session.lock();
        logout_context.background_pending.borrow_mut().take();
        logout_context.pending.borrow_mut().take();
        set_sync_busy(&logout_context, true, "正在撤销本机同步令牌…");
        let context = logout_context.clone();
        gtk::glib::spawn_future_local(async move {
            match context.token_vault.clear().await {
                Ok(()) => {
                    if let Some(application) = context.window.application() {
                        application.withdraw_notification("sync-action-required");
                    }
                    set_sync_busy(&context, false, "");
                    context.summary.set_label("已退出当前同步账户");
                    context.detail.set_label(
                        "本机访问令牌、刷新令牌和主密码会话已清除。正式服务暂未提供远端令牌撤销端点；如需切换账户，请直接使用新账户登录。",
                    );
                    context.app_status.set_label("未登录 · 后台同步已暂停");
                }
                Err(error) => show_sync_error(
                    &context,
                    &format!("无法从系统密钥环清除令牌，退出未完成：{error}"),
                ),
            }
        });
    });

    let login_context = dialog_context.clone();
    let login_pending = pending_auth.clone();
    let terms_for_login = terms.clone();
    let master_focus = master_password.clone();
    let username_for_login = username.clone();
    let password_for_login = login_password.clone();
    let login_button = dialog_context.login.clone();
    login_button.connect_clicked(move |_| {
        if !terms_for_login.is_active() {
            login_context
                .summary
                .set_label("请先阅读并同意使用条款与隐私说明");
            return;
        }
        login_pending.replace(Some(SyncAuthInput::Login {
            username: username_for_login.text().to_string(),
            password: password_for_login.text().to_string(),
        }));
        login_context.page_stack.set_visible_child_name("unlock");
        master_focus.grab_focus();
    });

    let register_context = dialog_context.clone();
    let register_pending = pending_auth.clone();
    let register_username = username.clone();
    let register_password = login_password.clone();
    let register_invite = invite_code.clone();
    let register_terms = terms.clone();
    let register_button = register.clone();
    register.connect_clicked(move |_| {
        if !register_terms.is_active() {
            register_context
                .summary
                .set_label("请先同意服务条款与隐私说明");
            return;
        }
        let username = register_username.text().trim().to_owned();
        let password = register_password.text().to_string();
        let invite = register_invite.text().trim().to_owned();
        register_button.set_sensitive(false);
        set_sync_busy(&register_context, true, "正在安全创建账户…");
        let (sender, receiver) = mpsc::channel();
        let request_username = username.clone();
        let request_password = password.clone();
        std::thread::spawn(move || {
            let result = CloudClient::production().and_then(|client| {
                client.register(&request_username, &request_password, &invite)?;
                Ok(())
            });
            let _ = sender.send(result);
        });
        let completion_context = register_context.clone();
        let completion_button = register_button.clone();
        let completion_pending = register_pending.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
            match receiver.try_recv() {
                Ok(Ok(())) => {
                    completion_button.set_sensitive(true);
                    set_sync_busy(&completion_context, false, "");
                    completion_pending.replace(Some(SyncAuthInput::Login {
                        username: username.clone(),
                        password: password.clone(),
                    }));
                    completion_context
                        .summary
                        .set_label("账户创建成功，请输入主密码解锁同步");
                    completion_context
                        .page_stack
                        .set_visible_child_name("unlock");
                    gtk::glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    completion_button.set_sensitive(true);
                    show_sync_error(&completion_context, &format!("注册失败：{error}"));
                    gtk::glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
                Err(_) => {
                    completion_button.set_sensitive(true);
                    show_sync_error(&completion_context, "注册线程意外退出。");
                    gtk::glib::ControlFlow::Break
                }
            }
        });
    });

    let saved_context = dialog_context.clone();
    let saved_pending = pending_auth.clone();
    let saved_button = dialog_context.saved_login.clone();
    saved_button.connect_clicked(move |_| {
        let context = saved_context.clone();
        let completion_pending = saved_pending.clone();
        set_sync_busy(&context, true, "正在读取系统密钥环中的登录…");
        gtk::glib::spawn_future_local(async move {
            match context.token_vault.lookup().await {
                Ok(Some(tokens)) => {
                    completion_pending.replace(Some(SyncAuthInput::Saved(SyncTokens {
                        access_token: tokens.access_token.clone(),
                        refresh_token: tokens.refresh_token.clone(),
                        account_scope: tokens.account_scope.clone(),
                    })));
                    set_sync_busy(&context, false, "");
                    context.page_stack.set_visible_child_name("unlock");
                }
                Ok(None) => show_sync_error(&context, "尚未保存云同步登录，请先使用账户密码登录。"),
                Err(error) => show_sync_error(&context, &format!("无法读取登录令牌：{error}")),
            }
        });
    });

    let unlock_context = dialog_context.clone();
    let unlock_pending = pending_auth.clone();
    unlock.connect_clicked(move |_| {
        let Some(auth) = unlock_pending.borrow_mut().take() else {
            show_sync_error(&unlock_context, "账户认证状态已过期，请返回重新登录。");
            return;
        };
        begin_cloud_preview(
            unlock_context.clone(),
            auth,
            master_password.text().to_string(),
        );
    });
    let back_stack = page_stack.clone();
    auth_back.connect_clicked(move |_| back_stack.set_visible_child_name("auth"));
    let legal_parent = window.clone();
    let legal_terms = terms.clone();
    view_terms
        .connect_clicked(move |_| present_legal_terms_window(&legal_parent, legal_terms.clone()));

    let import_context = dialog_context.clone();
    let import_button = dialog_context.import.clone();
    import_button.connect_clicked(move |_| apply_sync_preview(import_context.clone()));
    let retry_all_context = dialog_context.clone();
    let retry_all_button = dialog_context.retry_all.clone();
    retry_all_button
        .connect_clicked(move |_| retry_sync_queue(retry_all_context.clone(), None, true));
    if let Some(pending) = context.background_pending.borrow_mut().take() {
        render_sync_preview(&dialog_context, pending);
        context.sync_session.clear_notification();
    } else {
        render_sync_timeline(&dialog_context);
    }
    window.present();
    let automatic_context = dialog_context.clone();
    gtk::glib::timeout_add_local(Duration::from_secs(5), move || {
        if !automatic_context.window.is_visible() {
            return gtk::glib::ControlFlow::Break;
        }
        let due = automatic_context
            .pending
            .borrow()
            .as_ref()
            .and_then(|pending| {
                current_unix_ms().ok().and_then(|now| {
                    automatic_context
                        .sync_operations
                        .next_due(&pending.account_fingerprint, now)
                        .ok()
                        .flatten()
                })
            })
            .is_some();
        if due && !automatic_context.spinner.is_spinning() {
            retry_sync_queue(automatic_context.clone(), None, false);
        }
        gtk::glib::ControlFlow::Continue
    });
}

fn append_labeled_widget<W: IsA<gtk::Widget>>(container: &gtk::Box, label: &str, widget: &W) {
    let field = gtk::Box::new(Orientation::Vertical, 6);
    let field_label = gtk::Label::new(Some(label));
    field_label.set_xalign(0.0);
    field_label.add_css_class("field-label");
    field.append(&field_label);
    let widget_ref: &gtk::Widget = widget.as_ref();
    if widget_ref.is::<gtk::Switch>() {
        widget_ref.set_halign(Align::Start);
        widget_ref.set_hexpand(false);
    }
    field.append(widget);
    container.append(&field);
}

fn present_legal_terms_window(parent: &gtk::Window, accepted: gtk::CheckButton) {
    let window = gtk::Window::builder()
        .title("使用条款与隐私说明")
        .transient_for(parent)
        .modal(true)
        .default_width(660)
        .default_height(600)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 10);
    root.add_css_class("document-window");
    let text = gtk::TextView::new();
    text.set_editable(false);
    text.set_cursor_visible(false);
    text.set_wrap_mode(gtk::WrapMode::WordChar);
    text.buffer().set_text(ORBIT_LEGAL_TERMS);
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&text)
            .build(),
    );
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let close = gtk::Button::with_label("关闭");
    let agree = gtk::Button::with_label("同意并继续");
    agree.add_css_class("suggested-action");
    actions.append(&close);
    actions.append(&agree);
    root.append(&actions);
    let close_target = window.clone();
    close.connect_clicked(move |_| close_target.close());
    let agree_target = window.clone();
    agree.connect_clicked(move |_| {
        accepted.set_active(true);
        agree_target.close();
    });
    window.set_child(Some(&root));
    window.present();
}

fn begin_cloud_preview(context: SyncDialogContext, auth: SyncAuthInput, master_password: String) {
    if context.sync_scheduler.background_busy() {
        show_sync_error(
            &context,
            "后台正在恢复离线队列，请稍候片刻后再次执行同步检查。",
        );
        return;
    }
    if master_password.is_empty() {
        show_sync_error(&context, "请输入用于解密云端配置的主密码。");
        return;
    }
    set_sync_busy(&context, true, "正在通过 HTTPS 登录并生成只读预览…");
    context.pending.borrow_mut().take();
    let local_assets = context.catalog.borrow().assets().to_vec();
    let sync_state = context.sync_state.clone();
    let sync_operations = context.sync_operations.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let client = CloudClient::production();
        let result = client.and_then(|client| {
            let mut tokens = match auth {
                SyncAuthInput::Login { username, password } => {
                    let username = zeroize::Zeroizing::new(username);
                    let password = zeroize::Zeroizing::new(password);
                    client.login(&username, &password)?
                }
                SyncAuthInput::Saved(tokens) => tokens,
            };
            let fingerprint = account_fingerprint(&tokens.access_token)?;
            process_due_sync_queue(
                &client,
                &mut tokens,
                &sync_operations,
                &sync_state,
                &fingerprint,
            )?;
            let cursor = sync_state
                .cursor(&fingerprint)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let device_id = sync_state
                .device_id()
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let applied_revisions = sync_state
                .applied_revisions(&fingerprint, &local_assets)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            let mut dirty_asset_ids = HashSet::new();
            for asset in &local_assets {
                let metadata = sync_state
                    .asset(&fingerprint, asset.id)
                    .map_err(|error| SyncError::LocalState(error.to_string()))?;
                if metadata.is_some_and(|metadata| {
                    metadata.applied
                        && metadata.state == "active"
                        && !applied_revisions.contains_key(&asset.id)
                }) {
                    dirty_asset_ids.insert(asset.id);
                }
            }
            let deferred_assets: HashSet<_> = sync_operations
                .pending(&fingerprint)
                .map_err(|error| SyncError::LocalState(error.to_string()))?
                .into_iter()
                .map(|item| item.asset_id)
                .collect();
            let (mut remote, checkpoint) = match client.pull_changes(&mut tokens, cursor) {
                Ok(batch) => {
                    let checkpoint = SyncCheckpoint {
                        revision: batch.next_cursor,
                        reset_recovered: batch.reset_recovered,
                    };
                    (batch.items, Some(checkpoint))
                }
                Err(SyncError::IncrementalUnavailable) => {
                    (client.pull_inventory(&mut tokens)?, None)
                }
                Err(error) => return Err(error),
            };
            if !dirty_asset_ids.is_empty() {
                let inventory = client.pull_inventory(&mut tokens)?;
                append_missing_dirty_inventory(&mut remote, inventory, &dirty_asset_ids);
            }
            let master_password = zeroize::Zeroizing::new(master_password);
            let preview = build_pull_preview_with_deferred_for_account(
                remote,
                &local_assets,
                &applied_revisions,
                &deferred_assets,
                &master_password,
                &tokens.account_scope,
            )?;
            Ok::<_, SyncError>(PendingSyncRun {
                preview,
                tokens,
                checkpoint,
                account_fingerprint: fingerprint,
                device_id,
                master_password,
            })
        });
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok(pending)) => {
                let context = context.clone();
                gtk::glib::spawn_future_local(async move {
                    let material = AuthTokenMaterial {
                        access_token: pending.tokens.access_token.clone(),
                        refresh_token: pending.tokens.refresh_token.clone(),
                        account_scope: pending.tokens.account_scope.clone(),
                    };
                    if let Err(error) = context.token_vault.store(&material).await {
                        show_sync_error(
                            &context,
                            &format!("登录成功，但令牌无法安全保存：{error}"),
                        );
                        return;
                    }
                    let now = current_unix_ms().unwrap_or(0);
                    if !context.sync_session.unlock(
                        pending.account_fingerprint.clone(),
                        pending.master_password.to_string(),
                        now,
                    ) {
                        show_sync_error(&context, "主密码无法建立安全的应用会话。");
                        return;
                    }
                    context
                        .app_status
                        .set_label("同步会话已解锁 · 后台增量拉取已启用");
                    render_sync_preview(&context, pending);
                });
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                show_sync_error(&context, &format!("云同步检查失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_sync_error(&context, "同步工作线程意外退出。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn append_missing_dirty_inventory(
    remote: &mut Vec<RemoteConfig>,
    inventory: Vec<RemoteConfig>,
    dirty_asset_ids: &HashSet<Uuid>,
) {
    let mut represented: HashSet<Uuid> = remote
        .iter()
        .filter_map(|item| item.asset_id.as_deref())
        .filter_map(|value| Uuid::parse_str(value).ok())
        .collect();
    for item in inventory {
        let Some(asset_id) = item
            .asset_id
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok())
        else {
            continue;
        };
        if dirty_asset_ids.contains(&asset_id) && represented.insert(asset_id) {
            remote.push(item);
        }
    }
}

fn process_due_sync_queue(
    client: &CloudClient,
    tokens: &mut SyncTokens,
    operations: &SyncOperationRepository,
    sync_state: &SyncStateRepository,
    account_fingerprint: &str,
) -> Result<usize, SyncError> {
    let mut completed = 0;
    loop {
        let now = current_unix_ms().map_err(|error| SyncError::LocalState(error.to_string()))?;
        let Some(item) = operations
            .next_due(account_fingerprint, now)
            .map_err(|error| SyncError::LocalState(error.to_string()))?
        else {
            return Ok(completed);
        };
        let item = operations
            .begin_attempt(account_fingerprint, item.id)
            .map_err(|error| SyncError::LocalState(error.to_string()))?;
        match client.execute_queued(tokens, &item.payload) {
            Ok(remote) => {
                save_remote_state(
                    sync_state,
                    account_fingerprint,
                    &remote,
                    item.local_fingerprint.clone(),
                )
                .map_err(SyncError::LocalState)?;
                operations
                    .mark_completed(
                        account_fingerprint,
                        item.id,
                        remote
                            .server_revision
                            .map(|revision| format!("远端修订 {revision}")),
                    )
                    .map_err(|error| SyncError::LocalState(error.to_string()))?;
                completed += 1;
            }
            Err(error) => {
                operations
                    .mark_failed(account_fingerprint, item.id, &error.to_string())
                    .map_err(|state_error| SyncError::LocalState(state_error.to_string()))?;
                return Ok(completed);
            }
        }
    }
}

fn retry_sync_queue(context: SyncDialogContext, queue_id: Option<Uuid>, force_all: bool) {
    if context.sync_scheduler.background_busy() {
        context.summary.set_label("后台离线重试尚未完成");
        context
            .detail
            .set_label("请稍候片刻；完成后队列和时间线会使用同一持久化结果。");
        return;
    }
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    set_sync_busy(&context, true, "正在重试离线同步操作…");
    let operations = context.sync_operations.clone();
    let sync_state = context.sync_state.clone();
    let account = pending.account_fingerprint.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| match queue_id {
            Some(id) => retry_one_sync_operation(
                &client,
                &mut pending.tokens,
                &operations,
                &sync_state,
                &account,
                id,
            ),
            None if force_all => {
                let items = operations
                    .pending(&account)
                    .map_err(|error| SyncError::LocalState(error.to_string()))?;
                for item in items {
                    operations
                        .retry_now(&account, item.id)
                        .map_err(|error| SyncError::LocalState(error.to_string()))?;
                }
                process_due_sync_queue(
                    &client,
                    &mut pending.tokens,
                    &operations,
                    &sync_state,
                    &account,
                )
            }
            None => process_due_sync_queue(
                &client,
                &mut pending.tokens,
                &operations,
                &sync_state,
                &account,
            ),
        });
        pending.preview.deferred = operations
            .pending(&account)
            .map(|items| items.into_iter().map(|item| item.asset_id).collect())
            .unwrap_or_else(|_| pending.preview.deferred.clone());
        let _ = sender.send((pending, result));
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok((pending, result)) => {
                let material = AuthTokenMaterial {
                    access_token: pending.tokens.access_token.clone(),
                    refresh_token: pending.tokens.refresh_token.clone(),
                    account_scope: pending.tokens.account_scope.clone(),
                };
                render_sync_preview(&context, pending);
                match result {
                    Ok(completed) => {
                        let remaining = context
                            .pending
                            .borrow()
                            .as_ref()
                            .and_then(|pending| {
                                context
                                    .sync_operations
                                    .pending(&pending.account_fingerprint)
                                    .ok()
                            })
                            .map_or(0, |items| items.len());
                        context.app_status.set_label(&format!(
                            "离线同步重试 · 本次成功 {completed} 项 · 仍待 {remaining} 项"
                        ));
                    }
                    Err(error) => {
                        context.summary.set_label("离线同步重试失败");
                        context.detail.set_label(&format!(
                            "失败原因：{error}\n操作仍保留在队列中，可稍后再次手动重试。"
                        ));
                        context.detail.add_css_class("error-message");
                        context
                            .app_status
                            .set_label("离线同步重试失败 · 操作已保留");
                    }
                }
                let token_context = context.clone();
                gtk::glib::spawn_future_local(async move {
                    if let Err(error) = token_context.token_vault.store(&material).await {
                        token_context
                            .app_status
                            .set_label(&format!("重试已处理，但刷新后的登录令牌未保存：{error}"));
                    }
                });
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_sync_error(&context, "离线重试线程意外退出；队列内容保持不变。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn retry_one_sync_operation(
    client: &CloudClient,
    tokens: &mut SyncTokens,
    operations: &SyncOperationRepository,
    sync_state: &SyncStateRepository,
    account_fingerprint: &str,
    queue_id: Uuid,
) -> Result<usize, SyncError> {
    operations
        .retry_now(account_fingerprint, queue_id)
        .map_err(|error| SyncError::LocalState(error.to_string()))?;
    let item = operations
        .begin_attempt(account_fingerprint, queue_id)
        .map_err(|error| SyncError::LocalState(error.to_string()))?;
    match client.execute_queued(tokens, &item.payload) {
        Ok(remote) => {
            save_remote_state(
                sync_state,
                account_fingerprint,
                &remote,
                item.local_fingerprint,
            )
            .map_err(SyncError::LocalState)?;
            operations
                .mark_completed(
                    account_fingerprint,
                    queue_id,
                    remote
                        .server_revision
                        .map(|revision| format!("远端修订 {revision}")),
                )
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            Ok(1)
        }
        Err(error) => {
            operations
                .mark_failed(account_fingerprint, queue_id, &error.to_string())
                .map_err(|state_error| SyncError::LocalState(state_error.to_string()))?;
            Err(error)
        }
    }
}

fn render_sync_preview(context: &SyncDialogContext, mut pending: PendingSyncRun) {
    context.page_stack.set_visible_child_name("sync");
    if let Ok(queued) = context
        .sync_operations
        .pending(&pending.account_fingerprint)
    {
        pending
            .preview
            .deferred
            .extend(queued.into_iter().map(|item| item.asset_id));
        pending.preview.deferred.sort_unstable();
        pending.preview.deferred.dedup();
    }
    let importable = pending.preview.candidates.len();
    let unresolved = pending.preview.unresolved_count();
    let incremental = pending.checkpoint.is_some();
    context.summary.set_label(&format!(
        "云端活动 {} 项 · 可安全导入 {} 项 · 待处理 {} 项",
        pending.preview.remote_active, importable, unresolved
    ));
    context.detail.set_label(&format!(
        "同 UUID：{} 项\n跨端辅助记录：{} 项（已验证协议并安全跳过）\n涉及本机的删除墓碑：{} 项（本批墓碑共 {} 项）\n等待离线队列：{} 项\n无法解密或不受支持：{} 项\n同步方式：{}\n\n只有本批没有待处理记录且本地写入全部成功，才会向服务端确认修订并保存游标。",
        pending.preview.conflicts.len(),
        pending.preview.auxiliary_records,
        pending.preview.tombstone_conflicts.len(),
        pending.preview.tombstones,
        pending.preview.deferred.len(),
        pending.preview.failures.len(),
        if incremental { "增量拉取" } else { "兼容全量拉取（不确认游标）" }
    ));
    context.detail.remove_css_class("error-message");
    let can_confirm = unresolved == 0 && (importable > 0 || incremental);
    context.pending.replace(Some(pending));
    render_sync_conflicts(context);
    render_sync_timeline(context);
    set_sync_busy(context, false, "");
    context.import.set_sensitive(can_confirm);
    let action_label = if importable > 0 {
        format!("确认导入 {importable} 项")
    } else {
        "确认同步状态".into()
    };
    context.import.set_label(&action_label);
}

fn render_sync_conflicts(context: &SyncDialogContext) {
    while let Some(child) = context.conflicts.first_child() {
        context.conflicts.remove(&child);
    }
    context.resolution_buttons.borrow_mut().clear();
    let pending = context.pending.borrow();
    let Some(pending) = pending.as_ref() else {
        return;
    };
    if pending.preview.unresolved_count() == 0 {
        let empty = gtk::Label::new(Some("没有待处理记录"));
        empty.set_xalign(0.0);
        empty.add_css_class("caption");
        context.conflicts.append(&empty);
        return;
    }
    for conflict in &pending.preview.conflicts {
        append_active_sync_conflict(context, conflict);
    }
    for conflict in &pending.preview.tombstone_conflicts {
        append_tombstone_sync_conflict(context, conflict);
    }
    for asset_id in &pending.preview.deferred {
        append_sync_issue(
            &context.conflicts,
            "等待离线同步",
            &format!("资产 {asset_id} 已进入持久化队列；成功重试前不会确认本批游标。"),
        );
    }
    for failure in &pending.preview.failures {
        let id = failure
            .asset_id
            .map_or_else(|| "未知资产".into(), |value| value.to_string());
        append_sync_issue(
            &context.conflicts,
            "无法处理的云端记录",
            &format!("{id} · {}", failure.reason),
        );
    }
}

fn render_sync_timeline(context: &SyncDialogContext) {
    while let Some(child) = context.timeline.first_child() {
        context.timeline.remove(&child);
    }
    context.retry_buttons.borrow_mut().clear();
    let account = context
        .pending
        .borrow()
        .as_ref()
        .map(|pending| pending.account_fingerprint.clone());
    let Some(account) = account else {
        append_timeline_empty(&context.timeline, "登录后显示当前账户的离线操作与审计记录");
        context.retry_all.set_sensitive(false);
        return;
    };
    let queue = match context.sync_operations.pending(&account) {
        Ok(queue) => queue,
        Err(error) => {
            append_timeline_empty(&context.timeline, &format!("无法读取离线队列：{error}"));
            context.retry_all.set_sensitive(false);
            return;
        }
    };
    context.retry_all.set_sensitive(!queue.is_empty());
    for item in &queue {
        let row = gtk::Box::new(Orientation::Horizontal, 8);
        row.add_css_class("sync-queue-row");
        let copy = gtk::Box::new(Orientation::Vertical, 4);
        copy.set_hexpand(true);
        let title = gtk::Label::new(Some(&format!(
            "{} · {}",
            sync_operation_label(item.kind),
            short_asset_id(item.asset_id)
        )));
        title.set_xalign(0.0);
        title.add_css_class("heading");
        let retry_at = if item.next_retry_at_unix_ms <= current_unix_ms().unwrap_or(0) {
            "可立即重试".into()
        } else {
            format!(
                "{}后自动重试",
                relative_duration(item.next_retry_at_unix_ms)
            )
        };
        let detail = gtk::Label::new(Some(&format!(
            "已尝试 {} 次 · {}{}",
            item.attempt_count,
            retry_at,
            item.last_error
                .as_ref()
                .map(|error| format!("\n失败原因：{error}"))
                .unwrap_or_default()
        )));
        detail.set_xalign(0.0);
        detail.set_wrap(true);
        detail.add_css_class("caption");
        copy.append(&title);
        copy.append(&detail);
        let retry = gtk::Button::with_label("立即重试");
        retry.set_valign(Align::Center);
        let retry_context = context.clone();
        let queue_id = item.id;
        retry.connect_clicked(move |_| {
            retry_sync_queue(retry_context.clone(), Some(queue_id), false)
        });
        row.append(&copy);
        row.append(&retry);
        context.retry_buttons.borrow_mut().push(retry);
        context.timeline.append(&row);
    }
    match context.sync_operations.audit(&account, 20) {
        Ok(events) => {
            for event in events {
                let row = gtk::Box::new(Orientation::Vertical, 4);
                row.add_css_class("sync-audit-row");
                let title = gtk::Label::new(Some(&format!(
                    "{} · {} · {}",
                    sync_audit_label(event.outcome),
                    sync_operation_label(event.kind),
                    short_asset_id(event.asset_id)
                )));
                title.set_xalign(0.0);
                let detail = gtk::Label::new(Some(&format!(
                    "{} · 尝试 {}{}",
                    format_event_age(event.timestamp_unix_ms),
                    event.attempt_count,
                    event
                        .detail
                        .as_ref()
                        .map(|detail| format!(" · {detail}"))
                        .unwrap_or_default()
                )));
                detail.set_xalign(0.0);
                detail.set_wrap(true);
                detail.add_css_class("caption");
                row.append(&title);
                row.append(&detail);
                context.timeline.append(&row);
            }
            if queue.is_empty() && context.timeline.first_child().is_none() {
                append_timeline_empty(&context.timeline, "暂无离线操作或审计记录");
            }
        }
        Err(error) => {
            append_timeline_empty(&context.timeline, &format!("无法读取操作时间线：{error}"))
        }
    }
}

fn append_timeline_empty(list: &gtk::ListBox, message: &str) {
    let label = gtk::Label::new(Some(message));
    label.set_xalign(0.0);
    label.set_wrap(true);
    label.add_css_class("caption");
    label.set_margin_top(8);
    label.set_margin_bottom(8);
    label.set_margin_start(8);
    label.set_margin_end(8);
    list.append(&label);
}

fn sync_operation_label(kind: SyncOperationKind) -> &'static str {
    match kind {
        SyncOperationKind::KeepLocalUpload => "上传本机版本",
        SyncOperationKind::RestoreCloud => "恢复云端资产",
        SyncOperationKind::UseCloud => "采用云端版本",
        SyncOperationKind::AcceptDeletion => "接受云端删除",
    }
}

fn sync_audit_label(outcome: SyncAuditOutcome) -> &'static str {
    match outcome {
        SyncAuditOutcome::Queued => "已入队",
        SyncAuditOutcome::Retrying => "正在重试",
        SyncAuditOutcome::Failed => "重试失败",
        SyncAuditOutcome::Completed => "已完成",
        SyncAuditOutcome::ManualRetry => "手动重试",
    }
}

fn short_asset_id(id: Uuid) -> String {
    id.to_string().chars().take(8).collect()
}

fn relative_duration(future_unix_ms: u64) -> String {
    let delta = future_unix_ms.saturating_sub(current_unix_ms().unwrap_or(future_unix_ms));
    if delta < 60_000 {
        format!("{} 秒", (delta / 1_000).max(1))
    } else {
        format!("{} 分钟", (delta / 60_000).max(1))
    }
}

fn format_event_age(timestamp_unix_ms: u64) -> String {
    let age = current_unix_ms()
        .unwrap_or(timestamp_unix_ms)
        .saturating_sub(timestamp_unix_ms);
    if age < 60_000 {
        "刚刚".into()
    } else if age < 3_600_000 {
        format!("{} 分钟前", age / 60_000)
    } else if age < 86_400_000 {
        format!("{} 小时前", age / 3_600_000)
    } else {
        format!("{} 天前", age / 86_400_000)
    }
}

fn append_active_sync_conflict(
    context: &SyncDialogContext,
    conflict: &orbit_linux_sync::SyncConflict,
) {
    let body = gtk::Box::new(Orientation::Vertical, 8);
    body.add_css_class("sync-conflict-row");
    let title = gtk::Label::new(Some(&format!(
        "{} ↔ {}",
        conflict.local.name, conflict.remote.asset.name
    )));
    title.set_xalign(0.0);
    title.set_wrap(true);
    title.add_css_class("heading");
    body.append(&title);
    let detail = gtk::Label::new(Some(&format!(
        "UUID {} · 远端修订 {} · {}",
        conflict.asset_id,
        conflict.remote.remote.server_revision.unwrap_or(0),
        conflict.reason
    )));
    detail.set_xalign(0.0);
    detail.set_wrap(true);
    detail.add_css_class("caption");
    body.append(&detail);

    let grid = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(4)
        .build();
    grid.add_css_class("sync-compare-grid");
    append_comparison_heading(&grid, 0, "字段", "本机", "云端");
    let local = &conflict.local;
    let cloud = &conflict.remote.asset;
    let rows = [
        ("名称", local.name.clone(), cloud.name.clone()),
        (
            "分组",
            empty_as_dash(&local.group),
            empty_as_dash(&cloud.group),
        ),
        ("标签", tags_label(&local.tags), tags_label(&cloud.tags)),
        ("主机", local.host.clone(), cloud.host.clone()),
        (
            "协议",
            local.transport.display_name().into(),
            cloud.transport.display_name().into(),
        ),
        ("端口", local.port.to_string(), cloud.port.to_string()),
        ("用户", local.username.clone(), cloud.username.clone()),
        (
            "认证",
            auth_method_label(local.auth_method).into(),
            auth_method_label(cloud.auth_method).into(),
        ),
        (
            "密码回退",
            boolean_label(local.allow_password_fallback).into(),
            boolean_label(cloud.allow_password_fallback).into(),
        ),
        (
            "跳板机",
            local
                .jump_host
                .as_ref()
                .map(JumpHostConfiguration::endpoint)
                .unwrap_or_else(|| "—".into()),
            cloud
                .jump_host
                .as_ref()
                .map(JumpHostConfiguration::endpoint)
                .unwrap_or_else(|| "—".into()),
        ),
    ];
    for (index, (field, local_value, cloud_value)) in rows.into_iter().enumerate() {
        append_comparison_row(
            &grid,
            i32::try_from(index + 1).unwrap_or(i32::MAX),
            field,
            &local_value,
            &cloud_value,
        );
    }
    body.append(&grid);

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let keep_local = gtk::Button::with_label("保留本机");
    let use_cloud = gtk::Button::with_label("采用云端");
    use_cloud.add_css_class("suggested-action");
    let id = conflict.asset_id;
    let keep_context = context.clone();
    keep_local.connect_clicked(move |_| {
        confirm_sync_resolution(keep_context.clone(), id, SyncResolutionAction::KeepLocal)
    });
    let cloud_context = context.clone();
    use_cloud.connect_clicked(move |_| {
        confirm_sync_resolution(cloud_context.clone(), id, SyncResolutionAction::UseCloud)
    });
    actions.append(&keep_local);
    actions.append(&use_cloud);
    body.append(&actions);
    context
        .resolution_buttons
        .borrow_mut()
        .extend([keep_local, use_cloud]);
    context.conflicts.append(&body);
}

fn append_tombstone_sync_conflict(
    context: &SyncDialogContext,
    conflict: &orbit_linux_sync::TombstoneConflict,
) {
    let body = gtk::Box::new(Orientation::Vertical, 8);
    body.add_css_class("sync-conflict-row");
    let remote_state = if conflict.restorable {
        "云端已删除"
    } else {
        "云端已永久删除"
    };
    let title = gtk::Label::new(Some(&format!("{remote_state} · {}", conflict.local.name)));
    title.set_xalign(0.0);
    title.add_css_class("heading");
    body.append(&title);
    let detail = gtk::Label::new(Some(&format!(
        "{} · UUID {} · 远端修订 {}\n{}",
        conflict.local.endpoint(),
        conflict.asset_id,
        conflict.remote.server_revision.unwrap_or(0),
        conflict.reason
    )));
    detail.set_xalign(0.0);
    detail.set_wrap(true);
    detail.add_css_class("caption");
    body.append(&detail);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let accept = gtk::Button::with_label("接受删除");
    accept.add_css_class("destructive-action");
    let id = conflict.asset_id;
    let accept_context = context.clone();
    accept.connect_clicked(move |_| {
        confirm_sync_resolution(
            accept_context.clone(),
            id,
            SyncResolutionAction::AcceptDeletion,
        )
    });
    actions.append(&accept);
    context.resolution_buttons.borrow_mut().push(accept);
    if conflict.restorable {
        let restore = gtk::Button::with_label("恢复云端");
        restore.add_css_class("suggested-action");
        let restore_context = context.clone();
        restore.connect_clicked(move |_| {
            confirm_sync_resolution(
                restore_context.clone(),
                id,
                SyncResolutionAction::RestoreCloud,
            )
        });
        actions.append(&restore);
        context.resolution_buttons.borrow_mut().push(restore);
    }
    body.append(&actions);
    context.conflicts.append(&body);
}

fn append_comparison_heading(grid: &gtk::Grid, row: i32, field: &str, local: &str, cloud: &str) {
    for (column, value) in [(0, field), (1, local), (2, cloud)] {
        let label = gtk::Label::new(Some(value));
        label.set_xalign(0.0);
        label.add_css_class("field-label");
        grid.attach(&label, column, row, 1, 1);
    }
}

fn append_comparison_row(grid: &gtk::Grid, row: i32, field: &str, local: &str, cloud: &str) {
    let differs = local != cloud;
    for (column, value) in [(0, field), (1, local), (2, cloud)] {
        let label = gtk::Label::new(Some(value));
        label.set_xalign(0.0);
        label.set_wrap(true);
        label.set_hexpand(column > 0);
        if differs && column > 0 {
            label.add_css_class("sync-value-changed");
        }
        grid.attach(&label, column, row, 1, 1);
    }
}

fn empty_as_dash(value: &str) -> String {
    if value.is_empty() {
        "—".into()
    } else {
        value.into()
    }
}

fn tags_label(tags: &[String]) -> String {
    if tags.is_empty() {
        "—".into()
    } else {
        tags.join("、")
    }
}

fn auth_method_label(method: AuthMethod) -> &'static str {
    match method {
        AuthMethod::Password => "密码",
        AuthMethod::Key => "私钥",
    }
}

fn boolean_label(value: bool) -> &'static str {
    if value {
        "允许"
    } else {
        "禁止"
    }
}

fn confirm_sync_resolution(
    context: SyncDialogContext,
    asset_id: Uuid,
    action: SyncResolutionAction,
) {
    let (heading, body, verb, destructive) = match action {
        SyncResolutionAction::KeepLocal => (
            "用本机版本覆盖云端？",
            "本机资产和凭据会用主密码重新加密并写入云端。其他客户端随后会收到本机版本。",
            "保留本机",
            true,
        ),
        SyncResolutionAction::UseCloud => (
            "用云端版本替换本机？",
            "本机资产字段和凭据将被云端版本替换。云端配置本身不会改变。",
            "采用云端",
            true,
        ),
        SyncResolutionAction::AcceptDeletion => (
            "接受云端删除？",
            "该资产会从本机列表和系统密钥环删除。云端墓碑保持不变。",
            "接受删除",
            true,
        ),
        SyncResolutionAction::RestoreCloud => (
            "把本机资产恢复到云端？",
            "云端墓碑会恢复为活动资产，本机配置保持不变。其他客户端随后会收到恢复结果。",
            "恢复云端",
            false,
        ),
    };
    let dialog = adw::AlertDialog::builder()
        .heading(heading)
        .body(body)
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "取消");
    dialog.add_response("confirm", verb);
    if destructive {
        dialog.set_response_appearance("confirm", adw::ResponseAppearance::Destructive);
    } else {
        dialog.set_response_appearance("confirm", adw::ResponseAppearance::Suggested);
    }
    let parent = context.window.clone();
    gtk::glib::spawn_future_local(async move {
        if dialog.choose_future(Some(&parent)).await.as_str() == "confirm" {
            begin_sync_resolution(context, asset_id, action);
        }
    });
}

fn begin_sync_resolution(context: SyncDialogContext, asset_id: Uuid, action: SyncResolutionAction) {
    match action {
        SyncResolutionAction::KeepLocal => begin_keep_local_resolution(context, asset_id),
        SyncResolutionAction::UseCloud => begin_use_cloud_resolution(context, asset_id),
        SyncResolutionAction::AcceptDeletion => begin_accept_deletion_resolution(context, asset_id),
        SyncResolutionAction::RestoreCloud => begin_restore_cloud_resolution(context, asset_id),
    }
}

fn begin_keep_local_resolution(context: SyncDialogContext, asset_id: Uuid) {
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    let Some(index) = pending
        .preview
        .conflicts
        .iter()
        .position(|item| item.asset_id == asset_id)
    else {
        context.pending.replace(Some(pending));
        return;
    };
    let conflict = pending.preview.conflicts.remove(index);
    set_sync_busy(&context, true, "正在从系统密钥环读取本机凭据…");
    gtk::glib::spawn_future_local(async move {
        let credential = context
            .credential_vault
            .lookup(conflict.local.credential_id)
            .await;
        let credential = match credential {
            Ok(Some(value)) => value,
            Ok(None) => {
                pending.preview.conflicts.insert(index, conflict);
                restore_resolution_error(&context, pending, "本机凭据不存在，无法覆盖云端。");
                return;
            }
            Err(error) => {
                pending.preview.conflicts.insert(index, conflict);
                restore_resolution_error(&context, pending, &format!("无法读取本机凭据：{error}"));
                return;
            }
        };
        let jump_credential = match conflict.local.jump_host.as_ref() {
            Some(jump) => match context.credential_vault.lookup(jump.credential_id).await {
                Ok(Some(value)) => Some(value),
                Ok(None) => {
                    pending.preview.conflicts.insert(index, conflict);
                    restore_resolution_error(
                        &context,
                        pending,
                        "跳板机凭据不存在，无法用本机版本覆盖云端。",
                    );
                    return;
                }
                Err(error) => {
                    pending.preview.conflicts.insert(index, conflict);
                    restore_resolution_error(
                        &context,
                        pending,
                        &format!("无法读取跳板机凭据：{error}"),
                    );
                    return;
                }
            },
            None => None,
        };
        set_sync_busy(&context, true, "正在加密本机版本并写入云端…");
        let operations = context.sync_operations.clone();
        let account = pending.account_fingerprint.clone();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result = CloudClient::production().and_then(|client| {
                let payload = client.prepare_keep_local_for_account(
                    &conflict.local,
                    &credential,
                    jump_credential.as_ref(),
                    KeepLocalAccountContext {
                        remote: &conflict.remote.remote,
                        master_password: &pending.master_password,
                        device_id: pending.device_id,
                        account_scope: &pending.tokens.account_scope,
                    },
                )?;
                let local_fingerprint = asset_sync_fingerprint(&conflict.local)
                    .map_err(|error| SyncError::LocalState(error.to_string()))?;
                execute_persisted_operation(
                    &client,
                    &mut pending.tokens,
                    &operations,
                    &account,
                    SyncOperationKind::KeepLocalUpload,
                    payload,
                    Some(local_fingerprint),
                )
            });
            let _ = sender.send((pending, conflict, index, result));
        });
        poll_active_resolution(context, receiver, "已保留本机版本并更新云端");
    });
}

fn begin_restore_cloud_resolution(context: SyncDialogContext, asset_id: Uuid) {
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    let Some(index) = pending
        .preview
        .tombstone_conflicts
        .iter()
        .position(|item| item.asset_id == asset_id)
    else {
        context.pending.replace(Some(pending));
        return;
    };
    let conflict = pending.preview.tombstone_conflicts.remove(index);
    if !conflict.restorable {
        pending.preview.tombstone_conflicts.insert(index, conflict);
        restore_resolution_error(&context, pending, "云端资产已永久删除，不能恢复。");
        return;
    }
    set_sync_busy(&context, true, "正在恢复云端资产…");
    let operations = context.sync_operations.clone();
    let account = pending.account_fingerprint.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| {
            let payload = client.prepare_restore(
                &conflict.remote,
                pending.device_id,
                conflict.restore_operation_id,
            )?;
            let local_fingerprint = asset_sync_fingerprint(&conflict.local)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            execute_persisted_operation(
                &client,
                &mut pending.tokens,
                &operations,
                &account,
                SyncOperationKind::RestoreCloud,
                payload,
                Some(local_fingerprint),
            )
        });
        let _ = sender.send((pending, conflict, index, result));
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok((
                mut pending,
                conflict,
                index,
                Ok(QueuedNetworkOutcome::Completed { remote, operation }),
            )) => {
                if let Err(error) =
                    save_applied_remote(&context, &pending, &remote, Some(&conflict.local))
                {
                    let _ = context.sync_operations.mark_failed(
                        &pending.account_fingerprint,
                        operation.id,
                        &error,
                    );
                    pending.preview.tombstone_conflicts.insert(index, conflict);
                    restore_resolution_error(&context, pending, &error);
                } else {
                    if let Err(error) = context.sync_operations.mark_completed(
                        &pending.account_fingerprint,
                        operation.id,
                        remote
                            .server_revision
                            .map(|revision| format!("远端修订 {revision}")),
                    ) {
                        restore_resolution_error(
                            &context,
                            pending,
                            &format!("云端已恢复，但审计记录保存失败：{error}"),
                        );
                        return gtk::glib::ControlFlow::Break;
                    }
                    finish_network_resolution(
                        &context,
                        pending,
                        "已恢复云端资产；新修订将在下一次增量拉取中复核",
                    );
                }
                gtk::glib::ControlFlow::Break
            }
            Ok((
                mut pending,
                _conflict,
                _index,
                Ok(QueuedNetworkOutcome::Deferred { operation, reason }),
            )) => {
                if !pending.preview.deferred.contains(&operation.asset_id) {
                    pending.preview.deferred.push(operation.asset_id);
                }
                render_sync_preview(&context, pending);
                context.summary.set_label("恢复操作已进入离线队列");
                context.detail.set_label(&format!("失败原因：{reason}\n操作已持久化，将按退避策略自动重试，也可在时间线中立即重试。"));
                context
                    .app_status
                    .set_label("恢复操作已保存 · 等待网络重试");
                gtk::glib::ControlFlow::Break
            }
            Ok((mut pending, conflict, index, Err(error))) => {
                pending.preview.tombstone_conflicts.insert(index, conflict);
                restore_resolution_error(&context, pending, &format!("恢复云端失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_sync_error(&context, "恢复线程意外退出；本批游标未推进。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn poll_active_resolution(
    context: SyncDialogContext,
    receiver: mpsc::Receiver<(
        PendingSyncRun,
        orbit_linux_sync::SyncConflict,
        usize,
        Result<QueuedNetworkOutcome, SyncError>,
    )>,
    success_message: &'static str,
) {
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok((
                mut pending,
                conflict,
                index,
                Ok(QueuedNetworkOutcome::Completed { remote, operation }),
            )) => {
                if let Err(error) =
                    save_applied_remote(&context, &pending, &remote, Some(&conflict.local))
                {
                    let _ = context.sync_operations.mark_failed(
                        &pending.account_fingerprint,
                        operation.id,
                        &error,
                    );
                    pending.preview.conflicts.insert(index, conflict);
                    restore_resolution_error(&context, pending, &error);
                } else {
                    if let Err(error) = context.sync_operations.mark_completed(
                        &pending.account_fingerprint,
                        operation.id,
                        remote
                            .server_revision
                            .map(|revision| format!("远端修订 {revision}")),
                    ) {
                        restore_resolution_error(
                            &context,
                            pending,
                            &format!("云端已更新，但审计记录保存失败：{error}"),
                        );
                        return gtk::glib::ControlFlow::Break;
                    }
                    finish_network_resolution(&context, pending, success_message);
                }
                gtk::glib::ControlFlow::Break
            }
            Ok((
                mut pending,
                _conflict,
                _index,
                Ok(QueuedNetworkOutcome::Deferred { operation, reason }),
            )) => {
                if !pending.preview.deferred.contains(&operation.asset_id) {
                    pending.preview.deferred.push(operation.asset_id);
                }
                render_sync_preview(&context, pending);
                context.summary.set_label("上传操作已进入离线队列");
                context.detail.set_label(&format!("失败原因：{reason}\n操作已持久化，将按退避策略自动重试，也可在时间线中立即重试。"));
                context
                    .app_status
                    .set_label("上传操作已保存 · 等待网络重试");
                gtk::glib::ControlFlow::Break
            }
            Ok((mut pending, conflict, index, Err(error))) => {
                pending.preview.conflicts.insert(index, conflict);
                restore_resolution_error(&context, pending, &format!("冲突处理失败：{error}"));
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_sync_error(&context, "冲突处理线程意外退出；本批游标未推进。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn execute_persisted_operation(
    client: &CloudClient,
    tokens: &mut SyncTokens,
    operations: &SyncOperationRepository,
    account_fingerprint: &str,
    kind: SyncOperationKind,
    payload: orbit_linux_platform::QueuedSyncPayload,
    local_fingerprint: Option<String>,
) -> Result<QueuedNetworkOutcome, SyncError> {
    let operation = operations
        .enqueue(
            account_fingerprint,
            kind,
            payload,
            local_fingerprint,
            "等待首次发送",
        )
        .map_err(|error| SyncError::LocalState(error.to_string()))?;
    let operation = operations
        .begin_attempt(account_fingerprint, operation.id)
        .map_err(|error| SyncError::LocalState(error.to_string()))?;
    match client.execute_queued(tokens, &operation.payload) {
        Ok(remote) => Ok(QueuedNetworkOutcome::Completed { remote, operation }),
        Err(error) => {
            let reason = error.to_string();
            let operation = operations
                .mark_failed(account_fingerprint, operation.id, &reason)
                .map_err(|state_error| SyncError::LocalState(state_error.to_string()))?;
            Ok(QueuedNetworkOutcome::Deferred { operation, reason })
        }
    }
}

fn finish_network_resolution(
    context: &SyncDialogContext,
    pending: PendingSyncRun,
    message: &'static str,
) {
    let material = AuthTokenMaterial {
        access_token: pending.tokens.access_token.clone(),
        refresh_token: pending.tokens.refresh_token.clone(),
        account_scope: pending.tokens.account_scope.clone(),
    };
    let context = context.clone();
    gtk::glib::spawn_future_local(async move {
        if let Err(error) = context.token_vault.store(&material).await {
            render_sync_preview(&context, pending);
            context
                .summary
                .set_label("云端操作已完成，登录令牌保存失败");
            context.detail.set_label(&format!(
                "资产冲突已经处理，但刷新后的登录令牌无法写入系统密钥环：{error}\n当前窗口仍可继续；下次启动可能需要重新登录。"
            ));
            context.detail.add_css_class("error-message");
            context.app_status.set_label("冲突已处理 · 登录令牌未保存");
            return;
        }
        render_sync_preview(&context, pending);
        context.app_status.set_label(message);
    });
}

fn begin_use_cloud_resolution(context: SyncDialogContext, asset_id: Uuid) {
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    let Some(index) = pending
        .preview
        .conflicts
        .iter()
        .position(|item| item.asset_id == asset_id)
    else {
        context.pending.replace(Some(pending));
        return;
    };
    let conflict = pending.preview.conflicts.remove(index);
    set_sync_busy(&context, true, "正在用云端版本替换本机资产…");
    gtk::glib::spawn_future_local(async move {
        let old_credential = context
            .credential_vault
            .lookup(conflict.local.credential_id)
            .await;
        let old_credential = match old_credential {
            Ok(value) => value,
            Err(error) => {
                pending.preview.conflicts.insert(index, conflict);
                restore_resolution_error(
                    &context,
                    pending,
                    &format!("无法读取旧凭据以准备回滚：{error}"),
                );
                return;
            }
        };
        let old_jump_credential = match conflict.local.jump_host.as_ref() {
            Some(jump) => match context.credential_vault.lookup(jump.credential_id).await {
                Ok(value) => value,
                Err(error) => {
                    pending.preview.conflicts.insert(index, conflict);
                    restore_resolution_error(
                        &context,
                        pending,
                        &format!("无法读取旧跳板机凭据以准备回滚：{error}"),
                    );
                    return;
                }
            },
            None => None,
        };
        if let Err(error) = context
            .credential_vault
            .store(
                conflict.remote.asset.credential_id,
                &conflict.remote.asset.name,
                &conflict.remote.credential,
            )
            .await
        {
            pending.preview.conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &format!("云端凭据写入失败：{error}"));
            return;
        }
        if let Some((jump_id, jump_material)) = conflict.remote.jump_host_credential.as_ref() {
            if let Err(error) = context
                .credential_vault
                .store(
                    *jump_id,
                    &format!("{} · 跳板机", conflict.remote.asset.name),
                    jump_material,
                )
                .await
            {
                rollback_cloud_credential(
                    &context,
                    &conflict,
                    old_credential.as_ref(),
                    old_jump_credential.as_ref(),
                )
                .await;
                pending.preview.conflicts.insert(index, conflict);
                restore_resolution_error(
                    &context,
                    pending,
                    &format!("云端跳板机凭据写入失败：{error}"),
                );
                return;
            }
        }
        let catalog_result = {
            context
                .catalog
                .borrow_mut()
                .upsert(conflict.remote.asset.clone())
        };
        if let Err(error) = catalog_result {
            rollback_cloud_credential(
                &context,
                &conflict,
                old_credential.as_ref(),
                old_jump_credential.as_ref(),
            )
            .await;
            pending.preview.conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &format!("本机资产写入失败：{error}"));
            return;
        }
        if let Err(error) = save_applied_remote(
            &context,
            &pending,
            &conflict.remote.remote,
            Some(&conflict.remote.asset),
        ) {
            let _ = context.catalog.borrow_mut().upsert(conflict.local.clone());
            rollback_cloud_credential(
                &context,
                &conflict,
                old_credential.as_ref(),
                old_jump_credential.as_ref(),
            )
            .await;
            pending.preview.conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &error);
            return;
        }
        if conflict.local.credential_id != conflict.remote.asset.credential_id {
            let _ = context
                .credential_vault
                .clear(conflict.local.credential_id)
                .await;
        }
        let old_jump_id = conflict
            .local
            .jump_host
            .as_ref()
            .map(|jump| jump.credential_id);
        let new_jump_id = conflict
            .remote
            .asset
            .jump_host
            .as_ref()
            .map(|jump| jump.credential_id);
        if let Some(old_jump_id) = old_jump_id.filter(|old| Some(*old) != new_jump_id) {
            let _ = context.credential_vault.clear(old_jump_id).await;
        }
        if let Err(error) = context.sync_operations.record_completion(
            &pending.account_fingerprint,
            asset_id,
            SyncOperationKind::UseCloud,
            conflict
                .remote
                .remote
                .server_revision
                .map(|revision| format!("远端修订 {revision}")),
        ) {
            render_sync_preview(&context, pending);
            context.summary.set_label("已采用云端版本，但审计写入失败");
            context.detail.set_label(&format!(
                "本机资产与凭据已安全替换；操作审计记录未能保存：{error}"
            ));
            context.detail.add_css_class("error-message");
            return;
        }
        (context.refresh_assets)();
        render_sync_preview(&context, pending);
        context
            .app_status
            .set_label("已采用云端版本，本机资产与凭据已替换");
    });
}

async fn rollback_cloud_credential(
    context: &SyncDialogContext,
    conflict: &orbit_linux_sync::SyncConflict,
    old: Option<&CredentialMaterial>,
    old_jump: Option<&CredentialMaterial>,
) {
    if conflict.local.credential_id == conflict.remote.asset.credential_id {
        match old {
            Some(old) => {
                let _ = context
                    .credential_vault
                    .store(conflict.local.credential_id, &conflict.local.name, old)
                    .await;
            }
            None => {
                let _ = context
                    .credential_vault
                    .clear(conflict.local.credential_id)
                    .await;
            }
        }
    } else {
        let _ = context
            .credential_vault
            .clear(conflict.remote.asset.credential_id)
            .await;
    }
    let local_jump_id = conflict
        .local
        .jump_host
        .as_ref()
        .map(|jump| jump.credential_id);
    if let Some(remote_jump_id) = conflict
        .remote
        .asset
        .jump_host
        .as_ref()
        .map(|jump| jump.credential_id)
    {
        if Some(remote_jump_id) == local_jump_id {
            match old_jump {
                Some(old_jump) => {
                    let _ = context
                        .credential_vault
                        .store(remote_jump_id, "OrbitTerm 跳板机", old_jump)
                        .await;
                }
                None => {
                    let _ = context.credential_vault.clear(remote_jump_id).await;
                }
            }
        } else {
            let _ = context.credential_vault.clear(remote_jump_id).await;
        }
    }
}

fn begin_accept_deletion_resolution(context: SyncDialogContext, asset_id: Uuid) {
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    let Some(index) = pending
        .preview
        .tombstone_conflicts
        .iter()
        .position(|item| item.asset_id == asset_id)
    else {
        context.pending.replace(Some(pending));
        return;
    };
    let conflict = pending.preview.tombstone_conflicts.remove(index);
    set_sync_busy(&context, true, "正在从本机安全移除资产…");
    gtk::glib::spawn_future_local(async move {
        let old_credential = match context
            .credential_vault
            .lookup(conflict.local.credential_id)
            .await
        {
            Ok(value) => value,
            Err(error) => {
                pending.preview.tombstone_conflicts.insert(index, conflict);
                restore_resolution_error(
                    &context,
                    pending,
                    &format!("无法读取凭据以准备回滚：{error}"),
                );
                return;
            }
        };
        let old_jump_credential = match conflict.local.jump_host.as_ref() {
            Some(jump) => match context.credential_vault.lookup(jump.credential_id).await {
                Ok(value) => value,
                Err(error) => {
                    pending.preview.tombstone_conflicts.insert(index, conflict);
                    restore_resolution_error(
                        &context,
                        pending,
                        &format!("无法读取跳板机凭据以准备回滚：{error}"),
                    );
                    return;
                }
            },
            None => None,
        };
        if let Err(error) = context
            .credential_vault
            .clear(conflict.local.credential_id)
            .await
        {
            pending.preview.tombstone_conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &format!("无法删除本机凭据：{error}"));
            return;
        }
        if let Some(jump) = conflict.local.jump_host.as_ref() {
            if let Err(error) = context.credential_vault.clear(jump.credential_id).await {
                if let Some(old) = old_credential.as_ref() {
                    let _ = context
                        .credential_vault
                        .store(conflict.local.credential_id, &conflict.local.name, old)
                        .await;
                }
                pending.preview.tombstone_conflicts.insert(index, conflict);
                restore_resolution_error(
                    &context,
                    pending,
                    &format!("无法删除跳板机凭据：{error}"),
                );
                return;
            }
        }
        let catalog_result = { context.catalog.borrow_mut().remove(asset_id) };
        if let Err(error) = catalog_result {
            if let Some(old) = old_credential.as_ref() {
                let _ = context
                    .credential_vault
                    .store(conflict.local.credential_id, &conflict.local.name, old)
                    .await;
            }
            if let (Some(jump), Some(old)) = (
                conflict.local.jump_host.as_ref(),
                old_jump_credential.as_ref(),
            ) {
                let _ = context
                    .credential_vault
                    .store(jump.credential_id, "OrbitTerm 跳板机", old)
                    .await;
            }
            pending.preview.tombstone_conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &format!("无法删除本机资产：{error}"));
            return;
        }
        if let Err(error) = save_applied_remote(&context, &pending, &conflict.remote, None) {
            let _ = context.catalog.borrow_mut().upsert(conflict.local.clone());
            if let Some(old) = old_credential.as_ref() {
                let _ = context
                    .credential_vault
                    .store(conflict.local.credential_id, &conflict.local.name, old)
                    .await;
            }
            if let (Some(jump), Some(old)) = (
                conflict.local.jump_host.as_ref(),
                old_jump_credential.as_ref(),
            ) {
                let _ = context
                    .credential_vault
                    .store(jump.credential_id, "OrbitTerm 跳板机", old)
                    .await;
            }
            pending.preview.tombstone_conflicts.insert(index, conflict);
            restore_resolution_error(&context, pending, &error);
            return;
        }
        if let Err(error) = context.sync_operations.record_completion(
            &pending.account_fingerprint,
            asset_id,
            SyncOperationKind::AcceptDeletion,
            conflict
                .remote
                .server_revision
                .map(|revision| format!("远端修订 {revision}")),
        ) {
            (context.refresh_assets)();
            render_sync_preview(&context, pending);
            context.summary.set_label("已接受删除，但审计写入失败");
            context.detail.set_label(&format!(
                "本机资产与凭据已安全移除；操作审计记录未能保存：{error}"
            ));
            context.detail.add_css_class("error-message");
            return;
        }
        (context.refresh_assets)();
        render_sync_preview(&context, pending);
        context
            .app_status
            .set_label("已接受云端删除，本机资产与凭据已移除");
    });
}

fn save_applied_remote(
    context: &SyncDialogContext,
    pending: &PendingSyncRun,
    remote: &RemoteConfig,
    local_asset: Option<&ServerAsset>,
) -> Result<(), String> {
    let local_fingerprint = local_asset
        .map(asset_sync_fingerprint)
        .transpose()
        .map_err(|error| format!("本机资产指纹计算失败：{error}"))?;
    save_remote_state(
        &context.sync_state,
        &pending.account_fingerprint,
        remote,
        local_fingerprint,
    )
}

fn save_remote_state(
    sync_state: &SyncStateRepository,
    account_fingerprint: &str,
    remote: &RemoteConfig,
    local_fingerprint: Option<String>,
) -> Result<(), String> {
    let asset_id = remote
        .asset_id
        .as_deref()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| "服务端响应缺少合法资产 UUID；游标未推进。".to_owned())?;
    let server_revision = remote
        .server_revision
        .ok_or_else(|| "服务端响应缺少资产修订；游标未推进。".to_owned())?;
    sync_state
        .save_asset(
            account_fingerprint,
            asset_id,
            AssetSyncState {
                remote_id: remote.id,
                vector_clock: remote.vector_clock.clone(),
                state: remote.state.clone().unwrap_or_else(|| "active".into()),
                server_revision,
                applied: true,
                local_fingerprint,
            },
        )
        .map_err(|error| format!("逐资产修订保存失败：{error}；游标未推进。"))
}

fn restore_resolution_error(context: &SyncDialogContext, pending: PendingSyncRun, message: &str) {
    render_sync_preview(context, pending);
    context.summary.set_label("冲突处理未完成");
    context.detail.set_label(message);
    context.detail.add_css_class("error-message");
    context.app_status.set_label(message);
}

fn append_sync_issue(list: &gtk::ListBox, title: &str, detail: &str) {
    let row = gtk::Box::new(Orientation::Vertical, 4);
    row.add_css_class("sync-conflict-row");
    let title = gtk::Label::new(Some(title));
    title.set_xalign(0.0);
    title.set_wrap(true);
    title.add_css_class("heading");
    let detail = gtk::Label::new(Some(detail));
    detail.set_xalign(0.0);
    detail.set_wrap(true);
    detail.add_css_class("caption");
    row.append(&title);
    row.append(&detail);
    list.append(&row);
}

fn apply_sync_preview(context: SyncDialogContext) {
    let Some(mut pending) = context.pending.borrow_mut().take() else {
        return;
    };
    if pending.preview.unresolved_count() > 0 {
        show_sync_error(&context, "存在待处理记录，本阶段不会导入或推进游标。");
        return;
    }
    set_sync_busy(&context, true, "正在逐项写入系统密钥环与本地资产…");
    gtk::glib::spawn_future_local(async move {
        let mut imported = 0;
        let mut skipped = 0;
        let mut failed = 0;
        for remote in std::mem::take(&mut pending.preview.satisfied) {
            if save_applied_remote(&context, &pending, &remote, None).is_err() {
                failed += 1;
            }
        }
        for candidate in std::mem::take(&mut pending.preview.candidates) {
            if context
                .catalog
                .borrow()
                .assets()
                .iter()
                .any(|asset| asset.id == candidate.asset.id)
            {
                skipped += 1;
                continue;
            }
            if context
                .credential_vault
                .store(
                    candidate.asset.credential_id,
                    &candidate.asset.name,
                    &candidate.credential,
                )
                .await
                .is_err()
            {
                failed += 1;
                continue;
            }
            let jump_credential_id = candidate
                .jump_host_credential
                .as_ref()
                .map(|(credential_id, _)| *credential_id);
            if let Some((jump_id, jump_material)) = candidate.jump_host_credential.as_ref() {
                if context
                    .credential_vault
                    .store(
                        *jump_id,
                        &format!("{} · 跳板机", candidate.asset.name),
                        jump_material,
                    )
                    .await
                    .is_err()
                {
                    let _ = context
                        .credential_vault
                        .clear(candidate.asset.credential_id)
                        .await;
                    failed += 1;
                    continue;
                }
            }
            let credential_id = candidate.asset.credential_id;
            let asset = candidate.asset.clone();
            if context
                .catalog
                .borrow_mut()
                .upsert(candidate.asset)
                .is_err()
            {
                let _ = context.credential_vault.clear(credential_id).await;
                if let Some(jump_id) = jump_credential_id {
                    let _ = context.credential_vault.clear(jump_id).await;
                }
                failed += 1;
                continue;
            }
            if save_applied_remote(&context, &pending, &candidate.remote, Some(&asset)).is_err() {
                let _ = context.catalog.borrow_mut().remove(asset.id);
                let _ = context.credential_vault.clear(credential_id).await;
                if let Some(jump_id) = jump_credential_id {
                    let _ = context.credential_vault.clear(jump_id).await;
                }
                failed += 1;
                continue;
            }
            imported += 1;
        }
        (context.refresh_assets)();
        if skipped > 0 || failed > 0 {
            set_sync_busy(&context, false, "");
            context.import.set_sensitive(false);
            context.summary.set_label("本地写入未完全成功，游标未推进");
            context.app_status.set_label(&format!(
                "云同步未确认 · 成功 {imported} 项 · 跳过 {skipped} 项 · 失败 {failed} 项"
            ));
            context.detail.set_label(&format!(
                "导入成功：{imported} 项\n因本地出现同 UUID 而跳过：{skipped} 项\n写入失败：{failed} 项\n\n服务端修订未确认，本地游标未推进。"
            ));
            return;
        }
        let Some(checkpoint) = pending.checkpoint else {
            finish_full_pull_import(&context, imported);
            return;
        };
        acknowledge_sync_checkpoint(
            context,
            pending.tokens,
            pending.account_fingerprint,
            pending.device_id,
            checkpoint,
            imported,
        );
    });
}

fn finish_full_pull_import(context: &SyncDialogContext, imported: usize) {
    set_sync_busy(context, false, "");
    context.import.set_sensitive(false);
    context
        .summary
        .set_label(&format!("已导入 {imported} 项云端资产"));
    context
        .app_status
        .set_label(&format!("云同步兼容导入完成 · 成功 {imported} 项"));
    context.detail.set_label(&format!(
            "导入成功：{imported} 项\n\n服务端未提供增量同步端点，因此本次没有确认修订，也没有保存游标。"
        ));
}

fn acknowledge_sync_checkpoint(
    context: SyncDialogContext,
    mut tokens: SyncTokens,
    account_fingerprint: String,
    device_id: Uuid,
    checkpoint: SyncCheckpoint,
    imported: usize,
) {
    set_sync_busy(&context, true, "本地写入完成，正在确认服务端修订…");
    let state = context.sync_state.clone();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let result = CloudClient::production().and_then(|client| {
            let acknowledged = client.acknowledge(&mut tokens, device_id, checkpoint.revision)?;
            state
                .save_cursor(&account_fingerprint, acknowledged)
                .map_err(|error| SyncError::LocalState(error.to_string()))?;
            Ok::<_, SyncError>((tokens, acknowledged, checkpoint.reset_recovered))
        });
        let _ = sender.send(result);
    });
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        match receiver.try_recv() {
            Ok(Ok((tokens, revision, reset_recovered))) => {
                let context = context.clone();
                gtk::glib::spawn_future_local(async move {
                    let material = AuthTokenMaterial {
                        access_token: tokens.access_token.clone(),
                        refresh_token: tokens.refresh_token.clone(),
                        account_scope: tokens.account_scope.clone(),
                    };
                    if let Err(error) = context.token_vault.store(&material).await {
                        set_sync_busy(&context, false, "");
                        context.import.set_sensitive(false);
                        context.summary.set_label("同步已完成，登录令牌保存失败");
                        context.detail.set_label(&format!(
                            "服务端修订 {revision} 已确认且本机游标已保存，但刷新后的登录令牌无法写入系统密钥环：{error}\n下次同步可能需要重新登录。"
                        ));
                        context.detail.add_css_class("error-message");
                        context.app_status.set_label("同步已完成 · 登录令牌未保存");
                        return;
                    }
                    set_sync_busy(&context, false, "");
                    context.import.set_sensitive(false);
                    context
                        .summary
                        .set_label(&format!("同步完成 · 已确认修订 {revision}"));
                    context.app_status.set_label(&format!(
                        "云同步完成 · 导入 {imported} 项 · 游标 {revision}"
                    ));
                    context.detail.set_label(&format!(
                    "导入成功：{imported} 项\n服务端确认修订：{revision}\n游标重置恢复：{}\n\n所有冲突变更均来自逐项确认；检查点之后产生的远端修订将在下次增量同步中复核。",
                    if reset_recovered { "是" } else { "否" }
                ));
                });
                gtk::glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                show_sync_error(
                    &context,
                    &format!("本地导入已完成，但服务端确认失败，游标未推进：{error}"),
                );
                gtk::glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => gtk::glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => {
                show_sync_error(&context, "同步确认线程意外退出，游标未推进。");
                gtk::glib::ControlFlow::Break
            }
        }
    });
}

fn set_sync_busy(context: &SyncDialogContext, busy: bool, message: &str) {
    context.login.set_sensitive(!busy);
    context.saved_login.set_sensitive(!busy);
    for button in context.resolution_buttons.borrow().iter() {
        button.set_sensitive(!busy);
    }
    for button in context.retry_buttons.borrow().iter() {
        button.set_sensitive(!busy);
    }
    context.retry_all.set_sensitive(
        !busy
            && context.pending.borrow().as_ref().is_some_and(|pending| {
                context
                    .sync_operations
                    .pending(&pending.account_fingerprint)
                    .is_ok_and(|items| !items.is_empty())
            }),
    );
    context
        .import
        .set_sensitive(!busy && context.pending.borrow().is_some());
    context.spinner.set_visible(busy);
    if busy {
        context.spinner.start();
        context.summary.set_label(message);
    } else {
        context.spinner.stop();
    }
}

fn show_sync_error(context: &SyncDialogContext, message: &str) {
    set_sync_busy(context, false, "");
    context.import.set_sensitive(false);
    context.summary.set_label("云同步未执行");
    context.detail.set_label(message);
    context.detail.add_css_class("error-message");
}

fn present_edit_asset_window(
    parent: &adw::ApplicationWindow,
    catalog: Rc<RefCell<Catalog>>,
    vault: CredentialVault,
    asset_id: Uuid,
    refresh: Rc<dyn Fn()>,
) {
    let Some(original) = catalog
        .borrow()
        .assets()
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned()
    else {
        return;
    };
    let dialog = gtk::Window::builder()
        .title("编辑服务器")
        .transient_for(parent)
        .modal(true)
        .default_width(480)
        .default_height(620)
        .resizable(false)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 16);
    root.add_css_class("asset-dialog");
    let heading = gtk::Label::new(Some("编辑服务器资产"));
    heading.add_css_class("dialog-title");
    heading.set_xalign(0.0);
    root.append(&heading);

    let name = labeled_entry(&root, "名称", "服务器名称");
    name.set_text(&original.name);
    let group = labeled_entry(&root, "分组", "可选分组");
    group.set_text(&original.group);
    let tags = labeled_entry(&root, "标签", "多个标签用逗号分隔");
    tags.set_text(&original.tags.join(", "));
    let transport_field = gtk::Box::new(Orientation::Vertical, 6);
    let transport_label = gtk::Label::new(Some("连接协议"));
    transport_label.set_xalign(0.0);
    transport_label.add_css_class("field-label");
    let transport = gtk::DropDown::from_strings(&["SSH", "Telnet", "RDP"]);
    transport.set_selected(transport_index(original.transport));
    transport_field.append(&transport_label);
    transport_field.append(&transport);
    root.append(&transport_field);
    let host = labeled_entry(&root, "主机", "IP 地址或域名");
    host.set_text(&original.host);
    let username = labeled_entry(&root, "用户名", "SSH 登录用户");
    username.set_text(&original.username);
    let port = labeled_entry(&root, "端口", "22");
    port.set_text(&original.port.to_string());

    let auth_field = gtk::Box::new(Orientation::Vertical, 6);
    let auth_label = gtk::Label::new(Some("认证方式"));
    auth_label.set_xalign(0.0);
    auth_label.add_css_class("field-label");
    let auth = gtk::DropDown::from_strings(&["密码", "SSH 私钥"]);
    auth.set_selected(if original.auth_method == AuthMethod::Key {
        1
    } else {
        0
    });
    auth.set_sensitive(original.transport == Transport::Ssh);
    auth_field.append(&auth_label);
    auth_field.append(&auth);
    root.append(&auth_field);

    let credential_stack = gtk::Stack::new();
    let password = gtk::PasswordEntry::builder()
        .placeholder_text("新密码（留空则保留现有密码）")
        .show_peek_icon(true)
        .build();
    let password_field = gtk::Box::new(Orientation::Vertical, 6);
    let password_label = gtk::Label::new(Some("登录密码"));
    password_label.set_xalign(0.0);
    password_label.add_css_class("field-label");
    password_field.append(&password_label);
    password_field.append(&password);
    credential_stack.add_named(&password_field, Some("password"));

    let key_field = gtk::Box::new(Orientation::Vertical, 8);
    let key_picker = gtk::Button::builder()
        .label("选择新的私钥文件…")
        .icon_name("document-open-symbolic")
        .build();
    let key_status = gtk::Label::new(Some(if original.auth_method == AuthMethod::Key {
        if original.key_reference.is_empty() {
            "留空则保留现有私钥"
        } else {
            original.key_reference.as_str()
        }
    } else {
        "尚未选择私钥"
    }));
    key_status.add_css_class("caption");
    key_status.set_xalign(0.0);
    key_status.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    let key_passphrase = gtk::PasswordEntry::builder()
        .placeholder_text("新私钥口令（如有）")
        .show_peek_icon(true)
        .build();
    key_field.append(&key_picker);
    key_field.append(&key_status);
    key_field.append(&key_passphrase);
    credential_stack.add_named(&key_field, Some("key"));
    credential_stack.set_visible_child_name(if original.auth_method == AuthMethod::Key {
        "key"
    } else {
        "password"
    });
    root.append(&credential_stack);

    let stack_for_auth = credential_stack.clone();
    auth.connect_selected_notify(move |choice| {
        stack_for_auth.set_visible_child_name(if choice.selected() == 1 {
            "key"
        } else {
            "password"
        });
    });

    let selected_key = Rc::new(RefCell::new(None::<(String, String)>));
    let key_for_picker = selected_key.clone();
    let dialog_for_picker = dialog.clone();
    let status_for_picker = key_status.clone();
    key_picker.connect_clicked(move |_| {
        let chooser = gtk::FileDialog::builder().title("选择 SSH 私钥").build();
        let key_for_picker = key_for_picker.clone();
        let dialog_for_picker = dialog_for_picker.clone();
        let status_for_picker = status_for_picker.clone();
        gtk::glib::spawn_future_local(async move {
            let Ok(file) = chooser.open_future(Some(&dialog_for_picker)).await else {
                return;
            };
            let Some(path) = file.path() else {
                status_for_picker.set_label("所选私钥没有可读取的本地路径");
                status_for_picker.add_css_class("error-message");
                return;
            };
            let allowed = std::fs::metadata(&path)
                .map(|metadata| metadata.is_file() && metadata.len() <= 1024 * 1024)
                .unwrap_or(false);
            if !allowed {
                status_for_picker.set_label("私钥必须是小于 1 MiB 的普通文件");
                status_for_picker.add_css_class("error-message");
                return;
            }
            match std::fs::read_to_string(&path) {
                Ok(content) if !content.contains('\0') => {
                    let file_name = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("imported-key")
                        .to_owned();
                    status_for_picker.set_label(&file_name);
                    status_for_picker.remove_css_class("error-message");
                    key_for_picker.replace(Some((file_name, content)));
                }
                _ => {
                    status_for_picker.set_label("私钥必须是有效 UTF-8 文本");
                    status_for_picker.add_css_class("error-message");
                }
            }
        });
    });

    let jump_card = gtk::Box::new(Orientation::Vertical, 10);
    jump_card.add_css_class("form-card");
    let jump_header = gtk::Box::new(Orientation::Horizontal, 8);
    let jump_title = gtk::Label::new(Some("通过跳板机连接"));
    jump_title.set_xalign(0.0);
    jump_title.set_hexpand(true);
    jump_title.add_css_class("heading");
    let jump_enabled = gtk::Switch::new();
    jump_enabled.set_active(original.jump_host.is_some());
    jump_header.append(&jump_title);
    jump_header.append(&jump_enabled);
    jump_card.append(&jump_header);
    let jump_fields = gtk::Box::new(Orientation::Vertical, 8);
    let jump_host = labeled_entry(&jump_fields, "跳板机主机", "IP 地址或域名");
    let jump_port = labeled_entry(&jump_fields, "跳板机端口", "22");
    let jump_username = labeled_entry(&jump_fields, "跳板机用户名", "独立登录用户");
    if let Some(jump) = original.jump_host.as_ref() {
        jump_host.set_text(&jump.host);
        jump_port.set_text(&jump.port.to_string());
        jump_username.set_text(&jump.username);
    } else {
        jump_port.set_text("22");
    }
    let jump_password = gtk::PasswordEntry::builder()
        .placeholder_text(if original.jump_host.is_some() {
            "留空则保留现有凭据"
        } else {
            "新的跳板机密码"
        })
        .show_peek_icon(true)
        .build();
    append_labeled_widget(&jump_fields, "跳板机密码", &jump_password);
    jump_fields.set_visible(jump_enabled.is_active());
    let fields_for_switch = jump_fields.clone();
    jump_enabled
        .connect_active_notify(move |switch| fields_for_switch.set_visible(switch.is_active()));
    jump_card.append(&jump_fields);
    jump_card.set_visible(original.transport == Transport::Ssh);
    root.append(&jump_card);

    let transport_for_jump = transport.clone();
    let jump_card_for_transport = jump_card.clone();
    let jump_enabled_for_transport = jump_enabled.clone();
    let auth_for_transport = auth.clone();
    let credential_stack_for_transport = credential_stack.clone();
    transport.connect_selected_notify(move |_| {
        let ssh = transport_from_index(transport_for_jump.selected()) == Transport::Ssh;
        jump_card_for_transport.set_visible(ssh);
        auth_for_transport.set_sensitive(ssh);
        if !ssh {
            jump_enabled_for_transport.set_active(false);
            auth_for_transport.set_selected(0);
            credential_stack_for_transport.set_visible_child_name("password");
        }
    });

    let note = gtk::Label::new(Some(
        "资产 UUID 保持不变；主凭据与跳板机凭据独立保存在系统密钥环。留空不会读取或暴露现有秘密。",
    ));
    note.add_css_class("security-note");
    note.set_wrap(true);
    note.set_xalign(0.0);
    root.append(&note);
    let error = gtk::Label::new(None);
    error.add_css_class("error-message");
    error.set_wrap(true);
    error.set_xalign(0.0);
    error.set_visible(false);
    root.append(&error);

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let save = gtk::Button::with_label("保存修改");
    save.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&save);
    root.append(&actions);
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .child(&root)
        .build();
    dialog.set_child(Some(&scroller));

    let cancel_target = dialog.clone();
    cancel.connect_clicked(move |_| cancel_target.close());
    let save_target = dialog.clone();
    save.connect_clicked(move |save_button| {
        let parsed_port = match port.text().parse::<u16>() {
            Ok(port) if port > 0 => port,
            _ => {
                error.set_label("端口必须是 1–65535 范围内的数字。");
                error.set_visible(true);
                return;
            }
        };
        let mut updated = original.clone();
        updated.name = name.text().trim().to_owned();
        updated.group = group.text().trim().to_owned();
        updated.tags = parse_asset_tags(tags.text().as_str());
        updated.host = host.text().trim().to_owned();
        updated.username = username.text().trim().to_owned();
        updated.port = parsed_port;
        updated.transport = transport_from_index(transport.selected());
        updated.auth_method = if updated.transport == Transport::Ssh && auth.selected() == 1 {
            AuthMethod::Key
        } else {
            AuthMethod::Password
        };
        let primary_credential_update = match updated.auth_method {
            AuthMethod::Password => {
                updated.key_reference.clear();
                if password.text().is_empty() {
                    if original.auth_method != AuthMethod::Password {
                        error.set_label("改用密码认证时必须输入新的登录密码。");
                        error.set_visible(true);
                        return;
                    }
                    None
                } else {
                    Some(CredentialMaterial::password(password.text()))
                }
            }
            AuthMethod::Key => {
                if let Some((file_name, private_key)) = selected_key.borrow().as_ref().cloned() {
                    updated.key_reference = file_name;
                    Some(CredentialMaterial {
                        password: String::new(),
                        private_key,
                        private_key_passphrase: key_passphrase.text().to_string(),
                    })
                } else if original.auth_method == AuthMethod::Key {
                    updated.key_reference = original.key_reference.clone();
                    None
                } else {
                    error.set_label("改用 SSH 私钥认证时必须选择新的私钥文件。");
                    error.set_visible(true);
                    return;
                }
            }
        };
        let old_jump_id = original.jump_host.as_ref().map(|jump| jump.credential_id);
        let new_jump_material = if jump_enabled.is_active() {
            let parsed_jump_port = match jump_port.text().parse::<u16>() {
                Ok(port) if port > 0 => port,
                _ => {
                    error.set_label("跳板机端口必须是 1–65535 范围内的数字。");
                    error.set_visible(true);
                    return;
                }
            };
            let credential_id = old_jump_id.unwrap_or_else(Uuid::new_v4);
            updated.jump_host = Some(JumpHostConfiguration {
                credential_id,
                host: jump_host.text().trim().to_owned(),
                port: parsed_jump_port,
                username: jump_username.text().trim().to_owned(),
                auth_method: AuthMethod::Password,
                allow_password_fallback: false,
                key_reference: String::new(),
            });
            if jump_password.text().is_empty() {
                if old_jump_id.is_none() {
                    error.set_label("启用跳板机时必须输入独立的跳板机密码。");
                    error.set_visible(true);
                    return;
                }
                None
            } else {
                Some((
                    credential_id,
                    CredentialMaterial::password(jump_password.text()),
                ))
            }
        } else {
            updated.jump_host = None;
            None
        };
        if let Err(reason) = updated.validate() {
            error.set_label(&reason.to_string());
            error.set_visible(true);
            return;
        }
        if let Some((_, material)) = new_jump_material.as_ref() {
            if let Err(reason) = material.validate() {
                error.set_label(&reason.to_string());
                error.set_visible(true);
                return;
            }
        }
        if let Some(material) = primary_credential_update.as_ref() {
            if let Err(reason) = material.validate() {
                error.set_label(&reason.to_string());
                error.set_visible(true);
                return;
            }
        }
        save_button.set_sensitive(false);
        error.set_visible(false);
        let vault = vault.clone();
        let catalog = catalog.clone();
        let refresh = refresh.clone();
        let save_target = save_target.clone();
        let save_button = save_button.clone();
        let error = error.clone();
        let original_credential_id = original.credential_id;
        let original_name = original.name.clone();
        gtk::glib::spawn_future_local(async move {
            let old_primary_material = if primary_credential_update.is_some() {
                match vault.lookup(updated.credential_id).await {
                    Ok(material) => material,
                    Err(reason) => {
                        error.set_label(&format!("无法读取现有主凭据以建立回滚点：{reason}"));
                        error.set_visible(true);
                        save_button.set_sensitive(true);
                        return;
                    }
                }
            } else {
                None
            };
            let old_jump_material = if new_jump_material
                .as_ref()
                .is_some_and(|(jump_id, _)| Some(*jump_id) == old_jump_id)
            {
                match vault.lookup(old_jump_id.expect("matched jump id")).await {
                    Ok(material) => material,
                    Err(reason) => {
                        error.set_label(&format!("无法读取现有跳板机凭据以建立回滚点：{reason}"));
                        error.set_visible(true);
                        save_button.set_sensitive(true);
                        return;
                    }
                }
            } else {
                None
            };
            if let Some(material) = primary_credential_update.as_ref() {
                if let Err(reason) = vault
                    .store(updated.credential_id, &updated.name, material)
                    .await
                {
                    error.set_label(&reason.to_string());
                    error.set_visible(true);
                    save_button.set_sensitive(true);
                    return;
                }
            }
            if let Some((jump_id, material)) = new_jump_material.as_ref() {
                if let Err(reason) = vault.store(*jump_id, "OrbitTerm 跳板机", material).await {
                    if primary_credential_update.is_some() {
                        if let Some(old) = old_primary_material.as_ref() {
                            let _ = vault.store(updated.credential_id, &updated.name, old).await;
                        } else {
                            let _ = vault.clear(updated.credential_id).await;
                        }
                    }
                    error.set_label(&reason.to_string());
                    error.set_visible(true);
                    save_button.set_sensitive(true);
                    return;
                }
            }
            let new_jump_id = updated.jump_host.as_ref().map(|jump| jump.credential_id);
            let upsert_result = { catalog.borrow_mut().upsert(updated) };
            if let Err(reason) = upsert_result {
                if primary_credential_update.is_some() {
                    if let Some(old) = old_primary_material.as_ref() {
                        let _ = vault
                            .store(original_credential_id, &original_name, old)
                            .await;
                    } else {
                        let _ = vault.clear(original_credential_id).await;
                    }
                }
                if let Some((jump_id, _)) = new_jump_material.as_ref() {
                    if Some(*jump_id) == old_jump_id {
                        if let Some(old) = old_jump_material.as_ref() {
                            let _ = vault.store(*jump_id, "OrbitTerm 跳板机", old).await;
                        } else {
                            let _ = vault.clear(*jump_id).await;
                        }
                    } else {
                        let _ = vault.clear(*jump_id).await;
                    }
                }
                error.set_label(&reason.to_string());
                error.set_visible(true);
                save_button.set_sensitive(true);
                return;
            }
            if let Some(old_jump_id) = old_jump_id.filter(|old| Some(*old) != new_jump_id) {
                let _ = vault.clear(old_jump_id).await;
            }
            refresh();
            save_target.close();
        });
    });
    dialog.present();
}

fn parse_asset_tags(value: &str) -> Vec<String> {
    let mut tags = Vec::new();
    for tag in value
        .split([',', '，'])
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
    {
        if !tags.iter().any(|existing| existing == tag) {
            tags.push(tag.to_owned());
        }
    }
    tags
}

fn transport_from_index(index: u32) -> Transport {
    match index {
        1 => Transport::Telnet,
        2 => Transport::Rdp,
        _ => Transport::Ssh,
    }
}

fn transport_index(transport: Transport) -> u32 {
    match transport {
        Transport::Ssh => 0,
        Transport::Telnet => 1,
        Transport::Rdp => 2,
    }
}

struct BatchAssetInput {
    name: String,
    transport: Transport,
    host: String,
    port: u16,
    username: String,
    group: String,
    tags: Vec<String>,
    auth_method: AuthMethod,
    credential: CredentialMaterial,
}

fn parse_delimited_fields(line: &str) -> Result<Vec<String>, String> {
    let delimiter = if line.contains('\t') { '\t' } else { ',' };
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '"' if quoted && chars.peek() == Some(&'"') => {
                current.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            value if value == delimiter && !quoted => {
                fields.push(current.trim().to_owned());
                current.clear();
            }
            value => current.push(value),
        }
    }
    if quoted {
        return Err("存在未闭合的双引号。".into());
    }
    fields.push(current.trim().to_owned());
    Ok(fields)
}

fn parse_batch_assets(value: &str) -> Result<Vec<BatchAssetInput>, String> {
    let mut items = Vec::new();
    for (line_index, line) in value.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if items.len() >= 500 {
            return Err("单次最多导入 500 条资产。".into());
        }
        let fields = parse_delimited_fields(line)
            .map_err(|reason| format!("第 {} 行：{reason}", line_index + 1))?;
        if fields.len() != 11 {
            return Err(format!(
                "第 {} 行需要 11 个字段，当前为 {} 个。",
                line_index + 1,
                fields.len()
            ));
        }
        let transport = match fields[6].to_ascii_uppercase().as_str() {
            "SSH" => Transport::Ssh,
            "TELNET" => Transport::Telnet,
            "RDP" => Transport::Rdp,
            _ => {
                return Err(format!(
                    "第 {} 行协议必须是 SSH、Telnet 或 RDP。",
                    line_index + 1
                ))
            }
        };
        let port = fields[3]
            .parse::<u16>()
            .ok()
            .filter(|port| *port > 0)
            .ok_or_else(|| format!("第 {} 行端口无效。", line_index + 1))?;
        let auth_method = match fields[7].to_ascii_lowercase().as_str() {
            "password" | "密码" | "" => AuthMethod::Password,
            "key" | "privatekey" | "私钥" | "密钥" => AuthMethod::Key,
            _ => {
                return Err(format!(
                    "第 {} 行认证方式必须是密码或密钥。",
                    line_index + 1
                ))
            }
        };
        if transport != Transport::Ssh && auth_method == AuthMethod::Key {
            return Err(format!(
                "第 {} 行：Telnet 与 RDP 仅支持密码认证。",
                line_index + 1
            ));
        }
        let credential = CredentialMaterial {
            password: fields[5].clone(),
            private_key: fields[8].replace("\\n", "\n"),
            private_key_passphrase: fields[9].clone(),
        };
        credential
            .validate()
            .map_err(|error| format!("第 {} 行凭据无效：{error}", line_index + 1))?;
        if auth_method == AuthMethod::Key && credential.private_key.trim().is_empty() {
            return Err(format!(
                "第 {} 行选择密钥认证但未提供私钥。",
                line_index + 1
            ));
        }
        let item = BatchAssetInput {
            name: fields[0].to_owned(),
            transport,
            host: fields[2].to_owned(),
            port,
            username: fields[4].to_owned(),
            group: fields[1].to_owned(),
            tags: parse_asset_tags(&fields[10].replace(';', ",")),
            auth_method,
            credential,
        };
        let mut candidate = ServerAsset::new(&item.name, &item.host, &item.username);
        candidate.transport = item.transport;
        candidate.port = item.port;
        candidate.group = item.group.clone();
        candidate.tags = item.tags.clone();
        candidate
            .validate()
            .map_err(|error| format!("第 {} 行：{error}", line_index + 1))?;
        items.push(item);
    }
    if items.is_empty() {
        return Err("请至少输入一条资产。".into());
    }
    Ok(items)
}

fn present_bulk_import_window(
    parent: &gtk::Window,
    catalog: Rc<RefCell<Catalog>>,
    vault: CredentialVault,
    refresh: Rc<dyn Fn()>,
) {
    let window = gtk::Window::builder()
        .title("批量添加服务器")
        .transient_for(parent)
        .modal(true)
        .default_width(760)
        .default_height(640)
        .build();
    let root = gtk::Box::new(Orientation::Vertical, 12);
    root.add_css_class("asset-dialog");
    let title = gtk::Label::new(Some("批量导入资产"));
    title.add_css_class("dialog-title");
    title.set_xalign(0.0);
    root.append(&title);
    let guide = gtk::Label::new(Some("每行使用逗号或制表符：名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容,私钥口令,标签。支持双引号字段；私钥换行写作 \\n。协议支持 SSH、Telnet、RDP。"));
    guide.set_xalign(0.0);
    guide.set_wrap(true);
    guide.add_css_class("caption");
    root.append(&guide);
    let text = gtk::TextView::new();
    text.set_monospace(true);
    text.buffer().set_text("# 名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容,私钥口令,标签\n生产 SSH,生产,10.0.0.10,22,admin,change-me,SSH,密码,,,linux;核心\n测试桌面,测试,10.0.0.20,3389,tester,change-me,RDP,密码,,,desktop");
    root.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .min_content_height(240)
            .child(&text)
            .build(),
    );
    let security = gtk::Label::new(Some("每条资产使用本行凭据；解析只在内存中完成。密码与私钥导入后仅写入系统密钥环，绝不会写入资产文件或日志。请在粘贴后立即完成导入并清空来源剪贴板。"));
    security.add_css_class("security-note");
    security.set_xalign(0.0);
    security.set_wrap(true);
    root.append(&security);
    let error = gtk::Label::new(None);
    error.add_css_class("error-message");
    error.set_xalign(0.0);
    error.set_wrap(true);
    root.append(&error);
    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let import = gtk::Button::with_label("验证并导入");
    import.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&import);
    root.append(&actions);
    window.set_child(Some(&root));
    let close_target = window.clone();
    cancel.connect_clicked(move |_| close_target.close());
    let import_target = window.clone();
    import.connect_clicked(move |button| {
        let source = text
            .buffer()
            .text(&text.buffer().start_iter(), &text.buffer().end_iter(), true)
            .to_string();
        let inputs = match parse_batch_assets(&source) {
            Ok(inputs) => inputs,
            Err(reason) => {
                error.set_label(&reason);
                return;
            }
        };
        let mut endpoints = HashSet::new();
        let existing = catalog
            .borrow()
            .assets()
            .iter()
            .map(|asset| {
                (
                    asset.transport.display_name(),
                    asset.host.to_lowercase(),
                    asset.port,
                    asset.username.to_lowercase(),
                )
            })
            .collect::<HashSet<_>>();
        for input in &inputs {
            let endpoint = (
                input.transport.display_name(),
                input.host.to_lowercase(),
                input.port,
                input.username.to_lowercase(),
            );
            if existing.contains(&endpoint) || !endpoints.insert(endpoint) {
                error.set_label(&format!(
                    "检测到重复资产：{} · {}@{}:{}。导入尚未开始。",
                    input.name, input.username, input.host, input.port
                ));
                return;
            }
        }
        button.set_sensitive(false);
        error.set_label("正在安全写入资产与系统密钥环…");
        let catalog = catalog.clone();
        let vault = vault.clone();
        let refresh = refresh.clone();
        let error = error.clone();
        let button = button.clone();
        let target = import_target.clone();
        gtk::glib::spawn_future_local(async move {
            let mut inserted = Vec::new();
            for input in inputs {
                let mut asset = ServerAsset::new(input.name, input.host, input.username);
                asset.transport = input.transport;
                asset.port = input.port;
                asset.group = input.group;
                asset.tags = input.tags;
                asset.auth_method = input.auth_method;
                if asset.auth_method == AuthMethod::Key {
                    asset.key_reference = "批量导入 SSH 私钥".into();
                }
                if let Err(reason) = vault
                    .store(asset.credential_id, &asset.name, &input.credential)
                    .await
                {
                    for (asset_id, credential_id) in inserted.drain(..) {
                        let _ = catalog.borrow_mut().remove(asset_id);
                        let _ = vault.clear(credential_id).await;
                    }
                    error.set_label(&format!("密钥环写入失败，整批已回滚：{reason}"));
                    button.set_sensitive(true);
                    return;
                }
                let credential_id = asset.credential_id;
                let asset_id = asset.id;
                let upsert_result = { catalog.borrow_mut().upsert(asset) };
                if let Err(reason) = upsert_result {
                    let _ = vault.clear(credential_id).await;
                    for (asset_id, credential_id) in inserted.drain(..) {
                        let _ = catalog.borrow_mut().remove(asset_id);
                        let _ = vault.clear(credential_id).await;
                    }
                    error.set_label(&format!("资产写入失败，整批已回滚：{reason}"));
                    button.set_sensitive(true);
                    return;
                }
                inserted.push((asset_id, credential_id));
            }
            refresh();
            target.close();
        });
    });
    window.present();
}

fn present_add_asset_window(
    parent: &adw::ApplicationWindow,
    catalog: Rc<RefCell<Catalog>>,
    vault: CredentialVault,
    refresh: Rc<dyn Fn()>,
) {
    let dialog = gtk::Window::builder()
        .title("添加服务器")
        .transient_for(parent)
        .modal(true)
        .default_width(480)
        .default_height(680)
        .resizable(true)
        .build();

    let root = gtk::Box::new(Orientation::Vertical, 16);
    root.add_css_class("asset-dialog");
    let heading_row = gtk::Box::new(Orientation::Horizontal, 8);
    let heading = gtk::Label::new(Some("服务器资产"));
    heading.add_css_class("dialog-title");
    heading.set_xalign(0.0);
    heading.set_hexpand(true);
    let bulk = gtk::Button::with_label("批量导入");
    heading_row.append(&heading);
    heading_row.append(&bulk);
    root.append(&heading_row);
    let bulk_parent = dialog.clone();
    let bulk_catalog = catalog.clone();
    let bulk_vault = vault.clone();
    let bulk_refresh = refresh.clone();
    bulk.connect_clicked(move |_| {
        present_bulk_import_window(
            &bulk_parent,
            bulk_catalog.clone(),
            bulk_vault.clone(),
            bulk_refresh.clone(),
        );
    });

    let name = labeled_entry(&root, "名称", "例如：生产跳板机");
    let group = labeled_entry(&root, "分组", "例如：生产环境");
    let tags = labeled_entry(&root, "标签", "多个标签用逗号分隔");
    let transport_field = gtk::Box::new(Orientation::Vertical, 6);
    let transport_label = gtk::Label::new(Some("连接协议"));
    transport_label.set_xalign(0.0);
    transport_label.add_css_class("field-label");
    let transport = gtk::DropDown::from_strings(&["SSH", "Telnet", "RDP"]);
    transport_field.append(&transport_label);
    transport_field.append(&transport);
    root.append(&transport_field);
    let host = labeled_entry(&root, "主机", "IP 地址或域名");
    let username = labeled_entry(&root, "用户名", "远端登录用户");
    let port = labeled_entry(&root, "端口", "22");
    port.set_text("22");

    let auth_field = gtk::Box::new(Orientation::Vertical, 6);
    let auth_label = gtk::Label::new(Some("认证方式"));
    auth_label.set_xalign(0.0);
    auth_label.add_css_class("field-label");
    let auth = gtk::DropDown::from_strings(&["密码", "SSH 私钥"]);
    auth_field.append(&auth_label);
    auth_field.append(&auth);
    root.append(&auth_field);

    let credential_stack = gtk::Stack::new();
    let password = gtk::PasswordEntry::builder()
        .placeholder_text("保存在系统密钥环中")
        .show_peek_icon(true)
        .build();
    let password_field = gtk::Box::new(Orientation::Vertical, 6);
    let password_label = gtk::Label::new(Some("密码"));
    password_label.set_xalign(0.0);
    password_label.add_css_class("field-label");
    password_field.append(&password_label);
    password_field.append(&password);
    credential_stack.add_named(&password_field, Some("password"));

    let key_field = gtk::Box::new(Orientation::Vertical, 8);
    let key_picker = gtk::Button::builder()
        .label("选择私钥文件…")
        .icon_name("document-open-symbolic")
        .build();
    let key_status = gtk::Label::new(Some("尚未选择私钥"));
    key_status.add_css_class("caption");
    key_status.set_xalign(0.0);
    key_status.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    let key_passphrase = gtk::PasswordEntry::builder()
        .placeholder_text("私钥口令（如有）")
        .show_peek_icon(true)
        .build();
    key_field.append(&key_picker);
    key_field.append(&key_status);
    key_field.append(&key_passphrase);
    credential_stack.add_named(&key_field, Some("key"));
    root.append(&credential_stack);

    let jump_card = gtk::Box::new(Orientation::Vertical, 10);
    jump_card.add_css_class("form-card");
    let jump_header = gtk::Box::new(Orientation::Horizontal, 8);
    let jump_title = gtk::Label::new(Some("通过跳板机连接"));
    jump_title.set_xalign(0.0);
    jump_title.set_hexpand(true);
    jump_title.add_css_class("heading");
    let jump_enabled = gtk::Switch::new();
    jump_header.append(&jump_title);
    jump_header.append(&jump_enabled);
    jump_card.append(&jump_header);
    let jump_fields = gtk::Box::new(Orientation::Vertical, 8);
    let jump_host = labeled_entry(&jump_fields, "跳板机主机", "IP 地址或域名");
    let jump_port = labeled_entry(&jump_fields, "跳板机端口", "22");
    jump_port.set_text("22");
    let jump_username = labeled_entry(&jump_fields, "跳板机用户名", "独立登录用户");
    let jump_password = gtk::PasswordEntry::builder()
        .placeholder_text("保存在系统密钥环中")
        .show_peek_icon(true)
        .build();
    append_labeled_widget(&jump_fields, "跳板机密码", &jump_password);
    let jump_fallback = gtk::CheckButton::with_label("私钥失败时允许密码回退");
    jump_fallback.set_active(false);
    jump_fields.append(&jump_fallback);
    jump_fields.set_visible(false);
    let fields_for_switch = jump_fields.clone();
    jump_enabled
        .connect_active_notify(move |switch| fields_for_switch.set_visible(switch.is_active()));
    jump_card.append(&jump_fields);
    root.append(&jump_card);

    let stack_for_auth = credential_stack.clone();
    auth.connect_selected_notify(move |choice| {
        stack_for_auth.set_visible_child_name(if choice.selected() == 1 {
            "key"
        } else {
            "password"
        });
    });

    let selected_key = Rc::new(RefCell::new(None::<(String, String)>));
    let key_for_picker = selected_key.clone();
    let dialog_for_picker = dialog.clone();
    let status_for_picker = key_status.clone();
    key_picker.connect_clicked(move |_| {
        let chooser = gtk::FileDialog::builder().title("选择 SSH 私钥").build();
        let key_for_picker = key_for_picker.clone();
        let dialog_for_picker = dialog_for_picker.clone();
        let status_for_picker = status_for_picker.clone();
        gtk::glib::spawn_future_local(async move {
            let Ok(file) = chooser.open_future(Some(&dialog_for_picker)).await else {
                return;
            };
            let Some(path) = file.path() else {
                status_for_picker.set_label("所选私钥没有可读取的本地路径");
                status_for_picker.add_css_class("error-message");
                return;
            };
            let allowed = std::fs::metadata(&path)
                .map(|metadata| metadata.is_file() && metadata.len() <= 1024 * 1024)
                .unwrap_or(false);
            if !allowed {
                status_for_picker.set_label("私钥必须是小于 1 MiB 的普通文件");
                status_for_picker.add_css_class("error-message");
                return;
            }
            match std::fs::read_to_string(&path) {
                Ok(content) if !content.contains('\0') => {
                    let file_name = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("imported-key")
                        .to_owned();
                    status_for_picker.set_label(&file_name);
                    status_for_picker.remove_css_class("error-message");
                    key_for_picker.replace(Some((file_name, content)));
                }
                _ => {
                    status_for_picker.set_label("私钥必须是有效 UTF-8 文本");
                    status_for_picker.add_css_class("error-message");
                }
            }
        });
    });

    let note = gtk::Label::new(Some(
        "SSH 使用受检 Host Key 会话；密码、私钥与口令只写入 Secret Service。",
    ));
    note.add_css_class("caption");
    note.set_wrap(true);
    note.set_xalign(0.0);
    root.append(&note);

    let transport_for_change = transport.clone();
    let port_for_transport = port.clone();
    let auth_for_transport = auth.clone();
    let stack_for_transport = credential_stack.clone();
    let jump_card_for_transport = jump_card.clone();
    let jump_enabled_for_transport = jump_enabled.clone();
    let note_for_transport = note.clone();
    let previous_transport = Rc::new(Cell::new(Transport::Ssh));
    transport.connect_selected_notify(move |_| {
        let selected = transport_from_index(transport_for_change.selected());
        let previous = previous_transport.get();
        if port_for_transport.text().parse::<u16>().ok() == Some(previous.default_port()) {
            port_for_transport.set_text(&selected.default_port().to_string());
        }
        previous_transport.set(selected);
        let ssh = selected == Transport::Ssh;
        jump_card_for_transport.set_visible(ssh);
        if !ssh {
            jump_enabled_for_transport.set_active(false);
        }
        auth_for_transport.set_sensitive(ssh);
        if !ssh {
            auth_for_transport.set_selected(0);
            stack_for_transport.set_visible_child_name("password");
        }
        note_for_transport.set_label(match selected {
            Transport::Ssh => "SSH 使用受检 Host Key 会话；密码、私钥与口令只写入 Secret Service。",
            Transport::Telnet => {
                "Telnet 为明文协议；连接前会明确提示风险，凭据仍只存入系统密钥环。"
            }
            Transport::Rdp => "RDP 使用原生 FreeRDP 工作区并执行证书校验；密码只存入系统密钥环。",
        });
    });

    let error = gtk::Label::new(None);
    error.add_css_class("error-message");
    error.set_wrap(true);
    error.set_xalign(0.0);
    error.set_visible(false);
    root.append(&error);

    let actions = gtk::Box::new(Orientation::Horizontal, 8);
    actions.set_halign(Align::End);
    let cancel = gtk::Button::with_label("取消");
    let save = gtk::Button::with_label("保存资产");
    save.add_css_class("suggested-action");
    actions.append(&cancel);
    actions.append(&save);
    root.append(&actions);
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .child(&root)
        .build();
    dialog.set_child(Some(&scroller));

    let close_target = dialog.clone();
    cancel.connect_clicked(move |_| close_target.close());

    let dialog_for_save = dialog.clone();
    save.connect_clicked(move |save_button| {
        let parsed_port = match port.text().parse::<u16>() {
            Ok(port) if port > 0 => port,
            _ => {
                error.set_label("端口必须是 1–65535 范围内的数字。");
                error.set_visible(true);
                return;
            }
        };
        let mut asset = ServerAsset::new(name.text(), host.text(), username.text());
        asset.group = group.text().trim().to_owned();
        asset.tags = parse_asset_tags(tags.text().as_str());
        asset.transport = transport_from_index(transport.selected());
        asset.port = parsed_port;
        asset.auth_method = if asset.transport == Transport::Ssh && auth.selected() == 1 {
            AuthMethod::Key
        } else {
            AuthMethod::Password
        };
        asset.allow_password_fallback = asset.transport == Transport::Telnet;
        if asset.transport == Transport::Ssh {
            if let Some((file_name, _)) = selected_key.borrow().as_ref() {
                asset.key_reference = file_name.clone();
            }
        }
        let jump_credential = if jump_enabled.is_active() {
            let jump_port = match jump_port.text().parse::<u16>() {
                Ok(port) if port > 0 => port,
                _ => {
                    error.set_label("跳板机端口必须是 1–65535 范围内的数字。");
                    error.set_visible(true);
                    return;
                }
            };
            let credential_id = Uuid::new_v4();
            asset.jump_host = Some(JumpHostConfiguration {
                credential_id,
                host: jump_host.text().trim().to_owned(),
                port: jump_port,
                username: jump_username.text().trim().to_owned(),
                auth_method: AuthMethod::Password,
                allow_password_fallback: jump_fallback.is_active(),
                key_reference: String::new(),
            });
            Some((
                credential_id,
                CredentialMaterial::password(jump_password.text()),
            ))
        } else {
            None
        };
        if let Err(reason) = asset.validate() {
            error.set_label(&reason.to_string());
            error.set_visible(true);
            return;
        }
        let credential = if asset.auth_method == AuthMethod::Key {
            let Some((_, private_key)) = selected_key.borrow().as_ref().cloned() else {
                error.set_label("请选择 SSH 私钥文件。");
                error.set_visible(true);
                return;
            };
            CredentialMaterial {
                password: String::new(),
                private_key,
                private_key_passphrase: key_passphrase.text().to_string(),
            }
        } else {
            CredentialMaterial::password(password.text())
        };
        if let Err(reason) = credential.validate() {
            error.set_label(&reason.to_string());
            error.set_visible(true);
            return;
        }
        if let Some((_, jump_material)) = jump_credential.as_ref() {
            if let Err(reason) = jump_material.validate() {
                error.set_label(&format!("跳板机凭据无效：{reason}"));
                error.set_visible(true);
                return;
            }
        }

        save_button.set_sensitive(false);
        error.set_visible(false);
        let vault = vault.clone();
        let catalog = catalog.clone();
        let refresh = refresh.clone();
        let save_target = dialog_for_save.clone();
        let save_button = save_button.clone();
        let error_label = error.clone();
        gtk::glib::spawn_future_local(async move {
            if let Err(reason) = vault
                .store(asset.credential_id, &asset.name, &credential)
                .await
            {
                error_label.set_label(&reason.to_string());
                error_label.set_visible(true);
                save_button.set_sensitive(true);
                return;
            }
            if let Some((jump_id, jump_material)) = jump_credential.as_ref() {
                if let Err(reason) = vault
                    .store(*jump_id, &format!("{} · 跳板机", asset.name), jump_material)
                    .await
                {
                    let _ = vault.clear(asset.credential_id).await;
                    error_label.set_label(&reason.to_string());
                    error_label.set_visible(true);
                    save_button.set_sensitive(true);
                    return;
                }
            }
            let credential_id = asset.credential_id;
            let jump_credential_id = asset.jump_host.as_ref().map(|jump| jump.credential_id);
            let upsert_result = { catalog.borrow_mut().upsert(asset) };
            if let Err(reason) = upsert_result {
                let _ = vault.clear(credential_id).await;
                if let Some(jump_id) = jump_credential_id {
                    let _ = vault.clear(jump_id).await;
                }
                error_label.set_label(&reason.to_string());
                error_label.set_visible(true);
                save_button.set_sensitive(true);
                return;
            }
            refresh();
            save_target.close();
        });
    });
    dialog.present();
}

fn labeled_entry(container: &gtk::Box, label: &str, placeholder: &str) -> gtk::Entry {
    let field = gtk::Box::new(Orientation::Vertical, 6);
    let field_label = gtk::Label::new(Some(label));
    field_label.set_xalign(0.0);
    field_label.add_css_class("field-label");
    let entry = gtk::Entry::builder().placeholder_text(placeholder).build();
    field.append(&field_label);
    field.append(&entry);
    container.append(&field);
    entry
}

fn fatal_state(message: &str) -> adw::StatusPage {
    adw::StatusPage::builder()
        .icon_name("dialog-error-symbolic")
        .title("OrbitTerm 无法安全启动")
        .description(message)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workstation_panels_scale_with_the_window_and_keep_safe_bounds() {
        assert_eq!(responsive_workstation_panel_widths(980), (230, 280));
        assert_eq!(responsive_workstation_panel_widths(1280), (300, 328));
        assert_eq!(responsive_workstation_panel_widths(1600), (320, 410));
        assert_eq!(responsive_workstation_panel_widths(2200), (320, 420));
    }

    #[test]
    fn edit_asset_tags_are_trimmed_deduplicated_and_keep_order() {
        assert_eq!(
            parse_asset_tags(" matrix, linux，matrix, M02 "),
            vec!["matrix", "linux", "M02"]
        );
    }

    #[test]
    fn asset_transport_picker_covers_ssh_telnet_and_rdp() {
        for (index, transport) in [
            (0, Transport::Ssh),
            (1, Transport::Telnet),
            (2, Transport::Rdp),
        ] {
            assert_eq!(transport_from_index(index), transport);
            assert_eq!(transport_index(transport), index);
        }
    }

    #[test]
    fn module_fullscreen_requires_a_connected_desktop_protocol_session() {
        for transport in [Transport::Ssh, Transport::Telnet, Transport::Rdp] {
            assert!(module_fullscreen_available(
                transport,
                WorkspacePhase::Connected
            ));
            assert!(!module_fullscreen_available(
                transport,
                WorkspacePhase::Starting
            ));
            assert!(!module_fullscreen_available(
                transport,
                WorkspacePhase::Disconnected
            ));
            assert!(!module_fullscreen_available(
                transport,
                WorkspacePhase::Failed
            ));
        }

        for transport in [Transport::Ssh, Transport::Telnet] {
            assert!(module_fullscreen_button_available_for(
                transport,
                WorkspacePhase::Connected,
                false
            ));
            assert!(!module_fullscreen_button_available_for(
                transport,
                WorkspacePhase::Connected,
                true
            ));
        }
        assert!(module_fullscreen_button_available_for(
            Transport::Rdp,
            WorkspacePhase::Connected,
            true
        ));
        assert!(!module_fullscreen_button_available_for(
            Transport::Rdp,
            WorkspacePhase::Connected,
            false
        ));
    }

    #[test]
    fn terminal_fullscreen_pointer_guard_only_blocks_close_before_deadline() {
        let now = Instant::now();
        assert!(close_request_is_suppressed(
            Some(now + Duration::from_millis(1_200)),
            now
        ));
        assert!(!close_request_is_suppressed(Some(now), now));
        assert!(!close_request_is_suppressed(None, now));
    }

    #[test]
    fn dirty_inventory_only_adds_missing_tracked_assets() {
        fn remote(id: Uuid, revision: u64) -> RemoteConfig {
            RemoteConfig {
                id: revision,
                asset_id: Some(id.to_string()),
                encrypted_blob_base64: "fixture".into(),
                vector_clock: r#"{"linux":1}"#.into(),
                identity_fingerprint: None,
                state: Some("active".into()),
                server_revision: Some(revision),
                updated_at: String::new(),
            }
        }

        let already_present = Uuid::new_v4();
        let dirty = Uuid::new_v4();
        let unrelated = Uuid::new_v4();
        let mut incremental = vec![remote(already_present, 4)];
        append_missing_dirty_inventory(
            &mut incremental,
            vec![
                remote(already_present, 4),
                remote(dirty, 5),
                remote(unrelated, 6),
            ],
            &HashSet::from([already_present, dirty]),
        );

        assert_eq!(incremental.len(), 2);
        assert_eq!(
            incremental[1].asset_id.as_deref(),
            Some(dirty.to_string().as_str())
        );
    }

    #[test]
    fn remote_navigation_stays_absolute() {
        assert_eq!(normalize_remote_path("  /srv/log/ "), "/srv/log");
        assert_eq!(join_remote_path("/srv", "logs"), "/srv/logs");
        assert_eq!(parent_remote_path("/srv/logs"), "/srv");
        assert_eq!(parent_remote_path("/srv"), "/");
        assert_eq!(parent_remote_path("/"), "/");
    }

    #[test]
    fn byte_count_is_stable_for_tool_rows() {
        assert_eq!(format_byte_count(42), "42 B");
        assert_eq!(format_byte_count(1024), "1.0 KiB");
        assert_eq!(format_byte_count(1024 * 1024), "1.0 MiB");
    }

    #[test]
    fn terminal_sequences_cover_navigation_control_and_alt() {
        assert_eq!(
            terminal_key_sequence(gtk::gdk::Key::Up, gtk::gdk::ModifierType::empty()),
            Some(b"\x1b[A".to_vec())
        );
        assert_eq!(
            terminal_key_sequence(gtk::gdk::Key::c, gtk::gdk::ModifierType::CONTROL_MASK),
            Some(vec![3])
        );
        assert_eq!(
            terminal_key_sequence(gtk::gdk::Key::x, gtk::gdk::ModifierType::ALT_MASK),
            Some(b"\x1bx".to_vec())
        );
        assert!(!is_local_preinput_clipboard_shortcut(
            gtk::gdk::Key::c,
            gtk::gdk::ModifierType::CONTROL_MASK
        ));
        assert!(is_local_preinput_clipboard_shortcut(
            gtk::gdk::Key::c,
            gtk::gdk::ModifierType::CONTROL_MASK | gtk::gdk::ModifierType::SHIFT_MASK
        ));
    }

    #[test]
    fn workstation_shortcuts_cover_sessions_panes_and_preserve_terminal_controls() {
        use gtk::gdk::ModifierType as Modifiers;

        assert_eq!(
            workstation_shortcut_action(gtk::gdk::Key::Tab, Modifiers::CONTROL_MASK),
            Some(WorkstationShortcutAction::NextSession)
        );
        assert_eq!(
            workstation_shortcut_action(
                gtk::gdk::Key::Tab,
                Modifiers::CONTROL_MASK | Modifiers::SHIFT_MASK
            ),
            Some(WorkstationShortcutAction::PreviousSession)
        );
        assert_eq!(
            workstation_shortcut_action(gtk::gdk::Key::_3, Modifiers::CONTROL_MASK),
            Some(WorkstationShortcutAction::SelectSession(2))
        );
        assert_eq!(
            workstation_shortcut_action(gtk::gdk::Key::_4, Modifiers::ALT_MASK),
            Some(WorkstationShortcutAction::SelectPane(3))
        );
        assert_eq!(
            workstation_shortcut_action(
                gtk::gdk::Key::Right,
                Modifiers::ALT_MASK | Modifiers::SHIFT_MASK
            ),
            Some(WorkstationShortcutAction::NextPane)
        );
        assert_eq!(
            workstation_shortcut_action(
                gtk::gdk::Key::d,
                Modifiers::CONTROL_MASK | Modifiers::SHIFT_MASK
            ),
            Some(WorkstationShortcutAction::AddPane)
        );
        assert_eq!(
            workstation_shortcut_action(gtk::gdk::Key::c, Modifiers::CONTROL_MASK),
            None
        );
        assert_eq!(
            workstation_shortcut_action(
                gtk::gdk::Key::c,
                Modifiers::CONTROL_MASK | Modifiers::SHIFT_MASK
            ),
            None
        );
    }

    #[test]
    fn rdp_focus_routes_client_and_remote_shortcut_collisions_to_remote() {
        use gtk::gdk::ModifierType as Modifiers;

        let release = Modifiers::CONTROL_MASK | Modifiers::ALT_MASK | Modifiers::SHIFT_MASK;
        assert!(is_rdp_capture_release_shortcut(
            gtk::gdk::Key::Escape,
            release
        ));
        assert!(is_rdp_capture_release_shortcut(
            gtk::gdk::Key::Escape,
            Modifiers::SUPER_MASK
        ));
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                false,
                false,
                gtk::gdk::Key::Tab,
                Modifiers::CONTROL_MASK
            ),
            ShortcutRoutingLayer::RemoteDesktop
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                false,
                false,
                gtk::gdk::Key::F11,
                Modifiers::empty()
            ),
            ShortcutRoutingLayer::RemoteDesktop
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                false,
                true,
                gtk::gdk::Key::F11,
                Modifiers::empty()
            ),
            ShortcutRoutingLayer::Application
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                false,
                false,
                false,
                gtk::gdk::Key::Tab,
                Modifiers::CONTROL_MASK
            ),
            ShortcutRoutingLayer::Application
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                false,
                false,
                gtk::gdk::Key::Super_L,
                Modifiers::SUPER_MASK
            ),
            ShortcutRoutingLayer::LocalSystem
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                true,
                false,
                gtk::gdk::Key::Super_L,
                Modifiers::SUPER_MASK
            ),
            ShortcutRoutingLayer::RemoteDesktop
        );
        assert_eq!(
            shortcut_routing_layer(true, true, true, false, gtk::gdk::Key::Escape, release),
            ShortcutRoutingLayer::Application
        );
    }

    #[test]
    fn rdp_ime_only_handles_plain_or_shifted_text_input() {
        use gtk::gdk::ModifierType as Modifiers;

        assert!(rdp_key_event_allows_local_ime(Modifiers::empty()));
        assert!(rdp_key_event_allows_local_ime(Modifiers::SHIFT_MASK));
        for modifiers in [
            Modifiers::CONTROL_MASK,
            Modifiers::ALT_MASK,
            Modifiers::SUPER_MASK,
            Modifiers::META_MASK,
            Modifiers::HYPER_MASK,
            Modifiers::CONTROL_MASK | Modifiers::SHIFT_MASK,
        ] {
            assert!(!rdp_key_event_allows_local_ime(modifiers));
        }
    }

    #[test]
    fn rdp_fullscreen_tools_require_explicit_expansion_and_restore_windowed_controls() {
        assert_eq!(rdp_controls_presentation(true, false), (true, false));
        assert_eq!(rdp_controls_presentation(true, true), (true, true));
        assert_eq!(rdp_controls_presentation(false, false), (false, true));
        assert_eq!(rdp_controls_presentation(false, true), (false, true));
        assert!(window_resize_handles_visible(false, false));
        assert!(!window_resize_handles_visible(false, true));
        assert!(!window_resize_handles_visible(true, false));
        assert!(!window_resize_handles_visible(true, true));
    }

    #[test]
    fn rdp_fullscreen_capture_follows_focus_without_overwriting_windowed_preference() {
        let mut policy = RdpCapturePolicy::default();
        assert!(!policy.should_capture(false, true, true));
        assert!(policy.should_capture(true, true, true));
        assert!(!policy.should_capture(true, true, false));
        assert!(!policy.should_capture(true, false, true));
        // Focus recovery in fullscreen resumes automatic capture.
        assert!(policy.should_capture(true, true, true));
        // An explicit escape remains suspended across focus changes.
        policy.set_explicit(true, false);
        assert!(!policy.should_capture(true, true, false));
        assert!(!policy.should_capture(true, true, true));
        // A deliberate desktop click resumes it, without changing windowed mode.
        policy.set_explicit(true, true);
        assert!(policy.should_capture(true, true, true));
        assert!(!policy.should_capture(false, true, true));
        policy.set_explicit(false, true);
        assert!(policy.should_capture(false, true, true));
        assert!(!policy.should_capture(false, true, false));
        policy.set_explicit(true, false);
        assert!(policy.should_capture(false, true, true));
        assert!(!policy.should_capture(false, false, true));
    }

    #[test]
    fn background_reconnect_never_selects_or_owns_another_workspaces_input() {
        let ssh = Uuid::new_v4();
        let rdp_a = Uuid::new_v4();
        let rdp_b = Uuid::new_v4();
        let mut registry = SessionRegistry::default();
        assert!(!registry.select_for_connect(rdp_a, false));
        assert_eq!(registry.active_workspace_id, None);
        assert_eq!(registry.selected_asset_id, None);
        for foreground in [ssh, rdp_a, rdp_b] {
            assert!(registry.select_for_connect(foreground, true));
            for _ in 0..20 {
                for reconnecting in [rdp_a, rdp_b] {
                    assert_eq!(
                        registry.select_for_connect(reconnecting, false),
                        reconnecting == foreground
                    );
                    assert_eq!(registry.active_workspace_id, Some(foreground));
                    assert_eq!(registry.selected_asset_id, Some(foreground));
                    assert_eq!(
                        registry.owns_input(reconnecting),
                        reconnecting == foreground
                    );
                }
            }
        }
        // A deliberate user connection is still allowed to select its tab.
        assert!(registry.select_for_connect(ssh, true));
        assert_eq!(registry.active_workspace_id, Some(ssh));
    }

    #[test]
    fn captured_rdp_system_chords_route_remote_but_keep_local_escape_hatches() {
        use gtk::gdk::{Key, ModifierType as Modifiers};
        for (key, modifiers) in [
            (Key::Tab, Modifiers::ALT_MASK),
            (Key::Tab, Modifiers::CONTROL_MASK),
            (Key::d, Modifiers::SUPER_MASK),
            (Key::r, Modifiers::SUPER_MASK),
            (Key::Left, Modifiers::SUPER_MASK),
            (Key::Escape, Modifiers::CONTROL_MASK | Modifiers::SHIFT_MASK),
        ] {
            assert_eq!(
                shortcut_routing_layer(true, true, true, true, key, modifiers),
                ShortcutRoutingLayer::RemoteDesktop
            );
        }
        assert_eq!(
            shortcut_routing_layer(true, true, true, true, Key::F11, Modifiers::empty()),
            ShortcutRoutingLayer::Application
        );
        assert_eq!(
            shortcut_routing_layer(
                true,
                true,
                true,
                true,
                Key::Escape,
                Modifiers::CONTROL_MASK | Modifiers::ALT_MASK | Modifiers::SHIFT_MASK
            ),
            ShortcutRoutingLayer::Application
        );
        assert_eq!(
            shortcut_routing_layer(true, false, false, false, Key::d, Modifiers::SUPER_MASK),
            ShortcutRoutingLayer::LocalSystem
        );
    }

    #[test]
    fn rdp_surface_keeps_fullscreen_and_capture_escape_hatches_local() {
        use gtk::gdk::ModifierType as Modifiers;

        assert!(rdp_surface_reserves_local_key(
            true,
            gtk::gdk::Key::F11,
            Modifiers::empty()
        ));
        assert!(!rdp_surface_reserves_local_key(
            false,
            gtk::gdk::Key::F11,
            Modifiers::empty()
        ));
        assert!(!rdp_surface_reserves_local_key(
            true,
            gtk::gdk::Key::F11,
            Modifiers::SHIFT_MASK
        ));
        assert!(rdp_surface_reserves_local_key(
            false,
            gtk::gdk::Key::Escape,
            Modifiers::CONTROL_MASK | Modifiers::ALT_MASK | Modifiers::SHIFT_MASK
        ));
        assert!(rdp_surface_reserves_local_key(
            false,
            gtk::gdk::Key::Escape,
            Modifiers::SUPER_MASK
        ));
    }

    #[test]
    fn rdp_failures_distinguish_credentials_from_unavailable_service() {
        assert_eq!(
            classify_rdp_failure("FREERDP_ERROR_CONNECT_AUTHENTICATION_FAILED").kind,
            RdpFailureKind::Authentication
        );
        assert_eq!(
            classify_rdp_failure("FREERDP_ERROR_CONNECT_TRANSPORT_FAILED").kind,
            RdpFailureKind::ServiceUnavailable
        );
        assert_eq!(
            classify_rdp_failure("FREERDP_ERROR_DNS_NAME_NOT_FOUND").kind,
            RdpFailureKind::NameResolution
        );
        assert_eq!(
            classify_rdp_failure("FREERDP_ERROR_CONNECT_SECURITY_NEGO_CONNECT_FAILED").kind,
            RdpFailureKind::Protocol
        );
        assert!(rdp_failure_allows_auto_reconnect(
            RdpFailureKind::ServiceUnavailable
        ));
        assert!(rdp_failure_allows_auto_reconnect(RdpFailureKind::TimedOut));
        assert!(!rdp_failure_allows_auto_reconnect(
            RdpFailureKind::Authentication
        ));
        assert!(!rdp_failure_allows_auto_reconnect(
            RdpFailureKind::Certificate
        ));
        assert!(!rdp_failure_allows_auto_reconnect(RdpFailureKind::Protocol));
    }

    #[test]
    fn rdp_automatic_reconnect_is_bounded_and_backed_off() {
        let delays = (1..=MAX_RDP_RECONNECT_ATTEMPTS)
            .map(|attempt| rdp_reconnect_delay(attempt).unwrap().as_secs())
            .collect::<Vec<_>>();
        assert_eq!(delays, vec![1, 2, 4, 8, 15, 30, 30, 30]);
        assert_eq!(rdp_reconnect_delay(0), None);
        assert_eq!(rdp_reconnect_delay(MAX_RDP_RECONNECT_ATTEMPTS + 1), None);
        assert!(workspace_phase_accepts_connect_start(
            WorkspacePhase::Reconnecting
        ));
        assert!(!workspace_phase_accepts_connect_start(
            WorkspacePhase::Connected
        ));
    }

    #[test]
    fn rdp_scroll_translates_gtk_direction_without_losing_axis() {
        assert_eq!(
            rdp_scroll_pointer_flags(-1.0, false),
            Some(RDP_PTR_WHEEL | RDP_WHEEL_DELTA)
        );
        assert_eq!(
            rdp_scroll_pointer_flags(1.0, false),
            Some(RDP_PTR_WHEEL | RDP_PTR_WHEEL_NEGATIVE | RDP_WHEEL_DELTA)
        );
        assert_eq!(
            rdp_scroll_pointer_flags(1.0, true),
            Some(RDP_PTR_HWHEEL | RDP_WHEEL_DELTA)
        );
        assert_eq!(
            rdp_scroll_pointer_flags(-1.0, true),
            Some(RDP_PTR_HWHEEL | RDP_PTR_WHEEL_NEGATIVE | RDP_WHEEL_DELTA)
        );
        assert_eq!(rdp_scroll_pointer_flags(0.0, false), None);
        assert_eq!(rdp_scroll_pointer_flags(f64::NAN, false), None);
    }

    #[test]
    fn rdp_reconnect_overlay_never_looks_connected() {
        let (_, detail, visible) = rdp_state_presentation(WorkspacePhase::Reconnecting, 3);
        assert!(visible);
        assert!(detail.contains("3/8"));
        assert!(!rdp_state_presentation(WorkspacePhase::Connected, 0).2);
    }

    #[test]
    fn rdp_metrics_use_a_bounded_window_without_calling_static_content_unhealthy() {
        let started = Instant::now();
        let mut metrics = RdpSessionMetrics::new_at(started);
        let frame = RdpFrame {
            width: 1280,
            height: 720,
            stride: 16,
            bgra: vec![0; 64],
            damage: orbit_linux_session::RdpDamage {
                x: 0,
                y: 0,
                width: 4,
                height: 4,
            },
            source_updates: 1,
            decoded_bytes: 64,
        };
        for second in 1..=3 {
            metrics.record_frame_at(started + Duration::from_secs(second), &frame);
        }
        let active = metrics.snapshot_at(started + Duration::from_secs(3));
        assert_eq!(active.resolution, Some((1280, 720)));
        assert_eq!(active.frame_count, 3);
        assert_eq!(active.presentation_count, 3);
        assert_eq!(active.coalesced_update_count, 0);
        assert_eq!(active.decoded_bytes, 192);
        assert_eq!(active.avoided_native_full_frame_bytes, 11_059_008);
        assert!((active.frames_per_second - 0.6).abs() < f64::EPSILON);
        assert_eq!(active.largest_update_gap, Duration::from_secs(1));
        assert!(
            rdp_quality_button_label(WorkspacePhase::Connected, 0, Some(&active)).contains("fps")
        );

        let static_view = metrics.snapshot_at(started + Duration::from_secs(9));
        assert_eq!(static_view.frames_per_second, 0.0);
        assert_eq!(static_view.frame_count, 3);
        assert_eq!(
            rdp_quality_button_label(WorkspacePhase::Connected, 0, Some(&static_view)),
            "自适应 · 静态画面"
        );
    }

    #[test]
    fn rdp_input_metrics_measure_the_next_frame_without_claiming_network_rtt() {
        let started = Instant::now();
        let mut metrics = RdpSessionMetrics::new_at(started);
        metrics.record_input_at(
            started + Duration::from_millis(100),
            RdpInputKind::Pointer,
            true,
        );
        metrics.record_input_at(
            started + Duration::from_millis(110),
            RdpInputKind::Button,
            true,
        );
        metrics.record_input_at(
            started + Duration::from_millis(115),
            RdpInputKind::Scroll,
            false,
        );
        metrics.record_input_at(
            started + Duration::from_millis(120),
            RdpInputKind::KeyPress,
            true,
        );
        metrics.record_input_at(
            started + Duration::from_millis(125),
            RdpInputKind::KeyRelease,
            true,
        );
        metrics.record_input_at(
            started + Duration::from_millis(130),
            RdpInputKind::TextCommit,
            true,
        );
        let frame = RdpFrame {
            width: 1280,
            height: 720,
            stride: 4,
            bgra: vec![0; 4],
            damage: orbit_linux_session::RdpDamage {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
            },
            source_updates: 1,
            decoded_bytes: 4,
        };
        metrics.record_frame_at(started + Duration::from_millis(175), &frame);
        let snapshot = metrics.snapshot_at(started + Duration::from_millis(175));
        assert_eq!(snapshot.pointer_event_count, 1);
        assert_eq!(snapshot.button_event_count, 1);
        assert_eq!(snapshot.scroll_event_count, 0);
        assert_eq!(snapshot.key_event_count, 3);
        assert_eq!(snapshot.key_press_event_count, 1);
        assert_eq!(snapshot.key_release_event_count, 1);
        assert_eq!(snapshot.text_commit_event_count, 1);
        assert_eq!(snapshot.rejected_input_count, 1);
        assert_eq!(
            snapshot.last_input_to_frame,
            Some(Duration::from_millis(75))
        );
        assert_eq!(snapshot.largest_input_to_frame, Duration::from_millis(75));

        metrics.record_input_at(
            started + Duration::from_secs(1),
            RdpInputKind::Pointer,
            true,
        );
        metrics.record_frame_at(started + Duration::from_secs(7), &frame);
        let stale = metrics.snapshot_at(started + Duration::from_secs(7));
        assert_eq!(stale.last_input_to_frame, None);
        assert_eq!(stale.largest_input_to_frame, Duration::from_millis(75));
    }

    #[test]
    fn rdp_canvas_applies_partial_updates_without_touching_other_pixels() {
        let mut canvas = RdpCanvas::default();
        let full = RdpFrame {
            width: 4,
            height: 3,
            stride: 16,
            bgra: vec![1; 48],
            damage: orbit_linux_session::RdpDamage {
                x: 0,
                y: 0,
                width: 4,
                height: 3,
            },
            source_updates: 1,
            decoded_bytes: 48,
        };
        assert!(canvas.apply(&full));
        let patch = RdpFrame {
            width: 4,
            height: 3,
            stride: 8,
            bgra: vec![9; 16],
            damage: orbit_linux_session::RdpDamage {
                x: 1,
                y: 1,
                width: 2,
                height: 2,
            },
            source_updates: 2,
            decoded_bytes: 16,
        };
        assert!(canvas.apply(&patch));
        let stride = usize::try_from(canvas.stride).unwrap();
        let pixels = canvas.surface.as_mut().unwrap().data().unwrap();
        assert_eq!(&pixels[0..16], &[1; 16]);
        assert_eq!(&pixels[stride + 4..stride + 12], &[9; 8]);
        assert_eq!(&pixels[stride * 2 + 4..stride * 2 + 12], &[9; 8]);
        assert_eq!(&pixels[stride * 2 + 12..stride * 3], &[1; 4]);
        drop(pixels);
        assert_eq!(canvas.allocation_bytes(), 48);
    }

    #[test]
    fn rdp_canvas_is_shared_with_the_renderer_without_cloning_pixels() {
        let canvas = Rc::new(RefCell::new(RdpCanvas::default()));
        let renderer_reference = Rc::clone(&canvas);
        assert!(Rc::ptr_eq(&canvas, &renderer_reference));
        assert_eq!(Rc::strong_count(&canvas), 2);
    }

    #[test]
    fn rdp_automatic_reconnect_reuses_the_existing_canvas_allocation() {
        let mut asset = ServerAsset::new("desktop", "127.0.0.1", "user");
        asset.transport = Transport::Rdp;
        let canvas = Rc::new(RefCell::new(RdpCanvas::default()));
        let mut previous = SessionRuntime::new(&asset);
        previous.phase = WorkspacePhase::Reconnecting;
        previous.rdp_frame = Some(Rc::clone(&canvas));
        previous.rdp_frame_size = Some((1280, 720));

        let replacement = SessionRuntime::replacing_for_connect(&asset, Some(previous));

        let reused = replacement.rdp_frame.as_ref().unwrap();
        assert!(Rc::ptr_eq(&canvas, reused));
        assert_eq!(replacement.rdp_frame_size, Some((1280, 720)));
    }

    #[test]
    fn rdp_diagnostic_labels_are_explicit_about_reconnect_and_decoded_bytes() {
        let asset = ServerAsset::new("desktop", "127.0.0.1", "user");
        let mut metrics = RdpSessionMetrics::new_at(Instant::now());
        metrics.disconnect_count = 2;
        metrics.recovery_count = 1;
        metrics.canvas_allocation_bytes =
            u64::from(SAFE_RDP_DESKTOP_WIDTH * SAFE_RDP_DESKTOP_HEIGHT * 4);
        metrics.last_resolution = Some((SAFE_RDP_DESKTOP_WIDTH, SAFE_RDP_DESKTOP_HEIGHT));
        let snapshot = metrics.snapshot_at(metrics.started_at + Duration::from_secs(65));
        let report = rdp_diagnostic_report(
            &asset,
            WorkspacePhase::Reconnecting,
            3,
            &snapshot,
            (1600, 900),
            RdpLiveInputState {
                focused: true,
                capture_enabled: true,
                compositor_capture_granted: true,
                module_fullscreen: false,
                pointer_buttons_held: 0,
            },
        );
        assert!(report.contains("近 5 秒增量解码"));
        assert!(report.contains("非网络吞吐量"));
        assert!(report.contains("单通知背压"));
        assert!(report.contains("持久 Cairo 画布"));
        assert!(report.contains("像素管线峰值预算"));
        assert!(report.contains("持久画布：3.5 MiB"));
        assert!(report.contains("像素管线峰值预算：10.5 MiB"));
        assert!(report.contains("本地视口：1600 × 900 逻辑像素"));
        assert!(report.contains("本地等比缩放：125.0%"));
        assert!(report.contains("仅客户端交互参考，不等于网络 RTT"));
        assert!(report.contains("意外断开：2 次"));
        assert!(report.contains("自动恢复：1 次"));
        assert!(report.contains("当前重连：3/8"));
        assert!(report.contains("输入状态：焦点 在远端、系统快捷键捕获 已启用"));
        assert!(report.contains("诊断隐私：仅保留本次会话内的类别、次数和状态"));
        assert_eq!(format_metric_duration(Duration::from_secs(65)), "1 分 5 秒");
    }

    #[test]
    fn rdp_input_control_metrics_are_content_free_and_session_bounded() {
        let started = Instant::now();
        let mut metrics = RdpSessionMetrics::new_at(started);
        for event in [
            RdpInputControlEvent::LocallyReservedShortcut,
            RdpInputControlEvent::FocusEnter,
            RdpInputControlEvent::FocusLeave,
            RdpInputControlEvent::CaptureEnabled,
            RdpInputControlEvent::CaptureReleased,
            RdpInputControlEvent::ModifierSafetyRelease,
            RdpInputControlEvent::PointerSafetyRelease,
        ] {
            metrics.record_control_event(event);
        }
        let snapshot = metrics.snapshot_at(started);
        assert_eq!(snapshot.locally_reserved_shortcut_count, 1);
        assert_eq!(snapshot.focus_enter_count, 1);
        assert_eq!(snapshot.focus_leave_count, 1);
        assert_eq!(snapshot.capture_enable_count, 1);
        assert_eq!(snapshot.capture_release_count, 1);
        assert_eq!(snapshot.modifier_safety_release_count, 1);
        assert_eq!(snapshot.pointer_safety_release_count, 1);
    }

    #[test]
    fn rdp_uses_a_conservative_fixed_initial_desktop() {
        assert_eq!(
            (SAFE_RDP_DESKTOP_WIDTH, SAFE_RDP_DESKTOP_HEIGHT),
            (1280, 720)
        );
    }

    #[test]
    fn rdp_pointer_mapping_tracks_changed_resolution_and_ignores_letterbox_bars() {
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 1920, 1080, 640.0, 360.0),
            Some((960, 540))
        );
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 1024, 768, 640.0, 360.0),
            Some((512, 384))
        );
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 3440, 1440, 640.0, 360.0),
            Some((1720, 720))
        );
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 5120, 1440, 640.0, 360.0),
            Some((2560, 720))
        );
        // 4:3 content in a 16:9 viewport has left and right bars.
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 1024, 768, 100.0, 360.0),
            None
        );
        // Ultra-wide content has top and bottom bars in the same viewport.
        assert_eq!(
            rdp_pointer_coordinates(1280.0, 720.0, 5120, 1440, 640.0, 50.0),
            None
        );
        // The same remote centre remains stable across compact, HiDPI and 4K
        // local viewports because mapping is based on allocated widget size.
        assert_eq!(
            rdp_pointer_coordinates(640.0, 360.0, 1280, 720, 320.0, 180.0),
            Some((640, 360))
        );
        assert_eq!(
            rdp_pointer_coordinates(2560.0, 1440.0, 1280, 720, 1280.0, 720.0),
            Some((640, 360))
        );
        assert_eq!(
            rdp_pointer_coordinates(3840.0, 2160.0, 1280, 720, 1920.0, 1080.0),
            Some((640, 360))
        );
    }

    #[test]
    fn rdp_viewport_geometry_keeps_drawing_and_input_aligned_at_desktop_scales() {
        for (percent, viewport_width, viewport_height) in [
            (100, 1280.0, 720.0),
            (125, 1600.0, 900.0),
            (150, 1920.0, 1080.0),
            (200, 2560.0, 1440.0),
        ] {
            let geometry =
                rdp_viewport_geometry(viewport_width, viewport_height, 1280, 720).unwrap();
            assert!((geometry.scale * 100.0 - f64::from(percent)).abs() < f64::EPSILON);
            assert_eq!(geometry.offset_x, 0.0);
            assert_eq!(geometry.offset_y, 0.0);
            assert_eq!(
                rdp_pointer_coordinates(
                    viewport_width,
                    viewport_height,
                    1280,
                    720,
                    viewport_width / 2.0,
                    viewport_height / 2.0,
                ),
                Some((640, 360))
            );
        }
    }

    #[test]
    fn terminal_split_layout_matches_other_desktop_clients() {
        assert_eq!(terminal_pane_layout(1), vec![(0, 0, 2, 2)]);
        assert_eq!(terminal_pane_layout(2), vec![(0, 0, 2, 1), (0, 1, 2, 1)]);
        assert_eq!(
            terminal_pane_layout(3),
            vec![(0, 0, 2, 1), (0, 1, 1, 1), (1, 1, 1, 1)]
        );
        assert_eq!(
            terminal_pane_layout(4),
            vec![(0, 0, 1, 1), (1, 0, 1, 1), (0, 1, 1, 1), (1, 1, 1, 1)]
        );
        assert_eq!(terminal_pane_layout(8), terminal_pane_layout(4));
    }

    #[test]
    fn closing_middle_split_reindexes_channel_and_backlog_together() {
        let asset = ServerAsset::new("test", "127.0.0.1", "user");
        let mut runtime = SessionRuntime::new(&asset);
        runtime.terminal_channel_id = Some(10);
        runtime.terminal_backlog = b"primary".to_vec();
        for (channel, output) in [
            (20, b"second".as_slice()),
            (30, b"third".as_slice()),
            (40, b"fourth".as_slice()),
        ] {
            let mut split = TerminalSplitRuntime::new(channel);
            split.terminal_backlog = output.to_vec();
            runtime.terminal_splits.push(split);
        }
        runtime.active_terminal_pane = 3;

        let removed = remove_terminal_split(&mut runtime, 2).unwrap();

        assert_eq!(removed.channel_id, 30);
        assert_eq!(runtime.pane_count(), 3);
        assert_eq!(runtime.terminal_splits[1].channel_id, 40);
        assert_eq!(runtime.pane_backlog(2), b"fourth");
        assert_eq!(runtime.active_terminal_pane, 2);
    }

    #[test]
    fn terminal_search_escapes_regex_metacharacters_for_literal_matching() {
        assert_eq!(escape_terminal_search("a.b[1]+"), r"a\.b\[1\]\+");
    }

    #[test]
    fn batch_parser_accepts_all_three_desktop_protocols() {
        let inputs = parse_batch_assets(
            "one,prod,10.0.0.1,22,root,secret,SSH,密码,,,linux;core\n\
             two,legacy,10.0.0.2,23,ops,secret,Telnet,密码,,,network\n\
             three,desktop,10.0.0.3,3389,user,secret,RDP,密码,,,gui",
        )
        .unwrap();
        assert_eq!(inputs.len(), 3);
        assert_eq!(inputs[0].transport, Transport::Ssh);
        assert_eq!(inputs[1].transport, Transport::Telnet);
        assert_eq!(inputs[2].transport, Transport::Rdp);
        assert_eq!(inputs[0].tags, vec!["linux", "core"]);
        assert_eq!(inputs[0].credential.password, "secret");
    }

    #[test]
    fn batch_parser_rejects_invalid_protocol_and_port() {
        assert!(parse_batch_assets("bad,g,127.0.0.1,5900,user,p,VNC,密码,,,x").is_err());
        assert!(parse_batch_assets("bad,g,127.0.0.1,0,user,p,SSH,密码,,,x").is_err());
    }
}
