import SwiftUI

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @ObservedObject var store: ServerStore
    var onSaveAndConnect: (ServerEntry) -> Void

    @StateObject private var syncService = SyncService()
    @StateObject private var orbitManager = OrbitManager()

    @State private var name: String = ""
    @State private var group: String = ""
    @State private var host: String = ""
    @State private var port: Int = 22
    @State private var username: String = ""
    @State private var authMethod: ServerAuthMethod = .password
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""

    @State private var isTestingConnection = false
    @State private var isSaving = false
    @State private var testStatus = "尚未测试"
    @State private var isConnectionVerified = false

    @State private var showAdvanced = false
    @State private var testTimeoutSec = 8

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("主机信息") {
                        iconField("tag.fill", "名称", text: $name)
                        iconField("tray.full.fill", "分组（可选）", text: $group)
                        iconField("network", "IP 地址", text: $host)

                        HStack {
                            Label("端口", systemImage: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Stepper(value: $port, in: 1...65535) {
                                Text("\(port)")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 90, idealWidth: 130, maxWidth: 160, alignment: .trailing)
                        }
                    }

                    Section("认证") {
                        iconField("person.fill", "用户名", text: $username)

                        Picker("认证方式", selection: $authMethod) {
                            ForEach(ServerAuthMethod.allCases) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)

                        if authMethod == .password {
                            secureRow("lock.fill", "密码", text: $password)
                        } else {
                            iconField("key.fill", "密钥名称（如 id_rsa）", text: $privateKeyPath)
                            Text("当前版本连接测试与自动连接仅支持密码认证。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                        Stepper(value: $testTimeoutSec, in: 3...20) {
                            Text("连接测试超时：\(testTimeoutSec) 秒")
                        }
                        .padding(.top, 2)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(.clear)
                .font(.system(.body, design: .rounded))

                statusBar

                HStack(spacing: 10) {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)

                    Button(isSaving ? "保存中..." : "保存并连接") {
                        Task { await saveAndConnect() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: saveButtonEnabled
                                        ? [Color(red: 0.25, green: 0.58, blue: 1.0), Color(red: 0.09, green: 0.38, blue: 0.88)]
                                        : [Color.gray.opacity(0.45), Color.gray.opacity(0.4)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .foregroundStyle(.white)
                    .disabled(!saveButtonEnabled || isSaving)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .navigationTitle("添加服务器")
            .background(.ultraThinMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#if os(macOS)
            .frame(minWidth: 500, minHeight: 650)
#endif
            .padding(12)
            .onChange(of: name) { _, _ in invalidateVerification() }
            .onChange(of: host) { _, _ in invalidateVerification() }
            .onChange(of: username) { _, _ in invalidateVerification() }
            .onChange(of: port) { _, _ in invalidateVerification() }
            .onChange(of: authMethod) { _, _ in invalidateVerification() }
            .onChange(of: password) { _, _ in invalidateVerification() }
            .onChange(of: privateKeyPath) { _, _ in invalidateVerification() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isTestingConnection {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试连接...")
                    .foregroundStyle(.secondary)
            } else if isConnectionVerified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("连接测试成功，可直接保存并连接")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text(testStatus)
                    .foregroundStyle(statusColor(testStatus))
            }

            Spacer()

            Button("测试连接") {
                Task { await testConnection() }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingConnection || !canTestConnection)
        }
        .font(.system(.body, design: .rounded))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.secondary.opacity(0.1)), alignment: .top)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (authMethod == .password ? !password.isEmpty : !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var saveButtonEnabled: Bool {
        canSave && (authMethod == .key || isConnectionVerified)
    }

    private var canTestConnection: Bool {
        authMethod == .password &&
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty
    }

    private func iconField(_ icon: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
        }
        .padding(.vertical, 6)
    }

    private func secureRow(_ icon: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func invalidateVerification() {
        isConnectionVerified = false
        if !isTestingConnection {
            testStatus = "尚未测试"
        }
    }

    private func testConnection() async {
        guard canTestConnection else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask(priority: .userInitiated) {
                    await orbitManager.testConnectionAsync(ip: host, username: username, password: password)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(testTimeoutSec) * 1_000_000_000)
                    throw SFTPError.timeout
                }

                guard let first = try await group.next() else {
                    throw SFTPError.invalidResponse
                }
                group.cancelAll()
                return first
            }

            if result.hasPrefix("成功") {
                testStatus = "连接测试成功"
                isConnectionVerified = true
            } else {
                testStatus = result
                isConnectionVerified = false
            }
        } catch {
            testStatus = "连接测试失败: \(error.localizedDescription)"
            isConnectionVerified = false
        }
    }

    private func saveAndConnect() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        let server = ServerEntry(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            group: group.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            password: authMethod == .password ? password : "",
            privateKeyPath: authMethod == .key ? privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )

        store.addOrUpdate(server)
        onSaveAndConnect(server)

        let token = session.readToken()
        let masterPassword = session.readMasterPassword()

        dismiss()
        session.showTransientStatus("已保存并连接")

        Task(priority: .background) {
            await silentSync(server, token: token, masterPassword: masterPassword)
        }
    }

    private func silentSync(_ server: ServerEntry, token: String?, masterPassword: String?) async {
        guard let token, let masterPassword else {
            session.showTransientStatus("已本地保存，登录后将自动同步")
            return
        }

        let portable = server.makePortableConfig(savedAtUnix: Int(Date().timeIntervalSince1970))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let jsonData = try? encoder.encode(portable),
              let plaintext = String(data: jsonData, encoding: .utf8) else {
            session.showTransientStatus("同步暂不可用，已本地保存")
            return
        }

        let vectorClock = ["client": Int(Date().timeIntervalSince1970)]
        let ok = await syncService.uploadEncryptedConfig(
            token: token,
            masterPassword: masterPassword,
            plaintextConfig: plaintext,
            vectorClock: vectorClock
        )

        if !ok {
            session.showTransientStatus("云端同步失败，稍后自动重试")
        }
    }

    private func statusColor(_ text: String) -> Color {
        if text.contains("成功") { return .green }
        if text.contains("失败") { return .red }
        if text.contains("测试") || text.contains("尚未") { return .secondary }
        return .secondary
    }
}
