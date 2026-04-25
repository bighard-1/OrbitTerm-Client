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

    @State private var showAdvanced = false
    @State private var testTimeoutSec = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("名称", text: $name)
                    TextField("分组（可选）", text: $group)
                }

                Section("连接信息") {
                    TextField("IP 地址", text: $host)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif

                    Stepper(value: $port, in: 1...65535) {
                        HStack {
                            Text("端口")
                            Spacer()
                            Text("\(port)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("用户名", text: $username)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif

                    Picker("认证方式", selection: $authMethod) {
                        ForEach(ServerAuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .password {
                        SecureField("密码", text: $password)
                    } else {
                        TextField("密钥名称（如 id_rsa）", text: $privateKeyPath)
#if os(iOS)
                            .textInputAutocapitalization(.never)
#endif
                        Text("当前版本连接测试与自动连接仅支持密码认证。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                    Stepper(value: $testTimeoutSec, in: 3...20) {
                        Text("连接测试超时：\(testTimeoutSec) 秒")
                    }
                    Text("高级参数仅影响本地连接检测，不会改变你的日常使用界面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("连接检查") {
                    Button(isTestingConnection ? "测试中..." : "一键测试连接") {
                        Task { await testConnection() }
                    }
                    .disabled(isTestingConnection || !canTestConnection)

                    Text(testStatus)
                        .foregroundStyle(statusColor(testStatus))
                        .font(.callout)
                }

                Section("保存") {
                    Button(isSaving ? "保存中..." : "保存并连接") {
                        Task { await saveAndConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !canSave)
                }
            }
            .navigationTitle("添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (authMethod == .password ? !password.isEmpty : !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canTestConnection: Bool {
        authMethod == .password &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private func testConnection() async {
        guard canTestConnection else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }

        testStatus = "正在测试连接..."

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

            testStatus = result.hasPrefix("成功") ? "连接测试成功" : result
        } catch {
            testStatus = "连接测试失败: \(error.localizedDescription)"
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

        // 后台静默同步：失败仅显示轻提示，不打断当前 SSH 工作流。
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
        if text.contains("测试") { return .orange }
        return .secondary
    }
}
