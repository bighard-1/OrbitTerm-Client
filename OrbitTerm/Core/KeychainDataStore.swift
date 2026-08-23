import Foundation
import Security

/// 统一执行普通 Keychain 二进制数据的增删改查。
/// 生物识别条目有独立的 AccessControl/LAContext 约束，不通过此类型读写。
///
/// 在 macOS 上，所有新条目均写入 Data Protection Keychain。该实现与 iOS 的
/// SecItem 行为一致，并避免旧式文件钥匙串根据历史应用签名反复请求访问授权。
enum KeychainDataStore {
    static func save(_ data: Data, service: String, account: String) throws {
        let query = dataProtectionQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainManager.KeychainError.unhandled(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainManager.KeychainError.unhandled(addStatus)
        }
    }

    static func read(service: String, account: String) throws -> Data? {
        if let data = try copyData(matching: dataProtectionQuery(service: service, account: account)) {
            return data
        }

        #if os(macOS)
        // 仅为此前使用旧式 macOS 文件钥匙串写入的条目提供一次性兼容读取。
        // 成功读取后立即复制到 Data Protection Keychain；即使旧项清理被系统
        // 拒绝，后续读取也会优先命中新条目，不会再次触发旧项的访问控制提示。
        guard let legacyData = try copyData(matching: legacyQuery(service: service, account: account)) else {
            return nil
        }
        try save(legacyData, service: service, account: account)
        _ = SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
        return legacyData
        #else
        return nil
        #endif
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(dataProtectionQuery(service: service, account: account) as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainManager.KeychainError.unhandled(status)
        }

        #if os(macOS)
        let legacyStatus = SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw KeychainManager.KeychainError.unhandled(legacyStatus)
        }
        #endif
    }

    static func dataProtectionQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Data Protection Keychain is a macOS storage selection. iOS already
        // uses the protected system keychain by default; requesting the macOS
        // selection from an unsigned simulator build produces errSecMissingEntitlement
        // (-34018) before any login record can be saved.
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func legacyQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func copyData(matching baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unhandled(status)
        }
        guard let data = result as? Data else {
            throw KeychainManager.KeychainError.invalidData
        }
        return data
    }
}
