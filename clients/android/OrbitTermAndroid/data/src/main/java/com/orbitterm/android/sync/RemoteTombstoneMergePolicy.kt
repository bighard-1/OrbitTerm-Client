package com.orbitterm.android.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.data.local.AssetSyncOutboxEntity
import com.orbitterm.android.data.local.AssetSyncOperation
import java.util.UUID

/** Keeps one authoritative tombstone per stable asset identity. */
internal object RemoteTombstoneMergePolicy {
    fun coversQueuedDelete(remote: UploadConfigData, pending: AssetSyncOutboxEntity): Boolean =
        pending.operation == AssetSyncOperation.MOVE_TO_TRASH.name &&
            isTombstone(remote.state) &&
            remote.server_revision?.let { it > 0uL } == true &&
            canonicalAssetId(remote.asset_id) == canonicalAssetId(pending.assetId) &&
            SyncVectorClock.strictlyCovers(pending.requestVectorClock, remote.vector_clock)

    /** A stale import retry may be removed only after an in-memory exact-content check. */
    fun coversUnchangedQueuedUpsert(
        remote: UploadConfigData,
        pending: AssetSyncOutboxEntity,
        matchesLocalState: Boolean,
    ): Boolean =
        pending.operation == AssetSyncOperation.UPSERT.name &&
            remote.state == "deleted" &&
            canonicalAssetId(remote.asset_id) == canonicalAssetId(pending.assetId) &&
            canonicalAssetId(remote.asset_id) != null &&
            matchesLocalState

    fun isKnownState(state: String?): Boolean =
        state == null || state == "active" || state == "deleted" || state == "purged"

    fun isTombstone(state: String?): Boolean = state == "deleted" || state == "purged"

    fun inventoryTombstones(items: List<UploadConfigData>): List<UploadConfigData> {
        if (items.any { !isKnownState(it.state) }) {
            throw SyncFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
        }
        return items.filter { isTombstone(it.state) }
    }

    fun validatedTrashPage(items: List<UploadConfigData>): List<UploadConfigData> {
        if (items.any { !isTombstone(it.state) }) {
            throw SyncFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
        }
        return items
    }

    fun merge(
        inventoryTombstones: List<UploadConfigData>,
        trashItems: List<UploadConfigData>,
    ): List<UploadConfigData> {
        val byAssetId = linkedMapOf<String, UploadConfigData>()
        inventoryTombstones.forEach { item ->
            canonicalAssetId(item.asset_id)?.let { byAssetId[it] = item }
        }
        // The explicit trash feed is authoritative when the same asset also
        // appears in another feed with a different config-record ID.
        trashItems.forEach { item ->
            canonicalAssetId(item.asset_id)?.let { byAssetId[it] = item }
        }
        return byAssetId.toSortedMap().values.toList()
    }

    /** Active records for these identities must not be applied in this pull. */
    fun blockedAssetIds(tombstones: List<UploadConfigData>): Set<String> =
        tombstones.mapNotNullTo(linkedSetOf()) { canonicalAssetId(it.asset_id) }

    fun canonicalAssetId(raw: String?): String? {
        val normalized = raw?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val parsed = runCatching { UUID.fromString(normalized) }.getOrNull() ?: return null
        // UUID.fromString accepts some shortened legacy forms. Require the
        // canonical wire representation so malformed IDs cannot merge two
        // unrelated tombstones or evade identity checks on another client.
        return parsed.toString().takeIf { it.equals(normalized, ignoreCase = true) }
    }

    /** A declared remote asset ID must agree with the encrypted payload ID. */
    fun matchesPortableAssetId(remoteAssetId: String?, portableAssetId: String): Boolean {
        if (remoteAssetId == null) return true
        val canonicalRemoteId = canonicalAssetId(remoteAssetId) ?: return false
        val canonicalPortableId = canonicalAssetId(portableAssetId) ?: return false
        return canonicalRemoteId == canonicalPortableId
    }
}
