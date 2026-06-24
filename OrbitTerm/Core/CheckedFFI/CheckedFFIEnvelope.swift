import Foundation

enum CheckedFFIProtocolError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt32)
    case missingData
    case missingError
    case dataAndErrorPresent
    case unexpectedErrorPayload
    case requestIDMismatch
    case unexpectedKind(CheckedFFIResultKind)
    case unsupportedKind(String)
}

struct CheckedFFIEnvelope<Payload: Decodable>: Decodable {
    static var supportedSchemaVersion: UInt32 { 1 }

    let schemaVersion: UInt32
    let requestID: HostKeyRequestID?
    let kind: CheckedFFIResultKind
    let data: Payload?
    let error: CheckedFFIErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case kind
        case data
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CheckedFFIProtocolError.unsupportedSchemaVersion(schemaVersion)
        }
        requestID = try container.decodeIfPresent(HostKeyRequestID.self, forKey: .requestID)
        kind = try container.decode(CheckedFFIResultKind.self, forKey: .kind)
        data = try container.decodeIfPresent(Payload.self, forKey: .data)
        error = try container.decodeIfPresent(CheckedFFIErrorPayload.self, forKey: .error)

        if data != nil, error != nil {
            throw CheckedFFIProtocolError.dataAndErrorPresent
        }
        if kind == .error {
            guard data == nil else { throw CheckedFFIProtocolError.dataAndErrorPresent }
            guard let error else { throw CheckedFFIProtocolError.missingError }
            guard error.requestID == requestID else {
                throw CheckedFFIProtocolError.requestIDMismatch
            }
        } else {
            guard error == nil else { throw CheckedFFIProtocolError.unexpectedErrorPayload }
            guard data != nil else { throw CheckedFFIProtocolError.missingData }
        }
    }

    func validateRequestID(_ expected: HostKeyRequestID) throws {
        guard requestID == expected else {
            throw CheckedFFIProtocolError.requestIDMismatch
        }
    }

    func validateKind(_ expected: CheckedFFIResultKind) throws {
        guard kind == expected else {
            throw CheckedFFIProtocolError.unexpectedKind(kind)
        }
    }
}

private struct CheckedFFIEnvelopeHeader: Decodable {
    let schemaVersion: UInt32
    let requestID: HostKeyRequestID?
    let kind: CheckedFFIResultKind

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case kind
    }
}

private struct EmptyCheckedFFIPayload: Decodable {}

enum CheckedConnectResponse: Sendable {
    case connected(ConnectedPayload)
    case challenge(HostKeyChallengePayload)
    case blocked(HostKeyBlockedPayload)
    case failure(CheckedFFIErrorPayload)

    static func decode(
        _ responseData: Data,
        expectedRequestID: HostKeyRequestID,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Self {
        let header = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelopeHeader.self,
            from: responseData,
            using: decoder
        )
        guard header.schemaVersion == 1 else {
            throw CheckedFFIProtocolError.unsupportedSchemaVersion(header.schemaVersion)
        }
        guard header.requestID == expectedRequestID else {
            throw CheckedFFIProtocolError.requestIDMismatch
        }

        switch header.kind {
        case .connected:
            let envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<ConnectedPayload>.self,
                from: responseData,
                using: decoder
            )
            try envelope.validateRequestID(expectedRequestID)
            guard let payload = envelope.data else {
                throw CheckedFFIProtocolError.missingData
            }
            return .connected(payload)
        case .hostKeyChallenge:
            let envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<HostKeyChallengePayload>.self,
                from: responseData,
                using: decoder
            )
            try envelope.validateRequestID(expectedRequestID)
            guard envelope.data?.requestID == expectedRequestID else {
                throw CheckedFFIProtocolError.requestIDMismatch
            }
            guard let payload = envelope.data else {
                throw CheckedFFIProtocolError.missingData
            }
            return .challenge(payload)
        case .hostKeyBlocked:
            let envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<HostKeyBlockedPayload>.self,
                from: responseData,
                using: decoder
            )
            try envelope.validateRequestID(expectedRequestID)
            guard let payload = envelope.data else {
                throw CheckedFFIProtocolError.missingData
            }
            return .blocked(payload)
        case .error:
            let envelope = try CheckedFFIWireDecoder.decode(
                CheckedFFIEnvelope<EmptyCheckedFFIPayload>.self,
                from: responseData,
                using: decoder
            )
            try envelope.validateRequestID(expectedRequestID)
            guard let error = envelope.error else {
                throw CheckedFFIProtocolError.missingError
            }
            return .failure(error)
        case let .unknown(rawValue):
            throw CheckedFFIProtocolError.unsupportedKind(rawValue)
        default:
            throw CheckedFFIProtocolError.unexpectedKind(header.kind)
        }
    }
}
