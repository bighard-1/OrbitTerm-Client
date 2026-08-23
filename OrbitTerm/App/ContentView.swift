import SwiftUI
#if canImport(Charts)
import Charts
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum MobileShellTab: Hashable {
    case servers
    case session
    case sftp
    case docker
    case more
}

struct ContentView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var syncService: SyncService
    @EnvironmentObject private var diagnostics: DiagnosticsManager
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @State private var isAutoSyncRunning = false
    @State private var lastAutoSyncAt: Date = .distantPast
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var autoSyncGeneration = UUID()

    /// UI-test states are deliberately in-memory only. They must not start
    /// account-scoped work or derive recovery UI from absent credentials.
    private var isIsolatedUITestLaunch: Bool {
        AppUITestLaunchState.current != .standard
    }

    var body: some View {
        Group {
            if !session.isAuthenticated {
                AuthView()
                    .accessibilityIdentifier("orbit.root.auth")
            } else if !session.isUnlocked {
                MasterPasswordGateView()
                    .accessibilityIdentifier("orbit.root.locked")
            } else {
                MainShellView()
                    .accessibilityIdentifier("orbit.root.workspace")
            }
        }
        .task(id: autoSyncTaskKey) {
            guard !isIsolatedUITestLaunch else { return }
            applyOperationLifecycle(event(for: scenePhase))
            // 每次鉴权/解锁/token变更后都允许重试拉取，避免“仅首轮触发”导致不再同步。
            #if os(iOS)
            scheduleAutoSync(after: 700_000_000)
            #else
            // 首屏先展示本地缓存资产，云端同步以后台增量方式补齐。
            scheduleAutoSync(after: 900_000_000)
            #endif
        }
        .task(id: session.authRevision) {
            guard !isIsolatedUITestLaunch else { return }
            configureAccountScope()
        }
        .onOpenURL { url in
            guard !isIsolatedUITestLaunch else { return }
            deepLinkManager.handle(url: url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard !isIsolatedUITestLaunch else { return }
            guard newPhase == .active else {
                cancelAutoSync()
                applyOperationLifecycle(event(for: newPhase))
                return
            }
            applyOperationLifecycle(.becameActive)
            scheduleAutoSync(after: 0)
        }
        .onChange(of: session.isUnlocked) { _, isUnlocked in
            guard !isIsolatedUITestLaunch else { return }
            if isUnlocked {
                applyOperationLifecycle(event(for: scenePhase))
            } else if session.isAuthenticated {
                cancelAutoSync()
                applyOperationLifecycle(.accountLocked)
            }
        }
        .onChange(of: session.isAuthenticated) { _, isAuthenticated in
            guard !isIsolatedUITestLaunch else { return }
            guard !isAuthenticated else { return }
            cancelAutoSync()
            applyOperationLifecycle(.accountSignedOut)
        }
        .onDisappear {
            guard !isIsolatedUITestLaunch else { return }
            cancelAutoSync()
            #if os(macOS)
            applyOperationLifecycle(.mainWindowClosed)
            #else
            applyOperationLifecycle(.enteredBackground)
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            guard !isIsolatedUITestLaunch else { return }
            cancelAutoSync()
            applyOperationLifecycle(.applicationTerminating)
        }
        #endif
        #if os(macOS)
        .frame(minWidth: 980, minHeight: 700)
        #endif
        .alert(
            "检测到同步冲突",
            isPresented: Binding(
                get: { syncService.pendingConflictPrompt != nil },
                set: { shown in
                    if !shown, syncService.pendingConflictPrompt != nil {
                        syncService.chooseConflict(.keepCloud)
                    }
                }
            ),
            presenting: syncService.pendingConflictPrompt
        ) { prompt in
            Button("保留本地修改") {
                syncService.chooseConflict(.keepLocal)
            }
            Button("保留云端修改") {
                syncService.chooseConflict(.keepCloud)
            }
            Button("取消", role: .cancel) {
                syncService.chooseConflict(.keepCloud)
            }
        } message: { prompt in
            let fields = prompt.conflictedFields.map(\.rawValue).joined(separator: ", ")
            Text("""
            冲突字段：\(fields)

            本地修改：
            \(prompt.localSummary)

            云端修改：
            \(prompt.cloudSummary)
            """)
        }
    }

    private var autoSyncTaskKey: String {
        // 触发键只使用内存态，避免 SwiftUI 刷新时反复读取 Keychain 造成首屏卡顿。
        "\(session.isAuthenticated)-\(session.isUnlocked)-\(session.authRevision)"
    }

    private func applyOperationLifecycle(_ event: ApplicationOperationLifecycleEvent) {
        ApplicationOperationLifecycle.apply(
            event,
            isAuthenticated: session.isAuthenticated,
            isUnlocked: session.isUnlocked,
            sessionManager: sessionManager
        )
    }

    private func event(for phase: ScenePhase) -> ApplicationOperationLifecycleEvent {
        switch phase {
        case .active:
            return .becameActive
        case .inactive:
            return .becameInactive
        case .background:
            return .enteredBackground
        @unknown default:
            return .becameInactive
        }
    }

    /// Owns the one automatic sync for this view lifecycle. The generation
    /// prevents a cancelled request from a prior account, unlock state, or
    /// foreground activation from publishing a late result.
    private func scheduleAutoSync(after delayNanoseconds: UInt64) {
        cancelAutoSync()
        guard session.isAuthenticated, session.isUnlocked else { return }

        let generation = UUID()
        let expectedRevision = session.authRevision
        let expectedAccountID = session.username
        autoSyncGeneration = generation
        autoSyncTask = Task(priority: .background) {
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await runAutoSyncIfPossible(
                generation: generation,
                expectedRevision: expectedRevision,
                expectedAccountID: expectedAccountID
            )
        }
    }

    private func cancelAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        autoSyncGeneration = UUID()
        isAutoSyncRunning = false
    }

    private func runAutoSyncIfPossible(
        generation: UUID,
        expectedRevision: Int,
        expectedAccountID: String
    ) async {
        guard isCurrentAutoSync(
            generation: generation,
            expectedRevision: expectedRevision,
            expectedAccountID: expectedAccountID
        ) else {
            return
        }
        configureAccountScope()
        guard !isAutoSyncRunning else { return }
        // 避免前台频繁触发导致页面切换与首屏渲染抖动。
        #if os(macOS)
        guard Date().timeIntervalSince(lastAutoSyncAt) > 12 else { return }
        #else
        guard Date().timeIntervalSince(lastAutoSyncAt) > 2.5 else { return }
        #endif

        // 全端统一注册离线队列鉴权，避免仅桌面端可重试。
        SyncQueue.shared.setAuthContextProvider {
            guard let token = session.readToken(),
                  let scope = AccountScope(username: session.username) else {
                return nil
            }
            return SyncQueueAuthContext(token: token, accountIdentifier: scope.storageIdentifier)
        }

        guard isCurrentAutoSync(
            generation: generation,
            expectedRevision: expectedRevision,
            expectedAccountID: expectedAccountID
        ) else { return }
        guard let token = session.readToken() else {
            syncService.setSyncRecoveryPresentation(
                OperationRecoveryMapper.syncTokenUnavailable()
            )
            return
        }
        guard let masterPassword = session.readMasterPassword() else {
            syncService.setSyncRecoveryPresentation(
                OperationRecoveryMapper.syncMasterPasswordUnavailable()
            )
            return
        }

        isAutoSyncRunning = true
        lastAutoSyncAt = Date()

        // 自动同步不阻塞首屏：本地资产先可用，云端配置和片段在后台静默补齐。
        let accountID = session.username
        let ok = await syncService.pullAndApplyConfigs(
            token: token,
            masterPassword: masterPassword,
            store: serverStore,
            accountID: accountID,
            incremental: true,
            silentStart: true
        )
        guard isCurrentAutoSync(
            generation: generation,
            expectedRevision: expectedRevision,
            expectedAccountID: expectedAccountID
        ) else { return }

        do {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        } catch {
            return
        }
        guard isCurrentAutoSync(
            generation: generation,
            expectedRevision: expectedRevision,
            expectedAccountID: expectedAccountID
        ) else { return }

        await snippetStore.pullFromCloud(
            token: token,
            masterPassword: masterPassword,
            accountID: accountID
        )
        guard isCurrentAutoSync(
            generation: generation,
            expectedRevision: expectedRevision,
            expectedAccountID: expectedAccountID
        ) else { return }

        isAutoSyncRunning = false
        autoSyncTask = nil
        if !ok {
            if syncService.lastRecoveryPresentation?.code == .authenticationExpired {
                session.showTransientStatus("登录已失效，正在返回登录页")
                AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
                return
            }
            session.showTransientStatus("云端拉取失败，已保留本地数据")
        }
    }

    private func isCurrentAutoSync(
        generation: UUID,
        expectedRevision: Int,
        expectedAccountID: String
    ) -> Bool {
        !Task.isCancelled &&
            autoSyncGeneration == generation &&
            session.authRevision == expectedRevision &&
            session.isAuthenticated &&
            session.isUnlocked &&
            session.username == expectedAccountID
    }

    private func configureAccountScope() {
        AccountScopedServiceLifecycle.reconcile(
            isAuthenticated: session.isAuthenticated,
            username: session.username,
            services: [syncService, diagnostics]
        )
        guard session.isAuthenticated, !session.username.isEmpty else {
            serverStore.deactivateAccount()
            snippetStore.deactivateAccount()
            SshKeySyncStore.shared.deactivate()
            PortForwardProfileStore.shared.deactivate()
            return
        }
        serverStore.activateAccount(username: session.username)
        snippetStore.activateAccount(username: session.username)
        try? SshKeySyncStore.shared.activate(username: session.username)
        try? PortForwardProfileStore.shared.activate(username: session.username)
    }
}

private struct MainShellView: View {

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var securityPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var diagnostics: DiagnosticsManager
    @EnvironmentObject private var syncService: SyncService
    @StateObject private var snippetStore = SnippetStore.shared
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var showSettings = false
    @State private var selectedTab: MobileShellTab = .servers
    @State private var showingDeepLinkAddServer = false
    @State private var deepLinkPrefill: ServerAddPrefill?

    var body: some View {
        Group {
            #if os(macOS)
            NavigationStack {
                MainWorkstationView()
            }
            #else
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ServerListView { server in
                        sessionManager.openTab(for: server, autoConnect: true)
                        selectedTab = .session
                    }
                }
                    .tag(MobileShellTab.servers)
                    .tabItem { Label("服务器", systemImage: "server.rack") }

                NavigationStack {
                    MobileSessionView(
                        onBackToAssets: {
                            selectedTab = .servers
                        },
                        selectedTab: $selectedTab
                    )
                }
                    .tag(MobileShellTab.session)
                    .tabItem { Label("会话", systemImage: "terminal") }

                NavigationStack { SFTPBrowserView() }
                    .tag(MobileShellTab.sftp)
                    .tabItem { Label("SFTP", systemImage: "folder.badge.gearshape") }

                NavigationStack { DockerManagerView() }
                    .tag(MobileShellTab.docker)
                    .tabItem { Label("Docker", systemImage: "shippingbox.fill") }

                NavigationStack { MobileMoreView() }
                    .tag(MobileShellTab.more)
                    .tabItem { Label("个人中心", systemImage: "person.crop.circle.fill") }
            }
            .modifier(MobileShellTabBarStyle())
            .background(AppChromeBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if diagnostics.isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .overlay(alignment: .top) {
                if shouldShowSyncBanner {
                    syncStatusBanner
                        .padding(.top, 6)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowSyncBanner)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.88), value: selectedTab)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 6)
            }
            // The terminal supplies a UIKit-owned shortcut accessory above the
            // software keyboard. Other shell pages continue to use the normal
            // SwiftUI dismiss action without competing for that same region.
            .applyKeyboardDismissToolbar(enabled: selectedTab != .session)
            #endif
        }
        .sheet(isPresented: $showingDeepLinkAddServer) {
            AddServerView(store: serverStore, prefill: deepLinkPrefill) { server in
                serverStore.select(server)
                sessionManager.quickOpenServer = server
                sessionManager.openTab(for: server, autoConnect: true)
            }
            .environmentObject(session)
#if os(macOS)
            .frame(minWidth: 620, minHeight: 720)
#endif
        }
        .sheet(
            item: Binding(
                get: { sessionManager.checkedHostKeyRoute },
                set: { route in
                    if route == nil {
                        sessionManager.cancelCheckedHostKeyFlow()
                    }
                }
            )
        ) { route in
            HostKeyTrustView(
                coordinator: route.coordinator,
                copyText: { text in
                    _ = SecureClipboard.copy(text, kind: .hostKeyFingerprint)
                },
                onCancel: sessionManager.cancelCheckedHostKeyFlow,
                onTrust: {
                    Task { await sessionManager.trustCheckedHostKey() }
                },
                onRetrySave: {
                    Task { await sessionManager.retryCheckedHostKeySave() }
                },
                onClose: sessionManager.closeCheckedHostKeyPresentation
            )
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 420)
            #endif
        }
        .sheet(
            item: Binding(
                get: { sessionManager.telnetRiskRoute },
                set: { route in
                    if route == nil {
                        sessionManager.cancelTelnetRiskConfirmation()
                    }
                }
            )
        ) { route in
            TelnetRiskConfirmationView(
                route: route,
                onCancel: sessionManager.cancelTelnetRiskConfirmation,
                onConnect: {
                    Task { await sessionManager.confirmTelnetRiskAndConnect() }
                }
            )
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 430)
            #endif
        }
        .onAppear {
            processDeepLinkIfNeeded()
        }
        .onChange(of: deepLinkManager.pendingIntent?.id) { _, _ in
            processDeepLinkIfNeeded()
        }
    }

    private var shouldShowSyncBanner: Bool {
        syncService.lastRecoveryPresentation != nil
    }

    private var syncStatusBanner: some View {
        let recovery = syncService.lastRecoveryPresentation
        return HStack(spacing: 8) {
            Image(systemName: recovery?.systemImage ?? "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(recovery?.severity == .danger ? securityPalette.danger.color : securityPalette.warning.color)
            Text(recovery.map { "\($0.title)：\($0.message)" } ?? syncService.lastSyncMessage)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(syncBannerActionTitle(for: recovery)) {
                performSyncBannerAction(recovery)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedReadableSurface()
    }

    private func syncBannerActionTitle(for recovery: OperationRecoveryPresentation?) -> String {
        guard let recovery else { return "关闭" }
        if recovery.actions.contains(.reauthenticate) { return "重新登录" }
        if recovery.actions.contains(.retry) { return "重试" }
        if recovery.actions.contains(.unlock) { return "解锁" }
        return "关闭"
    }

    private func performSyncBannerAction(_ recovery: OperationRecoveryPresentation?) {
        guard let recovery else {
            syncService.clearSyncRecoveryPresentation()
            return
        }
        if recovery.actions.contains(.reauthenticate) {
            AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
        } else if recovery.actions.contains(.retry) {
            syncService.clearSyncRecoveryPresentation()
            Task { await retrySyncFromBanner() }
        } else if recovery.actions.contains(.unlock) {
            session.isUnlocked = false
        } else {
            syncService.clearSyncRecoveryPresentation()
        }
    }

    private func retrySyncFromBanner() async {
        guard let token = session.readToken() else {
            syncService.setSyncRecoveryPresentation(OperationRecoveryMapper.syncTokenUnavailable())
            return
        }
        guard let masterPassword = session.readMasterPassword() else {
            syncService.setSyncRecoveryPresentation(OperationRecoveryMapper.syncMasterPasswordUnavailable())
            return
        }
        await syncService.reconcileAssetInventory(
            token: token,
            masterPassword: masterPassword,
            store: serverStore,
            accountID: session.username
        )
        await syncService.refreshInventoryDiagnostic(token: token, store: serverStore)
    }

    private func processDeepLinkIfNeeded() {
        guard session.isAuthenticated, session.isUnlocked else { return }
        guard let intent = deepLinkManager.pendingIntent else { return }

        if let existing = serverStore.servers.first(where: {
            $0.host == intent.host && $0.port == intent.port && $0.username == intent.username
        }) {
            serverStore.select(existing)
            sessionManager.quickOpenServer = existing
            sessionManager.openTab(for: existing, autoConnect: true)
            session.showTransientStatus("已识别现有资产，正在连接 \(existing.name)")
            deepLinkManager.consumePendingIntent()
            return
        }

        deepLinkPrefill = intent.prefill
        showingDeepLinkAddServer = true
        session.showTransientStatus("已解析 SSH 链接，请确认后保存并连接")
        deepLinkManager.consumePendingIntent()
    }

}

#if os(iOS)
private struct MobileShellTabBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content
        }
    }
}
#endif
