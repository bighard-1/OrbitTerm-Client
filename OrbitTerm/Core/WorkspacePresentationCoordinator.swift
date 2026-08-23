import Combine
import Foundation

enum SFTPInitialPathPolicy {
    nonisolated static func preferredPath(username: String) -> String {
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !cleaned.contains("/"),
              !cleaned.contains("\\") else { return "/" }
        return cleaned == "root" ? "/root" : "/home/\(cleaned)"
    }
}

/// The minimal UI-facing identity a workspace must expose. It intentionally
/// excludes connection handles, credentials and service references so tab
/// presentation can be exercised with lightweight fixtures.
@MainActor
protocol WorkspaceSessionPresenting: AnyObject {
    var id: UUID { get }
    var presentationServerID: UUID { get }
}

/// Owns tab ordering and selection only. Connection, terminal, SFTP, Docker
/// and monitor lifecycles remain outside this type.
@MainActor
final class WorkspacePresentationCoordinator<Session: WorkspaceSessionPresenting>: ObservableObject {
    @Published private(set) var tabs: [Session] = []
    @Published private(set) var activeTabID: UUID?

    var activeSession: Session? {
        guard let activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == activeTabID })
    }

    func session(for id: UUID?) -> Session? {
        guard let id else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    func session(forServerID serverID: UUID) -> Session? {
        tabs.first(where: { $0.presentationServerID == serverID })
    }

    @discardableResult
    func appendAndActivate(_ session: Session) -> Session? {
        let previous = activeSession
        tabs.append(session)
        activeTabID = session.id
        return previous
    }

    /// Returns the prior active workspace only when the requested selection
    /// changes. Invalid or already-active IDs leave presentation untouched.
    @discardableResult
    func activate(_ id: UUID) -> Session? {
        guard tabs.contains(where: { $0.id == id }), activeTabID != id else { return nil }
        let previous = activeSession
        activeTabID = id
        return previous
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        let removedWasActive = activeTabID == id
        tabs.removeAll { $0.id == id }
        if removedWasActive {
            activeTabID = tabs.first?.id
        }
        return removedWasActive
    }
}
