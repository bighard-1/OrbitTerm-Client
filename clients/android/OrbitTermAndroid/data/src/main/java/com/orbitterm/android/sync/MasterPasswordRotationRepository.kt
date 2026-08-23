package com.orbitterm.android.sync

import com.orbitterm.android.core.OrbitCoreBridge
import com.orbitterm.android.domain.auth.AccountScope
import javax.inject.Inject

/**
 * Performs the cross-device half of a master-password rotation. The endpoint
 * accepts one complete replacement snapshot atomically, so partial cloud
 * re-encryption is impossible.
 */
class MasterPasswordRotationRepository @Inject constructor(
    private val api: OrbitApi,
) {
    suspend fun rotate(
        accessToken: String,
        currentMasterPassword: String,
        newMasterPassword: String,
        currentLoginPassword: String,
        accountScope: AccountScope,
    ): AuthResponse {
        require(currentMasterPassword.isNotBlank() && newMasterPassword.isNotBlank())
        require(currentMasterPassword != newMasterPassword)
        require(currentLoginPassword.isNotBlank())
        val snapshot = completeSnapshot(accessToken)
        val v2RootKey = snapshot
            .firstOrNull { ConfigCipherSession.isV2(it.encrypted_blob_base64) }
            ?.let { OrbitCoreBridge.deriveConfigRootKeyV2(currentMasterPassword, accountScope.storageId) }
        return try {
            val replacements = snapshot.map { item ->
                val plaintext = if (ConfigCipherSession.isV2(item.encrypted_blob_base64)) {
                    requireNotNull(v2RootKey) { "V2 configuration root is unavailable" }.let { root ->
                        OrbitCoreBridge.decryptConfigV2(root, item.encrypted_blob_base64)
                    }
                } else {
                    OrbitCoreBridge.decryptConfig(currentMasterPassword, item.encrypted_blob_base64)
                }
                MasterKeyRotationItemRequest(
                    id = item.id,
                    expected_vector_clock = item.vector_clock,
                    encrypted_blob_base64 = OrbitCoreBridge.encryptConfig(newMasterPassword, plaintext),
                )
            }
            api.rotateMasterKey(accessToken, currentLoginPassword, replacements)
        } finally {
            v2RootKey?.fill(0)
        }
    }

    private suspend fun completeSnapshot(accessToken: String): List<UploadConfigData> {
        val items = api.pullConfigs(accessToken).toMutableList()
        var offset = 0
        while (true) {
            val page = api.pullTrash(accessToken, limit = 500, offset = offset)
            items += page.items
            offset += page.items.size
            if (page.items.isEmpty() || offset >= page.total) break
        }
        check(items.map { it.id }.toSet().size == items.size) { "云端配置快照不一致，请重新同步后再试。" }
        return items
    }
}
