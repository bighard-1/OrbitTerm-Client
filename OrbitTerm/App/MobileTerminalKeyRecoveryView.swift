import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct MobileTerminalKeyRecoveryView: View {
    @ObservedObject var store: TerminalCustomKeyStore
    let lease: TerminalCustomKeyStore.Lease?
    var rescueOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exported: TerminalKeyBackupDocument?
    @State private var imported: Data?
    @State private var plan: TerminalCustomKeyImportPlan?
    @State private var rescueReview: TerminalCustomKeyStore.RescueReview?
    @State private var confirmImport = false
    @State private var work: Task<Void, Never>?

    private var authorized: Bool { (rescueOnly || store.canEdit) && lease != nil && lease == store.lease }
    private var validPassword: Bool { TerminalCustomKeyRecoveryPackage.validPassword(password) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if rescueOnly {
                        Text("只读保存当前账户的按键原始配置，不修复、不覆盖、不清空。文件可能包含旧数据和自行保存的敏感内容；请使用独立强口令，忘记口令无法解密。")
                        Text("救援文件不是可直接导入的按键备份。若原始数据无法读取，不能生成救援文件。请保留本机应用数据和系统钥匙，勿卸载或清除数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                    Text("恢复文件仅包含加密后的自定义按键及修订，不读取登录密码、主密码或服务器凭据。按键中自行保存的敏感内容也会包含在文件内。请使用独立强口令；忘记口令无法解密。")
                    Text("导入会合并到当前已解锁账户，可能带入删除记录或产生冲突。不会发送命令，也不会同步到云端。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("建议先导出当前配置；合并成功后无法一键撤销。")
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("独立导出口令") {
                    SecureField("至少 12 个字符", text: $password)
                        .disabled(busy)
                        .textContentType(.newPassword).autocorrectionDisabled()
                        .accessibilityIdentifier("terminal.recovery.password")
                    Text(rescueOnly
                         ? "至少 12 个字符，最多 256 个 UTF-8 字节；建议使用较长的随机口令，并将口令与救援文件分开保管。"
                         : "至少 12 个字符，最多 256 个 UTF-8 字节；建议使用较长的随机口令。导入时填写文件原来的导出口令。")
                        .font(.footnote).foregroundStyle(.secondary)
                    SecureField("导出时再次输入口令", text: $confirmation)
                        .disabled(busy)
                        .textContentType(.newPassword).autocorrectionDisabled()
                        .accessibilityIdentifier("terminal.recovery.confirmPassword")
                    Button("加密并导出文件") { export() }
                        .disabled(!authorized || busy || !validPassword || password != confirmation)
                        .accessibilityIdentifier("terminal.recovery.export")
                }
                if !rescueOnly { Section("导入与预览") {
                    Button(imported == nil ? "选择恢复文件" : "重新选择恢复文件") { showImporter = true }
                        .disabled(!authorized || busy)
                    if imported != nil { Text("已选择恢复文件（未导入）").foregroundStyle(.secondary) }
                    Button("解密并预览") { preview() }
                        .disabled(!authorized || busy || !validPassword || imported == nil)
                        .accessibilityIdentifier("terminal.recovery.preview")
                } }
                if rescueOnly {
                    Section("回读核验") {
                        Text("重新选择已导出的救援文件并输入该文件的独立口令。核验只读取文件和当前存储，不修复或写回。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(imported == nil ? "选择救援文件" : "重新选择救援文件") { showImporter = true }
                            .disabled(!authorized || busy)
                        if imported != nil {
                            Text(rescueReview == nil ? "已选择救援文件（未核验）" : "已选择救援文件（已完成本次只读核验）")
                                .foregroundStyle(.secondary)
                        }
                        Button("解密并核验") { inspectRescue() }
                            .disabled(!authorized || busy || !validPassword || imported == nil)
                            .accessibilityIdentifier("terminal.rescue.inspect")
                    }
                    if let rescueReview {
                        MobileTerminalKeyRescueReviewSection(review: rescueReview)
                            .id(rescueReview.decisionSessionToken)
                    }
                }
                if !rescueOnly, let plan {
                    Section("合并预览") {
                        Text("\(plan.changes.count) 项变化；合并后 \(plan.activeCount) 个可用按键，\(plan.conflictCount) 项冲突。")
                        if plan.changes.isEmpty { Text("文件中的版本已包含在本机，无需写入。") }
                        Text("文件中缺少的本机按键不会被删除；文件内较新的删除记录会参与合并。请逐项检查后再确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(plan.changes) { change in
                        Section("按键 · \(change.id.suffix(8))") {
                            Text("当前").font(.headline)
                            revisionRows(change.before)
                            Text("合并后").font(.headline)
                            revisionRows(change.after)
                        }
                    }
                    Section {
                        Button("确认合并到当前账户") { confirmImport = true }
                            .disabled(!authorized || busy || plan.changes.isEmpty)
                            .accessibilityIdentifier("terminal.recovery.commit")
                        Button("取消预览") { self.plan = nil; imported = nil }
                    }
                }
                if busy { Section { ProgressView("正在处理…") } }
                if let message { Section { Text(message).accessibilityIdentifier("terminal.recovery.message") } }
            }
            .navigationTitle(rescueOnly ? "原始配置加密救援" : "按键备份与恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                guard authorized else { return }
                switch result {
                case .success(let url):
                    plan = nil; rescueReview = nil; imported = nil; message = nil
                    let maximum = rescueOnly ? TerminalCustomKeyRecoveryPackage.maxRescueBytes
                                             : TerminalCustomKeyRecoveryPackage.maxBytes
                    run {
                        let bytes = try await Task.detached {
                            let granted = url.startAccessingSecurityScopedResource()
                            defer { if granted { url.stopAccessingSecurityScopedResource() } }
                            return try TerminalKeyBackupDocument.readLimited(url, maximum: maximum)
                        }.value
                        try Task.checkCancellation()
                        guard authorized else { return }
                        imported = bytes
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        message = "未读取恢复文件，原有配置未更改。"
                    }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exported, contentType: .data,
                          defaultFilename: rescueOnly ? "OrbitTerm-key-rescue.orbrescue" : "OrbitTerm-keys.orbkeys") { result in
                exported = nil
                guard authorized else { return }
                switch result {
                case .success: message = "加密文件已导出。请将口令与文件分开保管。"
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        message = "文件未成功导出；若目标位置留下不完整文件，请勿将其用作备份。"
                    }
                }
            }
            .alert("确认合并恢复文件？", isPresented: $confirmImport) {
                Button("取消", role: .cancel) {}
                Button("确认合并") {
                    guard !rescueOnly, authorized, let plan else { return }
                    do {
                        try store.importRecovery(plan, lease: lease)
                        self.plan = nil; imported = nil
                        message = "合并完成。冲突按键请返回管理页逐项处理。"
                    } catch { message = "恢复未完成，原数据保留。请重新读取并生成预览。" }
                }
            } message: { Text("将按预览更新当前账户的本机按键配置。此操作不会发送命令。") }
            .onChange(of: store.lease) { _, _ in clear(); dismiss() }
            .onDisappear { clear() }
        }
    }

    @ViewBuilder private func revisionRows(_ rows: [TerminalCustomKeyRevision]) -> some View {
        if rows.isEmpty { Text("无").foregroundStyle(.secondary) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if let value = row.value {
                Text("\(value.label) · \(value.section == "common" ? "常用" : "符号") · 顺序 \(value.order)")
                Text(value.payload).font(.system(.footnote, design: .monospaced))
            } else { Text("删除记录").foregroundStyle(.secondary) }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, authorized else { return }
        busy = true; message = nil
        work = Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError {}
            catch { if authorized { message = "处理失败：口令错误、文件无效或配置已变化。原有配置未更改。" } }
        }
    }
    private func export() {
        run {
            if rescueOnly {
                let source = try store.rescueSnapshot(lease: lease), pass = password
                let bytes = try await Task.detached { try TerminalCustomKeyRecoveryPackage.sealRescue(source, password: pass) }.value
                try Task.checkCancellation()
                guard authorized, try store.rescueSnapshot(lease: lease) == source else { throw TerminalCustomKeyStore.Failure.changed }
                exported = TerminalKeyBackupDocument(data: bytes)
                password = ""; confirmation = ""; showExporter = true
                return
            }
            let source = try store.recoveryEnvelope(lease: lease), pass = password
            let bytes = try await Task.detached { try TerminalCustomKeyRecoveryPackage.seal(source, password: pass) }.value
            try Task.checkCancellation()
            guard authorized, try store.recoveryEnvelope(lease: lease) == source else { throw TerminalCustomKeyStore.Failure.changed }
            exported = TerminalKeyBackupDocument(data: bytes)
            password = ""; confirmation = ""
            showExporter = true
        }
    }
    private func preview() {
        guard !rescueOnly else { return }
        run {
            guard let bytes = imported else { return }
            let pass = password
            let incoming = try await Task.detached { try TerminalCustomKeyRecoveryPackage.open(bytes, password: pass) }.value
            try Task.checkCancellation()
            guard authorized else { return }
            password = ""; confirmation = ""
            plan = try store.prepareImport(incoming, lease: lease)
        }
    }
    private func inspectRescue() {
        guard rescueOnly else { return }
        run {
            guard let bytes = imported else { return }
            let pass = password
            let result = try await Task.detached {
                let snapshot = try TerminalCustomKeyRecoveryPackage.openRescue(bytes, password: pass)
                let appleValid = snapshot.platform == 1
                    ? ((try? TerminalCustomKeyLocalDocument.decode(snapshot.sources[1]!, account: snapshot.account)) != nil)
                    : nil
                let repairPreview = snapshot.platform == 1
                    ? snapshot.sources[1].map { TerminalCustomKeyRepairPreviewParser.appleDocument($0, rescueAccount: snapshot.account) }
                    : nil
                return (snapshot, appleValid, repairPreview)
            }.value
            try Task.checkCancellation()
            guard authorized else { return }
            password = ""; confirmation = ""
            rescueReview = try store.inspectRescue(result.0, appleSourceIsValid: result.1,
                                                   repairPreview: result.2, lease: lease)
        }
    }
    private func clear() {
        work?.cancel(); work = nil
        password = ""; confirmation = ""; imported = nil; exported = nil; plan = nil; rescueReview = nil
        showImporter = false; showExporter = false
    }
}

struct MobileTerminalKeyRescueReviewSection: View {
    let review: TerminalCustomKeyStore.RescueReview
    @State private var decisions: [Int: TerminalCustomKeyRepairDecision] = [:]
    @State private var corrections: [Int: TerminalCustomKeyRepairCorrection] = [:]
    @State private var acceptsDataLoss = false
    @State private var shownBaseline: String?
    var body: some View {
        Section("只读核验结果") {
            Text("来源平台：\(review.platform == 1 ? "Apple" : "Android")")
            Text(review.accountMatches ? "账户归属：与当前账户一致" : "账户归属：与当前账户不一致，请勿用于当前账户修复")
            Text("当前存储：\(storageDescription(review.storageMatch))")
                .accessibilityIdentifier("terminal.rescue.review")
            ForEach(review.sources) { source in
                Text("\(sourceName(source.id)) · \(source.byteCount) 字节")
                Text(sourceStatus(source.status)).font(.footnote).foregroundStyle(.secondary)
            }
            if let preview = review.repairPreview {
                Text("逐条修复预览（只读）").font(.headline)
                    .accessibilityIdentifier("terminal.rescue.repairPreview")
                Text("仅诊断与当前存储逐字节一致、可安全枚举的本地文档；不会生成替换文件，也不会写回。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let blocked = preview.blockedReason {
                    Text("无法逐条预览：\(blockedDescription(blocked))").foregroundStyle(.red)
                } else {
                    if !preview.documentIssues.isEmpty {
                        Text("文档级诊断：\(preview.documentIssues.map(issueDescription).joined(separator: "；"))")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if preview.items.isEmpty { Text("未发现可枚举项目。") }
                    let unchanged = preview.items.filter { $0.disposition == .keepUnchanged }.count
                    let manual = preview.items.filter { [.manualCorrectionRequired, .cannotInterpret].contains($0.disposition) }.count
                    let capacity = preview.items.filter { $0.disposition == .capacitySelectionRequired }.count
                    Text("共 \(preview.items.count) 项 · 可原样保留 \(unchanged) · 需人工处理 \(manual) · 需容量取舍 \(capacity)")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(preview.items) { item in
                        Text("项目 \(item.index + 1) · \(dispositionDescription(item.disposition))").font(.subheadline).bold()
                        if let value = item.idSummary { Text("ID：\(value)").font(.footnote) }
                        if let value = item.labelSummary { Text("名称：\(value)").font(.footnote) }
                        if let value = item.sectionSummary { Text("分组：\(value)").font(.footnote) }
                        if let count = item.payloadUTF8Bytes { Text("发送内容：\(count) UTF-8 字节（内容不展示）").font(.footnote) }
                        if !item.issues.isEmpty {
                            Text("诊断：\(item.issues.map(issueDescription).joined(separator: "；"))")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        decisionEditor(item)
                    }
                    decisionReview(preview)
                }
            }
            Text("本结果没有修改任何按键。未知版本、截断数据或不可用密钥不能自动重建。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func decisionEditor(_ item: TerminalCustomKeyRepairItem) -> some View {
        Picker("处理决定", selection: Binding<TerminalCustomKeyRepairChoice?>(
            get: { decisions[item.index]?.choice },
            set: { value in
                shownBaseline = nil; acceptsDataLoss = false
                guard let value else { decisions[item.index] = nil; return }
                let correction = value == .correct ? (corrections[item.index] ?? .init()) : nil
                decisions[item.index] = .init(choice: value, correction: correction)
            })) {
                Text("尚未选择").tag(TerminalCustomKeyRepairChoice?.none)
                Text("保留原行").tag(TerminalCustomKeyRepairChoice?.some(.keep))
                Text("输入修正值").tag(TerminalCustomKeyRepairChoice?.some(.correct))
                Text("明确排除").tag(TerminalCustomKeyRepairChoice?.some(.exclude))
                if item.issues.contains(.capacitySelectionRequired) {
                    Text("因容量排除").tag(TerminalCustomKeyRepairChoice?.some(.capacityExclude))
                }
            }
            .accessibilityIdentifier("terminal.rescue.decision.\(item.index)")
        if decisions[item.index]?.choice == .correct {
            Text("修正沿用已验证的源 ID；ID 或版本时钟不可解释的行只能明确排除。不会回显原发送内容。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("修正后的名称", text: correctionBinding(item.index, \.label))
                .accessibilityIdentifier("terminal.rescue.correction.label.\(item.index)")
            TextField("重新输入发送内容", text: correctionBinding(item.index, \.payload))
                .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("terminal.rescue.correction.payload.\(item.index)")
            Picker("修正后的分组", selection: correctionBinding(item.index, \.section)) {
                Text("常用").tag("common")
                Text("符号").tag("symbols")
            }.pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func decisionReview(_ preview: TerminalCustomKeyRepairPreview) -> some View {
        let plan = TerminalCustomKeyRepairDecisionPlanner.make(preview: preview,
            sessionToken: review.decisionSessionToken.uuidString.lowercased(), decisions: decisions)
        Divider()
        Text("修复决策草案（仍为只读）").font(.headline)
            .accessibilityIdentifier("terminal.rescue.decisionDraft")
        Text("决策进度：\(plan.decidedCount)/\(plan.totalCount)；保留 \(plan.keptCount)，修正 \(plan.correctedCount)，排除 \(plan.excludedCount)，预计活动 ID \(plan.activeIdentityCount)。")
            .font(.footnote)
        ForEach(decisionProblemLines(plan), id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
        if plan.requiresDataLossAcknowledgement {
            Toggle("我理解排除项目可能造成数据丢失", isOn: $acceptsDataLoss)
                .accessibilityIdentifier("terminal.rescue.acknowledgeExclusions")
        }
        Button("生成二次确认清单") {
            shownBaseline = plan.confirmationBaseline
        }
        .disabled(!plan.isReadyForSecondConfirmation || (plan.requiresDataLossAcknowledgement && !acceptsDataLoss))
        .accessibilityIdentifier("terminal.rescue.prepareConfirmation")
        if let baseline = shownBaseline, baseline == plan.confirmationBaseline {
            Text("二次确认清单（未写回）").font(.headline)
                .accessibilityIdentifier("terminal.rescue.confirmationPreview")
            Text("确认基线：\(baseline)").font(.system(.footnote, design: .monospaced))
            ForEach(plan.rows) { row in
                Text("项目 \(row.index + 1) · \(choiceDescription(row.choice)) · \(row.included ? "纳入候选" : "排除")")
                    .font(.subheadline).bold()
                if let value = row.idSummary { Text("ID：\(value)").font(.footnote) }
                if let value = row.labelSummary { Text("名称：\(value)").font(.footnote) }
                if let value = row.sectionSummary { Text("分组：\(value)").font(.footnote) }
                if let count = row.payloadUTF8Bytes { Text("发送内容：\(count) UTF-8 字节（内容不展示）").font(.footnote) }
            }
            Text("此清单只绑定本次内存决策，不是修复授权；当前仍没有写回、替换或清库入口。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func correctionBinding(_ index: Int, _ path: WritableKeyPath<TerminalCustomKeyRepairCorrection, String>) -> Binding<String> {
        Binding(get: { (corrections[index] ?? .init())[keyPath: path] }, set: { value in
            var correction = corrections[index] ?? .init()
            correction[keyPath: path] = value
            corrections[index] = correction
            decisions[index] = .init(choice: .correct, correction: correction)
            shownBaseline = nil; acceptsDataLoss = false
        })
    }

    private func decisionProblemLines(_ plan: TerminalCustomKeyRepairDecisionPlan) -> [String] {
        var lines: [String] = []
        let missing = plan.issues.filter { if case .missingDecision = $0 { true } else { false } }.count
        let invalid = plan.issues.filter {
            if case .invalidChoice = $0 { return true }
            if case .invalidCorrection = $0 { return true }
            return false
        }.count
        if missing > 0 { lines.append("尚有 \(missing) 项未作决定。") }
        if invalid > 0 { lines.append("尚有 \(invalid) 项决定或修正值无效。") }
        if plan.issues.contains(.sourceBlocked) { lines.append("来源整体不可枚举，不能建立决策清单。") }
        if plan.issues.contains(.protectedSourceConflict) { lines.append("受保护来源并存，必须先解决来源优先级。") }
        if plan.issues.contains(.documentMetadataBlocked) { lines.append("文档元数据异常，当前阶段不允许重建。") }
        if plan.issues.contains(where: { if case .duplicateRetainedIdentity = $0 { true } else { false } }) {
            lines.append("Android 旧配置仍保留重复 ID，必须明确排除到每个 ID 只剩一项。")
        }
        if plan.issues.contains(where: { if case .tooManyVersions = $0 { true } else { false } }) {
            lines.append("同一 Apple ID 仍保留超过 8 个版本。")
        }
        if let count = plan.issues.compactMap({ if case .capacityExceeded(let value) = $0 { value } else { nil } }).first {
            lines.append("候选活动 ID 为 \(count)，仍超过 64 项容量。")
        }
        return lines
    }

    private func choiceDescription(_ value: TerminalCustomKeyRepairChoice) -> String {
        switch value {
        case .keep: return "保留原行"
        case .correct: return "采用修正值"
        case .exclude: return "明确排除"
        case .capacityExclude: return "因容量排除"
        }
    }
    private func storageDescription(_ value: TerminalCustomKeyStore.RescueStorageMatch) -> String {
        switch value {
        case .exact: return "与救援文件逐字节一致"
        case .different: return "已发生变化，需要重新导出或重新评估"
        case .missing: return "当前来源不存在或不可读取"
        case .notComparable: return "不同平台，无法与本机原始字段直接比较"
        }
    }
    private func sourceName(_ tag: UInt8) -> String {
        switch tag { case 1: return "Apple Keychain 原始项"; case 2: return "Android 加密字段"; case 3: return "Android 旧配置"; default: return "Android 迁移标记" }
    }
    private func sourceStatus(_ status: TerminalCustomKeyStore.RescueSourceStatus) -> String {
        switch status {
        case .validLibrary: return "可在本平台解析并通过有效库校验"
        case .invalidLibrary: return "不能解析为有效库；需要进一步只读诊断，不能猜测修复"
        case .opaqueForeignSource: return "已认证的外部平台原始项，本平台不解释"
        }
    }
    private func blockedDescription(_ value: TerminalCustomKeyRepairBlockedReason) -> String {
        switch value {
        case .malformedOrAmbiguous: return "JSON 损坏、截断或键名重复，禁止猜测"
        case .rootNotEnumerable: return "根结构不是可枚举的本地文档"
        case .tooManyItems: return "项目超过 256 条的安全审查上限"
        }
    }
    private func dispositionDescription(_ value: TerminalCustomKeyRepairDisposition) -> String {
        switch value {
        case .keepUnchanged: return "可原样保留"
        case .manualCorrectionRequired: return "需要人工修正"
        case .capacitySelectionRequired: return "需要人工取舍"
        case .cannotInterpret: return "无法解释"
        }
    }
    private func issueDescription(_ value: TerminalCustomKeyRepairIssue) -> String {
        switch value {
        case .rowNotObject: return "项目不是对象"
        case .unknownFields: return "字段集合不符合契约"
        case .missingOrWrongID: return "ID 缺失或类型错误"
        case .invalidID: return "ID 不合法"
        case .duplicateID: return "ID 重复"
        case .missingOrWrongLabel: return "名称缺失或类型错误"
        case .invalidLabel: return "名称不合法"
        case .missingOrWrongPayload: return "发送内容缺失或类型错误"
        case .invalidPayload: return "发送内容不合法"
        case .missingOrWrongSection: return "分组缺失或类型错误"
        case .invalidSection: return "分组值不合法"
        case .invalidClock: return "版本时钟不合法"
        case .invalidValue: return "项目值不合法"
        case .invalidDocumentMetadata: return "文档元数据不合法"
        case .revisionCollision: return "版本标识冲突"
        case .tooManyVersions: return "同一项目版本过多"
        case .capacitySelectionRequired: return "超过 64 项容量，需要人工取舍"
        }
    }
}

struct TerminalKeyBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= TerminalCustomKeyRecoveryPackage.maxBytes else {
            throw TerminalCustomKeyRecoveryPackage.Failure.format
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
    static func readLimited(_ url: URL, maximum: Int = TerminalCustomKeyRecoveryPackage.maxBytes) throws -> Data {
        guard (1...TerminalCustomKeyRecoveryPackage.maxRescueBytes).contains(maximum) else {
            throw TerminalCustomKeyRecoveryPackage.Failure.format
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while let part = try file.read(upToCount: min(8192, maximum + 1 - result.count)), !part.isEmpty {
            result.append(part)
            guard result.count <= maximum else { throw TerminalCustomKeyRecoveryPackage.Failure.format }
        }
        return result
    }
}
#endif
