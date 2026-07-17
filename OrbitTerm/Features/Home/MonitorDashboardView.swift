import SwiftUI
import Charts

private enum MonitorCredentialMode: String, CaseIterable, Identifiable {
    case password
    case key

    var id: String { rawValue }
    var title: String {
        switch self {
        case .password: return "密码优先"
        case .key: return "密钥优先"
        }
    }
}

struct MonitorDashboardView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var legacyService = MonitorService()

    @State private var showingAddSheet = false
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var privateKeyContent = ""
    @State private var privateKeyPassphrase = ""
    @State private var credentialMode: MonitorCredentialMode = .password
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        ZStack {
            AppChromeBackground()
            Group {
                if sessionManager.requiresCheckedConnection {
                    checkedDashboard
                } else {
                    #if os(iOS)
                    iosPager
                    #else
                    macDashboard
                    #endif
                }
            }
        }
        .navigationTitle("无代理监控")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新增主机") { showingAddSheet = true }
                    .opacity(sessionManager.requiresCheckedConnection ? 0 : 1)
                    .disabled(sessionManager.requiresCheckedConnection)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    TextField("显示名称", text: $name)
                    TextField("主机/IP", text: $host)
                    TextField("用户名", text: $username)
                    Picker("认证模式", selection: $credentialMode) {
                        ForEach(MonitorCredentialMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    SecureField("密码（可选）", text: $password)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("私钥内容（可选）")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)
                        TextEditor(text: $privateKeyContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 90)
                            .padding(6)
                            .foregroundStyle(palette.textPrimary.color)
                            .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
                    }

                    SecureField("私钥口令（可选）", text: $privateKeyPassphrase)
                }
                .scrollContentBackground(.hidden)
                .background(palette.surfaceReadable.color)
                .navigationTitle("新增监控主机")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            legacyService.addTarget(
                                name: name.isEmpty ? host : name,
                                host: host,
                                username: username,
                                credentials: ServerCredentials(
                                    password: password,
                                    privateKeyContent: privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines),
                                    privateKeyPassphrase: privateKeyPassphrase
                                )
                            )
                            name = ""
                            host = ""
                            username = ""
                            password = ""
                            privateKeyContent = ""
                            privateKeyPassphrase = ""
                            credentialMode = .password
                            showingAddSheet = false
                        }
                        .disabled(!canSaveTarget)
                    }
                }
            }
        }
    }

    private var canSaveTarget: Bool {
        let hasBase = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasBase else { return false }

        let hasPassword = !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if credentialMode == .password {
            return hasPassword || hasKey
        }
        return hasKey || hasPassword
    }

    #if os(iOS)
    private var iosPager: some View {
        TabView {
            ForEach(legacyService.panels) { panel in
                MonitorPanelCard(panel: panel, service: legacyService)
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
                ForEach(legacyService.panels) { panel in
                    MonitorPanelCard(panel: panel, service: legacyService)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var checkedDashboard: some View {
        if let active = sessionManager.activeSession,
           let panel = sessionManager.monitorService.panel(id: active.activeMonitorPanelID) {
            ScrollView {
                MonitorPanelCard(
                    panel: panel,
                    service: sessionManager.monitorService,
                    onStart: { await sessionManager.startMonitorForActiveSessionIfNeeded() }
                )
                .padding(14)
            }
        } else {
            ContentUnavailableView {
                Label("需要已验证会话", systemImage: "checkmark.shield")
            } description: {
                Text("安全监控只使用当前工作区的已验证 SSH 会话，不会读取凭据或静默重连。")
            } actions: {
                Button("从当前会话开始监控") {
                    Task { await sessionManager.startMonitorForActiveSessionIfNeeded() }
                }
                .buttonStyle(ThemedPrimaryButtonStyle())
                .disabled(sessionManager.activeSession?.verifiedSessionLease == nil)
            }
        }
    }
}

private struct MonitorPanelCard: View {
    let panel: MonitorPanelState
    @ObservedObject var service: MonitorService
    var onStart: (() async -> Void)?
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    init(
        panel: MonitorPanelState,
        service: MonitorService,
        onStart: (() async -> Void)? = nil
    ) {
        self.panel = panel
        self.service = service
        self.onStart = onStart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(panel.target.name)
                        .font(.title3.weight(.semibold))
                    Text(panel.target.host.isEmpty ? "未配置主机" : panel.target.host)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
                Spacer()
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(panelStatusColor)
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
                        } else if let onStart {
                            await onStart()
                        } else {
                            await service.connect(panel.id)
                        }
                    }
                }
                .buttonStyle(ThemedPrimaryButtonStyle())

                Button("移除", role: .destructive) {
                    service.removeTarget(panel.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .foregroundStyle(palette.textPrimary.color)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.surfaceGlassStrong.color))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        )
        .shadow(color: palette.borderGlass.color.opacity(0.24), radius: 12, x: 0, y: 8)
    }

    private var cpuChart: some View {
        Chart(panel.points) { point in
            LineMark(
                x: .value("时间", point.time),
                y: .value("CPU", point.cpuUsage)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(MonitorMetricPresentationLevel.existingCPUZone(point.cpuZone).themeColor(in: security, fallback: palette).color)

            AreaMark(
                x: .value("时间", point.time),
                y: .value("CPU", point.cpuUsage)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(palette.accentPrimary.color.opacity(0.08))
        }
        .chartYScale(domain: 0...100)
        .frame(height: 160)
        .accessibilityLabel("CPU 使用率趋势")
        .accessibilityValue("当前 \(currentCPUText)")
    }

    private var throughputChart: some View {
        Chart(panel.points) { point in
            LineMark(
                x: .value("时间", point.time),
                y: .value("下行KB/s", point.rxRateKBps)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(palette.accentPrimary.color)

            LineMark(
                x: .value("时间", point.time),
                y: .value("上行KB/s", point.txRateKBps)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(palette.accentSecondary.color)
        }
        .frame(height: 120)
        .accessibilityLabel("网络吞吐趋势")
        .accessibilityValue("当前下载 \(throughputAccessibilityValue(\.rxRateKBps))，上传 \(throughputAccessibilityValue(\.txRateKBps))")
    }

    private var lastPoint: MonitorPoint? { panel.points.last }

    private var panelStatusColor: Color {
        if service.checkedErrors[panel.id] != nil { return security.danger.color }
        return panel.isRunning ? security.success.color : palette.textSecondary.color
    }

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

    private func throughputAccessibilityValue(_ keyPath: KeyPath<MonitorPoint, Double>) -> String {
        guard let lastPoint else { return "暂无数据" }
        return String(format: "%.1f KB/s", lastPoint[keyPath: keyPath])
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary.color)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
