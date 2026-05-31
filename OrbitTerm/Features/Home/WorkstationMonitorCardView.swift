import SwiftUI

struct WorkstationMonitorCardView: View {
    let active: WorkspaceSession
    @ObservedObject var monitorService: MonitorService
    let isDetailShown: Bool
    let onHide: () -> Void
    let onShowDetail: () -> Void
    let onHideDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("系统监控")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                Button("查看详情", action: onShowDetail)
                    .buttonStyle(.borderedProminent)
                    .disabled(active.activeMonitorPanelID == nil)
                if isDetailShown {
                    Button("收起详情", action: onHideDetail)
                        .buttonStyle(.bordered)
                }
            }

            if let panel = monitorService.panel(id: active.activeMonitorPanelID) {
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let p = panel.points.last {
                    metricRow(title: "CPU", value: String(format: "%.1f%%", p.cpuUsage))
                    metricRow(title: "内存", value: String(format: "%.1f%%", p.memUsedPercent))
                    metricRow(title: "磁盘", value: String(format: "%.1f%%", p.diskUsedPercent))
                    metricRow(title: "延迟", value: p.pingLatencyMs.map { String(format: "%.0fms", $0) } ?? "--")
                    metricRow(title: "下载", value: formatRate(p.rxRateKBps))
                    metricRow(title: "上传", value: formatRate(p.txRateKBps))
                }
            } else {
                Text("连接终端后自动开始监控")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private func formatRate(_ kbps: Double) -> String {
        if kbps >= 1024 {
            return String(format: "%.2f MB/s", kbps / 1024.0)
        }
        return String(format: "%.0f KB/s", kbps)
    }
}
