import Foundation

/// A non-persistent UI-test-only root state. It never creates credentials,
/// writes Keychain data, or opens network services. Public Release builds
/// always use `.standard` regardless of the process environment.
enum AppUITestLaunchState: Equatable {
    case standard
    #if !ORBITTERM_PUBLIC_RELEASE
    case unauthenticated
    case authenticatedLocked
    case authenticatedUnlocked
    #endif

    static var current: Self {
        // UI-test fixtures are a non-public-build test harness. Requiring the
        // explicit marker keeps an arbitrary launch argument from putting a
        // normal development run into an in-memory account state, while
        // Release builds compile to `.standard` unconditionally.
        #if !ORBITTERM_PUBLIC_RELEASE
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("-orbitTermUITest") else {
            return .standard
        }
        let launchArgument = processInfo.arguments
            .drop { $0 != "-orbitTermUITestState" }
            .dropFirst()
            .first
        let requestedState = launchArgument
            ?? processInfo.environment["ORBITTERM_UI_TEST_STATE"]

        switch requestedState {
        case "unauthenticated":
            return .unauthenticated
        case "authenticated_locked":
            return .authenticatedLocked
        case "authenticated_unlocked":
            return .authenticatedUnlocked
        default:
            return .standard
        }
        #else
        return .standard
        #endif
    }
}
