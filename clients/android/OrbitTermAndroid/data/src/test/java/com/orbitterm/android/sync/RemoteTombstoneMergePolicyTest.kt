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
        val first = record(101u, "11111111-2222-3333-4444-555555555555", "deleted")
        val second = record(202u, "66666666-7777-8888-9999-aaaaaaaaaaaa", "deleted")

        val merged = RemoteTombstoneMergePolicy.merge(listOf(first), listOf(second))

        assertEquals(setOf(101u, 202u), merged.map(UploadConfigData::id).toSet())
    }

    @Test
    fun malformedAssetIdentityIsRejectedInsteadOfBeingMerged() {
        assertEquals(null, RemoteTombstoneMergePolicy.canonicalAssetId("asset-a"))
        assertEquals(null, RemoteTombstoneMergePolicy.canonicalAssetId("1-2-3-4-5"))
    }

    @Test
    fun remoteAssetIdentityMustMatchPortablePayload() {
        val assetId = "abcdef00-1234-5678-9abc-def012345678"
        assertEquals(
            true,
            RemoteTombstoneMergePolicy.matchesPortableAssetId(
                "  ABCDEF00-1234-5678-9ABC-DEF012345678  ",
                assetId,
            ),
        )
        assertEquals(
            false,
            RemoteTombstoneMergePolicy.matchesPortableAssetId(
                "11111111-2222-3333-4444-555555555555",
                assetId,
            ),
        )
        assertEquals(false, RemoteTombstoneMergePolicy.matchesPortableAssetId("asset-a", assetId))
        assertEquals(false, RemoteTombstoneMergePolicy.matchesPortableAssetId("asset-a", "asset-a"))
    }

    @Test
    fun tombstoneBlocksAnActiveRecordWithTheSameAssetIdentity() {
        val assetId = "abcdef00-1234-5678-9abc-def012345678"
        val tombstone = record(202u, assetId.uppercase(), "deleted")

        assertEquals(
            setOf(assetId),
            RemoteTombstoneMergePolicy.blockedAssetIds(listOf(tombstone)),
        )
    }

    private fun record(id: UInt, assetId: String, state: String) = UploadConfigData(
        id = id,
        asset_id = assetId,
        encrypted_blob_base64 = "ciphertext",
        vector_clock = "{}",
        state = state,
    )
}
