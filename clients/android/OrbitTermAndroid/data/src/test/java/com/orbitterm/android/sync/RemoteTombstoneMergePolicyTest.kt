package com.orbitterm.android.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.data.local.AssetSyncOutboxEntity
import com.orbitterm.android.data.local.AssetSyncOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RemoteTombstoneMergePolicyTest {
    @Test
    fun onlyDeclaredDeletedAndPurgedStatesCanRemoveLocalAssets() {
        val assetId = "abcdef00-1234-5678-9abc-def012345678"
        val active = record(1u, assetId, "active")
        val deleted = record(2u, assetId, "deleted")
        val purged = record(3u, assetId, "purged")

        assertEquals(listOf(deleted, purged), RemoteTombstoneMergePolicy.inventoryTombstones(listOf(active, deleted, purged)))
        assertEquals(listOf(deleted, purged), RemoteTombstoneMergePolicy.validatedTrashPage(listOf(deleted, purged)))
    }

    @Test
    fun futureInventoryStateFailsClosedBeforeAnyDeletion() {
        val future = record(4u, "abcdef00-1234-5678-9abc-def012345678", "archived")

        val error = assertThrows(SyncFailure::class.java) {
            RemoteTombstoneMergePolicy.inventoryTombstones(listOf(record(3u, future.asset_id!!, "deleted"), future))
        }
        assertEquals(OrbitErrorCode.RemoteProtocolViolation, error.error.code)
    }

    @Test
    fun unexpectedTrashStateFailsClosed() {
        val active = record(5u, "abcdef00-1234-5678-9abc-def012345678", "active")

        val error = assertThrows(SyncFailure::class.java) {
            RemoteTombstoneMergePolicy.validatedTrashPage(listOf(active))
        }
        assertEquals(OrbitErrorCode.RemoteProtocolViolation, error.error.code)
    }

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

    @Test
    fun queuedDeleteNeedsExactIdentityRevisionAndCoveringRequestClock() {
        val assetId = "abcdef00-1234-5678-9abc-def012345678"
        val queued = AssetSyncOutboxEntity(
            accountScope = "test-account",
            assetId = assetId,
            operation = AssetSyncOperation.MOVE_TO_TRASH.name,
            operationId = "test-operation",
            enqueuedAtUnix = 1,
            requestVectorClock = "{\"android\":8,\"ios\":4}",
        )
        val remote = record(22u, assetId.uppercase(), "deleted").copy(
            vector_clock = "{\"android\":8,\"ios\":4}",
            server_revision = 12uL,
        )

        assertEquals(true, RemoteTombstoneMergePolicy.coversQueuedDelete(remote, queued))
        assertEquals(false, RemoteTombstoneMergePolicy.coversQueuedDelete(remote.copy(server_revision = null), queued))
        assertEquals(false, RemoteTombstoneMergePolicy.coversQueuedDelete(remote.copy(asset_id = "11111111-2222-3333-4444-555555555555"), queued))
        assertEquals(false, RemoteTombstoneMergePolicy.coversQueuedDelete(remote.copy(vector_clock = "{\"android\":7,\"ios\":4}"), queued))
        assertEquals(false, RemoteTombstoneMergePolicy.coversQueuedDelete(remote.copy(vector_clock = "{\"android\":8,\"ios\":\"4\"}"), queued))
        assertEquals(false, RemoteTombstoneMergePolicy.coversQueuedDelete(remote, queued.copy(requestVectorClock = null)))
    }

    @Test
    fun unchangedLegacyImportCanYieldToExactDeletedTombstoneOnly() {
        val assetId = "abcdef00-1234-5678-9abc-def012345678"
        val queued = AssetSyncOutboxEntity(
            accountScope = "test-account",
            assetId = assetId,
            operation = AssetSyncOperation.UPSERT.name,
            operationId = "test-operation",
            enqueuedAtUnix = 1,
        )
        val deleted = record(22u, assetId.uppercase(), "deleted")

        assertEquals(true, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(deleted, queued, true))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(deleted, queued, false))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(deleted.copy(state = "purged"), queued, true))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(deleted.copy(state = "active"), queued, true))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(deleted.copy(asset_id = null), queued, true))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(
            deleted.copy(asset_id = "11111111-2222-3333-4444-555555555555"), queued, true,
        ))
        assertEquals(false, RemoteTombstoneMergePolicy.coversUnchangedQueuedUpsert(
            deleted, queued.copy(operation = AssetSyncOperation.MOVE_TO_TRASH.name), true,
        ))
    }

    private fun record(id: UInt, assetId: String, state: String) = UploadConfigData(
        id = id,
        asset_id = assetId,
        encrypted_blob_base64 = "ciphertext",
        vector_clock = "{}",
        state = state,
    )
}
