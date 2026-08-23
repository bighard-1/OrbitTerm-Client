import Foundation
import Security

// CredentialVault 仅托管敏感凭据：
// - password
// - privateKeyContent
// 普通服务器元数据继续由 ServerStore 管理，形成物理隔离。
final class CredentialVault {
    static let shared = CredentialVault()

    private let service = "com.orbitterm.credentials.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func save(_ credentials: ServerCredentials, for credentialID: UUID) throws {
        let data = try encoder.encode(credentials)
        try KeychainDataStore.save(data, service: service, account: credentialID.uuidString)
    }

    func read(for credentialID: UUID) throws -> ServerCredentials? {
        guard let data = try KeychainDataStore.read(service: service, account: credentialID.uuidString) else {
            return nil
        }
        return try decoder.decode(ServerCredentials.self, from: data)
    }

    func delete(for credentialID: UUID) throws {
        try KeychainDataStore.delete(service: service, account: credentialID.uuidString)
    }
}

enum SecurityPrimitives {
    static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unhandled(status)
        }
        return bytes
    }

    static func secureZero(_ data: inout Data) {
        data.withUnsafeMutableBytes { rawBuf in
            guard rawBuf.count > 0 else { return }
            _ = rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
        }
        data.removeAll(keepingCapacity: false)
    }

    static func secureZero(_ text: inout String) {
        if text.isEmpty {
            return
        }
        let length = text.utf8.count
        text = String(repeating: "\0", count: length)
        text.removeAll(keepingCapacity: false)
    }
}
