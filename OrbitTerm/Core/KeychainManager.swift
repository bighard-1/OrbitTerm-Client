import Foundation
import Security

// KeychainManager 负责在系统钥匙串中安全存储敏感信息。
// 这里专门用于保存 JWT Token 与 Master Password。
final class KeychainManager {
    static let shared = KeychainManager()

    private init() {}

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case let .unhandled(status):
                return "Keychain 操作失败，状态码: \(status)"
            case .invalidData:
                return "Keychain 数据格式错误"
            }
        }
    }

    func saveString(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try KeychainDataStore.save(data, service: service, account: account)
    }

    func readString(service: String, account: String) throws -> String? {
        guard let data = try KeychainDataStore.read(service: service, account: account) else {
            return nil
        }
        guard
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func delete(service: String, account: String) throws {
        try KeychainDataStore.delete(service: service, account: account)
    }
}
