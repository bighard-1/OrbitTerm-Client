import Foundation

struct OrbitCoreCheckedConnectCall: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let host: String
    let port: Int32
    let username: String
    let credentials: CheckedCredentials
    let knownHostsPath: String
    let requestID: String

    var description: String {
        "OrbitCoreCheckedConnectCall(host: [REDACTED], port: \(port), credentials: [REDACTED])"
    }

    var debugDescription: String { description }
}

struct OrbitCoreHostKeyPersistCall: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let challengeID: String
    let knownHostsPath: String
    let comment: String?

    var description: String { "OrbitCoreHostKeyPersistCall([REDACTED])" }
    var debugDescription: String { description }
}

struct OrbitCoreTerminalOpenCall: Sendable {
    let baseSessionID: UInt64
    let cols: UInt32
    let rows: UInt32
    let requestID: String
}

struct OrbitCoreSFTPOpenCall: Sendable {
    let baseSessionID: UInt64
    let requestID: String
}

struct OrbitCoreMonitorSnapshotCall: Sendable {
    let baseSessionID: UInt64
    let requestID: String
}

struct OrbitCoreDockerSessionCall: Sendable {
    let baseSessionID: UInt64
    let requestID: String
}

struct OrbitCoreDockerLogsCall: Sendable {
    let baseSessionID: UInt64
    let containerID: String
    let tail: UInt32
    let requestID: String
}

struct OrbitCoreDockerActionCall: Sendable {
    let baseSessionID: UInt64
    let containerID: String
    let action: String
    let requestID: String
}

struct OrbitCoreExecCheckedCall: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let baseSessionID: UInt64
    let command: String
    let timeoutSeconds: UInt32
    let maxStdoutBytes: UInt32
    let maxStderrBytes: UInt32
    let requestID: String

    var description: String {
        "OrbitCoreExecCheckedCall(baseSessionID: \(baseSessionID), command: [REDACTED])"
    }

    var debugDescription: String { description }
}

struct OrbitCoreCheckedFFIFunctions: @unchecked Sendable {
    typealias Connect = @Sendable (OrbitCoreCheckedConnectCall) -> UnsafeMutablePointer<CChar>?
    typealias Persist = @Sendable (OrbitCoreHostKeyPersistCall) -> UnsafeMutablePointer<CChar>?
    typealias OpenTerminal = @Sendable (OrbitCoreTerminalOpenCall) -> UnsafeMutablePointer<CChar>?
    typealias OpenSFTP = @Sendable (OrbitCoreSFTPOpenCall) -> UnsafeMutablePointer<CChar>?
    typealias MonitorSnapshot = @Sendable (OrbitCoreMonitorSnapshotCall) -> UnsafeMutablePointer<CChar>?
    typealias DockerSession = @Sendable (OrbitCoreDockerSessionCall) -> UnsafeMutablePointer<CChar>?
    typealias DockerLogs = @Sendable (OrbitCoreDockerLogsCall) -> UnsafeMutablePointer<CChar>?
    typealias DockerAction = @Sendable (OrbitCoreDockerActionCall) -> UnsafeMutablePointer<CChar>?
    typealias ExecChecked = @Sendable (OrbitCoreExecCheckedCall) -> UnsafeMutablePointer<CChar>?

    let connect: Connect
    let persist: Persist
    let openTerminal: OpenTerminal
    let openSFTP: OpenSFTP
    let monitorSnapshot: MonitorSnapshot
    let dockerList: DockerSession
    let dockerStats: DockerSession
    let dockerLogs: DockerLogs
    let dockerAction: DockerAction
    let execChecked: ExecChecked
}

actor OrbitCoreCheckedFFIClient: CheckedFFIClient {
    private static let maximumCommentUTF8Length = 256
    private static let maximumChallengeIDUTF8Length = 256

    private let credentialProvider: any CheckedCredentialProvider
    private let knownHostsPathProvider: any KnownHostsPathProvider
    private let functions: OrbitCoreCheckedFFIFunctions
    private let resultReader: OrbitCStringResultReader

    init(
        credentialProvider: any CheckedCredentialProvider,
        knownHostsPathProvider: any KnownHostsPathProvider,
        functions: OrbitCoreCheckedFFIFunctions,
        resultReader: OrbitCStringResultReader
    ) {
        self.credentialProvider = credentialProvider
        self.knownHostsPathProvider = knownHostsPathProvider
        self.functions = functions
        self.resultReader = resultReader
    }

    func connectChecked(
        requestID: HostKeyRequestID,
        input: CheckedConnectInput
    ) async throws -> CheckedClientResponse<CheckedConnectResponse> {
        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, input.port > 0 else {
            throw CheckedFFIClientError.invalidInput
        }

        let credentials: CheckedCredentials
        do {
            credentials = try await credentialProvider.credentials(for: input.credentialReference)
        } catch let error as CheckedFFIClientError {
            throw error
        } catch {
            throw CheckedFFIClientError.invalidInput
        }
        guard !credentials.password.isEmpty || !credentials.privateKey.isEmpty else {
            throw CheckedFFIClientError.invalidInput
        }

        let call = OrbitCoreCheckedConnectCall(
            host: host,
            port: Int32(input.port),
            username: username,
            credentials: credentials,
            knownHostsPath: try loadKnownHostsPath(),
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.connect(call))
        let response = try decodeConnect(json, expectedRequestID: requestID)
        return CheckedClientResponse(requestID: requestID, value: response)
    }

    func acceptAndPersistHostKey(
        requestID: HostKeyRequestID,
        challengeRequestID: HostKeyRequestID,
        challengeID: String,
        comment: String?
    ) async throws -> CheckedClientResponse<HostKeyTrustPersistResponse> {
        guard Self.validChallengeID(challengeID), Self.validComment(comment) else {
            throw CheckedFFIClientError.invalidInput
        }
        let call = OrbitCoreHostKeyPersistCall(
            challengeID: challengeID,
            knownHostsPath: try loadKnownHostsPath(),
            comment: comment
        )
        let json = try resultReader.take(functions.persist(call))
        let response = try decodePersist(
            json,
            challengeRequestID: challengeRequestID,
            challengeID: challengeID
        )
        return CheckedClientResponse(requestID: requestID, value: response)
    }

    func openTerminalChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        cols: UInt32,
        rows: UInt32
    ) async throws -> CheckedClientResponse<TerminalChannelOpenedPayload> {
        guard (1 ... 1_000).contains(cols), (1 ... 1_000).contains(rows) else {
            throw CheckedFFIClientError.invalidInput
        }
        let call = OrbitCoreTerminalOpenCall(
            baseSessionID: baseSessionID.ffiValue,
            cols: cols,
            rows: rows,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.openTerminal(call))
        let payload: TerminalChannelOpenedPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .terminalChannelOpened
        )
        guard payload.baseSessionID == baseSessionID else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func openSFTPChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<SFTPChannelOpenedPayload> {
        let call = OrbitCoreSFTPOpenCall(
            baseSessionID: baseSessionID.ffiValue,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.openSFTP(call))
        let payload: SFTPChannelOpenedPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .sftpChannelOpened
        )
        guard payload.baseSessionID == baseSessionID else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func monitorSnapshotChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<MonitorSnapshotPayload> {
        let call = OrbitCoreMonitorSnapshotCall(
            baseSessionID: baseSessionID.ffiValue,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.monitorSnapshot(call))
        let payload: MonitorSnapshotPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .monitorSnapshot
        )
        guard payload.baseSessionID == baseSessionID else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func dockerListChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerContainersPayload> {
        let call = OrbitCoreDockerSessionCall(
            baseSessionID: baseSessionID.ffiValue,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.dockerList(call))
        let payload: DockerContainersPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .dockerContainers
        )
        try Self.validateDockerBase(payload.baseSessionID, expected: baseSessionID)
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func dockerStatsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerStatsPayload> {
        let call = OrbitCoreDockerSessionCall(
            baseSessionID: baseSessionID.ffiValue,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.dockerStats(call))
        let payload: DockerStatsPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .dockerStats
        )
        try Self.validateDockerBase(payload.baseSessionID, expected: baseSessionID)
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func dockerLogsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        tail: UInt32
    ) async throws -> CheckedClientResponse<DockerLogsPayload> {
        guard Self.validDockerContainerID(containerID), tail <= 10_000 else {
            throw CheckedFFIClientError.invalidInput
        }
        let call = OrbitCoreDockerLogsCall(
            baseSessionID: baseSessionID.ffiValue,
            containerID: containerID,
            tail: tail,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.dockerLogs(call))
        let payload: DockerLogsPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .dockerLogs
        )
        try Self.validateDockerBase(payload.baseSessionID, expected: baseSessionID)
        guard payload.containerID == containerID else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func dockerActionChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        action: String
    ) async throws -> CheckedClientResponse<DockerActionResultPayload> {
        guard Self.validDockerContainerID(containerID), Self.validDockerAction(action) else {
            throw CheckedFFIClientError.invalidInput
        }
        let call = OrbitCoreDockerActionCall(
            baseSessionID: baseSessionID.ffiValue,
            containerID: containerID,
            action: action,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.dockerAction(call))
        let payload: DockerActionResultPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .dockerActionResult
        )
        try Self.validateDockerBase(payload.baseSessionID, expected: baseSessionID)
        guard payload.containerID == containerID, payload.action == action else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    func execChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        command: String,
        options: CheckedExecOptions
    ) async throws -> CheckedClientResponse<ExecResultPayload> {
        guard Self.validCheckedCommand(command), options.isValid else {
            throw CheckedFFIClientError.invalidInput
        }
        let call = OrbitCoreExecCheckedCall(
            baseSessionID: baseSessionID.ffiValue,
            command: command,
            timeoutSeconds: options.timeoutSeconds,
            maxStdoutBytes: options.maxStdoutBytes,
            maxStderrBytes: options.maxStderrBytes,
            requestID: requestID.rawValue
        )
        let json = try resultReader.take(functions.execChecked(call))
        let payload: ExecResultPayload = try decodePayload(
            json,
            expectedRequestID: requestID,
            expectedKind: .execResult
        )
        guard payload.baseSessionID == baseSessionID else {
            throw CheckedFFIClientError.protocolViolation
        }
        return CheckedClientResponse(requestID: requestID, value: payload)
    }

    private static func validateDockerBase(
        _ actual: BaseSessionID,
        expected: BaseSessionID
    ) throws {
        guard actual == expected else {
            throw CheckedFFIClientError.protocolViolation
        }
    }

    private static func validDockerContainerID(_ value: String) -> Bool {
        (12 ... 64).contains(value.utf8.count) &&
            value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (65 ... 70).contains(byte) ||
                    (97 ... 102).contains(byte)
            }
    }

    private static func validDockerAction(_ value: String) -> Bool {
        ["start", "stop", "restart", "kill", "pause", "unpause", "remove"].contains(value)
    }

    private static func validCheckedCommand(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
              value.utf8.count <= 16_384 else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private func loadKnownHostsPath() throws -> String {
        let path: String
        do {
            path = try knownHostsPathProvider.knownHostsPath()
        } catch {
            throw CheckedFFIClientError.invalidInput
        }
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.contains("\0"),
              !path.hasSuffix("/.ssh/known_hosts") else {
            throw CheckedFFIClientError.invalidInput
        }
        return path
    }

    private func decodeConnect(
        _ json: String,
        expectedRequestID: HostKeyRequestID
    ) throws -> CheckedConnectResponse {
        do {
            return try CheckedConnectResponse.decode(
                Data(json.utf8),
                expectedRequestID: expectedRequestID
            )
        } catch {
            throw Self.mapDecodeError(error)
        }
    }

    private func decodePersist(
        _ json: String,
        challengeRequestID: HostKeyRequestID,
        challengeID: String
    ) throws -> HostKeyTrustPersistResponse {
        let data = Data(json.utf8)
        let header: OrbitCheckedEnvelopeHeader
        do {
            header = try CheckedFFIWireDecoder.decode(OrbitCheckedEnvelopeHeader.self, from: data)
        } catch {
            throw Self.mapDecodeError(error)
        }
        try Self.validateSchema(header.schemaVersion)
        if let responseRequestID = header.requestID,
           responseRequestID != challengeRequestID {
            throw CheckedFFIClientError.requestIDMismatch
        }

        let envelope: CheckedFFIEnvelope<TrustPersistedPayload>
        do {
            envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<TrustPersistedPayload>.self,
                from: data
            )
        } catch {
            throw Self.mapDecodeError(error)
        }

        switch header.kind {
        case .hostKeyTrustPersisted:
            guard header.requestID == challengeRequestID,
                  let payload = envelope.data,
                  payload.challengeID == challengeID else {
                throw CheckedFFIClientError.requestIDMismatch
            }
            return .persisted(payload)
        case .error:
            guard let error = envelope.error else {
                throw CheckedFFIClientError.protocolViolation
            }
            if header.requestID == nil, error.challengeID != challengeID {
                throw CheckedFFIClientError.requestIDMismatch
            }
            if let responseChallengeID = error.challengeID,
               responseChallengeID != challengeID {
                throw CheckedFFIClientError.requestIDMismatch
            }
            return .failure(error)
        case let .unknown(rawValue):
            throw CheckedFFIClientError.unknownKind(rawValue)
        default:
            throw CheckedFFIClientError.unexpectedKind(header.kind)
        }
    }

    private func decodePayload<Payload: Decodable>(
        _ json: String,
        expectedRequestID: HostKeyRequestID,
        expectedKind: CheckedFFIResultKind
    ) throws -> Payload {
        let data = Data(json.utf8)
        let header: OrbitCheckedEnvelopeHeader
        do {
            header = try CheckedFFIWireDecoder.decode(OrbitCheckedEnvelopeHeader.self, from: data)
        } catch {
            throw Self.mapDecodeError(error)
        }
        try Self.validateSchema(header.schemaVersion)
        guard header.requestID == expectedRequestID else {
            throw CheckedFFIClientError.requestIDMismatch
        }
        if case let .unknown(rawValue) = header.kind {
            throw CheckedFFIClientError.unknownKind(rawValue)
        }
        if header.kind == .error {
            let envelope: CheckedFFIEnvelope<Payload>
            do {
                envelope = try CheckedFFIWireDecoder.decode(
                    CheckedFFIEnvelope<Payload>.self,
                    from: data
                )
            } catch {
                throw Self.mapDecodeError(error)
            }
            guard let error = envelope.error else {
                throw CheckedFFIClientError.protocolViolation
            }
            throw CheckedFFIClientError.ffiErrorPayload(error)
        }
        guard header.kind == expectedKind else {
            throw CheckedFFIClientError.unexpectedKind(header.kind)
        }

        let envelope: CheckedFFIEnvelope<Payload>
        do {
            envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<Payload>.self,
                from: data
            )
        } catch {
            throw Self.mapDecodeError(error)
        }
        guard let payload = envelope.data else {
            throw CheckedFFIClientError.protocolViolation
        }
        return payload
    }

    private static func validateSchema(_ version: UInt32) throws {
        guard version == 1 else {
            throw CheckedFFIClientError.unsupportedSchema(version)
        }
    }

    private static func mapDecodeError(_ error: Error) -> CheckedFFIClientError {
        switch error {
        case let CheckedFFIProtocolError.unsupportedSchemaVersion(version):
            .unsupportedSchema(version)
        case CheckedFFIProtocolError.requestIDMismatch:
            .requestIDMismatch
        case let CheckedFFIProtocolError.unexpectedKind(kind):
            .unexpectedKind(kind)
        case let CheckedFFIProtocolError.unsupportedKind(rawValue):
            .unknownKind(rawValue)
        case is CheckedFFIProtocolError, is CheckedFFIIDError, is CheckedFFIPayloadError:
            .jsonDecodeFailed
        default:
            .jsonDecodeFailed
        }
    }

    private static func validChallengeID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumChallengeIDUTF8Length
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 95
                    || $0 == 45
            }
    }

    private static func validComment(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumCommentUTF8Length
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private struct OrbitCheckedEnvelopeHeader: Decodable {
    let schemaVersion: UInt32
    let requestID: HostKeyRequestID?
    let kind: CheckedFFIResultKind

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case kind
    }
}
