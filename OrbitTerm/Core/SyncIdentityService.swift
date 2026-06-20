import CryptoKit
import Foundation

enum SyncIdentityService {
    /// 为同一账号下的传输协议、主机、端口、用户名生成稳定的零知识身份指纹。
    /// 服务端只能比较 HMAC 摘要，无法从摘要还原资产连接信息。
    static func fingerprint(
        portable: PortableServerConfig,
        accountID: String,
        masterPassword: String
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            var derivedKey = try deriveAccountKey(accountID: accountID, masterPassword: masterPassword)
            defer { SecurityPrimitives.secureZero(&derivedKey) }

            let canonical = canonicalIdentity(portable)
            let digest = HMAC<SHA256>.authenticationCode(
                for: Data(canonical.utf8),
                using: SymmetricKey(data: derivedKey)
            )
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func deriveAccountKey(accountID: String, masterPassword: String) throws -> Data {
        let normalizedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let saltDigest = SHA256.hash(data: Data("OrbitTerm.Identity.v1|\(normalizedAccount)".utf8))
        var salt = Data(saltDigest.prefix(16))
        defer { SecurityPrimitives.secureZero(&salt) }

        var passwordC = masterPassword.utf8CString
        defer {
            passwordC.withUnsafeMutableBytes { buffer in
                _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            passwordC.removeAll(keepingCapacity: false)
        }
        let raw = salt.withUnsafeBytes { buffer in
            passwordC.withUnsafeBufferPointer { passwordBuffer in
                orbit_argon2id_derive(
                    passwordBuffer.baseAddress,
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count
                )
            }
        }
        guard let raw else { throw KeychainManager.KeychainError.invalidData }
        defer { orbit_free_string(raw) }

        let response = String(cString: raw)
        guard response.hasPrefix("OK:"),
              let key = Data(base64Encoded: String(response.dropFirst(3))),
              key.count == 32 else {
            throw KeychainManager.KeychainError.invalidData
        }
        return key
    }

    private static func canonicalIdentity(_ portable: PortableServerConfig) -> String {
        let transport = portable.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var host = portable.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        let username = portable.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = ["v1", transport, host, String(portable.port), username]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
