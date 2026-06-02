import Foundation

struct AddServerConnectionTestInput {
    let host: String
    let port: Int
    let username: String
    let password: String
    let authMethod: ServerAuthMethod
    let transport: ServerTransportProtocol
    let networkDeviceProfile: NetworkDeviceProfile
    let allowPasswordFallback: Bool
    let privateKeyContent: String
    let privateKeyPassphrase: String
    let timeoutSeconds: Int
}

struct AddServerConnectionTestResult {
    let status: String
    let isVerified: Bool
}

enum AddServerConnectionTester {
    static func test(input: AddServerConnectionTestInput, orbitManager: OrbitManager) async -> AddServerConnectionTestResult {
        if input.transport == .telnet {
            return await testTelnet(input)
        }

        do {
            let result = try await runSSHTestWithTimeout(seconds: input.timeoutSeconds) {
                await orbitManager.testConnectionAsync(
                    ip: input.host,
                    port: input.port,
                    username: input.username,
                    password: input.password,
                    privateKeyContent: input.privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    privateKeyPassphrase: input.privateKeyPassphrase,
                    allowPasswordFallback: input.allowPasswordFallback
                )
            }

            if result.hasPrefix("成功") {
                return AddServerConnectionTestResult(status: "连接测试成功", isVerified: true)
            }
            return AddServerConnectionTestResult(status: result, isVerified: false)
        } catch {
            return AddServerConnectionTestResult(status: "连接测试失败: \(error.localizedDescription)", isVerified: false)
        }
    }

    private static func testTelnet(_ input: AddServerConnectionTestInput) async -> AddServerConnectionTestResult {
        let probe = TelnetClient(host: input.host, port: input.port)
        let autoLogin = TelnetClient.AutoLoginConfig(
            username: input.username,
            password: input.password,
            profile: input.networkDeviceProfile
        )
        let ok = await probe.connect(autoLogin: autoLogin, onData: { _ in }, onState: { _ in })
        await probe.disconnect()

        if ok {
            let message = autoLogin.isEnabled ? "连接测试成功 (Telnet，已尝试自动登录)" : "连接测试成功 (Telnet 端口可达)"
            return AddServerConnectionTestResult(status: message, isVerified: true)
        }

        return AddServerConnectionTestResult(status: "连接测试失败: Telnet 端口不可达", isVerified: false)
    }

    private static func runSSHTestWithTimeout(seconds: Int, operation: @escaping @Sendable () async -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask(priority: .userInitiated) {
                await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
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
