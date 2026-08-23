import Foundation

enum SFTPError: LocalizedError {
    case notConnected
    case timeout
    case invalidResponse
    case rustError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SFTP 未连接"
        case .timeout:
            return "网络连接超时，请检查 SSH 服务状态后重试"
        case .invalidResponse:
            return "Rust 返回了无效响应"
        case let .rustError(message):
            return message
        }
    }
}

enum RustFFI {
    struct GeneratedEd25519KeyPair: Decodable {
        let privateKey: String
        let publicKey: String
        let format: String

        private enum CodingKeys: String, CodingKey {
            case privateKey = "private_key"
            case publicKey = "public_key"
            case format
        }
    }

    nonisolated static func clampedPort(_ port: Int) -> Int32 {
        Int32(max(1, min(65_535, port)))
    }

    nonisolated static func call(_ call: () -> UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr = call() else {
            return "ERR:Rust 返回空指针"
        }

        defer { orbit_free_string(ptr) }
        return String(cString: ptr)
    }

    nonisolated static func parseOKPayload(_ raw: String) throws -> String {
        if raw.hasPrefix("OK:") {
            return String(raw.dropFirst(3))
        }
        if raw.hasPrefix("ERR:") {
            throw SFTPError.rustError(String(raw.dropFirst(4)))
        }
        throw SFTPError.invalidResponse
    }

    nonisolated static func parseSessionID(_ payload: String) -> UInt64? {
        var normalized = payload
        if normalized.hasPrefix("session:") {
            normalized = String(normalized.dropFirst("session:".count))
        }
        return UInt64(normalized)
    }

    nonisolated static func generateEd25519KeyPair(comment: String) throws -> GeneratedEd25519KeyPair {
        let raw = comment.withCString { orbit_generate_ed25519_key_pair_v1($0) }
        let payload = try parseOKPayload(call { raw })
        guard let data = payload.data(using: .utf8) else { throw SFTPError.invalidResponse }
        return try JSONDecoder().decode(GeneratedEd25519KeyPair.self, from: data)
    }

    nonisolated static func publicKey(privateKey: String, passphrase: String) throws -> String {
        let raw = privateKey.withCString { privateKeyPointer in
            passphrase.withCString { passphrasePointer in
                orbit_ssh_public_key_from_private_v1(privateKeyPointer, passphrasePointer)
            }
        }
        return try parseOKPayload(call { raw })
    }

    nonisolated static func callWithTimeout(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?
    ) async throws -> String {
        try await runWithTimeout(seconds: seconds) {
            try parseOKPayload(RustFFI.call(operation))
        }
    }

    nonisolated static func runWithTimeout<T>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .userInitiated) {
                try work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SFTPError.timeout
            }

            guard let first = try await group.next() else {
                throw SFTPError.invalidResponse
            }
            group.cancelAll()
            return first
        }
    }

    nonisolated static func requestChannel(
        baseSessionID: UInt64,
        type: String
    ) -> UnsafeMutablePointer<CChar>? {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        type.withCString { typePtr in
            orbit_request_channel(baseSessionID, typePtr)
        }
        #else
        nil
        #endif
    }

    nonisolated static func connectSFTP(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKeyContent: String,
        privateKeyPassphrase: String,
        allowPasswordFallback: Bool
    ) -> UnsafeMutablePointer<CChar>? {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleanHost.withCString { hostPtr in
            cleanUsername.withCString { userPtr in
                password.withCString { passwordPtr in
                    cleanKey.withCString { keyPtr in
                        privateKeyPassphrase.withCString { passphrasePtr in
                            orbit_sftp_connect(
                                hostPtr,
                                clampedPort(port),
                                userPtr,
                                passwordPtr,
                                keyPtr,
                                passphrasePtr,
                                allowPasswordFallback ? 1 : 0
                            )
                        }
                    }
                }
            }
        }
        #else
        nil
        #endif
    }

    nonisolated static func connectSSH(
        host: String,
        port: Int,
        username: String,
        password: String,
        privateKeyContent: String,
        privateKeyPassphrase: String,
        allowPasswordFallback: Bool
    ) -> UnsafeMutablePointer<CChar>? {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleanHost.withCString { hostPtr in
            cleanUsername.withCString { userPtr in
                password.withCString { passwordPtr in
                    cleanKey.withCString { keyPtr in
                        privateKeyPassphrase.withCString { passphrasePtr in
                            orbit_ssh_connect(
                                hostPtr,
                                clampedPort(port),
                                userPtr,
                                passwordPtr,
                                keyPtr,
                                passphrasePtr,
                                allowPasswordFallback ? 1 : 0
                            )
                        }
                    }
                }
            }
        }
        #else
        nil
        #endif
    }
}
