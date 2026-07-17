import SwiftUI

struct WorkstationMonitorCardView: View {
    let active: WorkspaceSession
    @ObservedObject var monitorService: MonitorService
    let isDetailShown: Bool
    let onShowDetail: () -> Void
    let onHideDetail: () -> Void
    let onStartCheckedMonitoring: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("系统监控")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("查看详情", action: onShowDetail)
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(active.activeMonitorPanelID == nil)
                if isDetailShown {
                    Button("收起详情", action: onHideDetail)
                        .buttonStyle(.bordered)
                }
            }

            if let panel = monitorService.panel(id: active.activeMonitorPanelID) {
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(panelStatusColor(for: panel))

                if let p = panel.points.last {
                    metricRow(title: "CPU", value: String(format: "%.1f%%", p.cpuUsage))
                    metricRow(title: "内存", value: String(format: "%.1f%%", p.memUsedPercent))
                    metricRow(title: "磁盘", value: String(format: "%.1f%%", p.diskUsedPercent))
                    metricRow(title: "延迟", value: p.pingLatencyMs.map { String(format: "%.0fms", $0) } ?? "--")
                    metricRow(title: "下载", value: formatRate(p.rxRateKBps))
                    metricRow(title: "上传", value: formatRate(p.txRateKBps))
                }
            } else {
                if active.verifiedSessionLease != nil {
                    Button("开始安全监控", action: onStartCheckedMonitoring)
                        .buttonStyle(ThemedPrimaryButtonStyle())
                } else {
                    Text("需要已验证会话")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
        }
        .padding(10)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary.color)
        }
        .font(.caption)
    }

    private func panelStatusColor(for panel: MonitorPanelState) -> Color {
        if monitorService.checkedErrors[panel.id] != nil { return security.danger.color }
        return panel.isRunning ? security.success.color : palette.textSecondary.color
    }

    private func formatRate(_ kbps: Double) -> String {
        if kbps >= 1024 {
            return String(format: "%.2f MB/s", kbps / 1024.0)
        }
        return String(format: "%.0f KB/s", kbps)
    }
}
