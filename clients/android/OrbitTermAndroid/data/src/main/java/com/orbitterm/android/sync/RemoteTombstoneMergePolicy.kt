package com.orbitterm.android.sync

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

    fun canonicalAssetId(raw: String?): String? =
        raw?.trim()?.takeIf(String::isNotEmpty)?.lowercase()
}
