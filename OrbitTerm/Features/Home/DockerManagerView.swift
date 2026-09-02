import SwiftUI

struct DockerManagerView: View {
    @StateObject private var service = DockerService()
    @ObservedObject private var sessionManager = SessionManager.shared

    @State private var connectionDraft = DockerConnectionDraft()
    @State private var renameDraft = DockerContainerRenameDraft()
    @State private var editingContainer: DockerContainerCard?
    @State private var inspectingContainer: DockerContainerCard?
    @State private var logContainer: DockerContainerCard?
    @State private var updateDraft = DockerContainerUpdateDraft()
    private let vault = CredentialVault.shared
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    
    private var effectiveService: DockerService {
        resolvePreferredSession()?.dockerService ?? service
    }

    var body: some View {
        ZStack {
            AppChromeBackground()
            Group {
                if !effectiveService.isConnected {
                    connectPanel
                } else {
                    containerList
                }
            }
        }
        .navigationTitle("Docker 管理")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await autoBindActiveSessionIfNeeded()
        }
        .task(id: effectiveService.operationNotice) {
            guard let message = effectiveService.operationNotice,
                  let delay = OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            effectiveService.dismissOperationNotice(message)
        }
        .alert("编辑容器名称", isPresented: Binding(
            get: { renameDraft.isPresented },
            set: { shown in
                if !shown {
                    renameDraft.reset()
                }
            }
        )) {
            TextField("新容器名称", text: $renameDraft.name)
            Button("取消", role: .cancel) {}
            Button("确认") {
                guard let target = renameDraft.target else { return }
                Task {
                    await effectiveService.renameContainer(containerID: target.id, newName: renameDraft.name)
                }
                renameDraft.reset()
            }
            .disabled(!renameDraft.canSubmit)
        } message: {
            Text("请输入新的容器名称")
        }
        .sheet(item: $editingContainer) { container in
            NavigationStack {
                Form {
                    Section("重启策略") {
                        Picker("策略", selection: $updateDraft.restartPolicy) {
                            Text("no").tag("no")
                            Text("on-failure").tag("on-failure")
                            Text("always").tag("always")
                            Text("unless-stopped").tag("unless-stopped")
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("资源限制") {
                        TextField("内存限制（如 512m / 1g）", text: $updateDraft.memoryLimit)
                            .applyInputPolish()
                        TextField("CPU Shares（如 128 / 512）", text: $updateDraft.cpuSharesText)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .applyInputPolish()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(palette.surfaceReadable.color)
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
                                    options: updateDraft.options
                                )
                                editingContainer = nil
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $inspectingContainer) { container in
            NavigationStack {
                DockerContainerDetailsView(container: container)
            }
        }
        .sheet(item: $logContainer) { container in
            NavigationStack {
                DockerLogStreamView(service: effectiveService, container: container)
            }
        }
    }

    private var connectPanel: some View {
        Form {
            if sessionManager.requiresCheckedConnection {
                Section("安全会话") {
                    if let preferred = resolvePreferredSession(),
                       preferred.verifiedSessionLease != nil {
                        HStack {
                            Text("当前资产")
                            Spacer()
                            Text(preferred.server.name)
                                .foregroundStyle(palette.textSecondary.color)
                        }
                        Text("Docker 仅使用该工作区的已验证 SSH 会话。")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)
                    } else {
                        Text("需要已验证会话")
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
                Section("操作") {
                    Button("从当前会话启动 Docker") {
                        Task { await sessionManager.startDockerForActiveSessionIfNeeded() }
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(
                        resolvePreferredSession()?.verifiedSessionLease == nil ||
                            effectiveService.isLoading
                    )
                    Text("不会读取凭据、创建 SFTP 会话或回退到旧连接。")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
            } else if let preferred = resolvePreferredSession() {
                Section("自动关联资产") {
                    HStack {
                        Text("当前资产")
                        Spacer()
                        Text(preferred.server.name)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    Text("点击下方“连接 Docker”将优先复用该资产的会话凭据。")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
            if !sessionManager.requiresCheckedConnection {
                Section("SSH 信息") {
                    TextField("主机/IP", text: $connectionDraft.host)
                        .applyInputPolish()
                    TextField("用户名", text: $connectionDraft.username)
                        .applyInputPolish()
                    SecureField("密码", text: $connectionDraft.password)
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
                                await effectiveService.connect(
                                    host: connectionDraft.host,
                                    username: connectionDraft.username,
                                    password: connectionDraft.password
                                )
                            }
                        }
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(effectiveService.isLoading)
                }
            }

            Section("状态") {
                if let recovery = effectiveService.recoveryPresentation {
                    Label(recovery.message, systemImage: recovery.systemImage)
                        .accessibilityLabel("Docker：\(recovery.title)。\(recovery.message)")
                } else {
                    Text(effectiveService.statusText)
                }
            }
            .foregroundStyle(
                effectiveService.recoveryPresentation?.severity == .danger
                    ? security.danger.color
                    : connectionPresentation.themeColor(in: security, fallback: palette).color
            )
        }
        .scrollContentBackground(.hidden)
        .background(palette.surfaceReadable.color)
    }

    private var containerList: some View {
        let presentation = OperationalContentPresentationMapper.docker(
            isLoading: effectiveService.isLoading || effectiveService.isScanning,
            hasContainers: !effectiveService.cards.isEmpty,
            failureDetail: effectiveService.recoveryPresentation?.message
        )
        let actionPresentation = OperationalContentPresentationMapper.refreshAction(
            module: .docker,
            phase: presentation.phase,
            isRefreshing: effectiveService.isLoading || effectiveService.isScanning,
            hasContent: !effectiveService.cards.isEmpty
        )
        return List {
            if presentation.phase == .failed, !effectiveService.cards.isEmpty {
                Section {
                    OperationalFailureBanner(
                        content: presentation,
                        action: actionPresentation,
                        accessibilityPrefix: "Docker"
                    )
                }
            }
            if let notice = effectiveService.operationNotice {
                Section {
                    OperationalTransientSuccessBanner(message: notice)
                }
            }
            Section {
                if effectiveService.cards.isEmpty {
                    ContentUnavailableView {
                        Label(
                            presentation.headline,
                            systemImage: presentation.phase == .failed
                                ? "exclamationmark.triangle.fill"
                                : "shippingbox"
                        )
                    } description: {
                        Text(presentation.detail)
                    }
                } else {
                    ForEach(effectiveService.cards) { card in
                        NavigationLink(destination: DockerLogStreamView(service: effectiveService, container: card)) {
                            DockerCardView(card: card)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(palette.surfaceReadable.color)
                        .contextMenu {
                            Button("查看详情") {
                                inspectingContainer = card
                            }
                            Button("查看日志") {
                                logContainer = card
                            }
                            Button("复制容器 ID") {
                                TerminalPlatformSupport.copyToClipboard(Data(card.id.utf8), kind: .ordinaryText)
                            }
                            Divider()
                            ForEach(card.availableActions, id: \.self) { action in
                                Button(action.label, role: action.isDestructive ? .destructive : nil) {
                                    Task { await effectiveService.performAction(containerID: card.id, action: action) }
                                }
                            }
                            if effectiveService.isRenameUpdateAvailable {
                                Button("编辑") {
                                    renameDraft.begin(card)
                                }
                                Button("高级编辑") {
                                    updateDraft.reset()
                                    editingContainer = card
                                }
                            } else {
                                Button("重命名与更新将在安全接口完成后启用") {}
                                    .disabled(true)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("容器列表")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(presentation.headline)
                        .font(.caption)
                        .foregroundStyle(presentation.phase == .failed ? security.danger.color : palette.textSecondary.color)
                }
                .padding(.vertical, 2)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(palette.surfaceReadable.color)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                OperationalRefreshButton(presentation: actionPresentation) {
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

    private var connectionPresentation: DockerConnectionPresentationState {
        if effectiveService.isLoading || effectiveService.isScanning { return .connecting }
        if effectiveService.dockerEnvironmentMissing { return .unavailable }
        return effectiveService.isConnected ? .connected : .disconnected
    }
}

/// Presents only metadata supplied by the checked Docker list/stat payloads.
/// It deliberately does not claim to be `docker inspect`: that command needs
/// a dedicated, typed backend contract before it can be exposed safely.
private struct DockerContainerDetailsView: View {
    let container: DockerContainerCard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette

    private var presentation: DockerContainerPresentationState {
        DockerContainerPresentationState.resolve(
            isRunning: container.isRunning,
            isPaused: container.isPaused
        )
    }

    var body: some View {
        List {
            Section("状态") {
                LabeledContent("运行状态") {
                    DockerContainerStatusBadge(presentation: presentation)
                }
                LabeledContent("状态详情", value: container.status)
                LabeledContent("运行时长", value: container.runningFor.isEmpty ? "-" : container.runningFor)
            }

            Section("容器") {
                LabeledContent("名称", value: container.name)
                LabeledContent("镜像", value: container.image)
                LabeledContent("容器 ID") {
                    HStack(spacing: 8) {
                        Text(container.id)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            TerminalPlatformSupport.copyToClipboard(Data(container.id.utf8), kind: .ordinaryText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("复制容器 ID")
                    }
                }
            }

            Section("资源") {
                LabeledContent("CPU", value: String(format: "%.1f%%", container.cpuPercent))
                LabeledContent("内存", value: String(format: "%.1f%%", container.memPercent))
                LabeledContent("内存用量", value: container.memUsage)
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.surfaceReadable.color)
        .navigationTitle("容器详情")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(palette.textPrimary.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("容器详情，\(container.name)，\(presentation.label)")
    }
}

private extension DockerAction {
    var isDestructive: Bool {
        switch self {
        case .kill, .remove: true
        case .start, .stop, .restart, .pause, .unpause: false
        }
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
        guard !sessionManager.requiresCheckedConnection else { return }
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
