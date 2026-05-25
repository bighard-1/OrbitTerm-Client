import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var username: String = ""
    @Published var transientStatus: String = ""
    @Published private(set) var authRevision: Int = 0

    private let keychain: KeychainManager

    private let tokenService = "com.orbitterm.auth"
    private let tokenAccount = "jwt_token"
    private let refreshTokenAccount = "jwt_refresh_token"
    private let passwordService = "com.orbitterm.security"
    private let legacyPasswordAccount = "master_password"
    private let passwordVerifierAccount = "master_password_verifier_v2"
    private let passwordBlobAccount = "master_password_blob_v2"
    private let wrapKeyAccount = "master_password_wrap_key_v2"

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        loadAuthState()
        bindLifecycleObservers()
    }

    func loadAuthState() {
        do {
            let token = try keychain.readString(service: tokenService, account: tokenAccount)
            isAuthenticated = !(token?.isEmpty ?? true)
            if !isAuthenticated {
                isUnlocked = false
            }
            authRevision += 1
        } catch {
            isAuthenticated = false
            isUnlocked = false
            authRevision += 1
        }
    }

    func persistLogin(accessToken: String, refreshToken: String?, username: String) throws {
        try keychain.saveString(accessToken, service: tokenService, account: tokenAccount)
        if let refreshToken, !refreshToken.isEmpty {
            try keychain.saveString(refreshToken, service: tokenService, account: refreshTokenAccount)
        }
        self.username = username
        isAuthenticated = true
        authRevision += 1
    }

    func readToken() -> String? {
        try? keychain.readString(service: tokenService, account: tokenAccount)
    }

    func readRefreshToken() -> String? {
        try? keychain.readString(service: tokenService, account: refreshTokenAccount)
    }

    func updateAccessToken(_ token: String) {
        try? keychain.saveString(token, service: tokenService, account: tokenAccount)
        authRevision += 1
    }

    func updateRefreshToken(_ token: String) {
        try? keychain.saveString(token, service: tokenService, account: refreshTokenAccount)
        authRevision += 1
    }

    func logout() {
        do {
            try keychain.delete(service: tokenService, account: tokenAccount)
            try keychain.delete(service: tokenService, account: refreshTokenAccount)
            try keychain.delete(service: passwordService, account: passwordBlobAccount)
        } catch {
            // 忽略删除异常，仍执行本地状态重置。
        }
        isAuthenticated = false
        isUnlocked = false
        username = ""
        authRevision += 1
    }

    var hasMasterPassword: Bool {
        let existing = (try? keychain.readString(service: passwordService, account: passwordVerifierAccount)) ?? nil
        if !(existing?.isEmpty ?? true) {
            return true
        }
        let legacy = (try? keychain.readString(service: passwordService, account: legacyPasswordAccount)) ?? nil
        return !(legacy?.isEmpty ?? true)
    }

    func setupMasterPassword(_ value: String) throws {
        var input = value
        defer { SecurityPrimitives.secureZero(&input) }

        var salt = try SecurityPrimitives.randomBytes(count: 16)
        defer { SecurityPrimitives.secureZero(&salt) }

        let verifier = try deriveArgon2id(password: input, salt: salt)
        var verifierWipe = verifier
        defer { SecurityPrimitives.secureZero(&verifierWipe) }

        let record = "\(salt.base64EncodedString()):\(verifier.base64EncodedString())"
        try keychain.saveString(record, service: passwordService, account: passwordVerifierAccount)

        let encryptedBlob = try encryptMasterPasswordForStorage(input)
        try keychain.saveString(encryptedBlob, service: passwordService, account: passwordBlobAccount)
        isUnlocked = true
    }

    func verifyMasterPassword(_ input: String) -> Bool {
        guard let record = (try? keychain.readString(service: passwordService, account: passwordVerifierAccount)) ?? nil else {
            // 兼容旧版明文存储：首次验证成功后迁移到 v2。
            let legacy = (try? keychain.readString(service: passwordService, account: legacyPasswordAccount)) ?? nil
            guard let legacy else { return false }
            let passedLegacy = (legacy == input)
            if passedLegacy {
                try? setupMasterPassword(input)
                try? keychain.delete(service: passwordService, account: legacyPasswordAccount)
            }
            isUnlocked = passedLegacy
            return passedLegacy
        }
        let parts = record.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let salt = Data(base64Encoded: parts[0]),
              let expected = Data(base64Encoded: parts[1]) else {
            return false
        }
        var candidate = (try? deriveArgon2id(password: input, salt: salt)) ?? Data()
        defer { SecurityPrimitives.secureZero(&candidate) }

        let passed = candidate == expected
        isUnlocked = passed
        if passed, let encryptedBlob = try? encryptMasterPasswordForStorage(input) {
            try? keychain.saveString(encryptedBlob, service: passwordService, account: passwordBlobAccount)
        }
        return passed
    }

    func markUnlockedByBiometric() {
        isUnlocked = true
    }

    func readMasterPassword() -> String? {
        guard let blob = (try? keychain.readString(service: passwordService, account: passwordBlobAccount)) ?? nil else {
            return nil
        }
        return try? decryptMasterPasswordFromStorage(blob)
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

    private func bindLifecycleObservers() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.hasMasterPassword {
                    self.isUnlocked = false
                }
            }
        }
#elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.hasMasterPassword {
                    self.isUnlocked = false
                }
            }
        }
#endif
    }

    private func deriveArgon2id(password: String, salt: Data) throws -> Data {
        guard let passwordC = password.cString(using: .utf8) else {
            throw KeychainManager.KeychainError.invalidData
        }
        let raw = salt.withUnsafeBytes { rawBuf in
            orbit_argon2id_derive(
                passwordC,
                rawBuf.bindMemory(to: UInt8.self).baseAddress,
                salt.count
            )
        }
        let payload = parseOKPayload(raw)
        guard let data = Data(base64Encoded: payload) else {
            throw KeychainManager.KeychainError.invalidData
        }
        return data
    }

    private func parseOKPayload(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        defer { orbit_free_string(ptr) }
        let raw = String(cString: ptr)
        if raw.hasPrefix("OK:") {
            return String(raw.dropFirst(3))
        }
        return ""
    }

    private func readOrCreateWrapKey() throws -> SymmetricKey {
        if let existing = try keychain.readString(service: passwordService, account: wrapKeyAccount),
           let data = Data(base64Encoded: existing), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var raw = try SecurityPrimitives.randomBytes(count: 32)
        defer { SecurityPrimitives.secureZero(&raw) }
        try keychain.saveString(raw.base64EncodedString(), service: passwordService, account: wrapKeyAccount)
        return SymmetricKey(data: raw)
    }

    private func encryptMasterPasswordForStorage(_ text: String) throws -> String {
        let key = try readOrCreateWrapKey()
        guard let plain = text.data(using: .utf8) else {
            throw KeychainManager.KeychainError.invalidData
        }
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw KeychainManager.KeychainError.invalidData
        }
        return combined.base64EncodedString()
    }

    private func decryptMasterPasswordFromStorage(_ blob: String) throws -> String {
        let key = try readOrCreateWrapKey()
        guard let combined = Data(base64Encoded: blob) else {
            throw KeychainManager.KeychainError.invalidData
        }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(sealed, using: key)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw KeychainManager.KeychainError.invalidData
        }
        return text
    }
}
