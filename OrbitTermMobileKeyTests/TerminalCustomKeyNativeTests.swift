import Security
import SwiftUI
import UIKit
import XCTest

@MainActor
final class TerminalCustomKeyNativeTests: XCTestCase {
    func testCorruptKeychainRescueKeepsExactBytesAndOriginalItem() async throws {
        let account = try XCTUnwrap(AccountScope(username: "rescue-native-\(UUID().uuidString)@example.invalid"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("key-rescue-test-\(UUID().uuidString).orbrescue")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? KeychainDataStore.delete(service: TerminalCustomKeyStore.service, account: account.storageIdentifier)
        }
        let raw = Data([0xff, 0, 0xc0, 0x80])
        try KeychainDataStore.save(raw, service: TerminalCustomKeyStore.service, account: account.storageIdentifier)
        let store = TerminalCustomKeyStore.keychainBacked(); store.setAccess(account: account, unlocked: true)
        XCTAssertFalse(store.canEdit)
        let snapshot = try store.rescueSnapshot(lease: store.lease)
        let bytes = try TerminalCustomKeyRecoveryPackage.sealRescue(snapshot, password: "rescue-passphrase-2026")
        try TerminalKeyBackupDocument(data: bytes).data.write(to: url, options: .atomic)
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(try TerminalCustomKeyRecoveryPackage.openRescue(saved, password: "rescue-passphrase-2026"), snapshot)
        XCTAssertEqual(try KeychainDataStore.read(service: TerminalCustomKeyStore.service, account: account.storageIdentifier), raw)
        let review = try store.inspectRescue(snapshot, appleSourceIsValid: false,
            repairPreview: TerminalCustomKeyRepairPreviewParser.appleDocument(raw, rescueAccount: snapshot.account),
            lease: store.lease)
        capture(MobileTerminalKeyRecoveryView(store: store, lease: store.lease, rescueOnly: true), width: 320, name: "rescue-320")
        capture(NavigationStack { Form { MobileTerminalKeyRescueReviewSection(review: review) } },
                width: 320, name: "rescue-review-320")
    }
    func testPortableEncryptedFileRoundTripAndKeychainMergeWithoutCloningActor() async throws {
        let account = try XCTUnwrap(AccountScope(username: "backup-source-\(UUID().uuidString)@example.invalid"))
        let target = try XCTUnwrap(AccountScope(username: "backup-target-\(UUID().uuidString)@example.invalid"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("key-recovery-test-\(UUID().uuidString).orbkeys")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? KeychainDataStore.delete(service: TerminalCustomKeyStore.service, account: account.storageIdentifier)
            try? KeychainDataStore.delete(service: TerminalCustomKeyStore.service, account: target.storageIdentifier)
        }
        let source = TerminalCustomKeyStore.keychainBacked()
        source.setAccess(account: account, unlocked: true)
        let draft = TerminalCustomKeyDraft(label: "恢复测试😀", payload: "\\x12")
        try source.save(draft, lease: source.lease)
        let bytes = try TerminalCustomKeyRecoveryPackage.seal(source.recoveryEnvelope(lease: source.lease), password: "备份恢复-pass😀2026")
        try bytes.write(to: url, options: .atomic)
        let loaded = try TerminalKeyBackupDocument.readLimited(url)
        XCTAssertEqual(bytes, loaded)
        XCTAssertNil(loaded.range(of: Data("恢复测试".utf8)))
        let incoming = try TerminalCustomKeyRecoveryPackage.open(loaded, password: "备份恢复-pass😀2026")
        let destination = TerminalCustomKeyStore.keychainBacked()
        destination.setAccess(account: target, unlocked: true)
        try destination.save(.init(label: "Existing", payload: "x"), lease: destination.lease)
        let before = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(KeychainDataStore.read(service: TerminalCustomKeyStore.service, account: target.storageIdentifier)), account: target.storageIdentifier)
        let plan = try destination.prepareImport(incoming, lease: destination.lease)
        XCTAssertEqual(plan.changes.count, 1)
        XCTAssertEqual(destination.keys.count, 1)
        try destination.importRecovery(plan, lease: destination.lease)
        let reopened = TerminalCustomKeyStore.keychainBacked()
        reopened.setAccess(account: target, unlocked: true)
        XCTAssertEqual(reopened.keys.count, 2)
        XCTAssertEqual(reopened.bytes(id: draft.id, lease: reopened.lease), [18])
        let after = try TerminalCustomKeyLocalDocument.decode(XCTUnwrap(KeychainDataStore.read(service: TerminalCustomKeyStore.service, account: target.storageIdentifier)), account: target.storageIdentifier)
        XCTAssertEqual(before.actor, after.actor)
    }

    func testRecoveryFileReaderRejectsOversizeBeforeParsing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("key-recovery-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: TerminalCustomKeyRecoveryPackage.maxBytes + 1).write(to: url)
        XCTAssertThrowsError(try TerminalKeyBackupDocument.readLimited(url))
    }

    func testRealKeychainRoundTripIsDeviceOnlyAndAccountScoped() async throws {
        // Own only this random test account; never delete any user credential.
        let account = try XCTUnwrap(AccountScope(username: "key-test-\(UUID().uuidString)@example.invalid"))
        defer { try? KeychainDataStore.delete(service: TerminalCustomKeyStore.service, account: account.storageIdentifier) }
        let store = TerminalCustomKeyStore.keychainBacked()
        _ = try KeychainDataStore.read(service: TerminalCustomKeyStore.service, account: account.storageIdentifier)
        store.setAccess(account: account, unlocked: true)
        XCTAssertTrue(store.canEdit, store.notice ?? "")
        let draft = TerminalCustomKeyDraft(label: "Tab", payload: "\\t")
        try store.save(draft, lease: store.lease)

        var query = KeychainDataStore.dataProtectionQuery(service: TerminalCustomKeyStore.service, account: account.storageIdentifier)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        let reopened = TerminalCustomKeyStore.keychainBacked()
        reopened.setAccess(account: account, unlocked: true)
        XCTAssertEqual(reopened.bytes(id: draft.id, lease: reopened.lease), [9])
        let oldLease = reopened.lease
        reopened.lock()
        XCTAssertNil(reopened.bytes(id: draft.id, lease: oldLease))
        reopened.setAccess(account: AccountScope(username: "other-\(UUID().uuidString)@example.invalid"), unlocked: true)
        XCTAssertTrue(reopened.keys.isEmpty)
    }

    func testNativeEditorAndListSnapshotsAtCompactAndTabletWidths() async throws {
        for width: CGFloat in [320, 375, 414, 768] {
            var data: Data?
            let store = TerminalCustomKeyStore(read: { _ in data }, write: { _, value in data = value })
            store.setAccess(account: AccountScope(username: "snapshot@example.invalid"), unlocked: true)
            let draft = TerminalCustomKeyDraft(label: "Ctrl+R", payload: "\\x12")
            try store.save(draft, lease: store.lease)
            capture(MobileTerminalCustomKeysView(store: store), width: width, name: "list-\(Int(width))")
            capture(MobileTerminalCustomKeyEditor(store: store, draft: .init(label: "Enter", payload: "\\r"), lease: store.lease),
                    width: width, name: "editor-\(Int(width))")
        }
    }

    func testNativeEditorDarkAndAccessibilityTextSnapshots() async {
        let store = TerminalCustomKeyStore(read: { _ in nil }, write: { _, _ in })
        store.setAccess(account: AccountScope(username: "snapshot@example.invalid"), unlocked: true)
        capture(MobileTerminalCustomKeysView(store: store).environment(\.colorScheme, .dark),
                width: 375, name: "list-dark-375")
        capture(MobileTerminalCustomKeyEditor(store: store, draft: .init(label: "Enter", payload: "\\r"), lease: store.lease)
            .environment(\.dynamicTypeSize, .accessibility5), width: 375, name: "editor-accessibility-375")
    }

    func testAccessoryFreezesGroupSelectorAndUpdatesIdentityCallbacks() async throws {
        let accessory = ShortcutAccessoryView()
        accessory.frame = CGRect(x: 0, y: 0, width: 320, height: 62)
        let id = UUID().uuidString.lowercased()
        let row = TerminalCustomKeyRevision(id: id, clock: [UUID().uuidString.lowercased(): 1],
            value: .init(label: "Ctrl+R", payload: "\\x12", section: "common", order: 0))
        var oldCalls = 0, newCalls: [String] = [], manages = 0
        accessory.updateCustomKeys([row], onSend: { _ in oldCalls += 1 }, onManage: {}, canManage: true)
        accessory.layoutIfNeeded()
        let control = try XCTUnwrap(accessory.subviews.compactMap { $0 as? UISegmentedControl }.first)
        let scroll = try XCTUnwrap(accessory.subviews.compactMap { $0 as? UIScrollView }.first)
        let stack = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIStackView }.first)
        let button = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "terminal.customKeys.send.\(id)"
        })
        let frozenFrame = control.frame
        scroll.contentOffset.x = 150
        accessory.layoutIfNeeded()
        XCTAssertEqual(control.frame, frozenFrame)
        XCTAssertTrue(control.superview === accessory)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        accessory.updateCustomKeys([row], onSend: { newCalls.append($0) }, onManage: { manages += 1 }, canManage: true)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(newCalls, [id])
        let manage = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "terminal.customKeys.accessoryManage"
        })
        manage.sendActions(for: .touchUpInside)
        XCTAssertEqual(manages, 1)
        // Lock removes displayed custom keys and revokes retained UIActions too.
        accessory.updateCustomKeys([], onSend: nil, onManage: nil, canManage: false)
        button.sendActions(for: .touchUpInside)
        manage.sendActions(for: .touchUpInside)
        XCTAssertEqual(newCalls, [id])
        XCTAssertEqual(manages, 1)
        XCTAssertFalse(stack.arrangedSubviews.contains(button))
    }

    private func capture<Content: View>(_ content: Content, width: CGFloat, name: String) {
        let controller = UIHostingController(rootView: content)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("The native snapshot lane requires its isolated UIKit test host")
            return
        }
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 820)
        controller.didMove(toParent: container)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        window.rootViewController = nil
    }
}
