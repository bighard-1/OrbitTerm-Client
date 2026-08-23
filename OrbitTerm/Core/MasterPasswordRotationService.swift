import Foundation

@MainActor
final class MasterPasswordRotationService {
    static let shared = MasterPasswordRotationService()

    enum RotationError: LocalizedError {
        case currentMasterPasswordIncorrect
        case newMasterPasswordUnchanged
        case duplicateRemoteConfiguration
        case localCommitPending

        var errorDescription: String? {
            switch self {
            case .currentMasterPasswordIncorrect:
                return "当前主密码不正确。"
            case .newMasterPasswordUnchanged:
                return "新主密码不能与当前主密码相同。"
            case .duplicateRemoteConfiguration:
                return "云端配置快照不一致，请重新同步后重试。"
            case .localCommitPending:
                return "云端主密码已轮换，但本地钥匙串尚未完成更新；请在账户安全中重试完成本地更新。"
            }
        }
    }

    private let network: NetworkService
    private let orbitManager = OrbitManager()

    init(network: NetworkService = .shared) {
        self.network = network
    }

    // The server sees only a complete replacement of opaque ciphertext. Every
    // item is decrypted and re-encrypted locally before the request is sent.
    func rotate(
        currentMasterPassword: String,
        newMasterPassword: String,
        currentLoginPassword: String,
        session: AppSession
    ) async throws {
        guard session.validateMasterPassword(currentMasterPassword) else {
            throw RotationError.currentMasterPasswordIncorrect
        }
        guard currentMasterPassword != newMasterPassword else {
            throw RotationError.newMasterPasswordUnchanged
        }

        let snapshot = try await fetchCompleteSnapshot()
        let v2RootKey: Data?
        if snapshot.contains(where: { item in
            Data(base64Encoded: item.encrypted_blob_base64).map(OrbitManager.isV2ConfigBlob) ?? false
        }) {
            guard let accountScope = AccountScope(username: session.username) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            try orbitManager.prepareConfigRootKeyV2(
                masterPassword: currentMasterPassword,
                accountScope: accountScope
            )
            v2RootKey = try orbitManager.configRootKeyV2ForBackground(scope: accountScope)
        } else {
            v2RootKey = nil
        }
        defer { orbitManager.clearConfigRootKeyV2() }
        let replacements = try snapshot.map {
            try reencrypt(
                $0,
                from: currentMasterPassword,
                to: newMasterPassword,
                v2RootKey: v2RootKey
            )
        }

        try session.stageMasterPasswordRotation(newMasterPassword)
        var serverAcceptedRotation = false
        do {
            let login = try await network.rotateMasterKey(
                currentLoginPassword: currentLoginPassword,
                items: replacements
            )
            serverAcceptedRotation = true
            try session.markStagedMasterPasswordRotationAccepted()
            guard !login.accessTokenValue.isEmpty else {
                throw NetworkService.NetworkError.decodeFailed
            }
            try session.persistLogin(
                accessToken: login.accessTokenValue,
                refreshToken: login.refreshTokenValue,
                username: session.username
            )
            do {
                try session.commitStagedMasterPasswordRotation()
            } catch {
                throw RotationError.localCommitPending
            }
        } catch {
            // Once the server accepted a rotation the staged encrypted record
            // is the recovery path; never discard it in that case.
            if !serverAcceptedRotation {
                session.discardStagedMasterPasswordRotation()
            }
            throw error
        }
    }

    func finishPendingLocalCommit(session: AppSession) throws {
        guard session.hasAcceptedStagedMasterPasswordRotation else { return }
        try session.commitStagedMasterPasswordRotation()
    }

    private func fetchCompleteSnapshot() async throws -> [UploadConfigData] {
        var items = try await network.pullConfigs(token: "")
        var offset = 0
        while true {
            let page = try await network.pullTrash(limit: 500, offset: offset)
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total { break }
        }

        var identifiers = Set<UInt>()
        for item in items where !identifiers.insert(item.id).inserted {
            throw RotationError.duplicateRemoteConfiguration
        }
        return items
    }

    private func reencrypt(
        _ item: UploadConfigData,
        from currentMasterPassword: String,
        to newMasterPassword: String,
        v2RootKey: Data?
    ) throws -> MasterKeyRotationItemRequest {
        guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let plaintext: Data
        if OrbitManager.isV2ConfigBlob(encrypted) {
            guard let v2RootKey, v2RootKey.count == 32 else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let encoded = encrypted.base64EncodedString()
            guard let encodedCString = encoded.cString(using: .utf8) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let result = v2RootKey.withUnsafeBytes { keyBuffer in
                orbit_decrypt_config_v2(
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    v2RootKey.count,
                    encodedCString
                )
            }
            guard let result else { throw NetworkService.NetworkError.decodeFailed }
            defer { orbit_free_string(result) }
            let raw = String(cString: result)
            guard raw.hasPrefix("OK:"),
                  let decoded = Data(base64Encoded: String(raw.dropFirst(3))) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            plaintext = decoded
        } else {
            plaintext = try orbitManager.decrypt(password: currentMasterPassword, encrypted: encrypted)
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let reencrypted = try orbitManager.encrypt(password: newMasterPassword, data: text)
        return MasterKeyRotationItemRequest(
            id: item.id,
            expected_vector_clock: item.vector_clock,
            encrypted_blob_base64: reencrypted.base64EncodedString()
        )
    }
}
