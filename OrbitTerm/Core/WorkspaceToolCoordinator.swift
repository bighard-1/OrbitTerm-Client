import Foundation

/// Minimal per-workspace surface required to coordinate checked companion
/// tools. It deliberately exposes no credentials, terminal handles or UI
/// state, allowing the coordinator to be exercised with fake sessions.
@MainActor
protocol WorkspaceToolSession: AnyObject {
    var id: UUID { get }
    var toolTransport: ServerTransportProtocol { get }
    var isConnected: Bool { get }
    var verifiedSessionLease: VerifiedWorkspaceSession? { get }
    var isSFTPConnected: Bool { get }
    var activeMonitorPanelID: UUID? { get set }
    var toolHost: String { get }
    var toolPort: Int { get }

    func configureToolConnection(
        policy: ConnectionSecurityPolicy,
        checkedDockerOperator: (any CheckedDockerOperating)?
    )
    func openCheckedSFTP(
        baseSessionID: BaseSessionID,
        opener: any CheckedSFTPConnectionOpening
    ) async -> Result<CheckedSFTPConnection, CheckedSFTPServiceError>
    func disconnectSFTP() async
    func rejectCheckedSFTP(_ error: CheckedSFTPServiceError)

    func startCheckedDocker(baseSessionID: BaseSessionID) async -> Result<Void, CheckedDockerServiceError>
    func disconnectDocker() async
    func rejectCheckedDocker(_ error: CheckedDockerServiceError)
    func suspendDockerRefresh() async
    func resumeDockerRefresh() async
}

@MainActor
protocol WorkspaceMonitoring: AnyObject {
    func startCheckedMonitoring(
        workspaceID: UUID,
        baseSessionID: BaseSessionID,
        name: String,
        host: String,
        port: Int
    ) async -> Result<UUID, CheckedMonitorServiceError>
    func suspendMonitoring(_ panelID: UUID) async
    func resumeMonitoring(_ panelID: UUID) async
    func disconnect(_ panelID: UUID) async
    func rejectCheckedStandalone(_ error: CheckedMonitorServiceError)
}

/// Coordinates companion tools which may only attach to an already-verified
/// SSH lease. Late successful operations are immediately torn down when their
/// original workspace or lease is no longer current.
@MainActor
final class WorkspaceToolCoordinator {
    private let policy: ConnectionSecurityPolicy
    private let sftpOpener: any CheckedSFTPConnectionOpening
    private let dockerOperator: any CheckedDockerOperating
    private let monitoring: any WorkspaceMonitoring

    init(
        policy: ConnectionSecurityPolicy,
        sftpOpener: any CheckedSFTPConnectionOpening,
        dockerOperator: any CheckedDockerOperating,
        monitoring: any WorkspaceMonitoring
    ) {
        self.policy = policy
        self.sftpOpener = sftpOpener
        self.dockerOperator = dockerOperator
        self.monitoring = monitoring
    }

    func configure(_ session: any WorkspaceToolSession) {
        session.configureToolConnection(policy: policy, checkedDockerOperator: dockerOperator)
    }

    /// Returns false only for the legacy path, which remains confined to the
    /// existing debug-only fallback in SessionManager.
    func openSFTPIfHandled(for session: any WorkspaceToolSession) async -> Bool {
        configure(session)
        guard policy.requiresCheckedNetwork else { return false }
        guard session.toolTransport == .ssh else {
            session.rejectCheckedSFTP(.requiresVerifiedSession)
            return true
        }
        guard !session.isSFTPConnected else { return true }

        switch SFTPConnectionPolicy(mode: policy).plan(verifiedSession: session.verifiedSessionLease) {
        case let .checked(lease):
            guard owns(session, lease: lease) else { return true }
            let result = await session.openCheckedSFTP(baseSessionID: lease.baseSessionID, opener: sftpOpener)
            guard case .success = result, owns(session, lease: lease) else {
                if case .success = result { await session.disconnectSFTP() }
                return true
            }
        case let .rejected(error):
            session.rejectCheckedSFTP(error)
        case .legacy:
            return false
        }
        return true
    }

    func startMonitorIfHandled(for session: any WorkspaceToolSession, name: String) async -> Bool {
        guard policy.requiresCheckedNetwork else { return false }
        guard session.activeMonitorPanelID == nil else { return true }

        switch MonitorConnectionPolicy(mode: policy).plan(verifiedSession: session.verifiedSessionLease) {
        case let .checked(lease):
            guard owns(session, lease: lease) else { return true }
            let result = await monitoring.startCheckedMonitoring(
                workspaceID: session.id,
                baseSessionID: lease.baseSessionID,
                name: name,
                host: session.toolHost,
                port: session.toolPort
            )
            if case let .success(panelID) = result, owns(session, lease: lease) {
                session.activeMonitorPanelID = panelID
            } else if case let .success(panelID) = result {
                await monitoring.disconnect(panelID)
            }
        case let .rejected(error):
            monitoring.rejectCheckedStandalone(error)
        case .legacy:
            return false
        }
        return true
    }

    func startDockerIfHandled(for session: any WorkspaceToolSession) async -> Bool {
        configure(session)
        guard policy.requiresCheckedNetwork else { return false }

        switch DockerConnectionPolicy(mode: policy).plan(verifiedSession: session.verifiedSessionLease) {
        case let .checked(lease):
            guard owns(session, lease: lease) else { return true }
            let result = await session.startCheckedDocker(baseSessionID: lease.baseSessionID)
            guard case .success = result, owns(session, lease: lease) else {
                if case .success = result { await session.disconnectDocker() }
                return true
            }
        case let .rejected(error):
            session.rejectCheckedDocker(error)
        case .legacy:
            return false
        }
        return true
    }

    func suspendAuxiliaryRefreshes(for session: any WorkspaceToolSession) async {
        await session.suspendDockerRefresh()
        if let panelID = session.activeMonitorPanelID {
            await monitoring.suspendMonitoring(panelID)
        }
    }

    func resumeAuxiliaryRefreshes(for session: any WorkspaceToolSession) async {
        guard session.isConnected else { return }
        await session.resumeDockerRefresh()
        if let panelID = session.activeMonitorPanelID {
            await monitoring.resumeMonitoring(panelID)
        }
    }

    func disconnectCompanionTools(for session: any WorkspaceToolSession) async {
        await session.disconnectSFTP()
        await session.disconnectDocker()
        if let panelID = session.activeMonitorPanelID {
            await monitoring.disconnect(panelID)
        }
    }

    private func owns(_ session: any WorkspaceToolSession, lease: VerifiedWorkspaceSession) -> Bool {
        session.toolTransport == .ssh &&
            session.isConnected &&
            session.verifiedSessionLease?.workspaceID == session.id &&
            session.verifiedSessionLease?.baseSessionID == lease.baseSessionID
    }
}
