import Foundation
import Combine

/// Main-actor serialization keeps local SecItem transactions and access changes
/// ordered. Leases prevent a retained editor/button from crossing a lock cycle.
@MainActor
final class TerminalCustomKeyStore: ObservableObject {
    enum RescueStorageMatch { case exact, different, missing, notComparable }
    enum RescueSourceStatus { case validLibrary, invalidLibrary, opaqueForeignSource }
    struct RescueSourceReview: Identifiable, Equatable {
        let id: UInt8
        let byteCount: Int
        let status: RescueSourceStatus
    }
    struct RescueReview: Equatable {
        let decisionSessionToken: UUID
        let platform: UInt8
        let accountMatches: Bool
        let storageMatch: RescueStorageMatch
        let sources: [RescueSourceReview]
        let repairPreview: TerminalCustomKeyRepairPreview?
    }
    struct Lease: Equatable {
        let account: String
        let generation: UUID
    }

    enum Failure: LocalizedError {
        case locked, unavailable, changed, invalid, capacity
        var errorDescription: String? {
            switch self {
            case .locked: return "账户已锁定或切换，请解锁后重新打开编辑器。"
            case .unavailable: return "自定义按键存储暂不可用，原数据未被替换。请重试读取。"
            case .changed: return "本机按键数据已变化，请重新读取后再编辑。"
            case .invalid: return "按键配置无效，请检查名称和发送内容。"
            case .capacity: return "自定义按键已达到容量限制，无法保存；原数据保持不变。"
            }
        }
    }

    static let service = "com.orbitterm.terminal-custom-keys.local.v1"
    @Published private(set) var keys: [TerminalCustomKeyRevision] = []
    @Published private(set) var conflicts: [TerminalCustomKeyConflict] = []
    @Published private(set) var notice: String?
    @Published private(set) var lease: Lease?
    @Published private(set) var canEdit = false
    private var document: TerminalCustomKeyLocalDocument?
    private var storedData: Data?
    private let read: (String) throws -> Data?
    private let write: (String, Data) throws -> Void

    init(read: @escaping (String) throws -> Data?, write: @escaping (String, Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    static func keychainBacked() -> TerminalCustomKeyStore {
        .init(read: { try KeychainDataStore.read(service: service, account: $0) },
              write: { try KeychainDataStore.save($1, service: service, account: $0) })
    }

    func setAccess(account: AccountScope?, unlocked: Bool) {
        let identifier = unlocked ? account?.storageIdentifier : nil
        guard identifier != lease?.account else { return }
        clear()
        guard let identifier else { return }
        lease = Lease(account: identifier, generation: UUID())
        reload()
    }

    func lock() { clear() }

    private func clear() {
        lease = nil
        canEdit = false
        document = nil
        storedData = nil
        keys = []
        conflicts = []
        notice = nil
    }

    func reload() {
        guard let lease else { return }
        canEdit = false
        document = nil
        storedData = nil
        keys = []
        conflicts = []
        // Reload also invalidates drafts made against the preceding snapshot.
        let readingLease = Lease(account: lease.account, generation: UUID())
        self.lease = readingLease
        do {
            let data = try read(lease.account)
            let loaded = try data.map { try TerminalCustomKeyLocalDocument.decode($0, account: lease.account) }
                ?? .empty(account: lease.account)
            guard self.lease == readingLease else { return }
            keys = try TerminalCustomKeyContract.active(loaded.envelope)
            conflicts = try TerminalCustomKeyContract.conflicts(loaded.envelope)
            document = loaded
            storedData = data
            notice = nil
            canEdit = true
        } catch {
            guard self.lease == readingLease else { return }
            notice = Failure.unavailable.localizedDescription
        }
    }

    func save(_ draft: TerminalCustomKeyDraft, lease: Lease?) throws {
        guard draft.validationMessage == nil else { throw Failure.invalid }
        guard !conflicts.contains(where: { $0.id == draft.id }) else { throw Failure.changed }
        try mutate(id: draft.id, value: draft.value, lease: lease)
    }

    func resolve(_ observed: TerminalCustomKeyConflict, keeping: TerminalCustomKeyRevision?, lease: Lease?) throws {
        try require(lease)
        guard let document else { throw Failure.unavailable }
        guard conflicts.contains(observed) else { throw Failure.changed }
        _ = try TerminalCustomKeyContract.resolving(document.envelope, observed: observed, keeping: keeping, actor: document.actor)
        try mutate(id: observed.id, value: keeping?.value, lease: lease)
    }

    func delete(id: String, lease: Lease?) throws {
        try require(lease)
        guard keys.contains(where: { $0.id == id }) else { throw Failure.changed }
        try mutate(id: id, value: nil, lease: lease)
    }

    func bytes(id: String, lease: Lease?) -> [UInt8]? {
        guard (try? require(lease)) != nil,
              let value = keys.first(where: { $0.id == id })?.value else { return nil }
        return TerminalCustomKeyPayload.decode(value.payload)
    }

    func recoveryEnvelope(lease: Lease?) throws -> TerminalCustomKeyEnvelope {
        try require(lease)
        guard let lease, let document, try read(lease.account) == storedData else { throw Failure.changed }
        return document.envelope
    }

    /// A failed decode must not prevent a byte-exact, read-only rescue. A failed
    /// Keychain read, however, is never interpreted as empty or exportable data.
    func rescueSnapshot(lease candidate: Lease?) throws -> TerminalCustomKeyRecoveryPackage.RescueSnapshot {
        guard let candidate, candidate == lease else { throw Failure.locked }
        guard let raw = try read(candidate.account) else { throw Failure.unavailable }
        guard candidate == lease else { throw Failure.locked }
        let snapshot = TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 1, account: candidate.account, sources: [1: raw])
        _ = try snapshot.encoded()
        return snapshot
    }

    /// Authenticated rescue inspection is read-only. Foreign-platform payloads
    /// are verified but never interpreted as native storage or offered for import.
    func inspectRescue(_ snapshot: TerminalCustomKeyRecoveryPackage.RescueSnapshot,
                       appleSourceIsValid: Bool?, repairPreview: TerminalCustomKeyRepairPreview?,
                       lease candidate: Lease?) throws -> RescueReview {
        guard let candidate, candidate == lease else { throw Failure.locked }
        let current = try? read(candidate.account)
        guard candidate == lease else { throw Failure.locked }
        let accountMatches = snapshot.account == candidate.account
        let storageMatch: RescueStorageMatch
        if snapshot.platform != 1 { storageMatch = .notComparable }
        else if current == nil { storageMatch = .missing }
        else { storageMatch = current == snapshot.sources[1] ? .exact : .different }
        let sources = snapshot.sources.keys.sorted().map { tag -> RescueSourceReview in
            let bytes = snapshot.sources[tag]!
            let status: RescueSourceStatus
            if snapshot.platform == 1, tag == 1 {
                status = appleSourceIsValid == true ? .validLibrary : .invalidLibrary
            } else { status = .opaqueForeignSource }
            return .init(id: tag, byteCount: bytes.count, status: status)
        }
        guard current == (try? read(candidate.account)) else { throw Failure.changed }
        guard candidate == lease else { throw Failure.locked }
        let eligiblePreview = snapshot.platform == 1 && accountMatches && storageMatch == .exact
            ? repairPreview : nil
        return .init(decisionSessionToken: UUID(), platform: snapshot.platform, accountMatches: accountMatches,
                     storageMatch: storageMatch, sources: sources, repairPreview: eligiblePreview)
    }

    func prepareImport(_ incoming: TerminalCustomKeyEnvelope, lease: Lease?) throws -> TerminalCustomKeyImportPlan {
        try .make(current: recoveryEnvelope(lease: lease), incoming: incoming)
    }

    func importRecovery(_ plan: TerminalCustomKeyImportPlan, lease: Lease?) throws {
        try require(lease)
        guard var next = document else { throw Failure.unavailable }
        let fresh = try TerminalCustomKeyImportPlan.make(current: next.envelope, incoming: plan.incoming)
        guard fresh.before == plan.before, fresh.merged == plan.merged else { throw Failure.changed }
        guard !fresh.changes.isEmpty else { return }
        next.envelope = fresh.merged
        try commit(next, lease: lease)
    }

    private func require(_ candidate: Lease?) throws {
        guard let candidate, candidate == lease else { throw Failure.locked }
        guard canEdit, document != nil else { throw Failure.unavailable }
    }

    private func mutate(id: String, value: TerminalCustomKeyValue?, lease: Lease?) throws {
        try require(lease)
        guard var next = document else { throw Failure.unavailable }
        do {
            next.envelope = try TerminalCustomKeyContract.replacing(next.envelope, id: id, actor: next.actor, value: value)
        } catch TerminalCustomKeyContract.Failure.capacity { throw Failure.capacity }
        try commit(next, lease: lease)
    }

    private func commit(_ next: TerminalCustomKeyLocalDocument, lease: Lease?) throws {
        try require(lease)
        guard let lease else { throw Failure.locked }
        do {
            let encoded = try next.encoded()
            // Do not overwrite a changed, deleted, inaccessible or corrupt item.
            guard try read(lease.account) == storedData else {
                canEdit = false
                keys = []
                conflicts = []
                notice = Failure.changed.localizedDescription
                throw Failure.changed
            }
            try require(lease)
            try write(lease.account, encoded)
            try require(lease)
            storedData = encoded
            document = next
            keys = try TerminalCustomKeyContract.active(next.envelope)
            conflicts = try TerminalCustomKeyContract.conflicts(next.envelope)
        } catch let failure as Failure {
            throw failure
        } catch TerminalCustomKeyContract.Failure.capacity {
            throw Failure.capacity
        } catch {
            // A failed write is not an empty store. Keep the editor's draft and
            // block retries until the user explicitly re-reads durable state.
            canEdit = false
            keys = []
            conflicts = []
            notice = Failure.unavailable.localizedDescription
            throw Failure.unavailable
        }
    }
}
