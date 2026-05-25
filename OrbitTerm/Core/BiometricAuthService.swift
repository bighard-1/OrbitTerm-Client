import Foundation
import LocalAuthentication
import Security
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class BiometricAuthService: ObservableObject {
    static let shared = BiometricAuthService()

    private let service = "com.orbitterm.biometric"
    private let account = "master_password_derived_key"
    private let saltAccount = "master_password_argon2_salt_v1"
    private let logger = Logger(subsystem: "com.orbitterm.app", category: "biometric")
    private var transientDerivedKey: Data?

    private init() {
        bindLifecycleCleanup()
    }

    enum BiometricType {
        case none
        case faceID
        case touchID
    }

    var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    var biometricIconName: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return "lock.shield"
        }
    }

    var isBiometricAvailable: Bool {
        biometricType != .none
    }

    var hasEnrollment: Bool {
        readSalt() != nil && hasProtectedDerivedKeyItem()
    }

    func validateBiometricOnly() async -> Bool {
        guard isBiometricAvailable else { return false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "取消"
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "启用生物识别解锁 OrbitTerm"
            )
        } catch {
            if let laError = error as? LAError {
                logger.error("[BIO] validate-only failed code=\(laError.code.rawValue) msg=\(laError.localizedDescription, privacy: .public)")
            } else {
                logger.error("[BIO] validate-only failed msg=\(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    func enroll(masterPassword: String) throws {
        guard isBiometricAvailable else { return }

        var mutablePassword = masterPassword
        var salt = try SecurityPrimitives.randomBytes(count: 16)
        defer {
            SecurityPrimitives.secureZero(&mutablePassword)
            SecurityPrimitives.secureZero(&salt)
        }

        let derived = try deriveArgon2id(password: mutablePassword, salt: salt)
        defer {
            var wipe = derived
            SecurityPrimitives.secureZero(&wipe)
        }

        try saveSalt(salt)
        try saveProtectedDerivedKey(derived)
    }

    func authenticate(masterPasswordProvider: () -> String?) async -> Bool {
        guard isBiometricAvailable else { return false }
        guard hasEnrollment else { return false }

        let context = LAContext()
        context.localizedFallbackTitle = "使用主密码"
        context.localizedCancelTitle = "取消"

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "验证身份以解锁 OrbitTerm"
            )
            guard ok else { return false }
        } catch {
            if let laError = error as? LAError {
                logger.error("[BIO] evaluatePolicy failed code=\(laError.code.rawValue) msg=\(laError.localizedDescription, privacy: .public)")
            } else {
                logger.error("[BIO] evaluatePolicy failed msg=\(error.localizedDescription, privacy: .public)")
            }
            return false
        }

        guard let salt = readSalt() else { return false }
        guard var master = masterPasswordProvider(), !master.isEmpty else { return false }
        var enrolled = readProtectedDerivedKey(context: context)
        if enrolled == nil {
            // 自愈：如果生物识别通过但受保护条目异常，使用当前主密码重建一次并重读。
            do {
                try enroll(masterPassword: master)
                enrolled = readProtectedDerivedKey(context: context)
                logger.notice("[BIO] protected key self-healed by re-enroll")
            } catch {
                logger.error("[BIO] self-heal enroll failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let enrolled else {
            logger.error("[BIO] read protected key failed after successful evaluatePolicy")
            return false
        }

        defer { SecurityPrimitives.secureZero(&master) }
        var localDerived = (try? deriveArgon2id(password: master, salt: salt)) ?? Data()
        defer { SecurityPrimitives.secureZero(&localDerived) }

        transientDerivedKey = localDerived
        let passed = (localDerived == enrolled)
        clearSensitiveCache()
        return passed
    }

    func clearSensitiveCache() {
        if var key = transientDerivedKey {
            SecurityPrimitives.secureZero(&key)
        }
        transientDerivedKey = nil
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

    private func saveProtectedDerivedKey(_ derived: Data) throws {
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        )
        guard access != nil else {
            throw KeychainManager.KeychainError.invalidData
        }

        var add = baseDerivedQuery()
        add[kSecUseDataProtectionKeychain as String] = true
        add[kSecAttrAccessControl as String] = access
        add[kSecValueData as String] = derived

        // 统一删后重建，确保 ACL 策略始终生效（从旧 userPresence 升级到 biometryCurrentSet）。
        _ = SecItemDelete(baseDerivedQuery() as CFDictionary)
        var legacyDelete = baseDerivedQuery()
        legacyDelete.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        _ = SecItemDelete(legacyDelete as CFDictionary)

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        throw KeychainManager.KeychainError.unhandled(addStatus)
    }

    private func readProtectedDerivedKey(context: LAContext?) -> Data? {
        var query = baseDerivedQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            context.localizedReason = "验证身份以解锁 OrbitTerm"
            query[kSecUseAuthenticationContext as String] = context
        } else {
            let readContext = LAContext()
            readContext.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = readContext
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            // 兼容早期版本未写入 kSecUseDataProtectionKeychain 的条目。
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            let legacyStatus = SecItemCopyMatching(query as CFDictionary, &item)
            guard legacyStatus == errSecSuccess else {
                logger.error("[BIO] keychain legacy read status=\(legacyStatus)")
                return nil
            }
            return item as? Data
        }
        guard status == errSecSuccess else {
            logger.error("[BIO] keychain read status=\(status)")
            return nil
        }
        return item as? Data
    }

    private func hasProtectedDerivedKeyItem() -> Bool {
        var query = baseDerivedQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            let legacyStatus = SecItemCopyMatching(query as CFDictionary, &item)
            return isExistingProtectedItemStatus(legacyStatus)
        }
        return isExistingProtectedItemStatus(status)
    }

    private func isExistingProtectedItemStatus(_ status: OSStatus) -> Bool {
        // 受生物识别保护的 Keychain 条目在禁止交互的探测查询中，
        // 可能返回“需要交互/认证失败”，这仍代表条目存在，不应误判为未注册。
        status == errSecSuccess ||
            status == errSecInteractionNotAllowed ||
            status == errSecAuthFailed
    }

    private func saveSalt(_ salt: Data) throws {
        let query = baseSaltQuery()
        let attrs: [String: Any] = [
            kSecValueData as String: salt,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = salt
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainManager.KeychainError.unhandled(addStatus)
            }
            return
        }
        throw KeychainManager.KeychainError.unhandled(updateStatus)
    }

    private func readSalt() -> Data? {
        var query = baseSaltQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            let legacyStatus = SecItemCopyMatching(query as CFDictionary, &item)
            guard legacyStatus == errSecSuccess else { return nil }
            guard let legacyData = item as? Data, legacyData.count == 16 else { return nil }
            return legacyData
        }
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data, data.count == 16 else { return nil }
        return data
    }

    private func baseDerivedQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func baseSaltQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: saltAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func bindLifecycleCleanup() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearSensitiveCache()
            }
        }
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearSensitiveCache()
            }
        }
        #endif
    }
}
