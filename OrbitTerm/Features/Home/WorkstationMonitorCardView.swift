import SwiftUI
import Charts

struct WorkstationMonitorCardView: View {
    @ObservedObject var active: WorkspaceSession
    @ObservedObject var monitorService: MonitorService
    let isDetailShown: Bool
    let onShowDetail: () -> Void
    let onHideDetail: () -> Void
    let onStartCheckedMonitoring: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("系统监控")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("查看详情", action: onShowDetail)
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .controlSize(.mini)
                    .fixedSize()
                    .disabled(active.activeMonitorPanelID == nil)
                if isDetailShown {
                    Button("收起详情", action: onHideDetail)
                        .buttonStyle(.bordered)
                }
            }

            if let panel = monitorService.panel(id: active.activeMonitorPanelID) {
                monitorStatus(panel)

                if let p = panel.points.last {
                    MonitorSystemSummary(systemInfo: p.systemInfo)

                    metricPairRow(
                        first: (
                            "CPU \(cpuCapacity(p.systemInfo))",
                            String(format: "%.1f%%", p.cpuUsage),
                            p.cpuUsage,
                            panel.points.map(\.cpuUsage),
                            100
                        ),
                        second: latencyMetric(for: panel.points)
                    )
                    metricPairRow(
                        first: ("内存 \(capacity(p.systemInfo.memoryTotalMB))", String(format: "%.1f%%", p.memUsedPercent), p.memUsedPercent, panel.points.map(\.memUsedPercent), 100),
                        second: ("交换 \(capacity(p.systemInfo.swapTotalMB))", String(format: "%.1f%%", swapPercent(p.systemInfo)), swapPercent(p.systemInfo), panel.points.map { swapPercent($0.systemInfo) }, 100)
                    )
                    let networkCeiling = dynamicCeiling(for: panel.points.flatMap { [$0.rxRateKBps, $0.txRateKBps] })
                    metricPairRow(
                        first: ("下载", formatRate(p.rxRateKBps), p.rxRateKBps, panel.points.map(\.rxRateKBps), networkCeiling),
                        second: ("上传", formatRate(p.txRateKBps), p.txRateKBps, panel.points.map(\.txRateKBps), networkCeiling)
                    )
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
        .padding(8)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func metricPairRow(
        first: (title: String, value: String, current: Double, history: [Double], ceiling: Double),
        second: (title: String, value: String, current: Double, history: [Double], ceiling: Double)
    ) -> some View {
        HStack(spacing: 8) {
            compactMetric(first)
            Divider()
            compactMetric(second)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactMetric(
        _ metric: (title: String, value: String, current: Double, history: [Double], ceiling: Double)
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(metric.title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(metric.value)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary.color)
            }
            MonitorMetricSparkline(
                values: metric.history,
                ceiling: metric.ceiling,
                tint: panelMetricColor(current: metric.current, ceiling: metric.ceiling)
            )
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title)，当前 \(metric.value)，最近变化")
    }

    private func panelStatusColor(for panel: MonitorPanelState) -> Color {
        if let recovery = monitorService.recoveryPresentation(for: panel.id) {
            return recovery.severity == .danger ? security.danger.color : security.warning.color
        }
        return panel.isRunning ? security.success.color : palette.textSecondary.color
    }

    private func monitorStatus(_ panel: MonitorPanelState) -> some View {
        let recovery = monitorService.recoveryPresentation(for: panel.id)
        let statusText = recovery?.message ?? panel.status
        return Label(
            statusText,
            systemImage: recovery?.systemImage ?? (panel.isRunning ? "checkmark.shield.fill" : "pause.circle")
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(palette.textPrimary.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(panelStatusColor(for: panel).opacity(0.20), in: Capsule())
        .overlay {
            Capsule().stroke(panelStatusColor(for: panel).opacity(0.62), lineWidth: 1)
        }
        .accessibilityLabel("监控状态：\(recovery?.title ?? statusText)。\(statusText)")
    }

    private func latencyMetric(
        for points: [MonitorPoint]
    ) -> (title: String, value: String, current: Double, history: [Double], ceiling: Double) {
        let recent = points.filter { $0.time >= Date().addingTimeInterval(-300) }
        let latencies = points.compactMap(\.pingLatencyMs)
        // Do not carry the previous successful value across a failed current
        // handshake; that would make a disconnected SSH port look healthy.
        let latest = points.last?.pingLatencyMs
        let failureText: String
        if recent.isEmpty {
            failureText = "失败 --"
        } else {
            let failure = TCPLatencySamplePolicy.statistics(samples: recent.map(\.pingLatencyMs)).failurePercent ?? 0
            failureText = String(format: "失败 %.1f%%", failure)
        }
        let value = latest.map { String(format: "%.0f ms · %@", $0, failureText) } ?? "-- ms · \(failureText)"
        return (
            "TCP 延迟",
            value,
            latest ?? 0,
            latencies,
            dynamicCeiling(for: latencies)
        )
    }

    private func formatRate(_ kbps: Double) -> String {
        if kbps >= 1024 {
            return String(format: "%.2f MB/s", kbps / 1024.0)
        }
        return String(format: "%.0f KB/s", kbps)
    }

    private func dynamicCeiling(for values: [Double]) -> Double {
        max(1, (values.max() ?? 0) * 1.12)
    }

    private func panelMetricColor(current: Double, ceiling: Double) -> Color {
        guard ceiling > 0 else { return palette.accentPrimary.color }
        if current / ceiling >= 0.9 { return security.warning.color }
        return palette.accentPrimary.color
    }

    private func swapPercent(_ info: MonitorSystemInfo) -> Double {
        guard info.swapTotalMB > 0 else { return 0 }
        return Double(info.swapUsedMB) / Double(info.swapTotalMB) * 100
    }

    private func cpuCapacity(_ info: MonitorSystemInfo) -> String {
        guard info.cpuThreadCount > 0 else { return "" }
        return info.cpuCoreCount > 0 ? "\(info.cpuCoreCount)核/\(info.cpuThreadCount)线程" : "\(info.cpuThreadCount)线程"
    }

    private func capacity(_ megabytes: UInt64) -> String {
        guard megabytes > 0 else { return "待采集" }
        let gigabytes = Double(megabytes) / 1_024
        return gigabytes > 2_048 ? String(format: "%.1fTB", gigabytes / 1_024) : String(format: "%.1fGB", gigabytes)
    }
}

struct WorkstationMonitorOverviewStrip: View {
    @ObservedObject var active: WorkspaceSession
    @ObservedObject var monitorService: MonitorService
    let onShowDetail: () -> Void
    let onStartCheckedMonitoring: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        Group {
            if let panel = monitorService.panel(id: active.activeMonitorPanelID),
               let latest = panel.points.last {
                GeometryReader { proxy in
                    let allMetrics = metrics(for: panel, latest: latest)
                    let detailWidth: CGFloat = 54
                    let spacing: CGFloat = 6
                    let cardCount = CGFloat(allMetrics.count + 1)
                    let requiredSpacing = spacing * cardCount
                    let metricWidth = max(
                        0,
                        floor((proxy.size.width - detailWidth - requiredSpacing) / cardCount)
                    )

                    HStack(spacing: spacing) {
                        overviewEndpoint
                            .frame(width: metricWidth, alignment: .leading)

                        ForEach(allMetrics) { metric in
                            overviewMetric(metric)
                                .frame(width: metricWidth, alignment: .leading)
                        }

                        Button(action: onShowDetail) {
                            Label("详情", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(palette.textOnAccent.color)
                        .frame(width: detailWidth, height: 32)
                        .background(palette.accentPrimary.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("查看系统监控详情")
                        .help("查看系统监控详情")
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(height: 34)
            } else if active.verifiedSessionLease != nil {
                WorkstationMonitorPlaceholderStrip(
                    host: active.server.host,
                    actionTitle: "开始",
                    action: onStartCheckedMonitoring
                )
            } else {
                WorkstationMonitorPlaceholderStrip(host: active.server.host)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewEndpoint: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("当前资产 IP")
                    .foregroundStyle(palette.textSecondary.color)
                Text(active.server.host)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            Button {
                _ = SecureClipboard.copy(active.server.host, kind: .ordinaryText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制当前资产 IP")
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前资产 IP，\(active.server.host)")
    }

    private func overviewMetric(_ metric: MonitorOverviewMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(metric.title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(metric.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(palette.textSecondary.color)
            }
            MonitorMetricSparkline(
                values: metric.history,
                ceiling: metric.ceiling,
                tint: metric.isElevated ? security.warning.color : palette.accentPrimary.color
            )
        }
        .font(.caption2)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .leading)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title)，当前 \(metric.value)，最近变化")
    }

    private func metrics(for panel: MonitorPanelState, latest: MonitorPoint) -> [MonitorOverviewMetric] {
        let points = panel.points
        let networkCeiling = dynamicCeiling(for: points.flatMap { [$0.rxRateKBps, $0.txRateKBps] })
        let latency = points.compactMap(\.pingLatencyMs)
        let recent = points.filter { $0.time >= Date().addingTimeInterval(-300) }
        let failure = recent.isEmpty
            ? "失败 --"
            : String(
                format: "失败 %.1f%%",
                TCPLatencySamplePolicy.statistics(samples: recent.map(\.pingLatencyMs)).failurePercent ?? 0
            )
        let latencyValue = latest.pingLatencyMs.map { String(format: "%.0f ms · %@", $0, failure) } ?? "-- ms · \(failure)"
        return [
            MonitorOverviewMetric(
                title: cpuTitle(latest.systemInfo), value: String(format: "%.1f%%", latest.cpuUsage),
                current: latest.cpuUsage, history: points.map(\.cpuUsage), ceiling: 100
            ),
            MonitorOverviewMetric(
                title: "内存 \(capacity(latest.systemInfo.memoryTotalMB))", value: String(format: "%.1f%%", latest.memUsedPercent),
                current: latest.memUsedPercent, history: points.map(\.memUsedPercent), ceiling: 100
            ),
            MonitorOverviewMetric(
                title: "磁盘 \(capacity(latest.systemInfo.diskTotalMB))", value: String(format: "%.1f%%", latest.diskUsedPercent),
                current: latest.diskUsedPercent, history: points.map(\.diskUsedPercent), ceiling: 100
            ),
            MonitorOverviewMetric(
                title: "下载", value: formatRate(latest.rxRateKBps), current: latest.rxRateKBps,
                history: points.map(\.rxRateKBps), ceiling: networkCeiling
            ),
            MonitorOverviewMetric(
                title: "上传", value: formatRate(latest.txRateKBps), current: latest.txRateKBps,
                history: points.map(\.txRateKBps), ceiling: networkCeiling
            ),
            MonitorOverviewMetric(
                title: "TCP 延迟", value: latencyValue, current: latest.pingLatencyMs ?? 0,
                history: latency, ceiling: dynamicCeiling(for: latency)
            )
        ]
    }

    private func cpuTitle(_ info: MonitorSystemInfo) -> String {
        guard info.cpuThreadCount > 0 else { return "CPU" }
        return info.cpuCoreCount > 0 ? "CPU \(info.cpuCoreCount)核/\(info.cpuThreadCount)线程" : "CPU \(info.cpuThreadCount)线程"
    }

    private func swapPercent(_ info: MonitorSystemInfo) -> Double {
        guard info.swapTotalMB > 0 else { return 0 }
        return Double(info.swapUsedMB) / Double(info.swapTotalMB) * 100
    }

    private func capacity(_ megabytes: UInt64) -> String {
        guard megabytes > 0 else { return "待采集" }
        let gigabytes = Double(megabytes) / 1_024
        return gigabytes > 2_048 ? String(format: "%.1fTB", gigabytes / 1_024) : String(format: "%.1fGB", gigabytes)
    }

    private func formatRate(_ kbps: Double) -> String {
        kbps >= 1_024 ? String(format: "%.2f MB/s", kbps / 1_024) : String(format: "%.0f KB/s", kbps)
    }

    private func dynamicCeiling(for values: [Double]) -> Double {
        max(1, (values.max() ?? 0) * 1.12)
    }
}

private struct MonitorOverviewMetric: Identifiable {
    let title: String
    let value: String
    let current: Double
    let history: [Double]
    let ceiling: Double

    var id: String { title }
    var isElevated: Bool { ceiling > 0 && current / ceiling >= 0.9 }
}

private struct MonitorSystemSummary: View {
    let systemInfo: MonitorSystemInfo
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(systemInfo.osName, systemImage: "desktopcomputer")
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            Label("硬盘 \(capacity(systemInfo.diskTotalMB))", systemImage: "internaldrive")
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.textPrimary.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("系统信息，\(systemInfo.osName)，硬盘总量 \(capacity(systemInfo.diskTotalMB))")
    }

    private func capacity(_ megabytes: UInt64) -> String {
        guard megabytes > 0 else { return "待采集" }
        let gigabytes = Double(megabytes) / 1_024
        if gigabytes > 2_048 {
            return String(format: "%.1f TB", gigabytes / 1_024)
        }
        if gigabytes >= 1 {
            return String(format: "%.1f GB", gigabytes)
        }
        return "\(megabytes) MB"
    }
}

/// A compact, read-only identity card for the connected host. It reuses the
/// monitor payload already collected for the active checked session and does
/// not start polling or retain any connection state.
private struct MonitorSystemOverviewCard: View {
    let systemInfo: MonitorSystemInfo
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("系统概览")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textSecondary.color)

            Text(systemInfo.osName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Text("CPU \(cpuCapacity) · 内存 \(capacity(systemInfo.memoryTotalMB)) · 硬盘 \(capacity(systemInfo.diskTotalMB))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已连接资产系统概览，\(systemInfo.osName)，CPU \(cpuCapacity)，内存总量 \(capacity(systemInfo.memoryTotalMB))，硬盘总量 \(capacity(systemInfo.diskTotalMB))")
    }

    private var cpuCapacity: String {
        guard systemInfo.cpuThreadCount > 0 else { return "待采集" }
        if systemInfo.cpuCoreCount > 0 {
            return "\(systemInfo.cpuCoreCount) 核 / \(systemInfo.cpuThreadCount) 线程"
        }
        return "\(systemInfo.cpuThreadCount) 线程"
    }

    private func capacity(_ megabytes: UInt64) -> String {
        guard megabytes > 0 else { return "待采集" }
        let gigabytes = Double(megabytes) / 1_024
        return gigabytes > 2_048
            ? String(format: "%.1f TB", gigabytes / 1_024)
            : String(format: "%.1f GB", gigabytes)
    }
}

private struct MonitorMetricSparkline: View {
    let values: [Double]
    let ceiling: Double
    let tint: Color
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        let samples = Array(values.suffix(24))
        Chart(Array(samples.enumerated()), id: \.offset) { index, sample in
            LineMark(
                x: .value("采样", index),
                y: .value("数值", min(max(sample, 0), max(ceiling, 1)))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .chartYScale(domain: 0...max(ceiling, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 18)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}
