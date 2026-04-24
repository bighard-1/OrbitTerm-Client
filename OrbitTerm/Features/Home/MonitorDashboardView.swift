import SwiftUI
import Charts

struct MonitorDashboardView: View {
    @StateObject private var service = MonitorService()

    @State private var showingAddSheet = false
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Group {
            #if os(iOS)
            iosPager
            #else
            macDashboard
            #endif
        }
        .navigationTitle("无代理监控")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新增主机") { showingAddSheet = true }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    TextField("显示名称", text: $name)
                    TextField("主机/IP", text: $host)
                    TextField("用户名", text: $username)
                    SecureField("密码", text: $password)
                }
                .navigationTitle("新增监控主机")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            service.addTarget(
                                name: name.isEmpty ? host : name,
                                host: host,
                                username: username,
                                password: password
                            )
                            name = ""
                            host = ""
                            username = ""
                            password = ""
                            showingAddSheet = false
                        }
                        .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
                    }
                }
            }
        }
    }

    #if os(iOS)
    private var iosPager: some View {
        TabView {
            ForEach(service.panels) { panel in
                MonitorPanelCard(panel: panel, service: service)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }
    #endif

    private var macDashboard: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(service.panels) { panel in
                    MonitorPanelCard(panel: panel, service: service)
                }
            }
            .padding(14)
        }
    }
}

private struct MonitorPanelCard: View {
    let panel: MonitorPanelState
    @ObservedObject var service: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(panel.target.name)
                        .font(.title3.weight(.semibold))
                    Text(panel.target.host.isEmpty ? "未配置主机" : panel.target.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                metricChip(title: "CPU", value: currentCPUText)
                metricChip(title: "内存", value: currentMemText)
                metricChip(title: "磁盘", value: currentDiskText)
                metricChip(title: "延迟", value: currentPingText)
            }

            if panel.points.isEmpty {
                ContentUnavailableView(
                    "暂无监控数据",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("连接后会在这里展示最近 10 分钟曲线")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                cpuChart
                throughputChart
            }

            HStack(spacing: 10) {
                Button(panel.isRunning ? "停止" : "开始") {
                    Task {
                        if panel.isRunning {
                            await service.disconnect(panel.id)
                        } else {
                            await service.connect(panel.id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("移除", role: .destructive) {
                    service.removeTarget(panel.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8)
    }

    private var cpuChart: some View {
        Chart(panel.points) { point in
            LineMark(
                x: .value("时间", point.time),
                y: .value("CPU", point.cpuUsage)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(by: .value("等级", point.cpuZone))

            AreaMark(
                x: .value("时间", point.time),
                y: .value("CPU", point.cpuUsage)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.blue.opacity(0.08))
        }
        .chartYScale(domain: 0...100)
        .chartForegroundStyleScale([
            "normal": Color.orbitBlue,
            "warning": Color.orange,
            "alert": Color.red
        ])
        .frame(height: 160)
    }

    private var throughputChart: some View {
        Chart(panel.points) { point in
            LineMark(
                x: .value("时间", point.time),
                y: .value("下行KB/s", point.rxRateKBps)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Color.green)

            LineMark(
                x: .value("时间", point.time),
                y: .value("上行KB/s", point.txRateKBps)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Color.purple)
        }
        .frame(height: 120)
    }

    private var lastPoint: MonitorPoint? { panel.points.last }

    private var currentCPUText: String {
        guard let lastPoint else { return "--" }
        return String(format: "%.1f%%", lastPoint.cpuUsage)
    }

    private var currentMemText: String {
        guard let lastPoint else { return "--" }
        return String(format: "%.1f%%", lastPoint.memUsedPercent)
    }

    private var currentDiskText: String {
        guard let lastPoint else { return "--" }
        return String(format: "%.1f%%", lastPoint.diskUsedPercent)
    }

    private var currentPingText: String {
        guard let latency = lastPoint?.pingLatencyMs else { return "--" }
        return String(format: "%.0fms", latency)
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension Color {
    static let orbitBlue = Color(red: 0.17, green: 0.52, blue: 0.98)
}
