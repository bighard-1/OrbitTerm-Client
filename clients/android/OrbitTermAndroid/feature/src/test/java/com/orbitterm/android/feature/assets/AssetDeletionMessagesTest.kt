package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.AssetStorageScope
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AssetDeletionMessagesTest {
    @Test
    fun localOnlyDeletionDoesNotPromiseTrashOrQueueCloudSync() {
        val scopes = listOf(AssetStorageScope.LOCAL_ONLY)

        assertTrue(assetDeletionConfirmation(scopes).contains("不会进入最近删除，无法在应用内恢复"))
        assertFalse(assetDeletionConfirmation(scopes).contains("保留期内可"))
        assertTrue(assetDeletionNotice(scopes).contains("不会出现在最近删除"))
        assertFalse(requiresCloudDeletionSync(scopes))
    }

    @Test
    fun accountSyncedDeletionRetainsRecoverableCloudTrashAndSync() {
        val scopes = listOf(AssetStorageScope.ACCOUNT_SYNCED)

        assertTrue(assetDeletionConfirmation(scopes).contains("保留期内可在个人中心恢复"))
        assertTrue(assetDeletionNotice(scopes).contains("同步成功后会出现在最近删除"))
        assertTrue(requiresCloudDeletionSync(scopes))
    }

    @Test
    fun mixedDeletionDistinguishesBothScopes() {
        val scopes = listOf(
            AssetStorageScope.LOCAL_ONLY,
            AssetStorageScope.ACCOUNT_SYNCED,
            AssetStorageScope.LOCAL_ONLY,
        )

        val confirmation = assetDeletionConfirmation(scopes)
        val notice = assetDeletionNotice(scopes)
        assertTrue(confirmation.contains("1 个账户同步资产"))
        assertTrue(confirmation.contains("2 个“仅此设备”资产"))
        assertTrue(confirmation.contains("无法在应用内恢复"))
        assertTrue(notice.contains("1 个账户同步资产"))
        assertTrue(notice.contains("2 个“仅此设备”资产"))
        assertTrue(requiresCloudDeletionSync(scopes))
    }

    @Test
    fun unsavedEditorScopeChangeDoesNotAlterDeletionWarning() {
        val editor = AssetEditorUiState(
            id = "fixture",
            credentialID = "fixture-credential",
            isNew = false,
            createdAtUnix = 1,
            storageScope = AssetStorageScope.LOCAL_ONLY,
            persistedStorageScope = AssetStorageScope.LOCAL_ONLY,
        ).copy(storageScope = AssetStorageScope.ACCOUNT_SYNCED)

        assertTrue(assetDeletionConfirmation(listOf(editor.persistedStorageScope)).contains("无法在应用内恢复"))
    }
}
