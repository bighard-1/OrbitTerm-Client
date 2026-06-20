import SwiftUI
#if canImport(Charts)
import Charts
#endif
#if canImport(UIKit)
import UIKit
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
    @StateObject private var syncService = SyncService.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @State private var isAutoSyncRunning = false
    @State private var lastAutoSyncAt: Date = .distantPast

    var body: some View {
        Group {
            if !session.isAuthenticated {
                AuthView()
            } else if !session.isUnlocked {
                MasterPasswordGateView()
            } else {
                MainShellView()
            }
        }
        .task(id: autoSyncTaskKey) {
            // 每次鉴权/解锁/token变更后都允许重试拉取，避免“仅首轮触发”导致不再同步。
            #if os(iOS)
            try? await Task.sleep(nanoseconds: 700_000_000)
            #else
            // 首屏先展示本地缓存资产，云端同步以后台增量方式补齐。
            try? await Task.sleep(nanoseconds: 900_000_000)
            #endif
            await runAutoSyncIfPossible()
        }
        .onOpenURL { url in
            deepLinkManager.handle(url: url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await runAutoSyncIfPossible()
            }
        }
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

    private func runAutoSyncIfPossible() async {
        guard !isAutoSyncRunning else { return }
        // 避免前台频繁触发导致页面切换与首屏渲染抖动。
        #if os(macOS)
        guard Date().timeIntervalSince(lastAutoSyncAt) > 12 else { return }
        #else
        guard Date().timeIntervalSince(lastAutoSyncAt) > 2.5 else { return }
        #endif

        // 全端统一注册离线队列鉴权，避免仅桌面端可重试。
        SyncQueue.shared.setAuthTokenProvider {
            session.readToken()
        }

        guard session.isAuthenticated,
              session.isUnlocked,
              let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else {
            return
        }

        isAutoSyncRunning = true
        lastAutoSyncAt = Date()

        // 自动同步不阻塞首屏：本地资产先可用，云端配置和片段在后台静默补齐。
        Task(priority: .background) {
            let ok = await syncService.pullAndApplyConfigs(
                token: token,
                masterPassword: masterPassword,
                store: serverStore,
                accountID: session.username,
                incremental: true,
                silentStart: true
            )
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await snippetStore.pullFromCloud(token: token, masterPassword: masterPassword)

            await MainActor.run {
                isAutoSyncRunning = false
                if !ok {
                    if syncService.lastSyncMessage.contains("过期") {
                        session.showTransientStatus("登录已过期，正在返回登录页")
                        session.logout()
                        return
                    }
                    session.showTransientStatus("云端拉取失败，已保留本地数据")
                }
            }
        }
    }
}

private struct MainShellView: View {

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var diagnostics = DiagnosticsManager.shared
    @StateObject private var syncService = SyncService.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var showSettings = false
    @State private var selectedTab: MobileShellTab = .servers
    @State private var showingDeepLinkAddServer = false
    @State private var deepLinkPrefill: ServerAddPrefill?
    @State private var lastTabSwipeAt: Date = .distantPast

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
                    .tabItem { Label("更多", systemImage: "ellipsis.circle") }
            }
            .modifier(MobileShellTabBarStyle())
            .background(
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.07, blue: 0.13), Color(red: 0.08, green: 0.11, blue: 0.17)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
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
            .animation(.easeInOut(duration: 0.2), value: shouldShowSyncBanner)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.88), value: selectedTab)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 6)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onEnded { value in
                        handleTabSwipe(value)
                    }
            )
            .applyKeyboardDismissToolbar()
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
            .frame(minWidth: 500, minHeight: 650)
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
        syncService.lastSyncMessage.contains("过期") || syncService.lastSyncMessage.contains("失败")
    }

    private var syncStatusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(syncService.lastSyncMessage)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(syncService.lastSyncMessage.contains("过期") ? "重新登录" : "关闭") {
                if syncService.lastSyncMessage.contains("过期") {
                    session.logout()
                } else {
                    syncService.lastSyncMessage = "已忽略本次提示"
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
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

    #if os(iOS)
    private func handleTabSwipe(_ value: DragGesture.Value) {
        // 会话页内部保留左右滑动给“终端/快捷指令/监控”子模块切换，避免误滑出会话。
        if selectedTab == .session, SessionManager.shared.activeSession != nil {
            return
        }
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 56, abs(dx) > abs(dy) * 1.2 else { return }
        guard Date().timeIntervalSince(lastTabSwipeAt) > 0.22 else { return }
        lastTabSwipeAt = Date()

        let order: [MobileShellTab] = [.servers, .session, .sftp, .docker, .more]
        guard let idx = order.firstIndex(of: selectedTab) else { return }

        if dx < 0, idx < order.count - 1 {
            withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.86)) {
                selectedTab = order[idx + 1]
            }
        } else if dx > 0, idx > 0 {
            withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.86)) {
                selectedTab = order[idx - 1]
            }
        }
    }
    #endif
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
