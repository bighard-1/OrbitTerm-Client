import SwiftUI

struct SnippetsPanelView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @ObservedObject var snippetStore: SnippetStore

    let session: WorkspaceSession?
    let onInsertCommand: (String, Bool) -> Void

    @State private var query: String = ""
    @State private var editorTarget: Snippet?
    @State private var editorDraft = SnippetEditorDraft()
    @State private var editorRestrictsAssets = false
    @State private var editorAssetIDs: Set<UUID> = []
    @State private var variablePrompt: SnippetVariablePrompt?
    @State private var deleteTarget: Snippet?
    @State private var batchRequest: SnippetBatchRequest?
    @FocusState private var focusedVariableKey: String?

    private var filtered: [Snippet] {
        snippetStore.filteredSnippets(query: query, assetID: session?.server.id)
    }

    private var grouped: [(group: String, items: [Snippet])] {
        let groups = Dictionary(grouping: filtered, by: { item in
            let trimmed = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "未分类" : trimmed
        })

        return groups
            .map { key, value in (key, value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Snippets")
                    .font(.headline)
                Spacer()
                historyMenu
                Button {
                    startCreateSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            TextField("搜索标题 / 命令 / 分类", text: $query)
                .textFieldStyle(.roundedBorder)

            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "暂无命令片段" : "未找到匹配项",
                    systemImage: "text.badge.plus"
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped, id: \.0) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.0)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(section.1) { snippet in
                                    snippetCard(snippet)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 180)
            }

            Text(snippetStore.lastSyncMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editorTarget) { target in
            snippetEditorSheet(for: target)
        }
        .alert("删除 Snippet", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) {
                deleteTarget = nil
            }
            Button("删除", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task {
                    await snippetStore.deleteSnippet(
                        target,
                        token: appSession.readToken(),
                        masterPassword: appSession.readMasterPassword()
                    )
                }
            }
        } message: {
            Text("将删除该命令片段，此变更会同步到其他设备。")
        }
        .sheet(item: $variablePrompt) { prompt in
            snippetVariableSheet(prompt: prompt)
        }
#if os(iOS)
        .sheet(item: $batchRequest) { request in
            BatchCommandRunnerView(
                store: serverStore,
                initialCommand: request.command,
                allowedServerIDs: request.allowedServerIDs
            )
            .environmentObject(appSession)
        }
#endif
    }

    @ViewBuilder
    private var historyMenu: some View {
        Menu {
            let history = session?.commandHistory ?? []
            if history.isEmpty {
                Text("暂无终端历史")
            } else {
                ForEach(Array(history.prefix(12).enumerated()), id: \.offset) { _, item in
                    Button(item) {
                        Task {
                            await snippetStore.quickSaveFromHistory(
                                command: item,
                                token: appSession.readToken(),
                                masterPassword: appSession.readMasterPassword()
                            )
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .buttonStyle(.borderless)
        .help("从终端历史一键保存")
    }

    private func snippetCard(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snippet.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(snippet.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ShellSyntaxHighlightedText(snippet.command, lineLimit: 3)

            HStack(spacing: 8) {
                Button("插入") {
                    triggerSnippet(snippet, invocation: .insert)
                }
                .buttonStyle(.bordered)
                .disabled(session == nil)

                Button("执行") {
                    triggerSnippet(snippet, invocation: .execute)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session == nil)

#if os(iOS)
                Button("批量") {
                    triggerSnippet(snippet, invocation: .batch)
                }
                .buttonStyle(.bordered)
#endif

                Spacer(minLength: 0)

                Text(snippet.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if snippet.assetScope.isRestricted {
                    Label("限 \(snippet.assetScope.assetIDs.count) 台资产", systemImage: "lock.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("此命令片段仅可用于 \(snippet.assetScope.assetIDs.count) 台指定资产")
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button("插入到终端") {
                triggerSnippet(snippet, invocation: .insert)
            }
            Button("立即执行") {
                triggerSnippet(snippet, invocation: .execute)
            }
#if os(iOS)
            Button("批量执行") {
                triggerSnippet(snippet, invocation: .batch)
            }
#endif
            Button("编辑") {
                startEditSnippet(snippet)
            }
            Button("删除", role: .destructive) {
                deleteTarget = snippet
            }
        }
        .onTapGesture {
            triggerSnippet(snippet, invocation: .insert)
        }
        .onTapGesture(count: 2) {
            triggerSnippet(snippet, invocation: .execute)
        }
    }

    private func snippetEditorSheet(for target: Snippet) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("标题", text: $editorDraft.title)
                    .textFieldStyle(.roundedBorder)

                TextField("分类", text: $editorDraft.category)
                    .textFieldStyle(.roundedBorder)

                Toggle("仅允许指定资产使用", isOn: $editorRestrictsAssets)

                if editorRestrictsAssets {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("允许执行的资产")
                            .font(.subheadline.weight(.medium))

                        if serverStore.servers.isEmpty {
                            Text("暂无可选资产。请先添加资产，或取消此限制。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(serverStore.servers) { server in
                                        let isSelected = editorAssetIDs.contains(server.id)
                                        Button {
                                            if isSelected {
                                                editorAssetIDs.remove(server.id)
                                            } else {
                                                editorAssetIDs.insert(server.id)
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(server.name)
                                                    Text(server.endpointText)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(isSelected ? "取消允许 \(server.name) 使用此命令片段" : "允许 \(server.name) 使用此命令片段")
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                        }

                        if editorAssetIDs.isEmpty {
                            Text("请至少选择一台资产，或关闭限制。")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                TextEditor(text: $editorDraft.command)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(minHeight: 220)

                if !editorDraft.command.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("代码预览")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ShellSyntaxHighlightedText(editorDraft.command, lineLimit: 4)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    Button("取消") {
                        editorTarget = nil
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("保存") {
                        let title = editorDraft.title
                        let command = editorDraft.command
                        let category = editorDraft.category
                        let assetScope = editorRestrictsAssets
                            ? SnippetAssetScope.selectedAssets(editorAssetIDs)
                            : .allAssets
                        let isCreate = target.id == UUID.snippetDraftID
                        editorTarget = nil
                        Task {
                            if isCreate {
                                await snippetStore.addSnippet(
                                    title: title,
                                    command: command,
                                    category: category,
                                    assetScope: assetScope,
                                    token: appSession.readToken(),
                                    masterPassword: appSession.readMasterPassword()
                                )
                            } else {
                                await snippetStore.updateSnippet(
                                    target,
                                    title: title,
                                    command: command,
                                    category: category,
                                    assetScope: assetScope,
                                    token: appSession.readToken(),
                                    masterPassword: appSession.readMasterPassword()
                                )
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editorRestrictsAssets && editorAssetIDs.isEmpty)
                }
            }
            .padding(14)
            .navigationTitle(target.id == UUID.snippetDraftID ? "新建 Snippet" : "编辑 Snippet")
        }
#if os(macOS)
        .frame(minWidth: 600, minHeight: 420)
#endif
    }

    private func snippetVariableSheet(prompt: SnippetVariablePrompt) -> some View {
        let keys = Array(prompt.variableValues.keys).sorted()
        return NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("检测到变量占位符，请先填写：")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(keys, id: \.self) { key in
                    TextField(key, text: Binding(
                        get: { variablePrompt?.variableValues[key] ?? "" },
                        set: { variablePrompt?.variableValues[key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedVariableKey, equals: key)
                    .submitLabel(nextVariableKey(after: key, in: keys) == nil ? .done : .next)
                    .onSubmit {
                        if let next = nextVariableKey(after: key, in: keys) {
                            focusedVariableKey = next
                        } else {
                            executeVariablePromptIfReady()
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack {
                    Button("取消") {
                        variablePrompt = nil
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(promptButtonTitle(prompt.invocation)) {
                        executeVariablePromptIfReady()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .navigationTitle("Snippet 变量")
            .onAppear {
                if let first = keys.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedVariableKey = first
                    }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 240)
#endif
    }

    private func executeVariablePromptIfReady() {
        guard let variablePrompt else { return }
        let command = SnippetVariableResolver.resolve(
            variablePrompt.snippet.command,
            values: variablePrompt.variableValues
        )
        switch variablePrompt.invocation {
        case .insert:
            onInsertCommand(command, false)
        case .execute:
            onInsertCommand(command, true)
        case .batch:
            batchRequest = SnippetBatchRequest(
                command: command,
                allowedServerIDs: variablePrompt.snippet.assetScope.isRestricted
                    ? variablePrompt.snippet.assetScope.assetIDs
                    : nil
            )
        }
        self.variablePrompt = nil
    }

    private func nextVariableKey(after key: String, in keys: [String]) -> String? {
        guard let idx = keys.firstIndex(of: key), idx + 1 < keys.count else { return nil }
        return keys[idx + 1]
    }

    private func startCreateSnippet() {
        let seed = Snippet(id: .snippetDraftID, title: "", command: "", category: "未分类")
        editorDraft = SnippetEditorDraft()
        editorRestrictsAssets = false
        editorAssetIDs = []
        editorTarget = seed
    }

    private func startEditSnippet(_ snippet: Snippet) {
        editorDraft = SnippetEditorDraft(
            title: snippet.title,
            command: snippet.command,
            category: snippet.category
        )
        editorRestrictsAssets = snippet.assetScope.isRestricted
        editorAssetIDs = snippet.assetScope.assetIDs
        editorTarget = snippet
    }

    private func triggerSnippet(_ snippet: Snippet, invocation: SnippetInvocation) {
        if invocation != .batch, session == nil { return }
        let keys = SnippetVariableResolver.extractVariables(from: snippet.command)
        if !keys.isEmpty {
            var values: [String: String] = [:]
            keys.forEach { values[$0] = "" }
            variablePrompt = SnippetVariablePrompt(
                snippet: snippet,
                invocation: invocation,
                variableValues: values
            )
            return
        }

        switch invocation {
        case .insert:
            onInsertCommand(snippet.command, false)
        case .execute:
            onInsertCommand(snippet.command, true)
        case .batch:
            batchRequest = SnippetBatchRequest(
                command: snippet.command,
                allowedServerIDs: snippet.assetScope.isRestricted ? snippet.assetScope.assetIDs : nil
            )
        }
    }

    private func promptButtonTitle(_ invocation: SnippetInvocation) -> String {
        switch invocation {
        case .insert: "填入终端"
        case .execute: "填入并执行"
        case .batch: "选择批量目标"
        }
    }
}

private struct SnippetBatchRequest: Identifiable {
    let id = UUID()
    let command: String
    let allowedServerIDs: Set<UUID>?
}
