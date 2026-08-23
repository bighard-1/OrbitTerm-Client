import Foundation

/// Lifecycle events that may change the ownership of account-scoped work.
/// They deliberately describe application policy rather than platform APIs so
/// the rules remain testable without a SwiftUI scene or live connection.
enum ApplicationOperationLifecycleEvent: Equatable {
    case becameActive
    case becameInactive
    case enteredBackground
    case accountLocked
    case accountSignedOut
    case mainWindowClosed
    case applicationTerminating
}

enum ApplicationOperationQueueDisposition: Equatable {
    case resume
    case suspend
}

struct ApplicationOperationLifecycleDirective: Equatable {
    let syncQueue: ApplicationOperationQueueDisposition
    let auxiliaryRefreshesActive: Bool
    let closeSessions: Bool
    let clearTransientSensitiveInput: Bool
}

/// Product-level lifecycle contract:
/// - an inactive app pauses refresh work but does not tear down a macOS user’s
///   visible workspace merely because focus changed;
/// - iOS backgrounding pauses application-owned refreshes. The operating
///   system may later suspend or close a socket; OrbitTerm never promises a
///   persistent background SSH connection. A configured master-password lock
///   then follows the existing account-lock teardown path;
/// - locking, signing out, or explicitly terminating the application closes
///   sessions, so no invisible SSH/SFTP/Docker/Monitor work survives without
///   an unlocked account owner;
/// - closing a macOS window is intentionally different from quitting: it
///   pauses visible auxiliary work but leaves the independently-owned session
///   lifecycle untouched. This preserves a workspace when macOS keeps the app
///   alive after its last window is closed;
/// - only an active, authenticated, unlocked account may resume background
///   work.
enum ApplicationOperationLifecyclePolicy {
    static func directive(
        for event: ApplicationOperationLifecycleEvent,
        isAuthenticated: Bool,
        isUnlocked: Bool
    ) -> ApplicationOperationLifecycleDirective {
        switch event {
        case .accountLocked, .accountSignedOut, .applicationTerminating:
            return ApplicationOperationLifecycleDirective(
                syncQueue: .suspend,
                auxiliaryRefreshesActive: false,
                closeSessions: true,
                clearTransientSensitiveInput: true
            )
        case .becameInactive, .enteredBackground, .mainWindowClosed:
            return ApplicationOperationLifecycleDirective(
                syncQueue: .suspend,
                auxiliaryRefreshesActive: false,
                closeSessions: false,
                clearTransientSensitiveInput: true
            )
        case .becameActive:
            let canResume = isAuthenticated && isUnlocked
            return ApplicationOperationLifecycleDirective(
                syncQueue: canResume ? .resume : .suspend,
                auxiliaryRefreshesActive: canResume,
                closeSessions: false,
                clearTransientSensitiveInput: !canResume
            )
        }
    }
}
