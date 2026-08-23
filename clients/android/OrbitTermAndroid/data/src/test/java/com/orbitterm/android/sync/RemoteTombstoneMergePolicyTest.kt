package com.orbitterm.android.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteTombstoneMergePolicyTest {
    @Test
    fun trashWinsWhenRecordIdsDifferForTheSameAsset() {
        val assetId = "ABCDEF00-1234-5678-9ABC-DEF012345678"
        val inventory = record(101u, assetId, "deleted")
        val trash = record(202u, assetId.lowercase(), "deleted")

        val merged = RemoteTombstoneMergePolicy.merge(listOf(inventory), listOf(trash))

        assertEquals(listOf(202u), merged.map(UploadConfigData::id))
    }

    @Test
    fun canonicalIdentityMatchesAppleAndWindowsUuidCasingAndWhitespace() {
        assertEquals(
            "abcdef00-1234-5678-9abc-def012345678",
            RemoteTombstoneMergePolicy.canonicalAssetId("  ABCDEF00-1234-5678-9ABC-DEF012345678  "),
        )
    }

    @Test
    fun distinctAssetsKeepDistinctTombstones() {
        val first = record(101u, "asset-a", "deleted")
        val second = record(202u, "asset-b", "deleted")

        val merged = RemoteTombstoneMergePolicy.merge(listOf(first), listOf(second))

        assertEquals(setOf(101u, 202u), merged.map(UploadConfigData::id).toSet())
    }

    private fun record(id: UInt, assetId: String, state: String) = UploadConfigData(
        id = id,
        asset_id = assetId,
        encrypted_blob_base64 = "ciphertext",
        vector_clock = "{}",
        state = state,
    )
}
