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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.securitySemanticPalette) private var securityPalette

    @State private var selectedServerIDs: Set<UUID> = []
    @State private var selectedGroups: Set<String> = []
    @State private var commandText = ""
    @State private var isRunning = false
    @State private var receipts: [BatchCommandReceipt] = []
    @State private var summaryText = "请选择资产或分组，然后输入命令执行。"

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    private let vault = CredentialVault.shared
    private let orbit = OrbitManager()
    #endif
    private let checkedBatchService = CheckedBatchCommandService(
        client: OrbitCoreCheckedFFIClient.live(
            credentialProvider: CredentialVaultCheckedProvider()
        )
    )

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                selectionPane
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                Divider()
                commandPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("多资产命令执行")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("执行命令") {
                        Task { await runBatchCommand() }
                    }
                    .disabled(!canExecute)
                }
            }
        }
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择分组")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if store.groupedServers.isEmpty {
                Text("暂无分组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.groupedServers, id: \.group) { section in
                            let isOn = selectedGroups.contains(section.group)
                            Button {
                                if isOn {
                                    selectedGroups.remove(section.group)
                                } else {
                                    selectedGroups.insert(section.group)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                    Text("\(section.group) (\(section.items.count))")
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
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
                    ForEach(store.servers) { server in
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
                    "\(targetsWithoutVerifiedSession.count) 台目标尚未建立已验证的 SSH 会话。请先从资产列表打开并完成主机身份确认。",
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
        store.servers.filter {
            selectedServerIDs.contains($0.id) || selectedGroups.contains($0.displayGroup)
        }
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
        !isRunning
            && !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveTargets.isEmpty
            && targetsWithoutVerifiedSession.isEmpty
    }

    private func runBatchCommand() async {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let targets = effectiveTargets
        guard !targets.isEmpty else { return }
        guard targetsWithoutVerifiedSession.isEmpty else {
            summaryText = "请先为全部目标建立已验证的 SSH 会话；批量命令不会自动连接或跳过主机身份确认。"
            return
        }

        isRunning = true
        receipts = []
        if SessionManager.shared.connectionSecurityPolicy.requiresCheckedNetwork {
            await runCheckedBatchCommand(command: command, targets: targets)
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
                receipts.append(receipt)
                receipts.sort { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
            }
        }

        let okCount = receipts.filter(\.success).count
        summaryText = "执行完成：成功 \(okCount) / \(receipts.count)"
        isRunning = false
        #else
        summaryText = "当前构建要求使用已验证会话"
        isRunning = false
        #endif
    }

    private func runCheckedBatchCommand(command: String, targets: [ServerEntry]) async {
        summaryText = "checked mode：仅对已验证会话执行 Batch 命令..."
        let checkedTargets = targets.map { server in
            let lease = SessionManager.shared.verifiedSessionLease(for: server.id)
            return CheckedBatchTarget(
                workspaceID: lease?.workspaceID ?? server.id,
                displayName: server.name,
                endpoint: server.endpointText,
                baseSessionID: lease?.baseSessionID
            )
        }

        let results = await checkedBatchService.execute(
            command: command,
            targets: checkedTargets,
            options: .defaults
        )
        receipts = results.map { result in
            BatchCommandReceipt(
                serverName: result.displayName,
                endpoint: result.endpoint,
                durationMs: result.durationMS,
                success: result.succeeded,
                output: result.displayOutput
            )
        }
        .sorted {
            $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
        let okCount = receipts.filter(\.success).count
        summaryText = "checked 执行完成：成功 \(okCount) / \(receipts.count)"
        isRunning = false
    }
}
