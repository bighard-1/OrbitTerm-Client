import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var username: String = ""
    @Published var transientStatus: String = ""

    private let keychain: KeychainManager

    private let tokenService = "com.orbitterm.auth"
    private let tokenAccount = "jwt_token"
    private let passwordService = "com.orbitterm.security"
    private let passwordAccount = "master_password"

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        loadAuthState()
    }

    func loadAuthState() {
        do {
            let token = try keychain.readString(service: tokenService, account: tokenAccount)
            isAuthenticated = !(token?.isEmpty ?? true)
            if !isAuthenticated {
                isUnlocked = false
            }
        } catch {
            isAuthenticated = false
            isUnlocked = false
        }
    }

    func persistLogin(token: String, username: String) throws {
        try keychain.saveString(token, service: tokenService, account: tokenAccount)
        self.username = username
        isAuthenticated = true
    }

    func readToken() -> String? {
        try? keychain.readString(service: tokenService, account: tokenAccount)
    }

    func logout() {
        do {
            try keychain.delete(service: tokenService, account: tokenAccount)
        } catch {
            // 忽略删除异常，仍执行本地状态重置。
        }
        isAuthenticated = false
        isUnlocked = false
        username = ""
    }

    var hasMasterPassword: Bool {
        let existing = (try? keychain.readString(service: passwordService, account: passwordAccount)) ?? nil
        return !(existing?.isEmpty ?? true)
    }

    func setupMasterPassword(_ value: String) throws {
        try keychain.saveString(value, service: passwordService, account: passwordAccount)
        isUnlocked = true
    }

    func verifyMasterPassword(_ input: String) -> Bool {
        let savedValue = (try? keychain.readString(service: passwordService, account: passwordAccount)) ?? nil
        guard let savedValue else {
            return false
        }
        let passed = input == savedValue
        isUnlocked = passed
        return passed
    }

    func readMasterPassword() -> String? {
        try? keychain.readString(service: passwordService, account: passwordAccount)
    }

    func showTransientStatus(_ message: String, duration: TimeInterval = 2.8) {
        transientStatus = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            if self.transientStatus == message {
                self.transientStatus = ""
            }
        }
    }
}
