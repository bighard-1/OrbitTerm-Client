import SwiftUI

struct BulkAddAssetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette

    @ObservedObject var store: ServerStore
    let onFinish: (Int) -> Void

    @EnvironmentObject private var syncService: SyncService
    @State private var rawText = """
    名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容,标签
    Web-01,生产,192.168.1.10,22,root,change-me,ssh,password,,web|prod
    Switch-01,网络,192.168.1.20,23,admin,change-me,telnet,password,,network
    """
    @State private var statusText = "支持带引号的逗号、Tab 或分号格式；单次最多 500 项。"
    @State private var isSaving = false
    @State private var importTask: Task<Void, Never>?
    @State private var importOwner = PageOperationOwner()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("字段顺序：名称、分组、主机、端口、用户名、密码、协议、认证方式、私钥内容、标签")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)

                TextEditor(text: $rawText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)
                    .padding(8)
                    .foregroundStyle(palette.textPrimary.color)
                    .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.borderGlass.color))

                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                    Spacer()
                }

                HStack {
                    Button("取消") { dismiss() }
                    .buttonStyle(ThemedSecondaryButtonStyle())
                    Spacer()
                    Button("导入并同步") {
                        startImport()
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(isSaving)
                }
            }
            .padding(16)
            .navigationTitle("批量添加资产")
            .background {
                ZStack {
                    AppChromeBackground()
                    palette.surfaceReadable.color.opacity(0.8)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
            cancelImport(.accountLocked)
            rawText = ""
        }
        .onDisappear { cancelImport(.pageDisappeared) }
        .onChange(of: session.username) { _, _ in cancelImport(.accountChanged) }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if !authenticated { cancelImport(.accountSignedOut) }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { cancelImport(.accountLocked) }
        }
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    private var accountOperationScope: OperationScope {
        guard let account = AccountScope(username: session.username) else { return .anonymous }
        return .account(account.storageIdentifier)
    }

    private func startImport() {
        guard importTask == nil, !isSaving else { return }
        let scope = accountOperationScope
        let lease = importOwner.begin(scope: scope, timeout: PageOperationTimeout.assetMutation)
        importTask = Task {
            await importAssets(lease: lease, scope: scope)
            if importOwner.timeoutReached(lease) {
                importOwner.cancel(.timedOut)
                isSaving = false
                statusText = "导入同步超时；已保存的本地资产不会丢失。"
                importTask = nil
                return
            }
            guard accepts(lease, scope: scope) else { return }
            importTask = nil
        }
    }

    private func cancelImport(_ reason: PageOperationCancellationReason) {
        importOwner.cancel(reason)
        importTask?.cancel()
        importTask = nil
        isSaving = false
    }

    private func accepts(_ lease: PageOperationLease, scope: OperationScope) -> Bool {
        !Task.isCancelled && importOwner.accepts(lease, scope: scope)
    }

    @MainActor
    private func importAssets(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        guard !isSaving else { return }
        isSaving = true
        defer { if accepts(lease, scope: scope) { isSaving = false } }

        guard rawText.count <= 1_048_576 else {
            statusText = "导入内容不能超过 1 MB"
            return
        }
        let parsed = Array(parseRows(rawText).prefix(500))
        guard !parsed.isEmpty else {
            statusText = "没有解析到有效资产"
            onFinish(0)
            return
        }

        var existingEndpoints = Set(store.servers.map(endpointKey))
        var imported: [(server: ServerEntry, credentials: ServerCredentials)] = []
        var skipped = 0
        for item in parsed {
            let key = endpointKey(item.server)
            guard !existingEndpoints.contains(key) else {
                skipped += 1
                continue
            }
            if store.addOrUpdate(item.server, credentials: item.credentials) {
                existingEndpoints.insert(key)
                imported.append(item)
            }
        }

        statusText = "已保存 \(imported.count) 个资产，跳过 \(skipped) 个重复项，正在后台同步..."
        await syncImported(imported)
        guard accepts(lease, scope: scope) else { return }
        onFinish(imported.count)
        dismiss()
    }

    private func parseRows(_ text: String) -> [(server: ServerEntry, credentials: ServerCredentials)] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> (ServerEntry, ServerCredentials)? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                let fields = splitRow(line)
                guard fields.count >= 5 else { return nil }
                if fields[0].localizedCaseInsensitiveContains("名称") ||
                    fields[0].localizedCaseInsensitiveContains("name") {
                    return nil
                }

                let name = fields[safe: 0].trimmed
                let group = fields[safe: 1].trimmed
                let host = fields[safe: 2].trimmed
                let port = Int(fields[safe: 3].trimmed) ?? 22
                let username = fields[safe: 4].trimmed
                let password = fields[safe: 5].trimmed
                let transportRaw = fields[safe: 6].trimmed.lowercased()
                let authRaw = fields[safe: 7].trimmed.lowercased()
                let keyContent = fields[safe: 8].trimmed
                    .replacingOccurrences(of: "\\r\\n", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                let tags = fields[safe: 9]
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "|" })
                    .map { String($0).trimmed }

                guard !host.isEmpty, !username.isEmpty else { return nil }
                let transport: ServerTransportProtocol = transportRaw == "telnet" ? .telnet : .ssh
                let authMethod: ServerAuthMethod = authRaw == "key" || !keyContent.isEmpty ? .key : .password
                let server = ServerEntry(
                    name: name.isEmpty ? host : name,
                    group: group,
                    tags: tags,
                    host: host,
                    port: max(1, min(65535, port)),
                    username: username,
                    authMethod: authMethod,
                    transport: transport,
                    allowPasswordFallback: !password.isEmpty
                )
                let credentials = ServerCredentials(password: password, privateKeyContent: keyContent)
                return (server, credentials)
            }
    }

    private func splitRow(_ line: String) -> [String] {
        let delimiter: Character = line.contains("\t") ? "\t" : (line.contains(";") && !line.contains(",") ? ";" : ",")
        var fields: [String] = []
        var current = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "\"", quoted, next < line.endIndex, line[next] == "\"" {
                current.append("\"")
                index = line.index(after: next)
                continue
            }
            if character == "\"" {
                quoted.toggle()
            } else if character == delimiter, !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = next
        }
        guard !quoted else { return [] }
        fields.append(current)
        return fields
    }

    private func endpointKey(_ server: ServerEntry) -> String {
        "\(server.username.lowercased())@\(server.host.lowercased()):\(server.port)"
    }

    private func syncImported(_ items: [(server: ServerEntry, credentials: ServerCredentials)]) async {
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        let accountID = session.username
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for item in items {
            let portable = item.server.makePortableConfig(
                savedAtUnix: Int(Date().timeIntervalSince1970),
                credentials: item.credentials
            )
            guard let data = try? encoder.encode(portable),
                  let plain = String(data: data, encoding: .utf8) else { continue }
            _ = await syncService.uploadEncryptedConfig(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID,
                plaintextConfig: plain,
                vectorClock: ["client": Int(Date().timeIntervalSince1970)],
                allowQueueOnNetworkFailure: true
            )
        }
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String {
        indices.contains(index) ? self[index] : ""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
