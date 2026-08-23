import Foundation

/// Applies the pure lifecycle policy to the existing application services.
/// It owns no connection state: `SessionManager` remains the sole place that
/// performs the established per-session disconnect sequence.
@MainActor
enum ApplicationOperationLifecycle {
    static func apply(
        _ event: ApplicationOperationLifecycleEvent,
        isAuthenticated: Bool,
        isUnlocked: Bool,
        sessionManager: SessionManager,
        syncQueue: SyncQueue = .shared
    ) {
        let directive = ApplicationOperationLifecyclePolicy.directive(
            for: event,
            isAuthenticated: isAuthenticated,
            isUnlocked: isUnlocked
        )

        if directive.clearTransientSensitiveInput {
            NotificationCenter.default.post(
                name: .orbitTermClearTransientSensitiveInput,
                object: nil
            )
            SyncService.shared.clearTransientConfigCrypto()
        }

        if directive.closeSessions {
            sessionManager.closeAllTabs()
        }

        sessionManager.setAuxiliaryRefreshesActive(directive.auxiliaryRefreshesActive)
        switch directive.syncQueue {
        case .resume:
            syncQueue.resumeProcessing()
        case .suspend:
            syncQueue.suspendProcessing()
        }
    }
}
