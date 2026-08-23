package com.orbitterm.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PortForwardProfileSyncContractTest {
    @Test
    fun `windows profile envelope round trips without live state`() {
        val decoded = PortForwardProfileSyncContract.decode(
            """{"kind":"orbit_port_forwards","version":1,"updatedAtUnix":1770000000,"profiles":[{"id":"ABCDEF00-1234-5678-9ABC-DEF012345678","assetId":"11111111-2222-3333-4444-555555555555","name":" db ","mode":"local","bindHost":"127.0.0.1","bindPort":15432,"destinationHost":"127.0.0.1","destinationPort":5432,"createdAtUnix":1760000000,"updatedAtUnix":1770000000}],"tombstones":[]}""",
        )
        val profile = requireNotNull(decoded).profiles.single()
        assertEquals("abcdef00-1234-5678-9abc-def012345678", profile.id)
        assertEquals("db", profile.name)
        val encoded = PortForwardProfileSyncContract.encode(decoded)
        assertFalse(encoded.contains("tunnelId"))
        assertFalse(encoded.contains("isRunning"))
    }

    @Test
    fun `live tunnel state is rejected`() {
        assertNull(
            PortForwardProfileSyncContract.decode(
                """{"kind":"orbit_port_forwards","version":1,"updatedAtUnix":1770000000,"profiles":[{"id":"abcdef00-1234-5678-9abc-def012345678","assetId":"11111111-2222-3333-4444-555555555555","name":"db","mode":"local","bindHost":"127.0.0.1","bindPort":15432,"destinationHost":"127.0.0.1","destinationPort":5432,"createdAtUnix":1760000000,"updatedAtUnix":1770000000,"tunnelId":7}],"tombstones":[]}""",
            ),
        )
    }
}
