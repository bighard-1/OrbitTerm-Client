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
    case shortcuts = "快捷指令"
    case monitor = "监控"

    var id: String { rawValue }
}

struct MobileMonitorPanel: View {
    @ObservedObject var manager: SessionManager
    let session: WorkspaceSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let panel = manager.monitorService.panel(id: session.activeMonitorPanelID) {
                    Text(panel.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    if let last = panel.points.last {
                        HStack(spacing: 10) {
                            MobileMonitorMetricCard("CPU", String(format: "%.1f%%", last.cpuUsage))
                            MobileMonitorMetricCard("内存", String(format: "%.1f%%", last.memUsedPercent))
                            MobileMonitorMetricCard("磁盘", String(format: "%.1f%%", last.diskUsedPercent))
                            MobileMonitorMetricCard("延迟", String(format: "%.0f ms", last.pingLatencyMs ?? 0))
                            MobileMonitorMetricCard("下载", String(format: "%.1f KB/s", last.rxRateKBps))
                            MobileMonitorMetricCard("上传", String(format: "%.1f KB/s", last.txRateKBps))
                        }
                        .padding(.horizontal, 12)
                        monitorMiniCharts(panel)
                    } else {
                        ContentUnavailableView("暂无监控数据", systemImage: "waveform.path.ecg")
                    }
                } else {
                    ContentUnavailableView("监控未启动", systemImage: "chart.line.uptrend.xyaxis")
                }
                Spacer(minLength: 0)
            }
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
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f %@", value(points.last ?? MonitorPoint(time: .now, cpuUsage: 0, memUsedPercent: 0, diskUsedPercent: 0, pingLatencyMs: 0, rxRateKBps: 0, txRateKBps: 0)), unit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("t", point.time),
                    y: .value("v", value(point))
                )
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 60)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
#endif
}

private struct MobileMonitorMetricCard: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MobileTerminalKeyboardAccessory: View {
    let onSend: ([UInt8]) -> Void

    private let shortcuts: [(title: String, bytes: [UInt8])] = [
        ("Tab", [9]),
        ("Ctrl+C", [3]),
        ("Esc", [27]),
        ("Ctrl+D", [4])
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shortcuts, id: \.title) { item in
                    Button {
                        onSend(item.bytes)
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }
}
#endif
