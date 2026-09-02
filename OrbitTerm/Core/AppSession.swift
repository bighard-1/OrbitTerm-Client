import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var username: String = ""
    @Published var transientStatus: String = ""
    @Published private(set) var masterPasswordPersistenceError: String?
    @Published private(set) var authRevision: Int = 0
    @Published private(set) var isCheckingLocalStorage: Bool = false
    @Published private(set) var localStorageRecovery: LocalStorageRecoveryPresentation?

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

    init(
        keychain: KeychainManager = .shared,
        uiTestLaunchState: AppUITestLaunchState = .standard
    ) {
        self.keychain = keychain
        #if !ORBITTERM_PUBLIC_RELEASE
        guard uiTestLaunchState == .standard else {
            applyUITestLaunchState(uiTestLaunchState)
            return
        }
        #else
        _ = uiTestLaunchState
        #endif
        loadAuthState()
        bindLifecycleObservers()
    }

    #if !ORBITTERM_PUBLIC_RELEASE
    private func applyUITestLaunchState(_ state: AppUITestLaunchState) {
        switch state {
        case .standard:
            return
        case .unauthenticated:
            isAuthenticated = false
            isUnlocked = false
            username = ""
        case .authenticatedLocked:
            isAuthenticated = true
            isUnlocked = false
            username = "ui-test@example.invalid"
        case .authenticatedUnlocked:
            isAuthenticated = true
            isUnlocked = true
            username = "ui-test@example.invalid"
        case .operationalStates, .syncRecoveryStates, .accountSecurityStates:
            isAuthenticated = true
            isUnlocked = true
            username = "ui-test@example.invalid"
        }
        authRevision = 1
    }
    #endif

    func loadAuthState() {
        isCheckingLocalStorage = true
        defer { isCheckingLocalStorage = false }
        do {
            let token = try keychain.readString(service: tokenService, account: tokenAccount)
            let storedUsername = try keychain.readString(service: tokenService, account: usernameAccount)
            isAuthenticated = !(token?.isEmpty ?? true)
            username = storedUsername ?? ""
            if !isAuthenticated {
                isUnlocked = false
                username = ""
            } else {
                migrateLegacyMasterPasswordIfNeeded()
            }
            localStorageRecovery = nil
            authRevision += 1
        } catch let error as KeychainManager.KeychainError {
            // Preserve the last known account state. A protected-storage fault
            // is not a logout and must not authorize replacement credentials.
            isUnlocked = false
            localStorageRecovery = LocalStorageRecoveryPolicy.keychainFailure(error)
            authRevision += 1
        } catch {
            isUnlocked = false
            localStorageRecovery = LocalStorageRecoveryPolicy.presentation(for: .secureStorageUnavailable)
            authRevision += 1
        }
    }

    func retryLocalStorageAccess() {
        loadAuthState()
    }

    func persistLogin(accessToken: String, refreshToken: String?, username: String) throws {
        do {
            try keychain.saveString(accessToken, service: tokenService, account: tokenAccount)
            if let refreshToken, !refreshToken.isEmpty {
                try keychain.saveString(refreshToken, service: tokenService, account: refreshTokenAccount)
            }
            try keychain.saveString(username, service: tokenService, account: usernameAccount)
        } catch let error as KeychainManager.KeychainError {
            localStorageRecovery = LocalStorageRecoveryPolicy.keychainFailure(error)
            throw error
        }
        localStorageRecovery = nil
        self.username = username
        isAuthenticated = true
        migrateLegacyMasterPasswordIfNeeded()
        authRevision += 1
    }

    func readToken() -> String? {
        do {
            return try keychain.readString(service: tokenService, account: tokenAccount)
        } catch {
            recordLocalStorageAccessFailure(error)
            return nil
        }
    }

    func readRefreshToken() -> String? {
        do {
            return try keychain.readString(service: tokenService, account: refreshTokenAccount)
        } catch {
            recordLocalStorageAccessFailure(error)
            return nil
        }
    }

    func updateAccessToken(_ token: String) {
        do {
            try keychain.saveString(token, service: tokenService, account: tokenAccount)
            localStorageRecovery = nil
        } catch {
            recordLocalStorageAccessFailure(error)
        }
        authRevision += 1
    }

    func updateRefreshToken(_ token: String) {
        do {
            try keychain.saveString(token, service: tokenService, account: refreshTokenAccount)
            localStorageRecovery = nil
        } catch {
            recordLocalStorageAccessFailure(error)
        }
        authRevision += 1
    }

    func logout() {
        do {
            try keychain.delete(service: tokenService, account: tokenAccount)
            try keychain.delete(service: tokenService, account: refreshTokenAccount)
            try keychain.delete(service: tokenService, account: usernameAccount)
            // Keep the account-scoped encrypted master-password blob. It is
            // required for biometric unlock after the same account signs in
            // again, cannot be decrypted without the local wrap key / user
            // presence, and is never made available to a different account.
        } catch let error as KeychainManager.KeychainError {
            // Logout is only complete after the durable token deletion. Keep
            // the account locked and surface recovery instead of pretending
            // that credentials no longer exist.
            isUnlocked = false
            localStorageRecovery = LocalStorageRecoveryPolicy.keychainFailure(error)
            authRevision += 1
            return
        } catch {
            isUnlocked = false
            localStorageRecovery = LocalStorageRecoveryPolicy.presentation(for: .secureStorageUnavailable)
            authRevision += 1
            return
        }
        localStorageRecovery = nil
        isAuthenticated = false
        isUnlocked = false
        username = ""
        authRevision += 1
    }

    var hasMasterPassword: Bool {
        guard let passwordVerifierAccount else { return false }
        do {
            let existing = try keychain.readString(service: passwordService, account: passwordVerifierAccount)
            return !(existing?.isEmpty ?? true)
        } catch {
            recordLocalStorageAccessFailure(error)
            // Fail closed: never offer setup while an existing verifier may
            // merely be temporarily inaccessible.
            return true
        }
    }

    func setupMasterPassword(_ value: String) throws {
        try persistMasterPassword(value, verifierAccount: passwordVerifierAccount, blobAccount: passwordBlobAccount)
        masterPasswordPersistenceError = nil
        isUnlocked = true
    }

    // Validation intentionally has no persistence side effect. Password
    // rotation uses it before preparing a new local keychain record.
    func validateMasterPassword(_ input: String) -> Bool {
        guard let passwordVerifierAccount else { return false }
        let record: String
        do {
            guard let stored = try keychain.readString(
                service: passwordService,
                account: passwordVerifierAccount
            ) else { return false }
            record = stored
        } catch {
            recordLocalStorageAccessFailure(error)
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
        if let stagedPasswordAcceptedAccount {
            try? keychain.delete(service: passwordService, account: stagedPasswordAcceptedAccount)
        }
    }

    var hasStagedMasterPasswordRotation: Bool {
        guard let stagedPasswordVerifierAccount, let stagedPasswordBlobAccount else { return false }
        let verifier = (try? keychain.readString(service: passwordService, account: stagedPasswordVerifierAccount)) ?? nil
        let blob = (try? keychain.readString(service: passwordService, account: stagedPasswordBlobAccount)) ?? nil
        return !(verifier?.isEmpty ?? true) && !(blob?.isEmpty ?? true)
    }

    func markStagedMasterPasswordRotationAccepted() throws {
        guard hasStagedMasterPasswordRotation, let stagedPasswordAcceptedAccount else {
            throw KeychainManager.KeychainError.invalidData
        }
        try keychain.saveString("accepted", service: passwordService, account: stagedPasswordAcceptedAccount)
    }

    var hasAcceptedStagedMasterPasswordRotation: Bool {
        guard hasStagedMasterPasswordRotation, let stagedPasswordAcceptedAccount else { return false }
        let marker = (try? keychain.readString(service: passwordService, account: stagedPasswordAcceptedAccount)) ?? nil
        return marker == "accepted"
    }

    func commitStagedMasterPasswordRotation() throws {
        guard hasAcceptedStagedMasterPasswordRotation,
              let stagedPasswordVerifierAccount,
              let stagedPasswordBlobAccount,
              let stagedPasswordAcceptedAccount,
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
        try keychain.delete(service: passwordService, account: stagedPasswordAcceptedAccount)
        masterPasswordPersistenceError = nil
        isUnlocked = true
    }

    func discardStagedMasterPasswordRotation() {
        guard let stagedPasswordVerifierAccount, let stagedPasswordBlobAccount else { return }
        try? keychain.delete(service: passwordService, account: stagedPasswordBlobAccount)
        try? keychain.delete(service: passwordService, account: stagedPasswordVerifierAccount)
        if let stagedPasswordAcceptedAccount {
            try? keychain.delete(service: passwordService, account: stagedPasswordAcceptedAccount)
        }
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
        guard let passwordBlobAccount else { return nil }
        let blob: String
        do {
            guard let stored = try keychain.readString(
                service: passwordService,
                account: passwordBlobAccount
            ) else { return nil }
            blob = stored
        } catch {
            recordLocalStorageAccessFailure(error)
            return nil
        }
        return try? decryptMasterPasswordFromStorage(blob)
    }

    private func recordLocalStorageAccessFailure(_ error: Error) {
        isUnlocked = false
        if let keychainError = error as? KeychainManager.KeychainError {
            localStorageRecovery = LocalStorageRecoveryPolicy.keychainFailure(keychainError)
        } else {
            localStorageRecovery = LocalStorageRecoveryPolicy.presentation(for: .secureStorageUnavailable)
        }
        authRevision += 1
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
                if MobileAutoLockPolicy.shouldLockOnBackground(
                    isAuthenticated: self.isAuthenticated,
                    hasMasterPassword: self.hasMasterPassword
                ) {
                    self.isUnlocked = false
                }
            }
        }
#elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            // This is delivered when the user session becomes inactive, which
            // includes the lock screen and fast-user switching. AppKit does
            // not expose a separate screen-lock notification on every macOS
            // deployment target.
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasMasterPassword else { return }
                self.isUnlocked = false
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

    private var stagedPasswordAcceptedAccount: String? {
        accountScope.map { "master_password_rotation_accepted_v1.\($0.storageIdentifier)" }
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
