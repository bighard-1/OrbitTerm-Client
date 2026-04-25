import Foundation
import Security

struct ServerCredentials: Codable, Equatable {
    var password: String
    var privateKeyContent: String
    var privateKeyPassphrase: String

    var isEmpty: Bool {
        password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            privateKeyPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(password: String = "", privateKeyContent: String = "", privateKeyPassphrase: String = "") {
        self.password = password
        self.privateKeyContent = privateKeyContent
        self.privateKeyPassphrase = privateKeyPassphrase
    }
}

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
        let account = credentialID.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainManager.KeychainError.unhandled(addStatus)
            }
            return
        }

        throw KeychainManager.KeychainError.unhandled(updateStatus)
    }

    func read(for credentialID: UUID) throws -> ServerCredentials? {
        let account = credentialID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unhandled(status)
        }
        guard let data = result as? Data else {
            throw KeychainManager.KeychainError.invalidData
        }
        return try decoder.decode(ServerCredentials.self, from: data)
    }

    func delete(for credentialID: UUID) throws {
        let account = credentialID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainManager.KeychainError.unhandled(status)
    }
}
