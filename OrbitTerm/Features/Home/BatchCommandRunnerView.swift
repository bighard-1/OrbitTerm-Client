import SwiftUI

private struct BatchCommandReceipt: Identifiable {
    let id = UUID()
    let serverName: String
    let endpoint: String
    let durationMs: Int
    let success: Bool
    let output: String
}

#if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
private struct BatchCommandTarget {
    let server: ServerEntry
    let credentials: ServerCredentials?
}
#endif

struct BatchCommandRunnerView: View {
    @ObservedObject var store: ServerStore
    let allowedServerIDs: Set<UUID>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.securitySemanticPalette) private var securityPalette
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedServerIDs: Set<UUID> = []
    @State private var commandText = ""
    @State private var isRunning = false
    @State private var receipts: [BatchCommandReceipt] = []
    @State private var summaryText = "请选择资产或分组，然后输入命令执行。"
    @State private var runTask: Task<Void, Never>?
    @State private var runOwner = PageOperationOwner()

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    private let vault = CredentialVault.shared
    private let orbit = OrbitManager()
    #endif
    private let checkedBatchService = CheckedBatchCommandService(
        client: OrbitCoreCheckedFFIClient.live(
            credentialProvider: CredentialVaultCheckedProvider()
        )
    )

    init(
        store: ServerStore,
        initialCommand: String = "",
        allowedServerIDs: Set<UUID>? = nil
    ) {
        self.store = store
        self.allowedServerIDs = allowedServerIDs
        _commandText = State(initialValue: initialCommand)
    }

    var body: some View {
        NavigationStack {
            Group {
#if os(iOS)
            VStack(spacing: 0) {
                selectionPane
                    .frame(maxWidth: .infinity, maxHeight: 300)
                Divider()
                commandPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#else
            HStack(spacing: 0) {
                selectionPane
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                Divider()
                commandPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#endif
            }
            .navigationTitle("多资产命令执行")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        cancelBatchRun()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRunning ? "取消执行" : "执行命令") {
                        if isRunning {
                            cancelBatchRun()
                        } else {
                            startBatchRun()
                        }
                    }
                    .disabled(isRunning ? false : !canExecute)
                }
            }
        }
        .onDisappear {
            cancelBatchRun()
        }
        .onChange(of: scenePhase) { _, _ in
            cancelBatchRunIfOwnershipWasLost()
        }
        .onChange(of: session.isAuthenticated) { _, _ in
            cancelBatchRunIfOwnershipWasLost()
        }
        .onChange(of: session.isUnlocked) { _, _ in
            cancelBatchRunIfOwnershipWasLost()
        }
        .onChange(of: session.username) { _, _ in
            cancelBatchRun(.accountChanged)
        }
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择分组")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if batchSelectionSections.isEmpty {
                Text("暂无分组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(batchSelectionSections, id: \.group) { section in
                            let sshItems = section.items
                            if !sshItems.isEmpty {
                                let groupIDs = Set(sshItems.map(\.id))
                                let selectedCount = groupIDs.intersection(selectedServerIDs).count
                                let isOn = selectedCount == groupIDs.count
                                Button {
                                    if isOn {
                                        selectedServerIDs.subtract(groupIDs)
                                    } else {
                                        selectedServerIDs.formUnion(groupIDs)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: selectedCount == 0
                                            ? "square"
                                            : isOn ? "checkmark.square.fill" : "minus.square.fill")
                                        Text("\(section.group) (\(sshItems.count))")
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            Divider().padding(.vertical, 4)

            Text("选择资产")
                .font(.headline)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(availableSSHServers) { server in
                        let isOn = selectedServerIDs.contains(server.id)
                        Button {
                            if isOn {
                                selectedServerIDs.remove(server.id)
                            } else {
                                selectedServerIDs.insert(server.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).lineLimit(1)
                                    Text("\(server.displayGroup) · \(server.endpointText)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var commandPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("目标数量：\(effectiveTargets.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !targetsWithoutVerifiedSession.isEmpty {
                Label(
                    "\(targetsWithoutVerifiedSession.count) 台目标将在执行时使用已保存凭据安全连接；未知或变化的主机密钥会仅使对应资产失败。",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
                .foregroundStyle(securityPalette.warning.color)
                .accessibilityLabel("批量命令需要已验证的 SSH 会话")
            }

            TextEditor(text: $commandText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )

            if !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("代码预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ShellSyntaxHighlightedText(commandText, lineLimit: 4)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            List(receipts) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.serverName)
                            .font(.headline)
                        Text(item.endpoint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.success ? "成功" : "失败")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((item.success ? Color.green : Color.red).opacity(0.14), in: Capsule())
                            .foregroundStyle(item.success ? .green : .red)
                        Text("\(item.durationMs)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.vertical) {
                        Text(item.output.isEmpty ? "(无输出)" : item.output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(.green)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
        .padding(14)
    }

    private var effectiveTargets: [ServerEntry] {
        availableSSHServers.filter { selectedServerIDs.contains($0.id) }
    }

    private var availableSSHServers: [ServerEntry] {
        store.servers.filter { server in
            server.transport == .ssh && (allowedServerIDs == nil || allowedServerIDs?.contains(server.id) == true)
        }
    }

    private var batchSelectionSections: [(group: String, items: [ServerEntry])] {
        Dictionary(grouping: availableSSHServers, by: \.displayGroup)
            .map { (group: $0.key, items: $0.value) }
            .sorted { $0.group.localizedStandardCompare($1.group) == .orderedAscending }
    }

    private var targetsWithoutVerifiedSession: [ServerEntry] {
        guard SessionManager.shared.connectionSecurityPolicy.requiresCheckedNetwork else {
            return []
        }
        return effectiveTargets.filter {
            SessionManager.shared.verifiedSessionLease(for: $0.id) == nil
        }
    }

    private var canExecute: Bool {
        canOwnBatchOperation
            && !isRunning
            && !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveTargets.isEmpty
    }

    private var canOwnBatchOperation: Bool {
        session.isAuthenticated && session.isUnlocked && scenePhase == .active
    }

    private func startBatchRun() {
        guard runTask == nil, canExecute else { return }
        let scope = accountOperationScope
        let lease = runOwner.begin(scope: scope, timeout: PageOperationTimeout.batchCommand)
        runTask = Task {
            await runBatchCommand(lease: lease, scope: scope)
            if runOwner.timeoutReached(lease) {
                runOwner.cancel(.timedOut)
                isRunning = false
                summaryText = "批量命令超时；不会发布迟到结果。"
                runTask = nil
                return
            }
            guard runOwner.accepts(lease, scope: scope) else { return }
            runTask = nil
        }
    }

    private func cancelBatchRunIfOwnershipWasLost() {
        guard !session.isAuthenticated else {
            if !session.isUnlocked {
                cancelBatchRun(.accountLocked)
            } else if scenePhase != .active {
                cancelBatchRun(.sceneInactive)
            }
            return
        }
        cancelBatchRun(.accountSignedOut)
    }

    private var accountOperationScope: OperationScope {
        guard let account = AccountScope(username: session.username) else { return .anonymous }
        return .account(account.storageIdentifier)
    }

    private func cancelBatchRun(_ reason: PageOperationCancellationReason = .userCancelled) {
        runOwner.cancel(reason)
        runTask?.cancel()
        runTask = nil
        guard isRunning else { return }
        isRunning = false
        summaryText = "执行已取消；不会发布迟到结果。"
        Task { await checkedBatchService.cancel() }
    }

    private func accepts(_ lease: PageOperationLease, scope: OperationScope) -> Bool {
        !Task.isCancelled && runOwner.accepts(lease, scope: scope) && canOwnBatchOperation
    }

    private func runBatchCommand(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let targets = effectiveTargets
        guard !targets.isEmpty else { return }
        isRunning = true
        receipts = []
        if SessionManager.shared.connectionSecurityPolicy.requiresCheckedNetwork {
            await runCheckedBatchCommand(command: command, targets: targets, lease: lease, scope: scope)
            return
        }

        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        summaryText = "正在并发执行：\(targets.count) 台资产..."
        let batchTargets = targets.map { server in
            BatchCommandTarget(
                server: server,
                credentials: try? vault.read(for: server.credentialID)
            )
        }
        let orbit = orbit

        await withTaskGroup(of: BatchCommandReceipt.self) { group in
            for target in batchTargets {
                group.addTask {
                    let server = target.server
                    let start = Date()
                    do {
                        guard let credentials = target.credentials, !credentials.isEmpty else {
                            throw OrbitManagerError.invalidInput("凭据不存在")
                        }
                        let output = try await orbit.executeRemoteCommandAsync(
                            ip: server.host,
                            port: server.port,
                            username: server.username,
                            password: credentials.password,
                            privateKeyContent: credentials.privateKeyContent,
                            privateKeyPassphrase: credentials.privateKeyPassphrase,
                            allowPasswordFallback: server.allowPasswordFallback,
                            command: command
                        )
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        return BatchCommandReceipt(
                            serverName: server.name,
                            endpoint: server.endpointText,
                            durationMs: ms,
                            success: true,
                            output: output
                        )
                    } catch {
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        return BatchCommandReceipt(
                            serverName: server.name,
                            endpoint: server.endpointText,
                            durationMs: ms,
                            success: false,
                            output: error.localizedDescription
                        )
                    }
                }
            }

            for await receipt in group {
                guard accepts(lease, scope: scope) else {
                    group.cancelAll()
                    break
                }
                receipts.append(receipt)
                receipts.sort { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
            }
        }

        guard accepts(lease, scope: scope) else { return }
        let okCount = receipts.filter(\.success).count
        summaryText = "执行完成：成功 \(okCount) / \(receipts.count)"
        isRunning = false
        #else
        guard accepts(lease, scope: scope) else { return }
        summaryText = "当前构建要求使用已验证会话"
        isRunning = false
        #endif
    }

    private func runCheckedBatchCommand(
        command: String,
        targets: [ServerEntry],
        lease: PageOperationLease,
        scope: OperationScope
    ) async {
        guard accepts(lease, scope: scope) else { return }
        summaryText = "正在使用已保存凭据准备目标会话…"
        var preparationFailures: [String: String] = [:]
        for target in targets where SessionManager.shared.verifiedSessionLease(for: target.id) == nil {
            guard accepts(lease, scope: scope) else { return }
            if let reason = await SessionManager.shared.prepareVerifiedSessionForBatch(server: target) {
                preparationFailures[target.endpointText] = reason
            }
        }

        guard accepts(lease, scope: scope) else { return }
        let checkedTargets = targets.map { server in
            let lease = SessionManager.shared.verifiedSessionLease(for: server.id)
            return CheckedBatchTarget(
                workspaceID: lease?.workspaceID ?? server.id,
                displayName: server.name,
                endpoint: server.endpointText,
                baseSessionID: lease?.baseSessionID
            )
        }

        let results: [CheckedBatchTargetResult]
        do {
            results = try await PageOperationTimeout.perform(timeout: PageOperationTimeout.batchCommand) {
                await checkedBatchService.execute(
                    command: command,
                    targets: checkedTargets,
                    options: .defaults
                )
            }
        } catch {
            if runOwner.timeoutReached(lease) {
                runOwner.cancel(.timedOut)
            }
            guard accepts(lease, scope: scope) else { return }
            summaryText = "批量命令未完成，请检查会话后重试。"
            isRunning = false
            return
        }
        guard accepts(lease, scope: scope) else { return }
        receipts = results.map { result in
            let preparationFailure = preparationFailures[result.endpoint]
            return BatchCommandReceipt(
                serverName: result.displayName,
                endpoint: result.endpoint,
                durationMs: result.durationMS,
                success: preparationFailure == nil && result.succeeded,
                output: preparationFailure.map { "连接失败：\($0)" } ?? result.displayOutput
            )
        }
        .sorted {
            $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
        guard accepts(lease, scope: scope) else { return }
        let okCount = receipts.filter(\.success).count
        summaryText = "checked 执行完成：成功 \(okCount) / \(receipts.count)"
        isRunning = false
    }
}
