import SwiftUI

struct BulkAddAssetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette

    @ObservedObject var store: ServerStore
    let onFinish: (Int) -> Void

    @StateObject private var syncService = SyncService.shared
    @State private var rawText = """
    名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容
    Web-01,生产,192.168.1.10,22,root,change-me,ssh,password,
    Switch-01,网络,192.168.1.20,23,admin,change-me,telnet,password,
    """
    @State private var statusText = "支持逗号、Tab 或分号分隔。一行一个资产。"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("字段顺序：名称、分组、主机、端口、用户名、密码、协议、认证方式、私钥内容")
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
                        Task { await importAssets() }
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
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    @MainActor
    private func importAssets() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let parsed = parseRows(rawText)
        guard !parsed.isEmpty else {
            statusText = "没有解析到有效资产"
            onFinish(0)
            return
        }

        for item in parsed {
            store.addOrUpdate(item.server, credentials: item.credentials)
        }

        statusText = "已保存 \(parsed.count) 个资产，正在后台同步..."
        await syncImported(parsed)
        onFinish(parsed.count)
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
                let keyContent = fields.dropFirst(8).joined(separator: ",").trimmingCharacters(in: .whitespacesAndNewlines)

                guard !host.isEmpty, !username.isEmpty else { return nil }
                let transport: ServerTransportProtocol = transportRaw == "telnet" ? .telnet : .ssh
                let authMethod: ServerAuthMethod = authRaw == "key" || !keyContent.isEmpty ? .key : .password
                let server = ServerEntry(
                    name: name.isEmpty ? host : name,
                    group: group,
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
        if line.contains("\t") {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        if line.contains(";") && !line.contains(",") {
            return line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        }
        return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private func syncImported(_ items: [(server: ServerEntry, credentials: ServerCredentials)]) async {
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
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
                accountID: session.username,
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
