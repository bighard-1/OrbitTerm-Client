import SwiftUI
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
    @StateObject private var syncService = SyncService.shared
    @State private var showDiagnostics = false
    @State private var biometricStatus: String = ""
    @AppStorage(TerminalThemeManager.storageKey) private var terminalThemeID: String = TerminalThemeManager.defaultThemeID
    @AppStorage("orbitterm.biometric.enabled") private var biometricEnabled: Bool = false
    @AppStorage("orbitterm.terminal.font.size") private var terminalFontSize: Double = 13
    @AppStorage(TelnetAccessPolicy.enabledStorageKey) private var telnetEnabled: Bool = false
    @AppStorage("orbitterm.monitor.realtime.interval") private var monitorInterval: Double = 1.0
    @State private var showTelnetEnableConfirmation = false
#if os(iOS)
    @State private var showSwitchAccountConfirmation = false
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
                Button("立即双向同步") {
                    Task {
                        guard let token = session.readToken() else {
                            syncService.lastSyncMessage = "同步不可用：登录令牌不可用，请重新登录"
                            return
                        }
                        guard let masterPassword = session.readMasterPassword() else {
                            syncService.lastSyncMessage = "同步不可用：请重新输入主密码解锁后重试"
                            return
                        }
                        await syncService.reconcileAssetInventory(
                            token: token,
                            masterPassword: masterPassword,
                            store: ServerStore.shared,
                            accountID: session.username
                        )
                        await syncService.refreshInventoryDiagnostic(
                            token: token,
                            store: ServerStore.shared
                        )
                    }
                }
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    Label("最近删除", systemImage: "trash")
                }
            }

            Section("诊断") {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("导出简单诊断日志", systemImage: "square.and.arrow.up")
                }
            }

            Section("安全") {
                Toggle("启用生物识别解锁", isOn: $biometricEnabled)
                if biometricEnabled {
                    Text("开启后会在应用解锁阶段优先触发 Face ID / Touch ID 验证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !biometricStatus.isEmpty {
                    Text(biometricStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#if os(macOS)
#else
                Button("切换账号") {
                    showSwitchAccountConfirmation = true
                }
                Button("退出登录", role: .destructive) {
                    AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
                }
#endif
            }
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
#if os(iOS)
        .alert("切换账号？", isPresented: $showSwitchAccountConfirmation) {
            Button("切换账号", role: .destructive) {
                AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前所有会话并返回登录页。本机资产、片段和待同步操作会继续按原账号隔离保存，不会交给下一个账号。")
        }
#endif
        .onChange(of: biometricEnabled) { _, enabled in
            if enabled {
                Task { await validateBiometricImmediately() }
            } else {
                biometricStatus = "已关闭生物识别解锁"
            }
        }
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
            biometricStatus = "请先设置并验证主密码后再启用生物识别"
            biometricEnabled = false
            return
        }
        guard BiometricAuthService.shared.isBiometricAvailable else {
            biometricStatus = "当前设备不可用 Face ID / Touch ID"
            biometricEnabled = false
            return
        }

        let passed = await BiometricAuthService.shared.validateBiometricOnly()
        guard passed else {
            biometricStatus = "生物识别验证失败，已自动关闭"
            biometricEnabled = false
            return
        }

        guard let pwd = session.readMasterPassword(), !pwd.isEmpty else {
            biometricStatus = "无法读取主密码，请先锁定后重新用主密码解锁，再启用生物识别"
            biometricEnabled = false
            return
        }

        do {
            try BiometricAuthService.shared.enroll(masterPassword: pwd)
        } catch {
            biometricStatus = "生物识别初始化失败：\(error.localizedDescription)"
            biometricEnabled = false
            return
        }

        biometricStatus = "生物识别已启用并验证成功"
    }
}
