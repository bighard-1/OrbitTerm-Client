import Foundation

enum ConnectionSecurityPolicy: Hashable, Sendable {
    case checkedRequired

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    case legacyInternal
    #endif

    static var applicationDefault: ConnectionSecurityPolicy {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        .legacyInternal
        #else
        .checkedRequired
        #endif
    }

    var requiresCheckedNetwork: Bool {
        !allowsLegacyNetwork
    }

    var allowsLegacyNetwork: Bool {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        self == .legacyInternal
        #else
        false
        #endif
    }

    static var allowsTelnet: Bool {
        applicationDefault.allowsLegacyNetwork
    }

    static var allowsLegacyConnectionTest: Bool { allowsTelnet }
    static var allowsLegacyQuickKeyDeployment: Bool { allowsTelnet }
}

enum SessionConnectionPath: Hashable, Sendable {
    case checked

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    case legacyInternal
    #endif
}

struct SessionConnectionDispatcher: Sendable {
    let policy: ConnectionSecurityPolicy

    var path: SessionConnectionPath {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        if policy.allowsLegacyNetwork {
            return .legacyInternal
        }
        #endif
        return .checked
    }

    func run(checked: @escaping @Sendable () async -> Void) async {
        await checked()
    }

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    func run(
        checked: @escaping @Sendable () async -> Void,
        legacyInternal: @escaping @Sendable () async -> Void
    ) async {
        if policy.allowsLegacyNetwork {
            await legacyInternal()
        } else {
            await checked()
        }
    }
    #endif
}

struct CheckedSideServicePolicy: Hashable, Sendable {
    let startsSFTP: Bool
    let startsMonitor: Bool
    let startsDocker: Bool
    let startsBatch: Bool

    static let migrationPending = CheckedSideServicePolicy(
        startsSFTP: false,
        startsMonitor: false,
        startsDocker: false,
        startsBatch: false
    )
}
