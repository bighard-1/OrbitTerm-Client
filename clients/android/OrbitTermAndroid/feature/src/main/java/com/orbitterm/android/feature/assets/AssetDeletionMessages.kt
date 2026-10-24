package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.AssetStorageScope

/** Local-only assets have no trash row: deletion is immediate and cannot be restored in-app. */
internal fun assetDeletionConfirmation(scopes: Collection<AssetStorageScope>): String {
    val localCount = scopes.count { it == AssetStorageScope.LOCAL_ONLY }
    val syncedCount = scopes.count { it == AssetStorageScope.ACCOUNT_SYNCED }
    return when {
        scopes.isEmpty() -> "没有可删除的资产。"
        localCount == 0 -> "$syncedCount 个账户同步资产将移入云端最近删除，删除会同步到其他设备；本机凭据会清除。保留期内可在个人中心恢复。"
        syncedCount == 0 -> "$localCount 个“仅此设备”资产会从本机直接删除，本机凭据同时清除；不会进入最近删除，无法在应用内恢复。"
        else -> "$syncedCount 个账户同步资产将移入云端最近删除（保留期内可恢复）；$localCount 个“仅此设备”资产会从本机直接删除（不会进入最近删除，无法在应用内恢复）。本机凭据均会清除。"
    }
}

internal fun assetDeletionNotice(scopes: Collection<AssetStorageScope>): String {
    val localCount = scopes.count { it == AssetStorageScope.LOCAL_ONLY }
    val syncedCount = scopes.count { it == AssetStorageScope.ACCOUNT_SYNCED }
    return when {
        scopes.isEmpty() -> "没有删除任何资产。"
        localCount == 0 -> "已从本机删除 $syncedCount 个账户同步资产及其凭据；云端删除已排队，同步成功后会出现在最近删除。"
        syncedCount == 0 -> "已从本机删除 $localCount 个“仅此设备”资产及其凭据；不会出现在最近删除。"
        else -> "已从本机删除 $syncedCount 个账户同步资产和 $localCount 个“仅此设备”资产及其凭据；云端删除已排队，“仅此设备”资产不会出现在最近删除。"
    }
}

internal fun requiresCloudDeletionSync(scopes: Collection<AssetStorageScope>): Boolean =
    scopes.any { it == AssetStorageScope.ACCOUNT_SYNCED }
