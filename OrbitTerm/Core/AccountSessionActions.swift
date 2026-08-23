import Foundation

@MainActor
enum AccountSessionActions {
    static func leaveCurrentAccount(session: AppSession, serverStore: ServerStore) {
        ApplicationOperationLifecycle.apply(
            .accountSignedOut,
            isAuthenticated: session.isAuthenticated,
            isUnlocked: session.isUnlocked,
            sessionManager: .shared
        )
        serverStore.deactivateAccount()
        SnippetStore.shared.deactivateAccount()
        SshKeySyncStore.shared.deactivate()
        PortForwardProfileStore.shared.deactivate()
        session.logout()
    }
}
