import SwiftUI
import Charts

private enum MonitorHistoryRange: String, CaseIterable, Identifiable {
    case realtime = "实时"
    case min5 = "5 分钟"
    case min10 = "10 分钟"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .realtime: return 30
        case .min5: return 5 * 60
        case .min10: return 10 * 60
        }
    }
}

struct MonitorDetailInlineView: View {
    let panelID: UUID
    @ObservedObject var service: MonitorService
    let onClose: () -> Void
    @State private var range: MonitorHistoryRange = .min10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("详细监控")
                    .font(.headline)
                Spacer()
                Picker("历史", selection: $range) {
                    ForEach(MonitorHistoryRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
            }

            if let panel = service.panel(id: panelID) {
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                chartCard(title: "CPU", points: filtered(panel.points), value: \.cpuUsage, tint: .blue, domain: 0...100, percent: true)
                chartCard(title: "内存", points: filtered(panel.points), value: \.memUsedPercent, tint: .green, domain: 0...100, percent: true)
                chartCard(title: "磁盘", points: filtered(panel.points), value: \.diskUsedPercent, tint: .orange, domain: 0...100, percent: true)
                chartCard(title: "延迟", points: filtered(panel.points), value: { $0.pingLatencyMs ?? 0 }, tint: .purple, domain: 0...300, percent: false)
                chartCard(title: "下载速率", points: filtered(panel.points), value: \.rxRateKBps, tint: .cyan, domain: 0...rateUpperBound(filtered(panel.points), keyPath: \.rxRateKBps), percent: false, unit: "KB/s")
                chartCard(title: "上传速率", points: filtered(panel.points), value: \.txRateKBps, tint: .mint, domain: 0...rateUpperBound(filtered(panel.points), keyPath: \.txRateKBps), percent: false, unit: "KB/s")
            } else {
                ContentUnavailableView("暂无监控数据", systemImage: "chart.line.uptrend.xyaxis")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func filtered(_ points: [MonitorPoint]) -> [MonitorPoint] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return points.filter { $0.time >= cutoff }
    }

    private func chartCard(
        title: String,
        points: [MonitorPoint],
        value: @escaping (MonitorPoint) -> Double,
        tint: Color,
        domain: ClosedRange<Double>,
        percent: Bool,
        unit: String = "ms"
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let latest = points.last {
                Text(percent ? String(format: "%.1f%%", value(latest)) : String(format: "%.1f %@", value(latest), unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("值", value(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            }
            .chartYScale(domain: domain)
            .frame(height: 120)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rateUpperBound(_ points: [MonitorPoint], keyPath: KeyPath<MonitorPoint, Double>) -> Double {
        let maxValue = points.map { $0[keyPath: keyPath] }.max() ?? 100
        return max(100, ceil(maxValue * 1.25))
    }
}


#if DEBUG
struct DebugFPSBadge: View {
    @StateObject private var meter = DebugFPSMeter()

    var body: some View {
        Text(String(format: "FPS %.0f", meter.fps))
            .font(.caption.monospacedDigit())
            .foregroundStyle(meter.fps >= 50 ? Color.secondary : (meter.fps >= 30 ? Color.orange : Color.red))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .help("渲染帧率采样（Debug）")
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
    }
}

private final class DebugFPSMeter: ObservableObject {
    @Published var fps: Double = 0
    private var timer: Timer?
    private var frameCount = 0
    private var lastSample = Date()

    func start() {
        guard timer == nil else { return }
        lastSample = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameCount += 1
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastSample)
                guard elapsed >= 1 else { return }
                self.fps = Double(self.frameCount) / elapsed
                self.frameCount = 0
                self.lastSample = now
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
#endif
