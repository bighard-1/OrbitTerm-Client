import Foundation

@MainActor
final class OrbitManager: ObservableObject {
    @Published var statusText: String = "未开始"

    // Swift 封装：调用 Rust C-API 完成加密。
    // 入参 data 为明文字符串，返回密文 Data。
    func encrypt(password: String, data: String) throws -> Data {
        guard let passwordCString = password.cString(using: .utf8) else {
            throw OrbitManagerError.invalidInput("密码编码失败")
        }

        let plainData = Data(data.utf8)
        let resultPtr = plainData.withUnsafeBytes { rawBuffer in
            orbit_encrypt_config(
                passwordCString,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                plainData.count
            )
        }

        return try parseResultAsData(resultPtr)
    }

    // Swift 封装：调用 Rust C-API 完成解密。
    func decrypt(password: String, encrypted: Data) throws -> Data {
        guard let passwordCString = password.cString(using: .utf8) else {
            throw OrbitManagerError.invalidInput("密码编码失败")
        }

        let encryptedB64 = encrypted.base64EncodedString()
        guard let encryptedCString = encryptedB64.cString(using: .utf8) else {
            throw OrbitManagerError.invalidInput("密文编码失败")
        }

        let resultPtr = orbit_decrypt_config(passwordCString, encryptedCString)
        return try parseResultAsData(resultPtr)
    }

    // 调用 Rust 的 SSH 测试接口，支持密码认证与密钥认证（含口令私钥）。
    func testConnection(
        ip: String,
        port: Int = 22,
        username: String,
        password: String,
        privateKeyContent: String = "",
        privateKeyPassphrase: String = "",
        allowPasswordFallback: Bool = true
    ) {
        statusText = "连接中..."

        Task.detached(priority: .userInitiated) {
            let result: String

            if let ipCString = ip.cString(using: .utf8),
               let usernameCString = username.cString(using: .utf8),
               let passwordCString = password.cString(using: .utf8),
               let keyCString = privateKeyContent.cString(using: .utf8),
               let passphraseCString = privateKeyPassphrase.cString(using: .utf8) {
                let ptr = orbit_test_ssh_connection(
                    ipCString,
                    Int32(max(1, min(65535, port))),
                    usernameCString,
                    passwordCString,
                    keyCString,
                    passphraseCString,
                    allowPasswordFallback ? 1 : 0
                )
                result = OrbitManager.parseResultAsStringStatic(ptr)
            } else {
                result = "失败: 参数编码失败"
            }

            await MainActor.run {
                self.statusText = result
            }
        }
    }

    // 异步返回连接测试结果，供 UI 层在不阻塞主线程的情况下复用。
    nonisolated func testConnectionAsync(
        ip: String,
        port: Int = 22,
        username: String,
        password: String,
        privateKeyContent: String = "",
        privateKeyPassphrase: String = "",
        allowPasswordFallback: Bool = true
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            if let ipCString = ip.cString(using: .utf8),
               let usernameCString = username.cString(using: .utf8),
               let passwordCString = password.cString(using: .utf8),
               let keyCString = privateKeyContent.cString(using: .utf8),
               let passphraseCString = privateKeyPassphrase.cString(using: .utf8) {
                let ptr = orbit_test_ssh_connection(
                    ipCString,
                    Int32(max(1, min(65535, port))),
                    usernameCString,
                    passwordCString,
                    keyCString,
                    passphraseCString,
                    allowPasswordFallback ? 1 : 0
                )
                return OrbitManager.parseResultAsStringStatic(ptr)
            }
            return "失败: 参数编码失败"
        }.value
    }

    private func parseResultAsData(_ resultPtr: UnsafeMutablePointer<CChar>?) throws -> Data {
        let raw = Self.parseRaw(resultPtr)
        if raw.hasPrefix("OK:") {
            let payload = String(raw.dropFirst(3))
            guard let decoded = Data(base64Encoded: payload) else {
                throw OrbitManagerError.invalidResponse("Rust 返回的 Base64 数据无效")
            }
            return decoded
        }

        let message = raw.hasPrefix("ERR:") ? String(raw.dropFirst(4)) : raw
        throw OrbitManagerError.rustError(message)
    }

    nonisolated private static func parseResultAsStringStatic(_ resultPtr: UnsafeMutablePointer<CChar>?) -> String {
        let raw = parseRaw(resultPtr)
        if raw.hasPrefix("OK:") {
            return "成功"
        }

        let message = raw.hasPrefix("ERR:") ? String(raw.dropFirst(4)) : raw
        return "失败: \(message)"
    }

    nonisolated private static func parseRaw(_ resultPtr: UnsafeMutablePointer<CChar>?) -> String {
        guard let resultPtr else {
            return "ERR:Rust 返回空指针"
        }

        defer { orbit_free_string(resultPtr) }
        return String(cString: resultPtr)
    }
}

enum OrbitManagerError: LocalizedError {
    case invalidInput(String)
    case invalidResponse(String)
    case rustError(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(msg):
            return msg
        case let .invalidResponse(msg):
            return msg
        case let .rustError(msg):
            return "Rust 调用失败: \(msg)"
        }
    }
}
