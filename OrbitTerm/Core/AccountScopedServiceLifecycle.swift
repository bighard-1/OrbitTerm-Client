import Foundation

/// Minimal account lifecycle contract for presentation-only services such as
/// synchronization status and diagnostics exports.
@MainActor
protocol AccountScopedPresentationService: AnyObject {
    func activateAccount(username: String)
    func deactivateAccount()
}

@MainActor
enum AccountScopedServiceLifecycle {
    static func reconcile(
        isAuthenticated: Bool,
        username: String,
        services: [any AccountScopedPresentationService]
    ) {
        guard isAuthenticated, !username.isEmpty else {
            services.forEach { $0.deactivateAccount() }
            return
        }
        services.forEach { $0.activateAccount(username: username) }
    }
}
