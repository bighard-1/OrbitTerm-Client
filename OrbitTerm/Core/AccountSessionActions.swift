import Foundation

@MainActor
enum AccountSessionActions {
    static func leaveCurrentAccount(session: AppSession, serverStore: ServerStore) {
        SessionManager.shared.closeAllTabs()
        serverStore.deactivateAccount()
        SnippetStore.shared.deactivateAccount()
        session.logout()
    }
}
