import Foundation

/// Keeps the V2 migration gate independent from the transport and from UI
/// text. A completed local marker avoids recurring background preflights, but
/// an explicit full sync is always allowed to verify that marker against the
/// currently authenticated cloud snapshot.
enum SyncConfigCipherMigrationPolicy {
    static func shouldAttempt(
        hasCompletedMarker: Bool,
        isExplicitFullSync: Bool,
        cooldownAllowsRetry: Bool
    ) -> Bool {
        if isExplicitFullSync {
            return true
        }
        return !hasCompletedMarker && cooldownAllowsRetry
    }

    static func userMessage(for result: Result) -> String {
        switch result {
        case let .migrated(count):
            return "加密格式迁移完成：\(count) 项"
        case let .alreadyVerified(count):
            return "加密格式已验证：\(count) 项"
        case let .pendingRetry(code):
            return "加密格式迁移待重试（\(code)）"
        }
    }

    enum Result: Equatable {
        case migrated(Int)
        case alreadyVerified(Int)
        /// The code is an app-owned recovery category, never a server error
        /// string, URL, account, asset, path, or encrypted payload.
        case pendingRetry(String)
    }
}
