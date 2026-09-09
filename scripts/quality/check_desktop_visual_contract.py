#!/usr/bin/env python3
"""Fail when the three native desktop workstations drift from shared UI rules."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


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
mac_themes = read("OrbitTerm/Core/Appearance/AppThemeID.swift")

windows_xaml = read("clients/windows/src/OrbitTerm.App/MainWindow.xaml")
windows_main = read("clients/windows/src/OrbitTerm.App/MainWindow.xaml.cs")
windows_view_model = read("clients/windows/src/OrbitTerm.Presentation/MainWindowViewModel.cs")
windows_tokens = read("clients/windows/src/OrbitTerm.App/Resources/OrbitTermTokens.xaml")

linux_ui = read("clients/linux/crates/orbit-linux-app/src/ui.rs")
linux_css = read("clients/linux/resources/orbitterm.css")


# Supported window floor. Native title bars may change the default outer size,
# but every desktop must preserve the same usable minimum workbench.
require(mac_shell, ".frame(minWidth: 980, minHeight: 700)", "macOS minimum window")
require(windows_main, "public const int MinimumWindowWidth = 980;", "Windows minimum width")
require(windows_main, "public const int MinimumWindowHeight = 700;", "Windows minimum height")
require(linux_ui, ".width_request(980)", "Linux minimum width")
require(linux_ui, ".height_request(700)", "Linux minimum height")
require(linux_css, "desktop-only, 980px minimum", "Linux documented minimum")


# Window-relative panel ratios and hard usability limits.
for fragment in (
    "totalWidth * 0.234_375",
    "totalWidth * 0.256_25",
    "min(max(220, requestedLeft), 320)",
    "min(max(280, requestedRight), 420)",
    "let minMiddle: CGFloat = 560",
):
    require(mac_metrics, fragment, "macOS responsive pane contract")

for fragment in (
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
    "total_width) * 0.234_375",
    ".clamp(220, 320)",
    "total_width) * 0.256_25",
    ".clamp(280, 420)",
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

tool_tabs = ["SFTP", "Docker", "Snippets"]
require_ordered(mac_right, [f'case .{name.lower()}: "{name}"' for name in tool_tabs], "macOS tool tabs")
require_ordered(
    windows_xaml,
    ['TextBlock Text="SFTP"', 'TextBlock Text="Docker"', 'TextBlock Text="Snippets"'],
    "Windows tool tabs",
)
require_ordered(
    between(linux_ui, "fn build_tools(", "fn refresh_snippet_list", "Linux tool tabs"),
    ['"SFTP"', '"Docker"', '"Snippets"'],
    "Linux tool tabs",
)


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

print("PASS: macOS, Windows and Linux desktop visual contract")
