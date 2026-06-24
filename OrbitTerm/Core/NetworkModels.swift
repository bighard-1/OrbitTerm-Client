import Foundation

struct AuthRequest: Encodable {
    let username: String
    let password: String
    let invite_code: String?

    init(username: String, password: String, inviteCode: String? = nil) {
        self.username = username
        self.password = password
        invite_code = inviteCode
    }
}

struct RefreshRequest: Encodable {
    let refresh_token: String
}

struct UploadConfigRequest: Codable {
    let id: UInt?
    let asset_id: String?
    let identity_fingerprint: String?
    let encrypted_blob_base64: String
    let vector_clock: String

    init(
        id: UInt?,
        encrypted_blob_base64: String,
        vector_clock: String,
        asset_id: String? = nil,
        identity_fingerprint: String? = nil
    ) {
        self.id = id
        self.asset_id = asset_id
        self.identity_fingerprint = identity_fingerprint
        self.encrypted_blob_base64 = encrypted_blob_base64
        self.vector_clock = vector_clock
    }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
}

struct EmptyResponseData: Decodable {}

struct RegisterData: Decodable {
    let id: UInt
    let username: String
    let created_at: String
}

struct LoginData: Decodable {
    let token: String?
    let access_token: String?
    let refresh_token: String?
    let type: String
    let expires_in_seconds: Int?
    let refresh_expires_in_seconds: Int?

    var accessTokenValue: String {
        access_token ?? token ?? ""
    }

    var refreshTokenValue: String? {
        refresh_token
    }
}

struct UploadConfigData: Decodable {
    let id: UInt
    let user_id: UInt
    let asset_id: String?
    let identity_fingerprint: String?
    let encrypted_blob_base64: String
    let vector_clock: String
    let state: String?
    let deleted_at: String?
    let purge_after: String?
    let deleted_by_device_id: String?
    let last_operation_id: String?
    let server_revision: UInt64?
    let updated_at: String
}

struct PullConfigData: Decodable {
    let items: [UploadConfigData]
}

struct SyncPullData: Decodable {
    let items: [UploadConfigData]
    let next_cursor: UInt64
    let has_more: Bool
    let reset_required: Bool
}

struct TrashConfigData: Decodable {
    let items: [UploadConfigData]
    let total: Int
    let limit: Int
    let offset: Int
}

struct AssetMutationRequest: Codable {
    let device_id: String
    let operation_id: String
    let vector_clock: String
    let confirmation: String?

    init(deviceID: UUID, operationID: UUID = UUID(), vectorClock: String, confirmation: String? = nil) {
        device_id = deviceID.uuidString
        operation_id = operationID.uuidString
        vector_clock = vectorClock
        self.confirmation = confirmation
    }
}

struct SyncAcknowledgementRequest: Encodable {
    let device_id: String
    let revision: UInt64
    let platform: String
    let client_version: String
}

struct SyncAcknowledgementData: Decodable {
    let acknowledged_revision: UInt64
}

struct IdentityMatchData: Decodable {
    let items: [IdentityMatchItem]
}

struct IdentityMatchItem: Decodable, Identifiable {
    let asset_id: String
    let state: String
    let deleted_at: String?
    let purge_after: String?
    let server_revision: UInt64

    var id: String { asset_id }
}

actor RefreshCoordinator {
    private var currentTask: Task<String, Error>?

    func value(_ builder: @escaping @Sendable () async throws -> String) async throws -> String {
        if let task = currentTask {
            return try await task.value
        }
        let task = Task { try await builder() }
        currentTask = task
        defer { currentTask = nil }
        return try await task.value
    }
}
