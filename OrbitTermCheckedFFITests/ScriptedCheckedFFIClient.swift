import Foundation

actor ScriptedCheckedFFIClient: CheckedFFIClient {
    enum ConnectOutcome: Sendable {
        case connected
        case challenge
        case challengeWithMismatchedRequest
        case blocked(HostKeyBlockReasonCode)
        case error(String)
        case clientError(CheckedFFIClientError)
    }

    enum PersistOutcome: Sendable {
        case persisted
        case error(String)
        case clientError(CheckedFFIClientError)
    }

    enum TerminalOutcome: Sendable {
        case opened
        case clientError(CheckedFFIClientError)
    }

    enum SFTPOutcome: Sendable {
        case opened
        case clientError(CheckedFFIClientError)
    }

    enum MonitorOutcome: Sendable {
        case snapshot
        case clientError(CheckedFFIClientError)
    }

    enum DockerOutcome: Sendable {
        case success
        case clientError(CheckedFFIClientError)
    }

    enum ExecOutcome: Sendable {
        case success
        case result(exitStatus: Int, stdout: String, stderr: String)
        case timedOut
        case outputTruncated
        case clientError(CheckedFFIClientError)
    }

    struct ConnectStep: Sendable {
        let outcome: ConnectOutcome
        let delayNanoseconds: UInt64
        let staleResponse: Bool

        init(
            _ outcome: ConnectOutcome,
            delayNanoseconds: UInt64 = 0,
            staleResponse: Bool = false
        ) {
            self.outcome = outcome
            self.delayNanoseconds = delayNanoseconds
            self.staleResponse = staleResponse
        }
    }

    struct PersistStep: Sendable {
        let outcome: PersistOutcome
        let delayNanoseconds: UInt64
        let staleResponse: Bool

        init(
            _ outcome: PersistOutcome,
            delayNanoseconds: UInt64 = 0,
            staleResponse: Bool = false
        ) {
            self.outcome = outcome
            self.delayNanoseconds = delayNanoseconds
            self.staleResponse = staleResponse
        }
    }

    struct TerminalStep: Sendable {
        let outcome: TerminalOutcome
        let staleResponse: Bool

        init(_ outcome: TerminalOutcome, staleResponse: Bool = false) {
            self.outcome = outcome
            self.staleResponse = staleResponse
        }
    }

    struct SFTPStep: Sendable {
        let outcome: SFTPOutcome
        let staleResponse: Bool

        init(_ outcome: SFTPOutcome, staleResponse: Bool = false) {
            self.outcome = outcome
            self.staleResponse = staleResponse
        }
    }

    struct MonitorStep: Sendable {
        let outcome: MonitorOutcome
        let delayNanoseconds: UInt64
        let staleResponse: Bool

        init(
            _ outcome: MonitorOutcome,
            delayNanoseconds: UInt64 = 0,
            staleResponse: Bool = false
        ) {
            self.outcome = outcome
            self.delayNanoseconds = delayNanoseconds
            self.staleResponse = staleResponse
        }
    }

    struct DockerStep: Sendable {
        let outcome: DockerOutcome
        let delayNanoseconds: UInt64
        let staleResponse: Bool

        init(
            _ outcome: DockerOutcome,
            delayNanoseconds: UInt64 = 0,
            staleResponse: Bool = false
        ) {
            self.outcome = outcome
            self.delayNanoseconds = delayNanoseconds
            self.staleResponse = staleResponse
        }
    }

    struct ExecStep: Sendable {
        let outcome: ExecOutcome
        let delayNanoseconds: UInt64
        let staleResponse: Bool

        init(
            _ outcome: ExecOutcome,
            delayNanoseconds: UInt64 = 0,
            staleResponse: Bool = false
        ) {
            self.outcome = outcome
            self.delayNanoseconds = delayNanoseconds
            self.staleResponse = staleResponse
        }
    }

    private var connectSteps: [ConnectStep]
    private var persistSteps: [PersistStep]
    private var terminalSteps: [TerminalStep]
    private var sftpSteps: [SFTPStep]
    private var monitorSteps: [MonitorStep]
    private var dockerListSteps: [DockerStep]
    private var dockerStatsSteps: [DockerStep]
    private var dockerLogsSteps: [DockerStep]
    private var dockerActionSteps: [DockerStep]
    private var execSteps: [ExecStep]
    private(set) var connectRequestIDs: [HostKeyRequestID] = []
    private(set) var persistRequestIDs: [HostKeyRequestID] = []
    private(set) var persistedChallengeIDs: [String] = []
    private(set) var terminalRequestIDs: [HostKeyRequestID] = []
    private(set) var terminalBaseSessionIDs: [BaseSessionID] = []
    private(set) var sftpRequestIDs: [HostKeyRequestID] = []
    private(set) var sftpBaseSessionIDs: [BaseSessionID] = []
    private(set) var monitorRequestIDs: [HostKeyRequestID] = []
    private(set) var monitorBaseSessionIDs: [BaseSessionID] = []
    private(set) var dockerListRequestIDs: [HostKeyRequestID] = []
    private(set) var dockerStatsRequestIDs: [HostKeyRequestID] = []
    private(set) var dockerLogsRequestIDs: [HostKeyRequestID] = []
    private(set) var dockerActionRequestIDs: [HostKeyRequestID] = []
    private(set) var dockerBaseSessionIDs: [BaseSessionID] = []
    private(set) var dockerContainerIDs: [String] = []
    private(set) var dockerActions: [String] = []
    private(set) var execRequestIDs: [HostKeyRequestID] = []
    private(set) var execBaseSessionIDs: [BaseSessionID] = []
    private(set) var execCommands: [String] = []
    private(set) var execOptions: [CheckedExecOptions] = []
    private var challengeSequence = 0

    init(
        connect: [ConnectStep],
        persist: [PersistStep] = [],
        terminal: [TerminalStep] = [],
        sftp: [SFTPStep] = [],
        monitor: [MonitorStep] = [],
        dockerList: [DockerStep] = [],
        dockerStats: [DockerStep] = [],
        dockerLogs: [DockerStep] = [],
        dockerAction: [DockerStep] = [],
        exec: [ExecStep] = []
    ) {
        connectSteps = connect
        persistSteps = persist
        terminalSteps = terminal
        sftpSteps = sftp
        monitorSteps = monitor
        dockerListSteps = dockerList
        dockerStatsSteps = dockerStats
        dockerLogsSteps = dockerLogs
        dockerActionSteps = dockerAction
        execSteps = exec
    }

    func connectChecked(
        requestID: HostKeyRequestID,
        input: CheckedConnectInput
    ) async throws -> CheckedClientResponse<CheckedConnectResponse> {
        connectRequestIDs.append(requestID)
        guard !connectSteps.isEmpty else { throw CheckedFFIClientError.protocolViolation }
        let step = connectSteps.removeFirst()
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        if case let .clientError(error) = step.outcome { throw error }

        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID
        let response: CheckedConnectResponse
        switch step.outcome {
        case .connected:
            response = .connected(connectedPayload(input: input))
        case .challenge:
            challengeSequence += 1
            response = .challenge(
                challengePayload(requestID: requestID, sequence: challengeSequence)
            )
        case .challengeWithMismatchedRequest:
            challengeSequence += 1
            response = .challenge(
                challengePayload(requestID: try staleRequestID(), sequence: challengeSequence)
            )
        case let .blocked(reason):
            response = .blocked(blockedPayload(reason: reason, input: input))
        case let .error(code):
            response = .failure(errorPayload(code: code, requestID: requestID))
        case .clientError:
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: responseRequestID, value: response)
    }

    func acceptAndPersistHostKey(
        requestID: HostKeyRequestID,
        challengeRequestID: HostKeyRequestID,
        challengeID: String,
        comment: String?
    ) async throws -> CheckedClientResponse<HostKeyTrustPersistResponse> {
        _ = challengeRequestID
        persistRequestIDs.append(requestID)
        persistedChallengeIDs.append(challengeID)
        guard !persistSteps.isEmpty else { throw CheckedFFIClientError.protocolViolation }
        let step = persistSteps.removeFirst()
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        if case let .clientError(error) = step.outcome { throw error }

        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID
        let response: HostKeyTrustPersistResponse
        switch step.outcome {
        case .persisted:
            response = .persisted(persistedPayload(challengeID: challengeID))
        case let .error(code):
            response = .failure(errorPayload(code: code, requestID: requestID))
        case .clientError:
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: responseRequestID, value: response)
    }

    func openTerminalChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        cols: UInt32,
        rows: UInt32
    ) async throws -> CheckedClientResponse<TerminalChannelOpenedPayload> {
        terminalRequestIDs.append(requestID)
        terminalBaseSessionIDs.append(baseSessionID)
        guard !terminalSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let step = terminalSteps.removeFirst()
        if case let .clientError(error) = step.outcome { throw error }
        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: try! TerminalChannelOpenedPayload(
                baseSessionID: baseSessionID,
                terminalChannelID: try! TerminalChannelID("72057594037927938"),
                securityGeneration: .hostKeyVerified,
                cols: cols,
                rows: rows
            )
        )
    }

    func openSFTPChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<SFTPChannelOpenedPayload> {
        sftpRequestIDs.append(requestID)
        sftpBaseSessionIDs.append(baseSessionID)
        guard !sftpSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let step = sftpSteps.removeFirst()
        if case let .clientError(error) = step.outcome { throw error }
        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: SFTPChannelOpenedPayload(
                baseSessionID: baseSessionID,
                sftpSessionID: try! SFTPSessionID("72057594037927937"),
                securityGeneration: .hostKeyVerified
            )
        )
    }

    func monitorSnapshotChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<MonitorSnapshotPayload> {
        monitorRequestIDs.append(requestID)
        monitorBaseSessionIDs.append(baseSessionID)
        guard !monitorSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let step = monitorSteps.removeFirst()
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        if case let .clientError(error) = step.outcome { throw error }
        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: MonitorSnapshotPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                stats: MonitorSnapshotStatsPayload(
                    sampledAtUnix: 1_900_000_000,
                    cpuUsagePercent: 12.3,
                    memAvailableMB: 4_096,
                    memUsedPercent: 45.6,
                    diskUsedPercent: 78.9,
                    pingLatencyMS: nil,
                    rxRateKBPS: 10.5,
                    txRateKBPS: 3.5,
                    systemInfo: MonitorSystemInfo(
                        osName: "Linux 6.8",
                        cpuCoreCount: 4,
                        cpuThreadCount: 8,
                        memoryTotalMB: 16_384,
                        swapTotalMB: 2_048,
                        swapUsedMB: 128,
                        diskTotalMB: 512_000,
                        diskUsedMB: 192_000
                    )
                ),
                diagnostics: [.pingUnavailable]
            )
        )
    }

    func dockerListChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerContainersPayload> {
        dockerListRequestIDs.append(requestID)
        dockerBaseSessionIDs.append(baseSessionID)
        guard !dockerListSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let responseRequestID = try await consumeDockerStep(
            dockerListSteps.removeFirst(),
            requestID: requestID
        )
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: DockerContainersPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                containers: [
                    DockerContainerPayload(
                        id: "abcdef123456",
                        name: "fixture-api",
                        image: "fixture/image:1",
                        state: "running",
                        status: "Up 5 minutes",
                        runningFor: "5 minutes"
                    )
                ]
            )
        )
    }

    func dockerStatsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerStatsPayload> {
        dockerStatsRequestIDs.append(requestID)
        dockerBaseSessionIDs.append(baseSessionID)
        guard !dockerStatsSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let responseRequestID = try await consumeDockerStep(
            dockerStatsSteps.removeFirst(),
            requestID: requestID
        )
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: DockerStatsPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                stats: [
                    DockerStatsItemPayload(
                        id: "abcdef123456",
                        name: "fixture-api",
                        cpuPercent: 2.5,
                        memPercent: 10,
                        memUsage: "100MiB / 1GiB",
                        netIO: "1kB / 2kB",
                        blockIO: "0B / 0B",
                        pids: 8
                    )
                ]
            )
        )
    }

    func dockerLogsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        tail: UInt32
    ) async throws -> CheckedClientResponse<DockerLogsPayload> {
        _ = tail
        dockerLogsRequestIDs.append(requestID)
        dockerBaseSessionIDs.append(baseSessionID)
        dockerContainerIDs.append(containerID)
        guard !dockerLogsSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let responseRequestID = try await consumeDockerStep(
            dockerLogsSteps.removeFirst(),
            requestID: requestID
        )
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: DockerLogsPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                containerID: containerID,
                logs: "fixture log line"
            )
        )
    }

    func dockerActionChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        action: String
    ) async throws -> CheckedClientResponse<DockerActionResultPayload> {
        dockerActionRequestIDs.append(requestID)
        dockerBaseSessionIDs.append(baseSessionID)
        dockerContainerIDs.append(containerID)
        dockerActions.append(action)
        guard !dockerActionSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let responseRequestID = try await consumeDockerStep(
            dockerActionSteps.removeFirst(),
            requestID: requestID
        )
        return CheckedClientResponse(
            requestID: responseRequestID,
            value: DockerActionResultPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                containerID: containerID,
                action: action,
                status: .completed
            )
        )
    }

    func execChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        command: String,
        options: CheckedExecOptions
    ) async throws -> CheckedClientResponse<ExecResultPayload> {
        execRequestIDs.append(requestID)
        execBaseSessionIDs.append(baseSessionID)
        execCommands.append(command)
        execOptions.append(options)
        guard !execSteps.isEmpty else { throw CheckedFFIClientError.unavailable }
        let step = execSteps.removeFirst()
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        if case let .clientError(error) = step.outcome { throw error }
        let responseRequestID = step.staleResponse ? try staleRequestID() : requestID

        let payload: ExecResultPayload
        switch step.outcome {
        case .success:
            payload = try ExecResultPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                exitStatus: 0,
                stdout: "fixture stdout",
                stderr: "",
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        case let .result(exitStatus, stdout, stderr):
            payload = try ExecResultPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                exitStatus: exitStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        case .timedOut:
            payload = try ExecResultPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                exitStatus: 124,
                stdout: "",
                stderr: "",
                timedOut: true,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        case .outputTruncated:
            payload = try ExecResultPayload(
                baseSessionID: baseSessionID,
                securityGeneration: .hostKeyVerified,
                exitStatus: 0,
                stdout: "fixture stdout",
                stderr: "",
                timedOut: false,
                stdoutTruncated: true,
                stderrTruncated: false
            )
        case .clientError:
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: responseRequestID, value: payload)
    }

    private func consumeDockerStep(
        _ step: DockerStep,
        requestID: HostKeyRequestID
    ) async throws -> HostKeyRequestID {
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        if case let .clientError(error) = step.outcome { throw error }
        return step.staleResponse ? try staleRequestID() : requestID
    }

    private func connectedPayload(input: CheckedConnectInput) -> ConnectedPayload {
        ConnectedPayload(
            sessionID: try! BaseSessionID("72057594037927936"),
            host: input.host,
            normalizedHost: input.host.lowercased(),
            port: input.port,
            lookupToken: "[\(input.host.lowercased())]:\(input.port)",
            keyAlgorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:fixtureConnected",
            securityGeneration: .hostKeyVerified
        )
    }

    private func challengePayload(
        requestID: HostKeyRequestID,
        sequence: Int
    ) -> HostKeyChallengePayload {
        HostKeyChallengePayload(
            challengeID: "challenge-\(sequence)",
            requestID: requestID,
            host: "fixture.example",
            normalizedHost: "fixture.example",
            port: 2222,
            lookupToken: "[fixture.example]:2222",
            keyAlgorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:fixtureChallenge\(sequence)",
            reasonCode: .unknownHost,
            knownState: .unknownHost,
            canTrust: true,
            canReplace: false,
            expiresAtUnix: 2_000_000_000,
            reusedExistingChallenge: false,
            relatedRequestCount: 1
        )
    }

    private func blockedPayload(
        reason: HostKeyBlockReasonCode,
        input: CheckedConnectInput
    ) -> HostKeyBlockedPayload {
        let previous = reason == .changed ? "SHA256:fixturePrevious" : nil
        return HostKeyBlockedPayload(
            host: input.host,
            normalizedHost: input.host.lowercased(),
            port: input.port,
            lookupToken: "[\(input.host.lowercased())]:\(input.port)",
            keyAlgorithm: "ssh-ed25519",
            presentedFingerprintSHA256: "SHA256:fixturePresented",
            previousFingerprintSHA256: previous,
            reasonCode: reason,
            knownState: reason == .changed ? .changed : .revoked,
            canTrust: false,
            canReplace: reason == .changed,
            messageKey: reason == .changed ? "host_key.changed" : "host_key.revoked"
        )
    }

    private func persistedPayload(challengeID: String) -> TrustPersistedPayload {
        TrustPersistedPayload(
            challengeID: challengeID,
            host: "fixture.example",
            normalizedHost: "fixture.example",
            port: 2222,
            lookupToken: "[fixture.example]:2222",
            keyAlgorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:fixtureChallenge",
            status: .trustedAdded
        )
    }

    private func errorPayload(
        code: String,
        requestID: HostKeyRequestID
    ) -> CheckedFFIErrorPayload {
        CheckedFFIErrorPayload(
            code: CheckedFFIErrorCode(rawValue: code),
            messageKey: "error.fixture",
            detailCode: "fixture_detail",
            retryable: false,
            requestID: requestID,
            challengeID: nil
        )
    }

    private func staleRequestID() throws -> HostKeyRequestID {
        try HostKeyRequestID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }
}
