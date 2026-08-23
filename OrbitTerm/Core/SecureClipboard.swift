import Foundation
import Combine

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum ClipboardContentKind: Sendable {
    case ordinaryText
    case terminalOutput
    case hostKeyFingerprint
    case credential
    case privateKey

    var expiryNanoseconds: UInt64? {
        switch self {
        case .ordinaryText:
            nil
        case .terminalOutput, .hostKeyFingerprint:
            60_000_000_000
        case .credential, .privateKey:
            nil
        }
    }

    var canCopy: Bool {
        switch self {
        case .credential, .privateKey:
            false
        case .ordinaryText, .terminalOutput, .hostKeyFingerprint:
            true
        }
    }
}

@MainActor
final class ClipboardSecurityNotice: ObservableObject {
    static let shared = ClipboardSecurityNotice()
    @Published private(set) var message: String?
    private var dismissal: Task<Void, Never>?

    func show(for kind: ClipboardContentKind) {
        guard kind.expiryNanoseconds != nil else { return }
        message = kind == .terminalOutput
            ? "终端内容已复制，将在 60 秒后自动清除。"
            : "主机密钥指纹已复制，将在 60 秒后自动清除。"
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// Central clipboard policy.  A delayed clear is conditional on the original
/// pasteboard revision so it never deletes text copied by the user afterwards.
@MainActor
enum SecureClipboard {
    @discardableResult
    static func copy(_ content: Data, kind: ClipboardContentKind) -> Bool {
        guard kind.canCopy else { return false }
        ClipboardSecurityNotice.shared.show(for: kind)

#if canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(content, forType: .string) else { return false }
        let revision = board.changeCount
        scheduleClear(kind: kind, matchesRevision: { board.changeCount == revision }) {
            board.clearContents()
        }
#elseif canImport(UIKit)
        let board = UIPasteboard.general
        board.setData(content, forPasteboardType: "public.utf8-plain-text")
        let revision = board.changeCount
        scheduleClear(kind: kind, matchesRevision: { board.changeCount == revision }) {
            board.items = []
        }
#else
        return false
#endif
        return true
    }

    static func copy(_ content: String, kind: ClipboardContentKind) -> Bool {
        copy(Data(content.utf8), kind: kind)
    }

    private static func scheduleClear(
        kind: ClipboardContentKind,
        matchesRevision: @escaping @MainActor () -> Bool,
        clear: @escaping @MainActor () -> Void
    ) {
        guard let expiry = kind.expiryNanoseconds else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: expiry)
            guard !Task.isCancelled, matchesRevision() else { return }
            clear()
        }
    }
}
