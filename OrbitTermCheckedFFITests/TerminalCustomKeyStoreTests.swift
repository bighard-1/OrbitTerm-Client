import Foundation
import XCTest

@MainActor
final class TerminalCustomKeyStoreTests: XCTestCase {
    private let account = AccountScope(username: "keys-a@example.invalid")!
    private let other = AccountScope(username: "keys-b@example.invalid")!
    private let draft = TerminalCustomKeyDraft(label: "Ctrl+R", payload: "\\x12")

    func testRescueCanReadCorruptRawBytesWithoutWritingOrEnablingEdits() async throws {
        let disk = Disk(), raw = Data([0xff, 0, 0xc0, 0x80])
        disk.data[account.storageIdentifier] = raw
        let store = disk.store(); store.setAccess(account: account, unlocked: true)
        XCTAssertFalse(store.canEdit)
        let source = try store.rescueSnapshot(lease: store.lease)
        XCTAssertEqual(source.sources[1], raw)
        XCTAssertEqual(disk.writes, 0)
        XCTAssertEqual(disk.data[account.storageIdentifier], raw)
        XCTAssertThrowsError(try store.recoveryEnvelope(lease: store.lease))
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(raw, rescueAccount: account.storageIdentifier)
        let review = try store.inspectRescue(source, appleSourceIsValid: false, repairPreview: preview, lease: store.lease)
        XCTAssertTrue(review.accountMatches)
        XCTAssertEqual(review.storageMatch, .exact)
        XCTAssertEqual(review.sources, [.init(id: 1, byteCount: raw.count, status: .invalidLibrary)])
        XCTAssertEqual(review.repairPreview, preview)
        XCTAssertEqual(disk.writes, 0)
        disk.data[account.storageIdentifier] = Data([1])
        let changed = try store.inspectRescue(source, appleSourceIsValid: false, repairPreview: preview, lease: store.lease)
        XCTAssertEqual(changed.storageMatch, .different)
        XCTAssertNil(changed.repairPreview)
    }
    func testRescueInspectionRejectsOldLeaseAndTreatsForeignPlatformAsOpaque() async throws {
        let disk = Disk(); disk.data[account.storageIdentifier] = Data([0xff])
        let store = disk.store(); store.setAccess(account: account, unlocked: true)
        let lease = store.lease
        let foreign = TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 2,
            account: other.storageIdentifier, sources: [3: Data("[]".utf8.map { byte in [UInt8(0), byte] }.flatMap { $0 })])
        let review = try store.inspectRescue(foreign, appleSourceIsValid: nil, repairPreview: nil, lease: lease)
        XCTAssertFalse(review.accountMatches)
        XCTAssertEqual(review.storageMatch, .notComparable)
        XCTAssertEqual(review.sources.count, 1)
        XCTAssertEqual(review.sources.first?.status, .opaqueForeignSource)
        XCTAssertNil(review.repairPreview)
        store.reload()
        XCTAssertThrowsError(try store.inspectRescue(foreign, appleSourceIsValid: nil, repairPreview: nil, lease: lease))
        XCTAssertEqual(disk.writes, 0)
    }
    func testRescueRejectsMissingInaccessibleAndExpiredAccountWithoutWrites() async throws {
        let disk = Disk(), store = disk.store(); store.setAccess(account: account, unlocked: true)
        let lease = store.lease
        XCTAssertThrowsError(try store.rescueSnapshot(lease: lease))
        disk.data[account.storageIdentifier] = Data([0xff]); disk.readFails = true
        XCTAssertThrowsError(try store.rescueSnapshot(lease: lease))
        disk.readFails = false; store.lock()
        XCTAssertThrowsError(try store.rescueSnapshot(lease: lease))
        store.setAccess(account: other, unlocked: true)
        XCTAssertThrowsError(try store.rescueSnapshot(lease: lease))
        XCTAssertEqual(disk.writes, 0)
    }

    func testRecoveryPreviewDoesNotWriteAndImportKeepsLocalActorAndUnrelatedKeys() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        try store.save(draft, lease: store.lease)
        let rescue = try store.rescueSnapshot(lease: store.lease)
        XCTAssertEqual(try store.inspectRescue(rescue, appleSourceIsValid: true,
            repairPreview: TerminalCustomKeyRepairPreviewParser.appleDocument(rescue.sources[1]!, rescueAccount: rescue.account),
            lease: store.lease).sources.first?.status, .validLibrary)
        let before = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        let imported = TerminalCustomKeyEnvelope.v1([.init(id: "22222222-2222-2222-2222-222222222222",
            clock: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": 2], value: .init(label: "Tab", payload: "\\t", section: "symbols", order: 9))])
        let plan = try store.prepareImport(imported, lease: store.lease)
        XCTAssertEqual(plan.changes.count, 1)
        XCTAssertEqual(plan.activeCount, 2)
        XCTAssertEqual(disk.writes, 1)
        try store.importRecovery(plan, lease: store.lease)
        XCTAssertEqual(store.keys.count, 2)
        let after = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        XCTAssertEqual(before.actor, after.actor)
        let repeatPlan = try store.prepareImport(imported, lease: store.lease)
        XCTAssertTrue(repeatPlan.changes.isEmpty)
        try store.importRecovery(repeatPlan, lease: store.lease)
        XCTAssertEqual(disk.writes, 2)
    }

    func testImportPreviewProtectsTombstonesAndShowsConcurrentConflict() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        try store.save(draft, lease: store.lease)
        let old = try store.recoveryEnvelope(lease: store.lease)
        try store.delete(id: draft.id, lease: store.lease)
        XCTAssertTrue(try store.prepareImport(old, lease: store.lease).changes.isEmpty)
        let incoming = TerminalCustomKeyEnvelope.v1([.init(id: draft.id,
            clock: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": 1], value: draft.value)])
        let plan = try store.prepareImport(incoming, lease: store.lease)
        XCTAssertEqual(plan.conflictCount, 1)
        XCTAssertEqual(plan.activeCount, 0)
        try store.importRecovery(plan, lease: store.lease)
        XCTAssertNil(store.bytes(id: draft.id, lease: store.lease))
        XCTAssertEqual(store.conflicts.count, 1)
    }

    func testImportRejectsStaleLeaseChangedStorageAndFailedWrite() async throws {
        for kind in 0..<4 {
            let disk = Disk(), store = disk.store()
            store.setAccess(account: account, unlocked: true)
            let lease = store.lease
            let incoming = TerminalCustomKeyEnvelope.v1([.init(id: draft.id,
                clock: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": 1], value: draft.value)])
            let plan = try store.prepareImport(incoming, lease: lease)
            switch kind {
            case 0: store.lock(); store.setAccess(account: account, unlocked: true)
            case 1: try store.save(.init(label: "Local", payload: "a"), lease: lease)
            case 2: disk.data[account.storageIdentifier] = Data("corrupt".utf8)
            default: disk.writeFails = true
            }
            let before = disk.data
            XCTAssertThrowsError(try store.importRecovery(plan, lease: lease))
            XCTAssertEqual(disk.data, before)
        }
    }

    private func conflictDocument() -> TerminalCustomKeyLocalDocument {
        var doc = TerminalCustomKeyLocalDocument.empty(account: account.storageIdentifier)
        doc.envelope = .v1([
            .init(id: draft.id, clock: [doc.actor: 1], value: draft.value),
            .init(id: draft.id, clock: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": 1], value: nil),
        ])
        return doc
    }

    func testConflictStoreRequiresExplicitResolutionAndKeepsActor() async throws {
        let disk = Disk(), doc = conflictDocument()
        disk.data[account.storageIdentifier] = try doc.encoded()
        let store = disk.store()
        store.setAccess(account: account, unlocked: true)
        let review = try XCTUnwrap(store.conflicts.first)
        XCTAssertNil(store.bytes(id: draft.id, lease: store.lease))
        XCTAssertThrowsError(try store.save(draft, lease: store.lease))
        XCTAssertThrowsError(try store.delete(id: draft.id, lease: store.lease))
        try store.resolve(review, keeping: review.revisions.first { $0.value != nil }, lease: store.lease)
        XCTAssertTrue(store.conflicts.isEmpty)
        XCTAssertEqual(store.bytes(id: draft.id, lease: store.lease), [18])
        let after = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        XCTAssertEqual(after.actor, doc.actor)
        XCTAssertEqual(after.envelope, try TerminalCustomKeyContract.merge(after.envelope, doc.envelope))
        XCTAssertThrowsError(try store.resolve(review, keeping: nil, lease: store.lease))
        XCTAssertEqual(disk.writes, 1)
    }

    func testConflictFailureAndExternalChangePreserveDurableVersions() async throws {
        for externalChange in [false, true] {
            let disk = Disk()
            disk.data[account.storageIdentifier] = try conflictDocument().encoded()
            let store = disk.store()
            store.setAccess(account: account, unlocked: true)
            let review = try XCTUnwrap(store.conflicts.first)
            if externalChange { disk.data[account.storageIdentifier] = Data("changed".utf8) }
            else { disk.writeFails = true }
            let before = disk.data
            XCTAssertThrowsError(try store.resolve(review, keeping: nil, lease: store.lease))
            XCTAssertEqual(before, disk.data)
            XCTAssertEqual(disk.writes, 0)
            XCTAssertTrue(store.conflicts.isEmpty)
            XCTAssertFalse(store.canEdit)
        }
    }

    func testConflictReviewExpiresOnReloadLockAndAccountSwitch() async throws {
        let disk = Disk()
        disk.data[account.storageIdentifier] = try conflictDocument().encoded()
        let store = disk.store()
        store.setAccess(account: account, unlocked: true)
        let review = try XCTUnwrap(store.conflicts.first), lease = store.lease
        store.reload()
        XCTAssertThrowsError(try store.resolve(review, keeping: nil, lease: lease))
        let second = store.lease
        store.lock()
        XCTAssertTrue(store.conflicts.isEmpty)
        store.setAccess(account: other, unlocked: true)
        XCTAssertThrowsError(try store.resolve(review, keeping: nil, lease: second))
        XCTAssertEqual(disk.writes, 0)
    }

    @MainActor private final class Disk {
        var data: [String: Data] = [:]
        var readFails = false
        var writeFails = false
        var writes = 0
        func store() -> TerminalCustomKeyStore {
            .init(read: {
                if self.readFails { throw CocoaError(.fileReadNoPermission) }
                return self.data[$0]
            }, write: {
                if self.writeFails { throw CocoaError(.fileWriteNoPermission) }
                self.writes += 1
                self.data[$0] = $1
            })
        }
    }

    func testFirstReadDoesNotWriteAndRestartRetainsActorAndClock() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(disk.writes, 0)
        try store.save(draft, lease: store.lease)
        let first = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        let reopened = disk.store()
        reopened.setAccess(account: account, unlocked: true)
        XCTAssertEqual(reopened.bytes(id: draft.id, lease: reopened.lease), [18])
        var edit = draft; edit.payload = "\\t"
        try reopened.save(edit, lease: reopened.lease)
        let second = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        XCTAssertEqual(first.actor, second.actor)
        XCTAssertEqual(second.envelope.revisions[0].clock, [first.actor: 2])
    }

    func testAccountIsolationAndLockRevokeRetainedActions() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        let oldLease = store.lease
        try store.save(draft, lease: oldLease)
        store.lock()
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertFalse(store.canEdit)
        XCTAssertNil(store.bytes(id: draft.id, lease: oldLease))
        store.setAccess(account: account, unlocked: true)
        XCTAssertThrowsError(try store.save(draft, lease: oldLease))
        store.setAccess(account: other, unlocked: true)
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertThrowsError(try store.delete(id: draft.id, lease: oldLease))
        XCTAssertEqual(disk.writes, 1)
        store.setAccess(account: account, unlocked: true)
        XCTAssertEqual(store.keys.count, 1)
    }

    func testCanonicalAccountDoesNotRotateCurrentLease() async {
        let store = Disk().store()
        store.setAccess(account: account, unlocked: true)
        let lease = store.lease
        store.setAccess(account: AccountScope(username: " KEYS-A@EXAMPLE.INVALID "), unlocked: true)
        XCTAssertEqual(store.lease, lease)
        store.setAccess(account: account, unlocked: false)
        XCTAssertNil(store.lease)
    }

    func testUnreadableAndCorruptDataNeverBecomeWritableEmptyState() async throws {
        for broken in [Data("not-json".utf8), Data()] {
            let disk = Disk(); disk.data[account.storageIdentifier] = broken
            let store = disk.store()
            store.setAccess(account: account, unlocked: true)
            XCTAssertFalse(store.canEdit)
            XCTAssertNotNil(store.notice)
            XCTAssertThrowsError(try store.save(draft, lease: store.lease))
            XCTAssertEqual(disk.data[account.storageIdentifier], broken)
            XCTAssertEqual(disk.writes, 0)
        }
        let disk = Disk(); disk.readFails = true
        let store = disk.store()
        store.setAccess(account: account, unlocked: true)
        XCTAssertFalse(store.canEdit)
        XCTAssertThrowsError(try store.save(draft, lease: store.lease))
        disk.readFails = false
        store.reload()
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(disk.writes, 0)
    }

    func testFailedWritePreservesDurableDataAndRequiresExplicitReload() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        try store.save(draft, lease: store.lease)
        let before = disk.data
        disk.writeFails = true
        var edit = draft; edit.payload = "changed"
        let oldLease = store.lease
        XCTAssertThrowsError(try store.save(edit, lease: oldLease))
        XCTAssertEqual(disk.data, before)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(store.keys.isEmpty)
        disk.writeFails = false
        XCTAssertThrowsError(try store.save(edit, lease: oldLease))
        store.reload()
        XCTAssertThrowsError(try store.save(edit, lease: oldLease))
        XCTAssertEqual(store.bytes(id: draft.id, lease: store.lease), [18])
    }

    func testExternalChangeOrDeletionBlocksOverwrite() async throws {
        for deleted in [false, true] {
            let disk = Disk(), store = disk.store()
            store.setAccess(account: account, unlocked: true)
            try store.save(draft, lease: store.lease)
            disk.data[account.storageIdentifier] = deleted ? nil : Data("changed".utf8)
            let before = disk.data
            XCTAssertThrowsError(try store.save(draft, lease: store.lease))
            XCTAssertEqual(disk.data, before)
            XCTAssertFalse(store.canEdit)
            XCTAssertEqual(disk.writes, 1)
        }
    }

    func testDeleteAndUndoRetainTombstoneCausality() async throws {
        let disk = Disk(), store = disk.store()
        store.setAccess(account: account, unlocked: true)
        try store.save(draft, lease: store.lease)
        try store.delete(id: draft.id, lease: store.lease)
        XCTAssertTrue(store.keys.isEmpty)
        let document = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(disk.data[account.storageIdentifier]), account: account.storageIdentifier)
        XCTAssertNil(document.envelope.revisions[0].value)
        XCTAssertEqual(document.envelope.revisions[0].clock[document.actor], 2)
        try store.save(draft, lease: store.lease)
        XCTAssertEqual(store.keys[0].clock[document.actor], 3)
        XCTAssertEqual(store.bytes(id: draft.id, lease: store.lease), [18])
    }

    func testWrapperRejectsOtherAccountFutureFieldsAndDuplicateKeys() async throws {
        let data = try TerminalCustomKeyLocalDocument.empty(account: account.storageIdentifier).encoded()
        XCTAssertThrowsError(try TerminalCustomKeyLocalDocument.decode(data, account: other.storageIdentifier))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for patch: [String: Any] in [["version": 2], ["actor": "invalid"], ["future": true]] {
            let changed = root.merging(patch) { _, new in new }
            XCTAssertThrowsError(try TerminalCustomKeyLocalDocument.decode(JSONSerialization.data(withJSONObject: changed), account: account.storageIdentifier))
        }
        let duplicate = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"\\u0076ersion\":1")
        XCTAssertThrowsError(try TerminalCustomKeyLocalDocument.decode(Data(duplicate.utf8), account: account.storageIdentifier))
        root["envelope"] = ["kind": "terminal_custom_keys", "version": 1, "payloadSyntaxVersion": 2, "revisions": []] as [String: Any]
        XCTAssertThrowsError(try TerminalCustomKeyLocalDocument.decode(JSONSerialization.data(withJSONObject: root), account: account.storageIdentifier))
    }

    func testDraftUnicodePayloadBoundariesAndReturnWarnings() async {
        XCTAssertNil(TerminalCustomKeyDraft(label: String(repeating: "😀", count: 16), payload: "\\t").validationMessage)
        for label in ["", " ", "a\n", "a\u{2028}", String(repeating: "😀", count: 17)] {
            XCTAssertNotNil(TerminalCustomKeyDraft(label: label, payload: "a").validationMessage)
        }
        for payload in ["", "\\x+F", String(repeating: "a", count: 65)] {
            XCTAssertNotNil(TerminalCustomKeyDraft(label: "a", payload: payload).validationMessage)
        }
        for payload in ["\\r", "\\n", "\\x0d", "a\nb"] {
            XCTAssertTrue(TerminalCustomKeyDraft(label: "a", payload: payload).sendsReturn)
        }
        XCTAssertFalse(draft.sendsReturn)
        XCTAssertFalse(TerminalCustomKeyDraft(label: "a", payload: "\\\\n").sendsReturn)
    }

    func testCapacityFailureDoesNotTruncateOrDisableExistingKeys() async throws {
        let disk = Disk()
        var document = TerminalCustomKeyLocalDocument.empty(account: account.storageIdentifier)
        document.envelope = .v1((0..<64).map { n in
            .init(id: String(format: "00000000-0000-0000-0000-%012d", n), clock: [document.actor: 1],
                  value: .init(label: "K\(n)", payload: "a", section: "common", order: n))
        })
        disk.data[account.storageIdentifier] = try document.encoded()
        let store = disk.store()
        store.setAccess(account: account, unlocked: true)
        let before = disk.data
        XCTAssertThrowsError(try store.save(draft, lease: store.lease))
        XCTAssertEqual(disk.data, before)
        XCTAssertEqual(store.keys.count, 64)
        XCTAssertTrue(store.canEdit)
    }

    func testConcurrentConflictsRemainUnsendable() async throws {
        let disk = Disk()
        var document = TerminalCustomKeyLocalDocument.empty(account: account.storageIdentifier)
        document.envelope = .v1([
            .init(id: draft.id, clock: [document.actor: 1], value: draft.value),
            .init(id: draft.id, clock: [UUID().uuidString.lowercased(): 1], value: nil)
        ])
        disk.data[account.storageIdentifier] = try document.encoded()
        let store = disk.store()
        store.setAccess(account: account, unlocked: true)
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertNil(store.bytes(id: draft.id, lease: store.lease))
        XCTAssertEqual(disk.writes, 0)
    }

    func testReentrantLockDuringReadCannotRepublishPlaintext() async throws {
        let disk = Disk(), initial = disk.store()
        initial.setAccess(account: account, unlocked: true)
        try initial.save(draft, lease: initial.lease)
        var store: TerminalCustomKeyStore!
        store = .init(read: { scope in
            store.lock()
            return disk.data[scope]
        }, write: { _, _ in XCTFail("Unexpected write") })
        store.setAccess(account: account, unlocked: true)
        XCTAssertNil(store.lease)
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertFalse(store.canEdit)
    }
}
