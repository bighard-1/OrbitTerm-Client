import SwiftUI

enum OrbitLegalTerms {
    static let version = "2026-08-21"
    static let fullText = """
    OrbitTerm 使用条款、免责声明与隐私说明
    生效日期：\(version)

    1. 授权范围
    您只能使用 OrbitTerm 连接、管理您拥有、管理或已取得明确合法授权的设备、账户、网络及数据。不得将本软件用于未授权访问、规避安全控制、破坏服务或其他违法活动。

    2. 账户与安全责任
    您负责妥善保管账户密码、主密码、SSH 私钥、令牌和远程资产凭据，并负责由您的账户或设备发起的操作。主密码和端到端加密密钥无法由 OrbitTerm 代为恢复；遗失可能导致加密数据无法解密。

    3. 同步、备份与数据
    跨设备同步采用端到端加密，但同步服务不等同于完整备份或长期托管。您应自行保留必要的独立备份，并在执行删除、覆盖、权限修改、批量命令、端口映射、进程终止等操作前核对目标与影响。

    4. 高风险操作与远端结果
    SSH、Telnet、RDP、SFTP、Docker、批量命令及端口映射会直接影响远端系统。网络中断、权限、系统差异、第三方组件或远端配置可能导致失败、重复、部分完成或数据损失。对于危险操作，您应先测试并建立可恢复方案。

    5. 隐私与诊断
    OrbitTerm 按最小必要原则处理数据。脱敏诊断不应包含密码、私钥、令牌、命令正文、终端内容或远端文件内容；但在导出、复制、截图或通过第三方应用分享前，您仍应检查并移除敏感信息。

    6. 第三方服务与开源组件
    本软件可能依赖操作系统能力、网络、远端服务及开源组件。相关服务的可用性、安全策略和许可由其提供者负责，OrbitTerm 不保证第三方服务持续可用或完全兼容。

    7. 免责声明
    在适用法律允许的最大范围内，本软件按“现状”和“可用状态”提供，不对不间断运行、无错误、适用于特定目的或绝对安全作出明示或默示保证。任何提示、监控与验证结果均不能替代专业运维、安全审计或备份。

    8. 责任限制
    在适用法律允许的最大范围内，开发者不对因使用或无法使用本软件而产生的间接、附带、特殊、惩罚性或后果性损失承担责任，包括数据丢失、业务中断、利润损失或第三方索赔。法律不允许排除的法定责任不受本条限制。

    9. 更新、暂停与终止
    为安全、兼容或合规需要，功能、协议和条款可能更新。严重滥用、违法使用或危害服务安全时，相关服务可被限制或终止。停止使用并退出账户不自动删除您在远端系统或独立备份中的数据。

    10. 适用规则与联系
    本条款应结合用户所在地不可排除的消费者保护及数据保护法律解释。问题、权利请求或安全报告可通过应用内“帮助与反馈”联系维护者。

    继续使用即表示您已阅读并同意上述条款；若不同意，请停止使用相关功能。
    """
}
#if os(macOS)
import AppKit
#endif
/*
struct TerminalRGB: Hashable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    var swiftUIColor: Color {
        Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0
        )
    }
}

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: TerminalRGB
    let foreground: TerminalRGB
    let ansi16: [TerminalRGB]
}

enum TerminalThemeManager {
    static let storageKey = "orbitterm.terminal.theme.id"
    static let defaultThemeID = "dracula"

    static let presets: [TerminalTheme] = [
        TerminalTheme(
            id: "dracula",
            name: "Dracula",
            background: .init(r: 40, g: 42, b: 54),
            foreground: .init(r: 248, g: 248, b: 242),
            ansi16: [
                .init(r: 40, g: 42, b: 54), .init(r: 255, g: 85, b: 85), .init(r: 80, g: 250, b: 123), .init(r: 241, g: 250, b: 140),
                .init(r: 98, g: 114, b: 164), .init(r: 255, g: 121, b: 198), .init(r: 139, g: 233, b: 253), .init(r: 248, g: 248, b: 242),
                .init(r: 68, g: 71, b: 90), .init(r: 255, g: 110, b: 110), .init(r: 105, g: 255, b: 160), .init(r: 255, g: 255, b: 170),
                .init(r: 189, g: 147, b: 249), .init(r: 255, g: 146, b: 213), .init(r: 170, g: 255, b: 255), .init(r: 255, g: 255, b: 255),
            ]
        ),
        TerminalTheme(
            id: "solarized-dark",
            name: "Solarized Dark",
            background: .init(r: 0, g: 43, b: 54),
            foreground: .init(r: 131, g: 148, b: 150),
            ansi16: [
                .init(r: 7, g: 54, b: 66), .init(r: 220, g: 50, b: 47), .init(r: 133, g: 153, b: 0), .init(r: 181, g: 137, b: 0),
                .init(r: 38, g: 139, b: 210), .init(r: 211, g: 54, b: 130), .init(r: 42, g: 161, b: 152), .init(r: 238, g: 232, b: 213),
                .init(r: 0, g: 43, b: 54), .init(r: 203, g: 75, b: 22), .init(r: 88, g: 110, b: 117), .init(r: 101, g: 123, b: 131),
                .init(r: 131, g: 148, b: 150), .init(r: 108, g: 113, b: 196), .init(r: 147, g: 161, b: 161), .init(r: 253, g: 246, b: 227),
            ]
        ),
        TerminalTheme(
            id: "nord",
            name: "Nord",
            background: .init(r: 46, g: 52, b: 64),
            foreground: .init(r: 216, g: 222, b: 233),
            ansi16: [
                .init(r: 59, g: 66, b: 82), .init(r: 191, g: 97, b: 106), .init(r: 163, g: 190, b: 140), .init(r: 235, g: 203, b: 139),
                .init(r: 129, g: 161, b: 193), .init(r: 180, g: 142, b: 173), .init(r: 136, g: 192, b: 208), .init(r: 229, g: 233, b: 240),
                .init(r: 76, g: 86, b: 106), .init(r: 191, g: 97, b: 106), .init(r: 163, g: 190, b: 140), .init(r: 235, g: 203, b: 139),
                .init(r: 129, g: 161, b: 193), .init(r: 180, g: 142, b: 173), .init(r: 143, g: 188, b: 187), .init(r: 236, g: 239, b: 244),
            ]
        ),
        TerminalTheme(
            id: "homebrew",
            name: "Homebrew",
            background: .init(r: 0, g: 0, b: 0),
            foreground: .init(r: 0, g: 255, b: 102),
            ansi16: [
                .init(r: 0, g: 0, b: 0), .init(r: 0, g: 221, b: 0), .init(r: 0, g: 255, b: 85), .init(r: 85, g: 255, b: 85),
                .init(r: 0, g: 170, b: 0), .init(r: 0, g: 204, b: 0), .init(r: 102, g: 255, b: 153), .init(r: 170, g: 255, b: 187),
                .init(r: 0, g: 68, b: 0), .init(r: 51, g: 255, b: 51), .init(r: 102, g: 255, b: 102), .init(r: 153, g: 255, b: 153),
                .init(r: 0, g: 136, b: 0), .init(r: 51, g: 204, b: 51), .init(r: 187, g: 255, b: 204), .init(r: 221, g: 255, b: 221),
            ]
        ),
    ]

    static func theme(for id: String) -> TerminalTheme {
        presets.first(where: { $0.id == id }) ?? presets[0]
    }
}
*/

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var appThemeManager: AppThemeManager
#if os(macOS)
    @EnvironmentObject private var shortcutPreferences: WorkstationShortcutPreferences
#endif
    @EnvironmentObject private var syncService: SyncService
    @State private var showDiagnostics = false
    @State private var biometricFeedback: SecurityOperationFeedback?
    @State private var biometricFeedbackDismissTask: Task<Void, Never>?
    @AppStorage(TerminalThemeManager.storageKey) private var terminalThemeID: String = TerminalThemeManager.defaultThemeID
    @AppStorage(TerminalThemeManager.followsApplicationThemeStorageKey) private var terminalFollowsApplicationTheme = false
    @State private var biometricEnabled: Bool = false
    @AppStorage("orbitterm.terminal.font.size") private var terminalFontSize: Double = 13
    @AppStorage(TelnetAccessPolicy.enabledStorageKey) private var telnetEnabled: Bool = false
    @AppStorage("orbitterm.monitor.realtime.interval") private var monitorInterval: Double = 1.0
    @AppStorage(MonitorRefreshPreference.storageKey) private var monitorAutoRefreshEnabled = true
#if os(macOS)
    @AppStorage("orbitterm.monitor.history.range") private var monitorHistoryRange = "10 分钟"
#endif
    @State private var showTelnetEnableConfirmation = false
    @State private var blockedSyncQueueCount = 0
    @State private var showDiscardBlockedSyncConfirmation = false
#if os(iOS)
#endif

    var body: some View {
        ZStack {
            AppChromeBackground()

        List {
            Section("应用外观") {
                Picker("外观模式", selection: Binding(get: { appThemeManager.appearanceMode }, set: { appThemeManager.selectMode($0) })) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                ForEach(AppThemeID.allCases) { theme in
                    Button {
                        appThemeManager.selectTheme(theme)
                    } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                ForEach(Array(AppThemePalette.make(theme: theme, colorScheme: .light).previewColors.enumerated()), id: \.offset) { _, color in
                                    Circle().fill(color.color).frame(width: 16, height: 16)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.displayName)
                                Text(theme.themeDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if appThemeManager.selectedTheme == theme {
                                Label("已选", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                            }
                        }
                    }
                    .accessibilityLabel("界面主题：\(theme.displayName)")
                    .accessibilityValue(appThemeManager.selectedTheme == theme ? "已选中" : "未选中")
                }
            }

            Section("终端外观") {
                Toggle("终端主题跟随应用主题", isOn: $terminalFollowsApplicationTheme)
                Picker("终端主题", selection: $terminalThemeID) {
                    ForEach(TerminalThemeManager.presets) { theme in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(theme.background.swiftUIColor)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            Circle()
                                .fill(theme.foreground.swiftUIColor)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
                            Text(theme.name)
                        }
                        .tag(theme.id)
                    }
                }
                .disabled(terminalFollowsApplicationTheme)

                let activeTheme = TerminalThemeManager.theme(for: terminalThemeID)
                HStack(spacing: 6) {
                    ForEach(Array(activeTheme.ansi16.prefix(8).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.swiftUIColor)
                            .frame(width: 14, height: 10)
                    }
                }
                .padding(.top, 2)
            }

            Section("终端与连接") {
                Toggle("启用 Telnet（明文，仅建议隔离内网）", isOn: telnetToggleBinding)
                Text("Telnet 不加密用户名、密码和命令，也无法验证服务器身份。关闭时不会影响 SSH。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("终端字号")
                    Spacer()
                    Stepper("\(Int(terminalFontSize))", value: $terminalFontSize, in: 8 ... 24)
                        .labelsHidden()
                }
                HStack {
                    Text("监控刷新间隔")
                    Spacer()
                    Picker("监控刷新间隔", selection: $monitorInterval) {
                        Text("1 秒").tag(1.0)
                        Text("2 秒").tag(2.0)
                        Text("5 秒").tag(5.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }

            Section("系统监控") {
                Toggle("自动刷新资源趋势", isOn: $monitorAutoRefreshEnabled)
#if os(macOS)
                Picker("趋势时间范围", selection: $monitorHistoryRange) {
                    Text("实时").tag("实时")
                    Text("5 分钟").tag("5 分钟")
                    Text("10 分钟").tag("10 分钟")
                }
                .pickerStyle(.segmented)
#endif
            }

#if os(macOS)
            Section("键盘与工作站") {
                NavigationLink {
                    WorkstationShortcutSettingsView()
                        .environmentObject(shortcutPreferences)
                } label: {
                    Label("自定义键盘快捷键", systemImage: "command")
                }
                Text("可修改工作站常用操作的快捷键，并随时恢复默认设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            Section("同步状态") {
                Text(syncService.lastSyncMessage.isEmpty ? "暂无同步状态" : syncService.lastSyncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !syncService.lastInventoryDiagnostic.isEmpty {
                    Text(syncService.lastInventoryDiagnostic)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if blockedSyncQueueCount > 0 {
                    Text("\(blockedSyncQueueCount) 项本地同步变更已停止后台重试。请先检查同步服务设置，再选择重新尝试；确认不再需要时也可丢弃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新尝试受阻项目") {
                        Task { await retryBlockedSyncQueue() }
                    }
                    Button("丢弃受阻项目", role: .destructive) {
                        showDiscardBlockedSyncConfirmation = true
                    }
                }
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    Label("最近删除", systemImage: "trash")
                }
            }

            Section("安全与同步") {
                Label("资产凭据与 SSH 私钥随账户资产端到端加密同步", systemImage: "lock.shield.fill")
                Text("macOS 将密钥作为对应 SSH 资产的受保护凭据同步；服务器只接收加密信封，不接收主密码或明文私钥。独立密钥的导入、生成、部署和测试请使用顶部“密钥管理”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("诊断") {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("导出简单诊断日志", systemImage: "square.and.arrow.up")
                }
            }

            Section("安全") {
                Toggle("启用生物识别解锁", isOn: biometricToggleBinding)
                if biometricEnabled {
                    Text("开启后会在应用解锁阶段优先触发 Face ID / Touch ID 验证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let biometricFeedback {
                    Text(biometricFeedback.message)
                        .font(.caption)
                        .foregroundStyle(biometricFeedback.isFailure ? .red : .green)
                }
            }

#if os(macOS)
            Section("账户与应用") {
                NavigationLink {
                    AccountSecurityView()
                } label: {
                    Label("个人中心与安全", systemImage: "person.crop.circle")
                }
                Button {
                    NSApp.orderFrontStandardAboutPanel(nil)
                } label: {
                    Label("关于 OrbitTerm", systemImage: "info.circle")
                }
                Button {
                    presentTerms()
                } label: {
                    Label("使用条款", systemImage: "doc.text")
                }
                Button {
                    presentUpdateStatus()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
            }
#endif
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        }
        .navigationTitle("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
#if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
#endif
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsExportView()
        }
        .alert("启用不安全的 Telnet？", isPresented: $showTelnetEnableConfirmation) {
            Button("取消", role: .cancel) {}
            Button("我了解风险，启用", role: .destructive) {
                TelnetAccessPolicy.shared.setEnabled(true)
                telnetEnabled = true
            }
        } message: {
            Text("Telnet 会以明文传输登录信息和终端内容。仅应连接隔离内网、VPN 内的受信旧设备；SSH 失败时 OrbitTerm 不会自动切换到 Telnet。")
        }
        .alert("丢弃受阻同步项目？", isPresented: $showDiscardBlockedSyncConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认丢弃", role: .destructive) {
                Task { await discardBlockedSyncQueue() }
            }
        } message: {
            Text("只会移除已确认停止重试的同步请求，不会删除本机资产或可自动重试项目。此操作无法撤销。")
        }
        .task(id: syncService.lastSyncMessage) {
            await refreshBlockedSyncQueueCount()
        }
        .onChange(of: monitorAutoRefreshEnabled) { _, enabled in
            Task {
                await SessionManager.shared.monitorService.applyAutoRefreshPreference(enabled)
            }
        }
        .onAppear {
            biometricEnabled = BiometricAuthService.shared.isEnabled(for: session.username)
        }
        .onDisappear {
            biometricFeedbackDismissTask?.cancel()
        }
    }

    @MainActor
    private func refreshBlockedSyncQueueCount() async {
        guard !session.username.isEmpty else {
            blockedSyncQueueCount = 0
            return
        }
        blockedSyncQueueCount = await SyncQueue.shared.blockedCount(accountID: session.username)
    }

    @MainActor
    private func retryBlockedSyncQueue() async {
        _ = await SyncQueue.shared.retryBlocked(accountID: session.username)
        await refreshBlockedSyncQueueCount()
    }

    @MainActor
    private func discardBlockedSyncQueue() async {
        _ = await SyncQueue.shared.discardBlocked(accountID: session.username)
        await refreshBlockedSyncQueueCount()
    }

    /// Loading the Settings screen must never authenticate the user. Only a
    /// deliberate toggle from off to on is allowed to request biometrics.
    private var biometricToggleBinding: Binding<Bool> {
        Binding(
            get: { biometricEnabled },
            set: { enabled in
                if enabled {
                    Task { await validateBiometricImmediately() }
                } else {
                    BiometricAuthService.shared.setEnabled(false, for: session.username)
                    biometricEnabled = false
                    setBiometricFeedback(
                        .init(kind: .success, message: SecurityOperationPresentation.biometricDisabledSuccess)
                    )
                }
            }
        )
    }

    private var telnetToggleBinding: Binding<Bool> {
        Binding(
            get: { telnetEnabled },
            set: { enabled in
                if enabled {
                    showTelnetEnableConfirmation = true
                } else {
                    telnetEnabled = false
                    Task { await SessionManager.shared.disableTelnetAndDisconnect() }
                }
            }
        )
    }

    @MainActor
    private func validateBiometricImmediately() async {
        guard session.hasMasterPassword else {
            setBiometricFeedback(.init(kind: .failure, message: "请先设置并验证主密码后再启用生物识别。"))
            biometricEnabled = false
            return
        }
        guard BiometricAuthService.shared.isBiometricAvailable else {
            setBiometricFeedback(
                .init(kind: .recoveryRequired, message: SecurityOperationPresentation.biometricUnavailable)
            )
            biometricEnabled = false
            return
        }

        let validation = await BiometricAuthService.shared.validateBiometricOnly()
        guard validation == .success else {
            biometricEnabled = false
            if case let .failure(failure) = validation,
               let feedback = SecurityOperationPresentation.biometricFailure(failure) {
                setBiometricFeedback(feedback)
            }
            return
        }

        guard let pwd = session.readMasterPassword(), !pwd.isEmpty else {
            setBiometricFeedback(
                .init(kind: .recoveryRequired, message: SecurityOperationPresentation.biometricInvalidated)
            )
            biometricEnabled = false
            return
        }

        do {
            try BiometricAuthService.shared.enroll(masterPassword: pwd, accountID: session.username)
        } catch {
            setBiometricFeedback(
                .init(kind: .recoveryRequired, message: SecurityOperationPresentation.biometricInvalidated)
            )
            biometricEnabled = false
            return
        }

        BiometricAuthService.shared.setEnabled(true, for: session.username)
        biometricEnabled = true
        setBiometricFeedback(
            .init(kind: .success, message: SecurityOperationPresentation.biometricEnabledSuccess)
        )
    }

    private func setBiometricFeedback(_ feedback: SecurityOperationFeedback) {
        biometricFeedbackDismissTask?.cancel()
        biometricFeedback = feedback
        guard let delay = feedback.autoDismissAfterNanoseconds else { return }
        biometricFeedbackDismissTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, biometricFeedback == feedback else { return }
            biometricFeedback = nil
        }
    }

#if os(macOS)
    private func presentTerms() {
        let alert = NSAlert()
        alert.messageText = "OrbitTerm 使用条款"
        alert.informativeText = OrbitLegalTerms.fullText
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func presentUpdateStatus() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let alert = NSAlert()
        alert.messageText = "OrbitTerm \(version)"
        alert.informativeText = "当前开发版本尚未配置正式更新源。正式发布后将从签名更新通道检查新版本。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
#endif
}

#if os(macOS)
/// Native, settings-scoped recorder. It never installs a global event tap and
/// therefore cannot observe typing outside this visible settings screen.
struct WorkstationShortcutSettingsView: View {
    @EnvironmentObject private var preferences: WorkstationShortcutPreferences
    @State private var feedback = ""

    var body: some View {
        List {
            Section("工作站快捷键") {
                Text("自定义常用操作。标签切换始终使用 ⌘1–⌘9，以保持稳定导航。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(WorkstationShortcutAction.allCases) { action in
                    shortcutRow(action)
                }
                if !feedback.isEmpty {
                    Text(feedback).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("键盘快捷键")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("恢复全部默认") { preferences.resetAll(); feedback = "已恢复全部默认快捷键。" }
            }
        }
    }

    private func shortcutRow(_ action: WorkstationShortcutAction) -> some View {
        HStack(spacing: 12) {
            Text(action.title)
            Spacer()
            ShortcutRecorder(shortcut: preferences.shortcut(for: action)) { record(shortcut: $0, for: action) }
                .frame(width: 110)
            Button("恢复默认") { preferences.reset(action); feedback = "已恢复\(action.title)的默认快捷键。" }
                .buttonStyle(.borderless)
        }
    }

    private func record(shortcut: WorkstationShortcut, for action: WorkstationShortcutAction) {
        switch preferences.assign(shortcut, to: action) {
        case .accepted: feedback = "已更新\(action.title)快捷键。"
        case .duplicate(let other): feedback = "该快捷键已用于“\(other.title)”。"
        case .reserved: feedback = "此快捷键由 macOS 保留，不能修改。"
        case .unsupported: feedback = "仅支持 Command 或 Command-Shift 加单个可打印按键。"
        }
    }
}

private struct ShortcutRecorder: View {
    let shortcut: WorkstationShortcut
    let onRecord: (WorkstationShortcut) -> Void
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Button(isRecording ? "请按快捷键…" : shortcut.displayString) { beginRecording() }
            .buttonStyle(.bordered)
            .help("点击后按 Command 或 Command-Shift 组合键；按 Escape 取消。")
            .accessibilityLabel(isRecording ? "正在录制快捷键" : "当前快捷键：\(shortcut.displayString)")
            .onDisappear(perform: stopRecording)
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { stopRecording(); return nil }
            let allowed: NSEvent.ModifierFlags = [.command, .shift]
            guard modifiers.contains(.command), modifiers.subtracting(allowed).isEmpty,
                  let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1
            else { NSSound.beep(); return nil }
            let captured = WorkstationShortcut(key: characters, includesShift: modifiers.contains(.shift))
            stopRecording(); onRecord(captured); return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        isRecording = false
    }
}
#endif
