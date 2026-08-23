import SwiftUI
#if canImport(Charts)
import Charts
#endif
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
struct MobileQuickCommand: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var command: String

    init(id: UUID = UUID(), title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }
}

enum MobileSessionModule: String, CaseIterable, Identifiable {
    case terminal = "终端"
    case shortcuts = "快捷操作"
    case monitor = "监控"
    case snippets = "Snippets"

    var id: String { rawValue }
}

struct MobileMonitorPanel: View {
    @ObservedObject var manager: SessionManager
    let session: WorkspaceSession
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    @State private var processes: [RemoteProcessSnapshot] = []
    @State private var processSearch = ""
    @State private var processSort: MobileProcessSort = .cpu
    @State private var processMonitorExpanded = false
    @State private var isRefreshingProcesses = false
    @State private var processError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let panel = manager.monitorService.panel(id: session.activeMonitorPanelID) {
                    Text(panel.status)
                        .font(.caption)
                        .foregroundStyle(manager.monitorService.checkedErrors[panel.id] != nil ? security.danger.color : (panel.isRunning ? security.success.color : palette.textSecondary.color))
                        .padding(.horizontal, 12)
                    if let last = panel.points.last {
                        let recentLatency = Array(panel.points.suffix(20)).map(\.pingLatencyMs)
                        let probeFailure = TCPLatencySamplePolicy.statistics(samples: recentLatency).failurePercent
                        HStack(spacing: 10) {
                            MobileMonitorMetricCard("CPU", String(format: "%.1f%%", last.cpuUsage))
                            MobileMonitorMetricCard("内存", String(format: "%.1f%%", last.memUsedPercent))
                            MobileMonitorMetricCard("磁盘", String(format: "%.1f%%", last.diskUsedPercent))
                            MobileMonitorMetricCard(
                                "TCP 延迟",
                                last.pingLatencyMs.map {
                                    String(format: "%.0f ms · 失败 %.0f%%", $0, probeFailure ?? 0)
                                } ?? String(format: "-- ms · 失败 %.0f%%", probeFailure ?? 100)
                            )
                            MobileMonitorMetricCard("下载", String(format: "%.1f KB/s", last.rxRateKBps))
                            MobileMonitorMetricCard("上传", String(format: "%.1f KB/s", last.txRateKBps))
                        }
                        .padding(.horizontal, 12)
                        monitorMiniCharts(panel)
                        mobileProcessMonitor
                    } else {
                        ContentUnavailableView("暂无监控数据", systemImage: "waveform.path.ecg")
                    }
                } else {
                    ContentUnavailableView {
                        Label("监控未启动", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text(manager.requiresCheckedConnection
                            ? "安全监控需要当前工作区的已验证会话"
                            : "连接终端后会自动启动监控")
                    } actions: {
                        if manager.requiresCheckedConnection {
                            Button("开始安全监控") {
                                Task { await manager.startMonitorForActiveSessionIfNeeded() }
                            }
                            .disabled(session.verifiedSessionLease == nil)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(palette.pageBackground.color)
        .task(id: "\(session.id.uuidString)-\(processMonitorExpanded)") {
            guard processMonitorExpanded else { return }
            while !Task.isCancelled {
                await refreshProcesses()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var visibleProcesses: [RemoteProcessSnapshot] {
        let query = processSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? processes : processes.filter {
            $0.command.localizedCaseInsensitiveContains(query)
                || $0.user.localizedCaseInsensitiveContains(query)
                || String($0.pid).contains(query)
        }
        return filtered.sorted { lhs, rhs in
            switch processSort {
            case .cpu: lhs.cpuPercent == rhs.cpuPercent ? lhs.pid < rhs.pid : lhs.cpuPercent > rhs.cpuPercent
            case .memory: lhs.memoryPercent == rhs.memoryPercent ? lhs.pid < rhs.pid : lhs.memoryPercent > rhs.memoryPercent
            case .pid: lhs.pid < rhs.pid
            case .name: lhs.command.localizedCaseInsensitiveCompare(rhs.command) == .orderedAscending
            }
        }
    }

    private var mobileProcessMonitor: some View {
        DisclosureGroup(isExpanded: $processMonitorExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("搜索名称、用户或 PID", text: $processSearch)
                        .textFieldStyle(.roundedBorder)
                    Picker("排序", selection: $processSort) {
                        ForEach(MobileProcessSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                    .labelsHidden()
                    Button {
                        Task { await refreshProcesses() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshingProcesses)
                    .accessibilityLabel("刷新进程")
                }

                if let processError {
                    Text(processError)
                        .font(.caption)
                        .foregroundStyle(security.danger.color)
                } else if isRefreshingProcesses && processes.isEmpty {
                    ProgressView("正在读取进程…")
                } else if visibleProcesses.isEmpty {
                    Text("没有匹配的进程")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleProcesses.prefix(200)) { process in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process.command)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text("PID \(process.pid) · \(process.user) · PPID \(process.parentPID)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(palette.textSecondary.color)
                                }
                                Spacer()
                                Text(String(format: "CPU %.1f%%\n内存 %.1f%%", process.cpuPercent, process.memoryPercent))
                                    .font(.caption2.monospacedDigit())
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(8)
                            .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("进程监控", systemImage: "list.bullet.rectangle.portrait")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(processes.isEmpty ? "按需加载" : "\(processes.count) 项")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
        .padding(10)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }

    @MainActor
    private func refreshProcesses() async {
        guard !isRefreshingProcesses else { return }
        isRefreshingProcesses = true
        defer { isRefreshingProcesses = false }
        do {
            processes = try await manager.fetchRemoteProcesses(session: session)
            processError = nil
        } catch {
            processError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func monitorMiniCharts(_ panel: MonitorPanelState) -> some View {
        let points = Array(panel.points.suffix(300))
#if canImport(Charts)
        VStack(spacing: 8) {
            miniChart(title: "CPU(5分钟)", points: points, value: { $0.cpuUsage }, unit: "%")
            miniChart(title: "内存(5分钟)", points: points, value: { $0.memUsedPercent }, unit: "%")
            miniChart(title: "磁盘(5分钟)", points: points, value: { $0.diskUsedPercent }, unit: "%")
            miniChart(title: "延迟(5分钟)", points: points, value: { $0.pingLatencyMs ?? 0 }, unit: "ms")
            miniChart(title: "下载(5分钟)", points: points, value: { $0.rxRateKBps }, unit: "KB/s")
            miniChart(title: "上传(5分钟)", points: points, value: { $0.txRateKBps }, unit: "KB/s")
        }
        .padding(.horizontal, 12)
#else
        EmptyView()
#endif
    }

#if canImport(Charts)
    private func miniChart(
        title: String,
        points: [MonitorPoint],
        value: @escaping (MonitorPoint) -> Double,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary.color)
                Spacer()
                Text(String(format: "%.1f %@", value(points.last ?? MonitorPoint(time: .now, cpuUsage: 0, memUsedPercent: 0, diskUsedPercent: 0, pingLatencyMs: 0, rxRateKBps: 0, txRateKBps: 0)), unit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.textSecondary.color)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("t", point.time),
                    y: .value("v", value(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(palette.accentPrimary.color)
            }
            .frame(height: 60)
            .accessibilityLabel("\(title) 趋势图")
            .accessibilityValue(points.last.map { String(format: "当前 %.1f %@", value($0), unit) } ?? "暂无数据")
        }
        .padding(8)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
#endif
}

private enum MobileProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    case pid = "PID"
    case name = "名称"

    var id: String { rawValue }
}

private struct MobileMonitorMetricCard: View {
    let title: String
    let value: String
    @Environment(\.appThemePalette) private var palette

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary.color)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#endif
