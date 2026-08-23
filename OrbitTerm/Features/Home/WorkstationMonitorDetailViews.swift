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

private enum RemoteProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    var id: String { rawValue }
}

struct MonitorDetailWindowRoute: Codable, Hashable {
    let sessionID: UUID
}

struct MonitorDetailWindowView: View {
    let route: MonitorDetailWindowRoute
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        if let session = sessionManager.session(for: route.sessionID) {
            MonitorDetailInlineView(
                session: session,
                service: sessionManager.monitorService,
                sessionManager: sessionManager
            )
        } else {
            ContentUnavailableView(
                "会话已关闭",
                systemImage: "rectangle.slash",
                description: Text("重新连接资产后可再次打开监控详情。")
            )
        }
    }
}

struct MonitorDetailInlineView: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var service: MonitorService
    @ObservedObject var sessionManager: SessionManager
    @AppStorage("orbitterm.monitor.history.range") private var range: MonitorHistoryRange = .min10
    @State private var processes: [RemoteProcessSnapshot] = []
    @State private var processSearch = ""
    @State private var processError: String?
    @State private var isRefreshingProcesses = false
    @State private var pendingTermination: RemoteProcessSnapshot?
    @State private var processSort: RemoteProcessSort = .cpu
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("监控详情")
                        .font(.title2.weight(.semibold))
                    Text("\(session.server.name) · \(session.server.host):\(session.server.port)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                    Text("TCP 延迟：本机 → 当前资产 SSH 端口 \(session.server.host):\(session.server.port)；失败率不等同于 IP 丢包")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                }
                Spacer()
                Picker("历史", selection: $range) {
                    ForEach(MonitorHistoryRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            ScrollView(.vertical, showsIndicators: true) {
                if let panel = service.panel(id: session.activeMonitorPanelID) {
                    let visiblePoints = filtered(panel.points)
                    let chartPoints = downsample(
                        visiblePoints,
                        maximumCount: OperationResourceBudget.monitorChartPoints
                    )

                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let latest = panel.points.last {
                            systemOverview(latest.systemInfo)
                        }

                        Text(panel.status)
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)

                        MonitorInteractiveChartCard(title: "CPU", points: chartPoints, value: \.cpuUsage, tint: palette.accentPrimary.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "内存", points: chartPoints, value: \.memUsedPercent, tint: palette.accentSecondary.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "磁盘", points: chartPoints, value: \.diskUsedPercent, tint: palette.focusRing.color, domain: 0...100, percent: true)
                        MonitorInteractiveChartCard(title: "TCP 延迟", points: chartPoints, value: { $0.pingLatencyMs ?? 0 }, tint: palette.textSecondary.color, domain: 0...300, percent: false)
                        MonitorInteractiveChartCard(title: "下载速率", points: chartPoints, value: \.rxRateKBps, tint: palette.accentPrimary.color, domain: 0...rateUpperBound(visiblePoints, keyPath: \.rxRateKBps), percent: false, unit: "KB/s")
                        MonitorInteractiveChartCard(title: "上传速率", points: chartPoints, value: \.txRateKBps, tint: palette.accentSecondary.color, domain: 0...rateUpperBound(visiblePoints, keyPath: \.txRateKBps), percent: false, unit: "KB/s")

                        processMonitorCard
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
        .task(id: session.id) {
            while !Task.isCancelled {
                await refreshProcesses()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(
            "结束进程 \(pendingTermination?.pid ?? 0)？",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }
            ),
            presenting: pendingTermination
        ) { process in
            Button("发送正常终止信号", role: .destructive) {
                pendingTermination = nil
                Task { await terminate(process, force: false) }
            }
            Button("取消", role: .cancel) { pendingTermination = nil }
        } message: { process in
            Text("将先核对 PID 与进程名称，避免 PID 复用导致误终止。系统关键进程不会执行。\n\(process.command) · PID \(process.pid)")
        }
    }

    private var visibleProcesses: [RemoteProcessSnapshot] {
        let query = processSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? processes : processes.filter {
            $0.command.localizedCaseInsensitiveContains(query) ||
                $0.user.localizedCaseInsensitiveContains(query) ||
                String($0.pid).contains(query)
        }
        return filtered.sorted {
            switch processSort {
            case .cpu:
                $0.cpuPercent == $1.cpuPercent ? $0.memoryPercent > $1.memoryPercent : $0.cpuPercent > $1.cpuPercent
            case .memory:
                $0.memoryPercent == $1.memoryPercent ? $0.cpuPercent > $1.cpuPercent : $0.memoryPercent > $1.memoryPercent
            }
        }
    }

    private var processMonitorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("进程监控", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                TextField("搜索 PID、用户或进程", text: $processSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Picker("排序", selection: $processSort) {
                    ForEach(RemoteProcessSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 116)
                Button {
                    Task { await refreshProcesses() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingProcesses || !session.isConnected)
            }

            if let processError {
                Label(processError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            } else if isRefreshingProcesses && processes.isEmpty {
                ProgressView("正在读取远端进程…")
                    .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Text("PID").frame(width: 58, alignment: .trailing)
                    Text("用户").frame(width: 100, alignment: .leading)
                    Text("CPU").frame(width: 62, alignment: .trailing)
                    Text("内存").frame(width: 62, alignment: .trailing)
                    Text("运行时间").frame(width: 80, alignment: .trailing)
                    Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                    Text("操作").frame(width: 76)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary.color)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleProcesses.prefix(200)) { process in
                            HStack(spacing: 8) {
                                Text("\(process.pid)").frame(width: 58, alignment: .trailing)
                                Text(process.user).lineLimit(1).frame(width: 100, alignment: .leading)
                                Text(String(format: "%.1f%%", process.cpuPercent)).frame(width: 62, alignment: .trailing)
                                Text(String(format: "%.1f%%", process.memoryPercent)).frame(width: 62, alignment: .trailing)
                                Text(elapsed(process.elapsedSeconds)).frame(width: 80, alignment: .trailing)
                                Text(process.command).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Button("结束") { pendingTermination = process }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .frame(width: 76)
                                    .disabled(process.pid <= 1)
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(palette.surfaceInput.color.opacity(process.cpuPercent >= 80 ? 1 : 0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
                .frame(height: 260)
            }
        }
        .padding(12)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func systemOverview(_ info: MonitorSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("系统概览", systemImage: "desktopcomputer")
                .font(.headline)
            Text(info.osName)
                .font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                summaryValue("CPU", info.cpuCoreCount > 0 ? "\(info.cpuCoreCount) 核 / \(info.cpuThreadCount) 线程" : "\(info.cpuThreadCount) 线程")
                summaryValue("内存总量", capacity(info.memoryTotalMB))
                summaryValue("交换空间", "\(capacity(info.swapUsedMB)) / \(capacity(info.swapTotalMB))")
                summaryValue("磁盘", "\(capacity(info.diskUsedMB)) / \(capacity(info.diskTotalMB))")
            }
        }
        .padding(12)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func summaryValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.textSecondary.color)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .padding(8)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func refreshProcesses() async {
        guard session.isConnected, !isRefreshingProcesses else { return }
        isRefreshingProcesses = true
        defer { isRefreshingProcesses = false }
        do {
            processes = try await sessionManager.fetchRemoteProcesses(session: session)
            processError = nil
        } catch {
            processError = error.localizedDescription
        }
    }

    private func terminate(_ process: RemoteProcessSnapshot, force: Bool) async {
        do {
            try await sessionManager.terminateRemoteProcess(process, session: session, force: force)
            processError = nil
            await refreshProcesses()
        } catch {
            processError = error.localizedDescription
        }
    }

    private func elapsed(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private func capacity(_ megabytes: UInt64) -> String {
        guard megabytes > 0 else { return "待采集" }
        let gigabytes = Double(megabytes) / 1_024
        return gigabytes >= 1 ? String(format: "%.1f GB", gigabytes) : "\(megabytes) MB"
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
                    Text(headerValue(displayed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
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

    private func headerValue(_ point: MonitorPoint) -> String {
        guard title == "TCP 延迟" else { return displayValue(point) }
        let statistics = TCPLatencySamplePolicy.statistics(samples: points.map(\.pingLatencyMs))
        let p50 = statistics.p50Milliseconds.map { String(format: "%.0f", $0) } ?? "--"
        let p95 = statistics.p95Milliseconds.map { String(format: "%.0f", $0) } ?? "--"
        let failure = statistics.failurePercent.map { String(format: "%.1f", $0) } ?? "--"
        return "\(displayValue(point)) · P50 \(p50) · P95 \(p95) · 失败 \(failure)%"
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
