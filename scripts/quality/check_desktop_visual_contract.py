#!/usr/bin/env python3
"""Fail when the three native desktop workstations drift from shared UI rules."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def png_corner_alphas(relative: str) -> tuple[list[int], int]:
    payload = (ROOT / relative).read_bytes()
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"desktop visual contract failed: not a PNG: {relative}")
    position = 8
    compressed = bytearray()
    width = height = colour_type = 0
    while position < len(payload):
        length = struct.unpack(">I", payload[position : position + 4])[0]
        chunk_type = payload[position + 4 : position + 8]
        chunk = payload[position + 8 : position + 8 + length]
        position += length + 12
        if chunk_type == b"IHDR":
            width, height, bit_depth, colour_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
            if bit_depth != 8 or colour_type != 6 or interlace != 0:
                raise SystemExit(
                    f"desktop visual contract failed: icon is not non-interlaced RGBA: {relative}"
                )
        elif chunk_type == b"IDAT":
            compressed.extend(chunk)
        elif chunk_type == b"IEND":
            break
    if width != height or colour_type != 6:
        raise SystemExit(f"desktop visual contract failed: icon is not square RGBA: {relative}")
    raw = zlib.decompress(bytes(compressed))
    stride = width * 4
    if any(raw[row * (stride + 1)] != 0 for row in range(height)):
        raise SystemExit(
            f"desktop visual contract failed: generated icon filter changed: {relative}"
        )

    def alpha(x: int, y: int) -> int:
        return raw[y * (stride + 1) + 1 + x * 4 + 3]

    return (
        [alpha(0, 0), alpha(width - 1, 0), alpha(0, height - 1), alpha(width - 1, height - 1)],
        alpha(width // 2, height // 2),
    )


def require(text: str, fragment: str, label: str) -> None:
    if fragment not in text:
        raise SystemExit(f"desktop visual contract failed: {label}: {fragment!r}")


def require_ordered(text: str, fragments: list[str], label: str) -> None:
    cursor = 0
    for fragment in fragments:
        index = text.find(fragment, cursor)
        if index < 0:
            raise SystemExit(
                f"desktop visual contract failed: {label}: missing or reordered {fragment!r}"
            )
        cursor = index + len(fragment)


def between(text: str, start: str, end: str, label: str) -> str:
    start_index = text.find(start)
    end_index = text.find(end, start_index + len(start))
    if start_index < 0 or end_index < 0:
        raise SystemExit(f"desktop visual contract failed: cannot locate {label}")
    return text[start_index:end_index]


mac_main = read("OrbitTerm/Features/Home/MainWorkstationView.swift")
mac_shell = read("OrbitTerm/App/ContentView.swift")
mac_toolbar = read("OrbitTerm/Features/Home/WorkstationToolbarModifier.swift")
mac_metrics = read("OrbitTerm/Features/Home/WorkstationLayoutMetrics.swift")
mac_monitor = read("OrbitTerm/Features/Home/WorkstationMonitorCardView.swift")
mac_assets = read("OrbitTerm/Features/Home/WorkstationAssetSidebarView.swift")
mac_right = read("OrbitTerm/Features/Home/WorkstationRightPanelView.swift")
mac_snippets = read("OrbitTerm/Features/Home/SnippetsPanelView.swift")
mac_sftp_dialogs = read("OrbitTerm/Features/Home/WorkstationSFTPDialogs.swift")
mac_terminal = read("OrbitTerm/Features/Home/SwiftTermTerminalView.swift")
mac_themes = read("OrbitTerm/Core/Appearance/AppThemeID.swift")

windows_xaml = read("clients/windows/src/OrbitTerm.App/MainWindow.xaml")
windows_main = read("clients/windows/src/OrbitTerm.App/MainWindow.xaml.cs")
windows_view_model = read("clients/windows/src/OrbitTerm.Presentation/MainWindowViewModel.cs")
windows_snippet_view_model = read("clients/windows/src/OrbitTerm.Presentation/SnippetViewModel.cs")
windows_tokens = read("clients/windows/src/OrbitTerm.App/Resources/OrbitTermTokens.xaml")

linux_ui = read("clients/linux/crates/orbit-linux-app/src/ui.rs")
linux_css = read("clients/linux/resources/orbitterm.css")
linux_flatpak = read("clients/linux/packaging/flatpak/com.orbitterm.Client.json")


# Supported window floor. Native title bars may change the default outer size,
# but every desktop must preserve the same usable minimum workbench.
require(mac_shell, ".frame(minWidth: 980, minHeight: 700)", "macOS minimum window")
require(windows_main, "public const int MinimumWindowWidth = 980;", "Windows minimum width")
require(windows_main, "public const int MinimumWindowHeight = 700;", "Windows minimum height")
require(linux_ui, ".width_request(820)", "Linux compact minimum width")
require(linux_ui, ".height_request(560)", "Linux compact minimum height")
require(linux_ui, ".resizable(true)", "Linux resizable native window")
require(linux_ui, "install_window_resize_handles", "Linux discoverable resize edges")
require(linux_css, "desktop-only, 820px compact minimum", "Linux documented compact minimum")


# Side panes open at their safe minimum and remain explicitly user-resizable.
for fragment in (
    "preferredLeft: CGFloat = 220",
    "preferredRight: CGFloat = 280",
    "min(max(220, requestedLeft), 320)",
    "min(max(280, requestedRight), 420)",
    "let minMiddle: CGFloat = 560",
):
    require(mac_metrics, fragment, "macOS responsive pane contract")

for fragment in (
    "DefaultAssetSidebarWidth = 220",
    "DefaultToolInspectorWidth = 280",
    "AssetSidebarWindowRatio = 0.234375",
    "ToolInspectorWindowRatio = 0.25625",
    "MinimumAssetSidebarWidth = 220",
    "MaximumAssetSidebarWidth = 320",
    "MinimumToolInspectorWidth = 280",
    "MaximumToolInspectorWidth = 420",
    "MinimumTerminalWorkspaceWidth = 560",
):
    require(windows_main, fragment, "Windows responsive pane contract")

for fragment in (
    "(220, 280)",
    "set_wide_handle(true)",
    ".max(560)",
):
    require(linux_ui, fragment, "Linux responsive pane contract")


# The dense global command row has one stable action order. Platform-specific
# icons are reserved for native identity/account affordances, not every command.
global_actions = [
    "添加服务器",
    "编辑凭据",
    "资产管理",
    "密钥管理",
    "端口映射",
    "批量命令",
    "Snippets",
    "设置",
]
require_ordered(
    between(mac_toolbar, "struct WorkstationTopBar", "struct WorkstationBrandOverview", "macOS top bar"),
    [f'Button("{label}")' for label in global_actions],
    "macOS top action order",
)
require_ordered(
    between(windows_xaml, 'x:Name="TitleBarCommandPanel"', 'x:Name="TitleBarDragRegion"', "Windows top bar"),
    [f'Content="{label}"' for label in global_actions],
    "Windows top action order",
)
linux_header = between(linux_ui, "fn build_header(", "fn window_resize_handles_visible", "Linux top bar")
require_ordered(
    linux_header,
    [f'top_bar_button("{label}"' for label in global_actions],
    "Linux top action order",
)
for forbidden in (
    'top_bar_button("添加服务器", "list-add-symbolic"',
    'top_bar_button("编辑凭据", "document-edit-symbolic"',
    'top_bar_button("资产管理", "network-server-symbolic"',
):
    if forbidden in linux_header:
        raise SystemExit("desktop visual contract failed: Linux global commands regained decorative icons")


# Endpoint plus six monitoring cards use one semantic order and one explicit
# latency label, regardless of native graph implementation.
monitor_labels = ["CPU", "内存", "磁盘", "下载", "上传", "TCP 延迟"]
require_ordered(
    between(mac_monitor, "private func metrics(", "private func cpuTitle", "macOS monitor metrics"),
    ['title: cpuTitle', 'title: "内存', 'title: "磁盘', 'title: "下载"', 'title: "上传"', 'title: "TCP 延迟"'],
    "macOS monitor order",
)
require_ordered(
    between(windows_view_model, "MonitorTrendMetrics { get; }", "CpuMonitorTrend", "Windows monitor metrics"),
    [f'"{label}"' for label in monitor_labels],
    "Windows monitor order",
)
require(
    linux_ui,
    '["CPU", "内存", "磁盘", "下载", "上传", "TCP 延迟"]',
    "Linux monitor order",
)
require(mac_monitor, ".frame(height: 34)", "macOS compact monitor height")
require(windows_xaml, '<Border Height="34"', "Windows compact monitor height")
require(linux_ui, "monitor.set_size_request(-1, 36);", "Linux compact monitor height")


# Empty-state meaning and right-inspector tab order are product behavior, not
# native styling choices.
empty_copy = [
    "还没有服务器",
    "添加服务器后，即可从这里安全地发起连接。",
    "暂无会话",
    "从左侧选择服务器，然后建立连接。",
]
for text, label in (
    (mac_assets + mac_main, "macOS empty states"),
    (windows_view_model, "Windows empty states"),
    (linux_ui, "Linux empty states"),
):
    for fragment in empty_copy:
        require(text, fragment, label)

tool_tabs = ["SFTP", "Docker"]
require_ordered(mac_right, [f'case .{name.lower()}: "{name}"' for name in tool_tabs], "macOS tool tabs")
require_ordered(
    windows_xaml,
    ['TextBlock Text="SFTP"', 'TextBlock Text="Docker"'],
    "Windows tool tabs",
)
require_ordered(
    between(linux_ui, "fn build_tools(", "fn refresh_snippet_list", "Linux tool tabs"),
    ['"SFTP"', '"Docker"'],
    "Linux tool tabs",
)
for text, forbidden, label in (
    (mac_right, "case snippets", "macOS right inspector"),
    (windows_xaml, 'Tag="Snippets"', "Windows right inspector"),
    (between(linux_ui, "fn build_tools(", "fn refresh_snippet_list", "Linux tool tabs"), 'Some("snippets")', "Linux right inspector"),
):
    if forbidden in text:
        raise SystemExit(f"desktop visual contract failed: {label} still contains Snippets")
require(mac_main, ".sheet(isPresented: $showingSnippets)", "macOS standalone Snippets")
require(windows_xaml, 'x:Name="SnippetsDialog"', "Windows standalone Snippets")
require(linux_ui, "fn present_snippets_window", "Linux standalone Snippets")

# Snippets presents one shared card vocabulary and keeps create/history in the
# header while native sheet/dialog mechanics remain platform-owned.
for text, label in (
    (mac_snippets, "macOS Snippets"),
    (windows_xaml + windows_snippet_view_model, "Windows Snippets"),
    (linux_ui, "Linux Snippets"),
):
    for fragment in ("跨资产管理", "插入", "执行", "全部资产"):
        require(text, fragment, label)
require(mac_snippets, "限 \(snippet.assetScope.assetIDs.count) 台资产", "macOS restricted Snippet scope")
require(windows_snippet_view_model, '$"限 {EffectiveAssetScope.AssetIds.Count} 台资产"', "Windows restricted Snippet scope")
require(linux_ui, 'format!("限 {} 台资产"', "Linux restricted Snippet scope")
require(windows_main, "RunWithSnippetsManagerSuspendedAsync", "Windows nested Snippet editor transition")


# SFTP keeps only navigation, path, refresh and one overflow entry in its
# visible chrome. Current-directory and item mutations remain available from
# native menus, while transfer history starts collapsed.
require(mac_right, "case .sftp", "macOS SFTP tab")
require(mac_main, "showingSnippets: $showingSnippets", "macOS Snippets command")
require(mac_right, "WorkstationSFTPCardView(", "macOS SFTP inspector")
require(read("OrbitTerm/Features/Home/WorkstationSFTPCardView.swift"), "@State private var isTransferQueueExpanded = false", "macOS collapsed transfer queue")
require(windows_xaml, '<Expander Grid.Row="4" IsExpanded="False"', "Windows collapsed transfer queue")
require(linux_ui, "sftp_transfers.set_expanded(false);", "Linux collapsed transfer queue")
require(windows_xaml, 'ContextRequested="SftpSurfaceContextRequested"', "Windows directory context menu")
require(linux_ui, 'icon_name("view-more-symbolic")', "Linux compact SFTP overflow")
for text, label in (
    (mac_sftp_dialogs, "macOS SFTP editor"),
    (windows_main, "Windows SFTP editor"),
    (linux_ui, "Linux SFTP editor"),
):
    for fragment in ('"还原"', '"复制"', '"保存"'):
        require(text, fragment, label)
for fragment in (
    'ScrollViewer.VerticalScrollBarVisibility="Hidden"',
    'ScrollViewer.HorizontalScrollBarVisibility="Disabled"',
):
    require(windows_xaml, fragment, "Windows hidden decorative SFTP scrollbars")
require(windows_xaml, 'MaxHeight="104"', "Windows wrapping SFTP feedback")

# Platform-specific rendering fixes remain guarded by deterministic source
# checks so future refactors cannot silently restore the reported regressions.
for unit in ("Kbps", "Mbps", "Gbps"):
    require(linux_ui, unit, "Linux adaptive network unit")
require(mac_terminal, ".padding(.horizontal, 7)", "macOS terminal horizontal optical inset")
require(mac_terminal, ".padding(.vertical, 5)", "macOS terminal vertical optical inset")


# Restore rails share the same top inset and height. Linux command pre-input
# uses zero left offset when the asset pane is not part of layout.
require(mac_main, ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)", "macOS left restore placement")
require(mac_main, ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)", "macOS right restore placement")
require(windows_xaml, 'Height="72"', "Windows restore rail height")
require(linux_ui, ".valign(Align::Start)", "Linux restore rail placement")
require(
    linux_ui,
    "let left = if sidebar_for_bottom_layout.is_visible()",
    "Linux collapsed command input left edge",
)


# macOS owns exactly one endpoint card inside the responsive monitoring strip,
# and every card is constrained to the shared compact height.
overview_band = between(mac_toolbar, "struct WorkstationOverviewBand", "struct WorkstationMonitorPlaceholderStrip", "macOS overview band")
if "RemoteEndpointMonitorCard(" in overview_band:
    raise SystemExit("desktop visual contract failed: macOS overview duplicates endpoint card")
require(mac_monitor, "minHeight: 34, maxHeight: 34", "macOS equal monitor card heights")


# Five palette names and their ordering remain shared even though SwiftUI,
# WinUI and GTK own their native focus/high-contrast rendering.
palette_names = ["天空糖果", "翡翠流光", "蜜桃晨光", "薰衣草雾", "冰川薄荷"]
require_ordered(mac_themes, [f'case .{name}: "{label}"' for name, label in (
    ("skyCandy", "天空糖果"),
    ("emeraldFlow", "翡翠流光"),
    ("peachDawn", "蜜桃晨光"),
    ("lavenderMist", "薰衣草雾"),
    ("glacierMint", "冰川薄荷"),
)], "macOS palette order")
require_ordered(
    between(windows_main, "ApplicationPaletteOptions", "];", "Windows palettes"),
    [f'new("{label}")' for label in palette_names],
    "Windows palette order",
)
require_ordered(
    between(linux_ui, 'let sky = gtk::ToggleButton::with_label', 'for choice in', "Linux palettes"),
    [f'with_label("{label}")' for label in palette_names],
    "Linux palette order",
)

for token in ("OrbitSidebarMinWidth", "OrbitInspectorMinWidth", "OrbitTerminalMinWidth"):
    require(windows_tokens, token, "Windows shared layout tokens")


# Synchronization is one independent full-width row below the three-pane body.
# Pane dividers must end above it on every platform.
require_ordered(
    mac_main,
    ["HStack(spacing: 0) {", "WorkstationPersistentSyncStatusView("],
    "macOS independent synchronization footer",
)
require(
    windows_xaml,
    'x:Name="SynchronizationStatusFooter"',
    "Windows synchronization footer",
)
windows_sync_footer = between(
    windows_xaml,
    '<Border x:Name="SynchronizationStatusFooter"',
    '<primitives:Thumb x:Name="AssetSidebarSplitter"',
    "Windows synchronization footer",
)
for fragment in ('Grid.Row="3"', 'Grid.ColumnSpan="3"', 'HorizontalAlignment="Stretch"'):
    require(windows_sync_footer, fragment, "Windows full-width synchronization footer")
require_ordered(
    linux_ui,
    ["root.append(&workbench_overlay);", "root.append(&sidebar.footer);"],
    "Linux independent synchronization footer",
)
if "workbench_overlay.add_overlay(&sidebar.footer)" in linux_ui:
    raise SystemExit(
        "desktop visual contract failed: Linux synchronization footer returned inside pane overlay"
    )
require(linux_css, ".sidebar-footer { min-height: 22px;", "Linux compact synchronization footer")


# Windows shell surfaces select target-size resources independently from tile
# logos. Unplated variants preserve the product's own transparent rounded mask
# instead of allowing the taskbar to synthesize a square backing plate.
for size in (16, 20, 24, 30, 32, 36, 40, 44, 48, 60, 64, 72, 80, 96, 256):
    relative = (
        "clients/windows/src/OrbitTerm.App/Assets/"
        f"Square44x44Logo.targetsize-{size}_altform-unplated.png"
    )
    corners, centre = png_corner_alphas(relative)
    if corners != [0, 0, 0, 0] or centre != 255:
        raise SystemExit(
            "desktop visual contract failed: "
            f"Windows {size}px unplated icon needs transparent corners and an opaque centre"
        )


# Linux cannot rely on the compositor masks used by Apple and Windows. Every
# packaged launcher size must therefore have transparent corners of its own.
for size in (16, 32, 64, 128, 256, 512):
    relative = f"clients/linux/resources/icons/hicolor/{size}.png"
    require(
        linux_flatpak,
        f"clients/linux/resources/icons/hicolor/{size}.png",
        f"Linux {size}px packaged icon",
    )
    corners, centre = png_corner_alphas(relative)
    if corners != [0, 0, 0, 0] or centre != 255:
        raise SystemExit(
            "desktop visual contract failed: "
            f"Linux {size}px icon needs transparent corners and an opaque centre"
        )

print("PASS: macOS, Windows and Linux desktop visual contract")
