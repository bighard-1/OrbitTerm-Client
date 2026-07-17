import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var username: String = ""
    @Published var transientStatus: String = ""
    @Published private(set) var masterPasswordPersistenceError: String?
    @Published private(set) var authRevision: Int = 0

    private let keychain: KeychainManager

    private let tokenService = "com.orbitterm.auth"
    private let tokenAccount = "jwt_token"
    private let refreshTokenAccount = "jwt_refresh_token"
    private let usernameAccount = "username"
    private let passwordService = "com.orbitterm.security"
    private let legacyPasswordAccount = "master_password"
    private let legacyPasswordVerifierAccount = "master_password_verifier_v2"
    private let legacyPasswordBlobAccount = "master_password_blob_v2"
    private let legacyWrapKeyAccount = "master_password_wrap_key_v2"
    private let masterPasswordMigrationFlag = "orbitterm.master-password.account-scope-migrated.v1"

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        loadAuthState()
        bindLifecycleObservers()
    }

    func loadAuthState() {
        do {
            let token = try keychain.readString(service: tokenService, account: tokenAccount)
            isAuthenticated = !(token?.isEmpty ?? true)
            username = (try? keychain.readString(service: tokenService, account: usernameAccount)) ?? ""
            if !isAuthenticated {
                isUnlocked = false
                username = ""
            } else {
                migrateLegacyMasterPasswordIfNeeded()
            }
            authRevision += 1
        } catch {
            isAuthenticated = false
            isUnlocked = false
            username = ""
            authRevision += 1
        }
    }

    func persistLogin(accessToken: String, refreshToken: String?, username: String) throws {
        try keychain.saveString(accessToken, service: tokenService, account: tokenAccount)
        if let refreshToken, !refreshToken.isEmpty {
            try keychain.saveString(refreshToken, service: tokenService, account: refreshTokenAccount)
        }
        try keychain.saveString(username, service: tokenService, account: usernameAccount)
        self.username = username
        isAuthenticated = true
        migrateLegacyMasterPasswordIfNeeded()
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
            try keychain.delete(service: tokenService, account: usernameAccount)
            if let passwordBlobAccount = passwordBlobAccount {
                try keychain.delete(service: passwordService, account: passwordBlobAccount)
            }
        } catch {
            // 忽略删除异常，仍执行本地状态重置。
        }
        isAuthenticated = false
        isUnlocked = false
        username = ""
        authRevision += 1
    }

    var hasMasterPassword: Bool {
        guard let passwordVerifierAccount else { return false }
        let existing = (try? keychain.readString(service: passwordService, account: passwordVerifierAccount)) ?? nil
        return !(existing?.isEmpty ?? true)
    }

    func setupMasterPassword(_ value: String) throws {
        try persistMasterPassword(value, verifierAccount: passwordVerifierAccount, blobAccount: passwordBlobAccount)
        masterPasswordPersistenceError = nil
        isUnlocked = true
    }

    // Validation intentionally has no persistence side effect. Password
    // rotation uses it before preparing a new local keychain record.
    func validateMasterPassword(_ input: String) -> Bool {
        guard let passwordVerifierAccount,
              let record = (try? keychain.readString(service: passwordService, account: passwordVerifierAccount)) ?? nil else {
            return false
        }
        return matchesMasterPassword(input, record: record)
    }

    // Stage first so a successful remote re-encryption is never paired with a
    // lost local replacement. A failed final Keychain write can be retried
    // without ever storing a plaintext master password.
    func stageMasterPasswordRotation(_ value: String) throws {
        try persistMasterPassword(
            value,
            verifierAccount: stagedPasswordVerifierAccount,
            blobAccount: stagedPasswordBlobAccount
        )
    }

    var hasStagedMasterPasswordRotation: Bool {
        guard let stagedPasswordVerifierAccount, let stagedPasswordBlobAccount else { return false }
        let verifier = (try? keychain.readString(service: passwordService, account: stagedPasswordVerifierAccount)) ?? nil
        let blob = (try? keychain.readString(service: passwordService, account: stagedPasswordBlobAccount)) ?? nil
        return !(verifier?.isEmpty ?? true) && !(blob?.isEmpty ?? true)
    }

    func commitStagedMasterPasswordRotation() throws {
        guard let stagedPasswordVerifierAccount,
              let stagedPasswordBlobAccount,
              let passwordVerifierAccount,
              let passwordBlobAccount,
              let verifier = try keychain.readString(service: passwordService, account: stagedPasswordVerifierAccount),
              let blob = try keychain.readString(service: passwordService, account: stagedPasswordBlobAccount),
              !verifier.isEmpty,
              !blob.isEmpty else {
            throw KeychainManager.KeychainError.invalidData
        }
        // Write the encrypted blob before its verifier. Either existing final
        // verifier remains valid, or both final records identify the new key.
        try keychain.saveString(blob, service: passwordService, account: passwordBlobAccount)
        try keychain.saveString(verifier, service: passwordService, account: passwordVerifierAccount)
        try keychain.delete(service: passwordService, account: stagedPasswordBlobAccount)
        try keychain.delete(service: passwordService, account: stagedPasswordVerifierAccount)
        masterPasswordPersistenceError = nil
        isUnlocked = true
    }

    func discardStagedMasterPasswordRotation() {
        guard let stagedPasswordVerifierAccount, let stagedPasswordBlobAccount else { return }
        try? keychain.delete(service: passwordService, account: stagedPasswordBlobAccount)
        try? keychain.delete(service: passwordService, account: stagedPasswordVerifierAccount)
    }

    func verifyMasterPassword(_ input: String) -> Bool {
        guard validateMasterPassword(input), let passwordBlobAccount else {
            return false
        }
        do {
            let encryptedBlob = try encryptMasterPasswordForStorage(input)
            try keychain.saveString(encryptedBlob, service: passwordService, account: passwordBlobAccount)
            masterPasswordPersistenceError = nil
            isUnlocked = true
            return true
        } catch {
            recordMasterPasswordPersistenceFailure(error)
            return false
        }
    }

    private func persistMasterPassword(
        _ value: String,
        verifierAccount: String?,
        blobAccount: String?
    ) throws {
        guard let verifierAccount, let blobAccount else {
            throw KeychainManager.KeychainError.invalidData
        }
        var input = value
        defer { SecurityPrimitives.secureZero(&input) }

        var salt = try SecurityPrimitives.randomBytes(count: 16)
        defer { SecurityPrimitives.secureZero(&salt) }

        let verifier = try deriveArgon2id(password: input, salt: salt)
        var verifierWipe = verifier
        defer { SecurityPrimitives.secureZero(&verifierWipe) }

        let record = "\(salt.base64EncodedString()):\(verifier.base64EncodedString())"
        let encryptedBlob = try encryptMasterPasswordForStorage(input)
        try keychain.saveString(encryptedBlob, service: passwordService, account: blobAccount)
        try keychain.saveString(record, service: passwordService, account: verifierAccount)
    }

    private func matchesMasterPassword(_ input: String, record: String) -> Bool {
        let parts = record.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let salt = Data(base64Encoded: parts[0]),
              let expected = Data(base64Encoded: parts[1]) else {
            return false
        }
        var candidate = (try? deriveArgon2id(password: input, salt: salt)) ?? Data()
        defer { SecurityPrimitives.secureZero(&candidate) }
        return candidate == expected
    }

    func markUnlockedByBiometric() {
        isUnlocked = true
    }

    func readMasterPassword() -> String? {
        guard let passwordBlobAccount,
              let blob = (try? keychain.readString(service: passwordService, account: passwordBlobAccount)) ?? nil else {
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
        guard let wrapKeyAccount else {
            throw KeychainManager.KeychainError.invalidData
        }
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

    private func recordMasterPasswordPersistenceFailure(_ error: Error) {
        isUnlocked = false
        masterPasswordPersistenceError = "无法安全保存主密码以执行同步，请检查钥匙串权限后重试。"
    }

    private var accountScope: AccountScope? {
        AccountScope(username: username)
    }

    private var passwordVerifierAccount: String? {
        accountScope.map { "master_password_verifier_v3.\($0.storageIdentifier)" }
    }

    private var passwordBlobAccount: String? {
        accountScope.map { "master_password_blob_v3.\($0.storageIdentifier)" }
    }

    private var wrapKeyAccount: String? {
        accountScope.map { "master_password_wrap_key_v3.\($0.storageIdentifier)" }
    }

    private var stagedPasswordVerifierAccount: String? {
        accountScope.map { "master_password_rotation_verifier_v1.\($0.storageIdentifier)" }
    }

    private var stagedPasswordBlobAccount: String? {
        accountScope.map { "master_password_rotation_blob_v1.\($0.storageIdentifier)" }
    }

    private func migrateLegacyMasterPasswordIfNeeded() {
        guard let scope = accountScope,
              !UserDefaults.standard.bool(forKey: masterPasswordMigrationFlag),
              let passwordVerifierAccount,
              let passwordBlobAccount,
              let wrapKeyAccount else {
            return
        }

        do {
            var migratedFromLegacyPlaintext = false
            if let verifier = try keychain.readString(service: passwordService, account: legacyPasswordVerifierAccount),
               !verifier.isEmpty {
                try keychain.saveString(verifier, service: passwordService, account: passwordVerifierAccount)
            } else if let legacyPlaintext = try keychain.readString(service: passwordService, account: legacyPasswordAccount),
                      !legacyPlaintext.isEmpty {
                let unlockedBeforeMigration = isUnlocked
                try setupMasterPassword(legacyPlaintext)
                isUnlocked = unlockedBeforeMigration
                migratedFromLegacyPlaintext = true
            }
            if !migratedFromLegacyPlaintext,
               let blob = try keychain.readString(service: passwordService, account: legacyPasswordBlobAccount),
               !blob.isEmpty {
                try keychain.saveString(blob, service: passwordService, account: passwordBlobAccount)
            }
            if !migratedFromLegacyPlaintext,
               let wrapKey = try keychain.readString(service: passwordService, account: legacyWrapKeyAccount),
               !wrapKey.isEmpty {
                try keychain.saveString(wrapKey, service: passwordService, account: wrapKeyAccount)
            }
            // The scoped copy is complete (or there was nothing to migrate).
            // Keep legacy records intact for recovery; never assign them to a
            // later account after this one-time ownership claim.
            UserDefaults.standard.set(true, forKey: masterPasswordMigrationFlag)
            _ = scope
        } catch {
            // Do not mark the migration complete: a later authenticated launch
            // can retry without weakening the existing keychain records.
        }
    }
}
