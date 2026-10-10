import Foundation

@MainActor
enum AccountSessionActions {
    static func leaveCurrentAccount(session: AppSession, serverStore: ServerStore) {
        let accessToken = session.readToken()
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
        guard !session.isAuthenticated, let accessToken, !accessToken.isEmpty else { return }
        let signedOutRevision = session.authRevision
        Task {
            do {
                try await NetworkService.shared.logoutCurrent(accessToken: accessToken)
            } catch {
                guard !session.isAuthenticated, session.authRevision == signedOutRevision else { return }
                session.reportLogoutRevocationFailure()
            }
        }
    }
}
