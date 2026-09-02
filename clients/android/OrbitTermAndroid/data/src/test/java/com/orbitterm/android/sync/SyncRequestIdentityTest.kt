package com.orbitterm.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncRequestIdentityTest {
    @Test
    fun `identical upload retry keeps the same opaque key`() {
        val payload = UploadConfigRequest(
            id = 17u,
            asset_id = "00000000-0000-0000-0000-000000000001",
            encrypted_blob_base64 = "opaque-ciphertext",
            vector_clock = "{\"android\":2}",
        )

        val first = SyncRequestIdentity.upload(payload)
        val replay = SyncRequestIdentity.upload(payload.copy())

        assertEquals(first, replay)
        assertTrue(first.matches(Regex("[0-9a-f]{64}")))
        assertNotEquals(first, SyncRequestIdentity.upload(payload.copy(vector_clock = "{\"android\":3}")))
    }

    @Test
    fun `mutation retry follows persisted operation id and not vector clock formatting`() {
        val original = AssetMutationRequest("device-a", "operation-7", "{\"android\":2}")
        val replay = original.copy(device_id = "device-b", vector_clock = "{ \"android\" : 2 }")

        assertEquals(SyncRequestIdentity.mutation(original), SyncRequestIdentity.mutation(replay))
        assertNotEquals(
            SyncRequestIdentity.mutation(original),
            SyncRequestIdentity.mutation(original.copy(operation_id = "operation-8")),
        )
    }
}
