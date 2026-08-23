package com.orbitterm.android.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncWorkContractTest {
    @Test
    fun `unique work is isolated by opaque account scope`() {
        val first = SyncWorkContract.uniqueName("scope-a")
        val second = SyncWorkContract.uniqueName("scope-b")

        assertEquals("orbitterm.sync.scope-a", first)
        assertEquals("orbitterm.sync.scope.scope-a", SyncWorkContract.tag("scope-a"))
        assertFalse(first == second)
    }

    @Test
    fun `worker input contract contains no credential field`() {
        assertEquals("account_scope", SyncWorkContract.ACCOUNT_SCOPE_KEY)
        assertTrue(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("scope"))
        assertFalse(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("token"))
        assertFalse(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("password"))
    }
}
