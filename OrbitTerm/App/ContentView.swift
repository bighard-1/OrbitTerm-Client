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
    @StateObject private var localStorageIssues = LocalStorageIssueCenter.shared
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
            if session.isCheckingLocalStorage {
                LocalStorageCheckingView()
                    .accessibilityIdentifier("orbit.root.storage-checking")
            } else if let recovery = session.localStorageRecovery {
                LocalStorageRecoveryView(presentation: recovery) {
                    session.retryLocalStorageAccess()
                }
                .accessibilityIdentifier("orbit.root.storage-recovery")
            } else if !session.isAuthenticated {
                AuthView()
                    .accessibilityIdentifier("orbit.root.auth")
            } else if !session.isUnlocked {
                MasterPasswordGateView()
                    .accessibilityIdentifier("orbit.root.locked")
            } else {
                #if !ORBITTERM_PUBLIC_RELEASE
                if AppUITestLaunchState.current == .operationalStates {
                    OperationalStateUITestHarnessView()
                        .accessibilityIdentifier("orbit.root.operational-states")
                } else if AppUITestLaunchState.current == .syncRecoveryStates {
                    SyncRecoveryStateUITestHarnessView()
                        .accessibilityIdentifier("orbit.root.sync-recovery-states")
                } else if AppUITestLaunchState.current == .accountSecurityStates {
                    AccountSecurityStateUITestHarnessView()
                        .accessibilityIdentifier("orbit.root.account-security-states")
                } else {
                    MainShellView()
                        .accessibilityIdentifier("orbit.root.workspace")
                }
                #else
                MainShellView()
                    .accessibilityIdentifier("orbit.root.workspace")
                #endif
            }
        }
        .safeAreaInset(edge: .top) {
            if session.localStorageRecovery == nil,
               let issue = localStorageIssues.syncQueueIssue {
                LocalStorageQueueRecoveryBanner(presentation: issue) {
                    SyncQueue.shared.retryStorageAccess()
                }
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
            SyncConflictPresentation.title,
            isPresented: Binding(
                get: { syncService.pendingConflictPrompt != nil },
                // A conflict is a data-selection decision. Never turn an
                // implicit dismissal into "keep cloud"; require one of the
                // two explicit actions below, matching Android.
                set: { _ in }
            ),
            presenting: syncService.pendingConflictPrompt
        ) { prompt in
            Button(SyncConflictPresentation.keepLocalLabel) {
                syncService.chooseConflict(.keepLocal)
            }
            Button(SyncConflictPresentation.keepCloudLabel) {
                syncService.chooseConflict(.keepCloud)
            }
        } message: { prompt in
            let fields = prompt.conflictedFields.map(\.rawValue).joined(separator: ", ")
            Text("""
            冲突字段：\(fields)

            \(SyncConflictPresentation.localSectionTitle)：
            \(prompt.localSummary)

            \(SyncConflictPresentation.cloudSectionTitle)：
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

private struct LocalStorageCheckingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在安全检查本地数据")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.04))
        .accessibilityElement(children: .combine)
    }
}

private struct LocalStorageRecoveryView: View {
    let presentation: LocalStorageRecoveryPresentation
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(presentation.actionLabel, action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("重新验证本地数据库和系统钥匙串是否可用")
            Text("如果问题持续存在，请保留当前应用数据并联系管理员。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.04))
    }
}

private struct LocalStorageQueueRecoveryBanner: View {
    let presentation: LocalStorageRecoveryPresentation
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title).font(.subheadline.weight(.semibold))
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(presentation.actionLabel, action: retry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

#if !ORBITTERM_PUBLIC_RELEASE
private struct OperationalStateUITestHarnessView: View {
    @State private var showsTransientSuccess = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fixture(
                        title: "监控读取失败",
                        detail: "监控请求超时。",
                        module: .monitor
                    )
                    fixture(
                        title: "SFTP 操作失败",
                        detail: "目录读取超时。",
                        module: .sftp
                    )
                    fixture(
                        title: "Docker 操作失败",
                        detail: "容器读取超时。",
                        module: .docker
                    )
                    let busy = OperationalContentPresentationMapper.refreshAction(
                        module: .monitor,
                        phase: .ready,
                        isRefreshing: true,
                        hasContent: true
                    )
                    OperationalRefreshButton(presentation: busy) {}
                    if showsTransientSuccess {
                        OperationalTransientSuccessBanner(message: "容器操作已完成。")
                    }
                }
                .padding(16)
            }
            .navigationTitle("操作状态回归")
        }
        .task {
            guard let delay = OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            showsTransientSuccess = false
        }
    }

    @ViewBuilder
    private func fixture(
        title: String,
        detail: String,
        module: OperationalModuleKind
    ) -> some View {
        let content = OperationalContentPresentation(
            phase: .failed,
            headline: title,
            detail: detail
        )
        let action = OperationalContentPresentationMapper.refreshAction(
            module: module,
            phase: content.phase,
            isRefreshing: false,
            hasContent: true
        )
        VStack(alignment: .leading, spacing: 8) {
            Text(content.headline)
                .font(.headline)
            OperationalFailureBanner(
                content: content,
                action: action,
                accessibilityPrefix: title
            )
            OperationalRefreshButton(presentation: action) {}
        }
        .themedReadableSurface()
    }
}

private struct SyncRecoveryStateUITestHarnessView: View {
    @State private var showsQueuedSuccess = true

    private let partialFailure = SyncPresentationState.afterCompletedPull(
        detail: "资产同步完成",
        auxiliaryFailureDetails: ["1 项等待网络恢复后重试"]
    )
    private let recentlyDeletedFailure = RecentlyDeletedPresentationMapper.make(
        isLoading: false,
        itemCount: 2,
        failureDetail: "无法加载最近删除，请检查网络或登录状态。",
        isMutating: false
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    syncStatus(SyncPresentationState.make(.awaitingNetwork, detail: "网络恢复后自动同步"))
                    syncStatus(SyncPresentationState.make(.awaitingUnlock, detail: "解锁后继续安全同步"))
                    syncStatus(partialFailure)
                    Button("重试同步") {}
                        .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(SyncConflictPresentation.title)
                            .font(.headline)
                        Button(SyncConflictPresentation.keepLocalLabel) {}
                        Button(SyncConflictPresentation.keepCloudLabel) {}
                    }
                    .padding(12)
                    .themedReadableSurface()

                    Label(
                        [recentlyDeletedFailure.detail, recentlyDeletedFailure.staleContentMessage]
                            .compactMap { $0 }
                            .joined(separator: " "),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .securityStatusStyle(.danger)
                    Button(recentlyDeletedFailure.refreshLabel) {}
                        .accessibilityLabel("重试最近删除")
                    if showsQueuedSuccess {
                        OperationalTransientSuccessBanner(message: "恢复已加入后台队列，联网后自动完成。")
                    }
                }
                .padding(16)
            }
            .navigationTitle("同步与恢复状态回归")
        }
        .task {
            guard let delay = OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            showsQueuedSuccess = false
        }
    }

    @ViewBuilder
    private func syncStatus(_ presentation: SyncPresentationState) -> some View {
        Label(
            "\(presentation.headline)：\(presentation.detail)",
            systemImage: presentation.phase == .failed ? "icloud.slash" : "icloud"
        )
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .securityStatusStyle(presentation.phase == .failed ? .danger : .warning)
    }
}

private struct AccountSecurityStateUITestHarnessView: View {
    @State private var showsLoginSuccess = true
    @State private var showsLogoutConfirmation = false

    private let loginSuccess = SecurityOperationFeedback(
        kind: .success,
        message: SecurityOperationPresentation.loginPasswordSuccess
    )
    private let masterRecovery = SecurityOperationFeedback(
        kind: .recoveryRequired,
        message: "云端主密码已轮换，但本机更新待完成；请勿退出应用并重试。"
    )
    private let biometricRecovery = SecurityOperationFeedback(
        kind: .recoveryRequired,
        message: SecurityOperationPresentation.biometricInvalidated
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showsLoginSuccess {
                        feedback(loginSuccess)
                    }
                    feedback(masterRecovery)
                    feedback(biometricRecovery)
                    Button(SecurityOperationPresentation.loginPasswordBusy) {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    Button(SecurityOperationPresentation.masterPasswordBusy) {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    Button(SecurityOperationPresentation.biometricBusy) {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                    Button(SecurityOperationPresentation.logoutConfirm, role: .destructive) {
                        showsLogoutConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
            }
            .navigationTitle("账户安全状态回归")
        }
        .alert(SecurityOperationPresentation.logoutTitle, isPresented: $showsLogoutConfirmation) {
            Button(SecurityOperationPresentation.logoutConfirm, role: .destructive) {}
            Button("取消", role: ButtonRole.cancel) {}
        } message: {
            Text(SecurityOperationPresentation.logoutMessage)
        }
        .task {
            guard let delay = loginSuccess.autoDismissAfterNanoseconds else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            showsLoginSuccess = false
        }
    }

    @ViewBuilder
    private func feedback(_ feedback: SecurityOperationFeedback) -> some View {
        Label(
            feedback.message,
            systemImage: feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .securityStatusStyle(feedback.isFailure ? .danger : .success)
    }
}
#endif

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
    @State private var deepLinkEditingServer: ServerEntry?
    @State private var activeDeepLinkIntentID: UUID?

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
        .sheet(isPresented: $showingDeepLinkAddServer, onDismiss: finishDeepLinkReview) {
            AddServerView(
                store: serverStore,
                editingServer: deepLinkEditingServer,
                prefill: deepLinkPrefill
            ) { server in
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
        guard !showingDeepLinkAddServer else { return }

        if let existing = serverStore.servers.first(where: {
            $0.host == intent.host && $0.port == intent.port && $0.username == intent.username
        }) {
            deepLinkPrefill = nil
            deepLinkEditingServer = existing
            activeDeepLinkIntentID = intent.id
            showingDeepLinkAddServer = true
            session.showTransientStatus("已识别现有资产，请确认后保存并连接")
            return
        }

        deepLinkEditingServer = nil
        deepLinkPrefill = intent.prefill
        activeDeepLinkIntentID = intent.id
        showingDeepLinkAddServer = true
        session.showTransientStatus("已解析 SSH 链接，请确认后保存并连接")
    }

    private func finishDeepLinkReview() {
        if DeepLinkReviewPolicy.shouldConsumePendingIntent(
            isAuthenticated: session.isAuthenticated,
            isUnlocked: session.isUnlocked,
            pendingIntentID: deepLinkManager.pendingIntent?.id,
            activeReviewID: activeDeepLinkIntentID
        ) {
            deepLinkManager.consumePendingIntent()
        }
        activeDeepLinkIntentID = nil
        deepLinkEditingServer = nil
        deepLinkPrefill = nil
        processDeepLinkIfNeeded()
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
