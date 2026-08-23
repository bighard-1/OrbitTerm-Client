import SwiftUI

struct DockerLogStreamView: View {
    @ObservedObject var service: DockerService
    let container: DockerContainerCard

    @State private var logs: String = "加载日志中..."
    @State private var isAutoRefresh: Bool = true
    @State private var logTask: Task<Void, Never>?
    @State private var logOwner = PageOperationOwner()
    @State private var isVisible = false
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        ScrollView {
            Text(logs)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(palette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(palette.surfaceInput.color)
        .overlay(Rectangle().stroke(palette.borderGlass.color, lineWidth: 1))
        .navigationTitle("\(container.name) 日志")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") {
                    guard canRefreshLogs else { return }
                    refreshNow()
                }
                .disabled(!canRefreshLogs)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("自动", isOn: $isAutoRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: isAutoRefresh) { _, newValue in
                        if newValue {
                            startStreaming()
                        } else {
                            stopStreaming()
                        }
                    }
            }
        }
        .onAppear {
            isVisible = true
            if isAutoRefresh, canRefreshLogs {
                startStreaming()
            }
        }
        .onDisappear {
            isVisible = false
            stopStreaming(.pageDisappeared)
        }
        .onChange(of: scenePhase) { _, _ in
            updateOperationLifecycle()
        }
        .onChange(of: session.isAuthenticated) { _, _ in
            updateOperationLifecycle()
        }
        .onChange(of: session.isUnlocked) { _, _ in
            updateOperationLifecycle()
        }
        .onChange(of: session.username) { _, _ in
            stopStreaming(.accountChanged)
        }
    }

    private var canRefreshLogs: Bool {
        isVisible && session.isAuthenticated && session.isUnlocked && scenePhase == .active
    }

    private func updateOperationLifecycle() {
        guard canRefreshLogs, isAutoRefresh else {
            stopStreaming()
            return
        }
        startStreaming()
    }

    private func startStreaming() {
        stopStreaming(.replaced)
        guard isAutoRefresh, canRefreshLogs else { return }
        let scope = accountOperationScope
        logTask = Task(priority: .utility) {
            while !Task.isCancelled {
                // The owner is per fetch rather than per visible page. A log
                // view may remain open for hours; each bounded request gets
                // its own deadline while page/account cancellation still
                // invalidates the active request immediately.
                let lease = logOwner.begin(scope: scope, timeout: PageOperationTimeout.dockerLogFetch)
                await refreshOnce(lease: lease, scope: scope)
                guard accepts(lease, scope: scope) else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: OperationResourceBudget.dockerRefreshIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func refreshNow() {
        stopStreaming(.replaced)
        guard canRefreshLogs else { return }
        let scope = accountOperationScope
        let lease = logOwner.begin(scope: scope, timeout: PageOperationTimeout.dockerLogFetch)
        logTask = Task(priority: .userInitiated) {
            await refreshOnce(lease: lease, scope: scope)
            guard accepts(lease, scope: scope) else { return }
            logTask = nil
        }
    }

    private var accountOperationScope: OperationScope {
        guard let account = AccountScope(username: session.username) else { return .anonymous }
        return .account(account.storageIdentifier)
    }

    private func stopStreaming(_ reason: PageOperationCancellationReason = .userCancelled) {
        logOwner.cancel(reason)
        logTask?.cancel()
        logTask = nil
    }

    private func accepts(_ lease: PageOperationLease, scope: OperationScope) -> Bool {
        !Task.isCancelled && canRefreshLogs && logOwner.accepts(lease, scope: scope)
    }

    private func refreshOnce(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        let span = PerformanceSignpost.begin(.dockerLogRefresh)
        do {
            let text = try await PageOperationTimeout.perform(timeout: PageOperationTimeout.dockerLogFetch) {
                try await service.fetchLogs(containerID: container.id)
            }
            guard accepts(lease, scope: scope) else {
                span.cancel()
                return
            }
            logs = DockerLogPresentationBuffer.renderedText(text)
            span.finish()
        } catch {
            span.cancel()
            if logOwner.timeoutReached(lease) {
                logs = "日志拉取超时，请稍后重试。"
                logOwner.cancel(.timedOut)
                logTask = nil
                return
            }
            guard accepts(lease, scope: scope) else { return }
            logs = "日志拉取失败，请稍后重试。"
        }
    }

}
