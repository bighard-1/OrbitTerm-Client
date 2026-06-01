import SwiftUI

struct DockerManagerView: View {
    @StateObject private var service = DockerService()
    @ObservedObject private var sessionManager = SessionManager.shared

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var renamingContainer: DockerContainerCard?
    @State private var renameTargetName: String = ""
    @State private var editingContainer: DockerContainerCard?
    @State private var restartPolicy: String = "unless-stopped"
    @State private var memoryLimit: String = ""
    @State private var cpuSharesText: String = ""
    private let vault = CredentialVault.shared
    
    private var effectiveService: DockerService {
        resolvePreferredSession()?.dockerService ?? service
    }

    var body: some View {
        Group {
            if !effectiveService.isConnected {
                connectPanel
            } else {
                containerList
            }
        }
        .navigationTitle("Docker 管理")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await autoBindActiveSessionIfNeeded()
        }
        .alert("编辑容器名称", isPresented: Binding(
            get: { renamingContainer != nil },
            set: { shown in
                if !shown {
                    renamingContainer = nil
                    renameTargetName = ""
                }
            }
        )) {
            TextField("新容器名称", text: $renameTargetName)
            Button("取消", role: .cancel) {}
            Button("确认") {
                guard let target = renamingContainer else { return }
                Task {
                    await effectiveService.renameContainer(containerID: target.id, newName: renameTargetName)
                }
                renamingContainer = nil
                renameTargetName = ""
            }
            .disabled(renameTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("请输入新的容器名称")
        }
        .sheet(item: $editingContainer) { container in
            NavigationStack {
                Form {
                    Section("重启策略") {
                        Picker("策略", selection: $restartPolicy) {
                            Text("no").tag("no")
                            Text("on-failure").tag("on-failure")
                            Text("always").tag("always")
                            Text("unless-stopped").tag("unless-stopped")
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("资源限制") {
                        TextField("内存限制（如 512m / 1g）", text: $memoryLimit)
                            .applyInputPolish()
                        TextField("CPU Shares（如 128 / 512）", text: $cpuSharesText)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .applyInputPolish()
                    }
                }
                .navigationTitle("编辑 \(container.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editingContainer = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            Task {
                                await effectiveService.updateContainer(
                                    containerID: container.id,
                                    options: DockerContainerUpdateOptions(
                                        restartPolicy: restartPolicy,
                                        memoryLimit: memoryLimit,
                                        cpuShares: Int(cpuSharesText)
                                    )
                                )
                                editingContainer = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectPanel: some View {
        Form {
            if let preferred = resolvePreferredSession() {
                Section("自动关联资产") {
                    HStack {
                        Text("当前资产")
                        Spacer()
                        Text(preferred.server.name)
                            .foregroundStyle(.secondary)
                    }
                    Text("点击下方“连接 Docker”将优先复用该资产的会话凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("SSH 信息") {
                TextField("主机/IP", text: $host)
                    .applyInputPolish()
                TextField("用户名", text: $username)
                    .applyInputPolish()
                SecureField("密码", text: $password)
            }

            Section("操作") {
                Button("连接 Docker") {
                    Task {
                        if let preferred = resolvePreferredSession(),
                           let creds = try? vault.read(for: preferred.server.credentialID),
                           !creds.isEmpty {
                            await preferred.dockerService.connect(
                                host: preferred.server.host,
                                port: preferred.server.port,
                                username: preferred.server.username,
                                password: creds.password,
                                privateKeyContent: creds.privateKeyContent,
                                privateKeyPassphrase: creds.privateKeyPassphrase,
                                allowPasswordFallback: preferred.server.allowPasswordFallback
                            )
                        } else {
                            await effectiveService.connect(host: host, username: username, password: password)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectiveService.isLoading)
            }

            Section("状态") {
                Text(effectiveService.statusText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var containerList: some View {
        List {
            Section {
                ForEach(effectiveService.cards) { card in
                    NavigationLink(destination: DockerLogStreamView(service: effectiveService, container: card)) {
                        DockerCardView(card: card)
                    }
                    .contextMenu {
                        ForEach(DockerAction.allCases, id: \.self) { action in
                            Button(action.label) {
                                Task { await effectiveService.performAction(containerID: card.id, action: action) }
                            }
                        }
                        Button("编辑") {
                            renamingContainer = card
                            renameTargetName = card.name
                        }
                        Button("高级编辑") {
                            restartPolicy = "unless-stopped"
                            memoryLimit = ""
                            cpuSharesText = ""
                            editingContainer = card
                        }
                    }
                }
            } header: {
                HStack {
                    Text("容器列表")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(effectiveService.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") {
                    Task { try? await effectiveService.refreshNow() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("断开") {
                    Task { await effectiveService.disconnect() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private extension DockerManagerView {
    func resolvePreferredSession() -> WorkspaceSession? {
        if let active = sessionManager.activeSession {
            return active
        }
        if let selected = ServerStore.shared.selectedServer {
            return sessionManager.tabs.first(where: { $0.server.id == selected.id })
        }
        return sessionManager.tabs.first
    }

    func autoBindActiveSessionIfNeeded() async {
        guard let active = resolvePreferredSession() else { return }
        guard active.isConnected, active.server.transport == .ssh else { return }
        if active.dockerService.isConnected { return }
        guard let creds = try? vault.read(for: active.server.credentialID), !creds.isEmpty else { return }
        await active.dockerService.connect(
            host: active.server.host,
            port: active.server.port,
            username: active.server.username,
            password: creds.password,
            privateKeyContent: creds.privateKeyContent,
            privateKeyPassphrase: creds.privateKeyPassphrase,
            allowPasswordFallback: active.server.allowPasswordFallback
        )
    }
}
