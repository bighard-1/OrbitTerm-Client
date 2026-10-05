package com.orbitterm.android.sync

import java.util.UUID

/** Keeps one authoritative tombstone per stable asset identity. */
internal object RemoteTombstoneMergePolicy {
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
