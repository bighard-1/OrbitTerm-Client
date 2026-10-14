import SwiftUI

#if os(iOS)
// Hallmark · component-scope · modern-minimal · existing native utility theme.
// System typography, semantic colours and Form layout intentionally stay native.
// Hallmark · pre-emit critique: P4 H4 E4 S4 R5 V3 (component; theme rotation N/A).
struct MobileTerminalCustomKeysView: View {
    @ObservedObject var store: TerminalCustomKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TerminalCustomKeyDraft?
    @State private var undoDraft: TerminalCustomKeyDraft?
    @State private var error: String?
    @State private var conflict: TerminalCustomKeyConflict?
    @State private var recovery = false
    @State private var rescue = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("按键仅保存在当前账户的本机钥匙串，不参与云端同步。点击终端中的按键会立即发送内容；保存和编辑不会发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if store.notice == nil {
                        Button("重试读取") { store.reload() }.disabled(store.lease == nil)
                    }
                }
                if let notice = store.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.lock")
                        Button("重试读取") { store.reload() }
                        Button("原始配置加密救援") { rescue = true; recovery = true }
                            .disabled(store.lease == nil)
                            .accessibilityIdentifier("terminal.customKeys.rescue")
                    }
                } else if store.lease == nil {
                    Section { Label("解锁账户后可管理自定义按键。", systemImage: "lock") }
                } else {
                    Section {
                        Button("按键备份与恢复") { rescue = false; recovery = true }
                            .disabled(!store.canEdit)
                            .accessibilityIdentifier("terminal.customKeys.recovery")
                    }
                    if !store.conflicts.isEmpty {
                        Section("待处理冲突（\(store.conflicts.count)）") {
                            Text("冲突按键暂不显示在终端键栏，也不能发送。选择保留版本或删除后才会恢复确定状态。")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(store.conflicts) { item in
                                Button {
                                    conflict = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.revisions.compactMap { $0.value?.label }.first ?? "已删除按键")
                                        Text("\(item.revisions.count) 个并发版本 · 查看并处理")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("terminal.customKeys.conflict.\(item.id)")
                            }
                        }
                    }
                    ForEach(["common", "symbols"], id: \.self) { section in
                        Section(section == "common" ? "常用" : "符号") {
                            let rows = store.keys.filter { $0.value?.section == section }
                            if rows.isEmpty {
                                Text("尚无自定义按键").foregroundStyle(.secondary)
                            }
                            ForEach(rows, id: \.id) { row in
                                if let value = row.value {
                                    Button {
                                        draft = makeDraft(row.id, value)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(value.label).foregroundStyle(.primary).lineLimit(1)
                                            Text(value.payload).font(.system(.footnote, design: .monospaced))
                                                .foregroundStyle(.primary).lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("编辑按键：\(value.label)")
                                    .accessibilityIdentifier("terminal.customKeys.edit.\(row.id)")
                                    .swipeActions(allowsFullSwipe: false) {
                                        Button("删除", role: .destructive) { delete(row.id, value) }
                                    }
                                }
                            }
                            Button("添加按键") {
                                draft = .init(section: section, order: nextOrder)
                            }
                            .disabled(!store.canEdit || store.keys.count >= 64)
                            .accessibilityIdentifier("terminal.customKeys.add.\(section)")
                        }
                    }
                    if store.keys.count >= 64 {
                        Section { Text("最多保存 64 个自定义按键。删除不再需要的按键后可继续添加。") }
                    }
                }
                if let undoDraft {
                    Section {
                        Text("已删除：\(undoDraft.label)").foregroundStyle(.secondary)
                        Button("撤销删除") {
                            do {
                                try store.save(undoDraft, lease: store.lease)
                                self.undoDraft = nil
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                        .disabled(!store.canEdit)
                        .accessibilityIdentifier("terminal.customKeys.undo")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle") }
                }
            }
            .navigationTitle("自定义按键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $draft) { draft in
                MobileTerminalCustomKeyEditor(store: store, draft: draft, lease: store.lease)
            }
            .sheet(item: $conflict) { conflict in
                MobileTerminalCustomKeyConflictView(store: store, conflict: conflict, lease: store.lease)
            }
            .sheet(isPresented: $recovery) {
                MobileTerminalKeyRecoveryView(store: store, lease: store.lease, rescueOnly: rescue)
            }
            .onChange(of: store.lease) { _, _ in
                // Drop plaintext drafts and undo buffers on lock/account/reload.
                draft = nil
                undoDraft = nil
                error = nil
                conflict = nil
                recovery = false
            }
        }
    }

    private var nextOrder: Int { min(1_000_000, (store.keys.compactMap { $0.value?.order }.max() ?? -1) + 1) }

    private func makeDraft(_ id: String, _ value: TerminalCustomKeyValue) -> TerminalCustomKeyDraft {
        .init(id: id, label: value.label, payload: value.payload, section: value.section, order: value.order)
    }

    private func delete(_ id: String, _ value: TerminalCustomKeyValue) {
        do {
            try store.delete(id: id, lease: store.lease)
            undoDraft = makeDraft(id, value)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct MobileTerminalCustomKeyConflictView: View {
    @ObservedObject var store: TerminalCustomKeyStore
    let conflict: TerminalCustomKeyConflict
    let lease: TerminalCustomKeyStore.Lease?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @State private var confirming = false
    @State private var error: String?

    private var current: Bool { store.canEdit && store.lease == lease && store.conflicts.contains(conflict) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(conflict.explanation)
                    Text("版本编号仅用于区分，不表示时间先后。处理不会发送终端内容，也不会上传到云端。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(conflict.revisions.enumerated()), id: \.offset) { index, revision in
                    Section("版本 \(index + 1)") {
                        if let value = revision.value {
                            Text(value.label)
                            Text(value.payload).font(.system(.body, design: .monospaced))
                            Text(value.section == "common" ? "常用" : "符号").foregroundStyle(.secondary)
                            if TerminalCustomKeyPayload.decode(value.payload)?.contains(where: { $0 == 10 || $0 == 13 }) == true {
                                Label("内容包含回车或换行，点击终端键栏中的按键可能立即执行命令。", systemImage: "exclamationmark.triangle")
                            }
                            Button { selection = index } label: {
                                Label("保留版本 \(index + 1)", systemImage: selection == index ? "checkmark.circle.fill" : "circle")
                                    .frame(minHeight: 44)
                            }
                            .disabled(!current)
                            .accessibilityAddTraits(selection == index ? .isSelected : [])
                            .accessibilityIdentifier("terminal.customKeys.keep.\(index)")
                        } else {
                            Label("此版本已删除按键", systemImage: "trash")
                        }
                    }
                }
                Section {
                    Button(role: .destructive) { selection = -1 } label: {
                        Label("删除此按键", systemImage: selection == -1 ? "checkmark.circle.fill" : "circle")
                            .frame(minHeight: 44)
                    }
                    .disabled(!current)
                    .accessibilityIdentifier("terminal.customKeys.resolveDelete")
                    Text("确认后，其他并发版本将不再作为待处理冲突保留；取消不会更改任何版本。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = error ?? (!current ? "配置已变化或暂不可用，请返回并重试读取。" : nil) {
                    Section { Label(message, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("terminal.customKeys.conflictError") }
                }
            }
            .navigationTitle("处理按键冲突")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用选择") { confirming = true }
                        .disabled(selection == nil || !current)
                        .accessibilityIdentifier("terminal.customKeys.resolveApply")
                }
            }
            .alert("确认处理冲突？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button(selection == -1 ? "确认删除" : "确认保留", role: selection == -1 ? .destructive : nil) {
                    guard let selection, current else { return }
                    do {
                        try store.resolve(conflict, keeping: selection == -1 ? nil : conflict.revisions[selection], lease: lease)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text(selection == -1 ? "将删除此按键并结束全部并发版本的冲突。" : "将保留选定版本并结束其他版本的冲突。")
            }
            .onChange(of: store.lease) { _, _ in dismiss() }
        }
    }
}

struct MobileTerminalCustomKeyEditor: View {
    @ObservedObject var store: TerminalCustomKeyStore
    @State var draft: TerminalCustomKeyDraft
    let lease: TerminalCustomKeyStore.Lease?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var attemptedSave = false
    @FocusState private var focusedField: Field?
    private enum Field { case label, payload }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如 Ctrl+R", text: $draft.label)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .label)
                        .accessibilityLabel("按键名称")
                        .accessibilityIdentifier("terminal.customKeys.label")
                }
                Section {
                    TextField("例如 \\x12", text: $draft.payload, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .payload)
                        .accessibilityLabel("发送内容")
                        .accessibilityIdentifier("terminal.customKeys.payload")
                } header: {
                    Text("发送内容")
                } footer: {
                    Text("支持普通文本、\\t、\\r、\\n、\\e、\\\\、\\xNN。解码后 1–64 字节，源文本最多 256 字节。")
                }
                Section("显示位置") {
                    Picker("键栏分组", selection: $draft.section) {
                        Text("常用").tag("common")
                        Text("符号").tag("symbols")
                    }
                    .pickerStyle(.segmented)
                }
                if draft.sendsReturn {
                    Section {
                        Label("内容包含回车或换行，点击此按键可能立即执行终端中的命令。", systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("terminal.customKeys.returnWarning")
                    }
                }
                if let message = error ?? (attemptedSave ? draft.validationMessage : nil) {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("terminal.customKeys.error")
                    }
                }
                Section {
                    Text("保存不会向终端发送内容。不建议在按键中保存密码、令牌等敏感信息。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑按键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!store.canEdit || lease != store.lease)
                        .accessibilityIdentifier("terminal.customKeys.save")
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: store.lease) { _, _ in
                draft.label = ""
                draft.payload = ""
                dismiss()
            }
            .onChange(of: draft.label) { _, _ in error = nil }
            .onChange(of: draft.payload) { _, _ in error = nil }
        }
    }

    private func save() {
        attemptedSave = true
        guard draft.validationMessage == nil else { return }
        do {
            try store.save(draft, lease: lease)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

#Preview("自定义按键 · 空状态") {
    let store = TerminalCustomKeyStore(read: { _ in nil }, write: { _, _ in })
    store.setAccess(account: AccountScope(username: "preview@example.invalid"), unlocked: true)
    return MobileTerminalCustomKeysView(store: store)
}
#endif
