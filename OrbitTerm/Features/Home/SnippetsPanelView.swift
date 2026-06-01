import SwiftUI

struct SnippetsPanelView: View {
    @EnvironmentObject private var appSession: AppSession
    @ObservedObject var snippetStore: SnippetStore

    let session: WorkspaceSession?
    let onInsertCommand: (String, Bool) -> Void

    @State private var query: String = ""
    @State private var editorTarget: Snippet?
    @State private var editorDraft = SnippetEditorDraft()
    @State private var variablePrompt: SnippetVariablePrompt?
    @State private var deleteTarget: Snippet?
    @FocusState private var focusedVariableKey: String?

    private var filtered: [Snippet] {
        snippetStore.filteredSnippets(query: query)
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

            Text(snippet.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Button("插入") {
                    triggerSnippet(snippet, executeImmediately: false)
                }
                .buttonStyle(.bordered)
                .disabled(session == nil)

                Button("执行") {
                    triggerSnippet(snippet, executeImmediately: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session == nil)

                Spacer(minLength: 0)

                Text(snippet.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button("插入到终端") {
                triggerSnippet(snippet, executeImmediately: false)
            }
            Button("立即执行") {
                triggerSnippet(snippet, executeImmediately: true)
            }
            Button("编辑") {
                startEditSnippet(snippet)
            }
            Button("删除", role: .destructive) {
                deleteTarget = snippet
            }
        }
        .onTapGesture {
            triggerSnippet(snippet, executeImmediately: false)
        }
        .onTapGesture(count: 2) {
            triggerSnippet(snippet, executeImmediately: true)
        }
    }

    private func snippetEditorSheet(for target: Snippet) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("标题", text: $editorDraft.title)
                    .textFieldStyle(.roundedBorder)

                TextField("分类", text: $editorDraft.category)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $editorDraft.command)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(minHeight: 220)

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
                        let isCreate = target.id == UUID.snippetDraftID
                        editorTarget = nil
                        Task {
                            if isCreate {
                                await snippetStore.addSnippet(
                                    title: title,
                                    command: command,
                                    category: category,
                                    token: appSession.readToken(),
                                    masterPassword: appSession.readMasterPassword()
                                )
                            } else {
                                await snippetStore.updateSnippet(
                                    target,
                                    title: title,
                                    command: command,
                                    category: category,
                                    token: appSession.readToken(),
                                    masterPassword: appSession.readMasterPassword()
                                )
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
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

                    Button(prompt.executeImmediately ? "填入并执行" : "填入终端") {
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
        onInsertCommand(command, variablePrompt.executeImmediately)
        self.variablePrompt = nil
    }

    private func nextVariableKey(after key: String, in keys: [String]) -> String? {
        guard let idx = keys.firstIndex(of: key), idx + 1 < keys.count else { return nil }
        return keys[idx + 1]
    }

    private func startCreateSnippet() {
        let seed = Snippet(id: .snippetDraftID, title: "", command: "", category: "未分类")
        editorDraft = SnippetEditorDraft()
        editorTarget = seed
    }

    private func startEditSnippet(_ snippet: Snippet) {
        editorDraft = SnippetEditorDraft(
            title: snippet.title,
            command: snippet.command,
            category: snippet.category
        )
        editorTarget = snippet
    }

    private func triggerSnippet(_ snippet: Snippet, executeImmediately: Bool) {
        guard session != nil else { return }
        let keys = SnippetVariableResolver.extractVariables(from: snippet.command)
        if !keys.isEmpty {
            var values: [String: String] = [:]
            keys.forEach { values[$0] = "" }
            variablePrompt = SnippetVariablePrompt(
                snippet: snippet,
                executeImmediately: executeImmediately,
                variableValues: values
            )
            return
        }

        onInsertCommand(snippet.command, executeImmediately)
    }
}
