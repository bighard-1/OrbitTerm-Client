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
}
