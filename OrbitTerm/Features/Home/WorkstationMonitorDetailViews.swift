import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

private let monitorDetailTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

#if os(macOS)
/// Keeps chart hover inspection responsive without treating scroll-wheel
/// movement as a new point-selection gesture. The gate is intentionally not
/// observable: its bookkeeping must never cause the detail list to redraw.
private final class MonitorChartHoverGate {
    private var lastScreenLocation: CGPoint?

    func acceptsCurrentPointerMove() -> Bool {
        guard NSApp.currentEvent?.type != .scrollWheel else { return false }

        let location = NSEvent.mouseLocation
        defer { lastScreenLocation = location }

        guard let lastScreenLocation else { return true }
        return hypot(
            location.x - lastScreenLocation.x,
            location.y - lastScreenLocation.y
        ) >= 0.5
    }

    func reset() {
        lastScreenLocation = nil
    }
}
#endif

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
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Picker("历史", selection: $range) {
                    ForEach(MonitorHistoryRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
            }

            ScrollView(.vertical, showsIndicators: true) {
                if let panel = service.panel(id: panelID) {
                    let visiblePoints = filtered(panel.points)
                    let chartPoints = downsample(visiblePoints, maximumCount: 180)

                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(panel.status)
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)

                        MonitorInteractiveChartCard(title: "CPU", points: chartPoints, value: \.cpuUsage, tint: palette.accentPrimary.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "内存", points: chartPoints, value: \.memUsedPercent, tint: palette.accentSecondary.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "磁盘", points: chartPoints, value: \.diskUsedPercent, tint: palette.focusRing.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "延迟", points: chartPoints, value: { $0.pingLatencyMs ?? 0 }, tint: palette.textSecondary.color, domain: 0...300, percent: false)
                        MonitorInteractiveChartCard(title: "下载速率", points: chartPoints, value: \.rxRateKBps, tint: palette.accentPrimary.color, domain: 0...rateUpperBound(visiblePoints, keyPath: \.rxRateKBps), percent: false, unit: "KB/s")
                        MonitorInteractiveChartCard(title: "上传速率", points: chartPoints, value: \.txRateKBps, tint: palette.accentSecondary.color, domain: 0...rateUpperBound(visiblePoints, keyPath: \.txRateKBps), percent: false, unit: "KB/s")
                    }
                } else {
                    ContentUnavailableView("暂无监控数据", systemImage: "chart.line.uptrend.xyaxis")
                }
            }
        }
        .padding(10)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func filtered(_ points: [MonitorPoint]) -> [MonitorPoint] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return points.filter { $0.time >= cutoff }
    }

    private func downsample(_ points: [MonitorPoint], maximumCount: Int) -> [MonitorPoint] {
        guard points.count > maximumCount, maximumCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            points[Int((Double(index) * step).rounded())]
        }
    }

}

private struct MonitorInteractiveChartCard: View {
    let title: String
    let points: [MonitorPoint]
    let value: (MonitorPoint) -> Double
    let tint: Color
    let domain: ClosedRange<Double>
    let percent: Bool
    let unit: String
    @State private var highlightedPoint: MonitorPoint?
#if os(macOS)
    @State private var hoverGate = MonitorChartHoverGate()
#endif
    @Environment(\.appThemePalette) private var palette

    init(
        title: String,
        points: [MonitorPoint],
        value: @escaping (MonitorPoint) -> Double,
        tint: Color,
        domain: ClosedRange<Double>,
        percent: Bool,
        unit: String = "ms"
    ) {
        self.title = title
        self.points = points
        self.value = value
        self.tint = tint
        self.domain = domain
        self.percent = percent
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let displayed = highlightedPoint ?? points.last {
                    Text(displayValue(displayed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
            if let highlightedPoint {
                Text(timeFormatter.string(from: highlightedPoint.time))
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("时间", point.time),
                        y: .value("值", value(point))
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint)
                }
                if let highlightedPoint {
                    RuleMark(x: .value("时间", highlightedPoint.time))
                        .foregroundStyle(palette.focusRing.color.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(
                        x: .value("时间", highlightedPoint.time),
                        y: .value("值", value(highlightedPoint))
                    )
                    .foregroundStyle(tint)
                }
            }
            .chartYScale(domain: domain)
            .frame(height: 120)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
#if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard hoverGate.acceptsCurrentPointerMove() else { return }
                                updateHighlight(location: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoverGate.reset()
                                if highlightedPoint != nil {
                                    highlightedPoint = nil
                                }
                            }
                        }
#else
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    updateHighlight(location: value.location, proxy: proxy, geometry: geometry)
                                }
                                .onEnded { _ in highlightedPoint = nil }
                        )
#endif
                }
            }
            .accessibilityLabel("\(title) 趋势图")
            .accessibilityValue(points.last.map { point in
                percent ? String(format: "当前 %.1f%%", value(point)) : String(format: "当前 %.1f %@", value(point), unit)
            } ?? "暂无数据")
        }
        .padding(10)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func displayValue(_ point: MonitorPoint) -> String {
        percent ? String(format: "%.1f%%", value(point)) : String(format: "%.1f %@", value(point), unit)
    }

    private func updateHighlight(
        location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard let selectedTime: Date = proxy.value(atX: x) else { return }
        let candidate = points.min {
            abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime))
        }
        guard highlightedPoint?.id != candidate?.id else { return }
        highlightedPoint = candidate
    }

    private var timeFormatter: DateFormatter { monitorDetailTimeFormatter }
}

private extension MonitorDetailInlineView {
    func rateUpperBound(_ points: [MonitorPoint], keyPath: KeyPath<MonitorPoint, Double>) -> Double {
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
