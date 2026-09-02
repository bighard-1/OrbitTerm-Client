package com.orbitterm.android.app

import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class SyncWorkContractTest {
    @Test
    fun `unique work is isolated by opaque account scope`() {
        val firstLease = "11111111-1111-1111-1111-111111111111"
        val secondLease = "22222222-2222-2222-2222-222222222222"
        val first = SyncWorkContract.uniqueName("scope-a", firstLease)
        val second = SyncWorkContract.uniqueName("scope-b", secondLease)

        assertEquals("orbitterm.sync.scope-a.$firstLease", first)
        assertEquals("orbitterm.sync.scope.scope-a", SyncWorkContract.tag("scope-a"))
        assertFalse(first == second)
    }

    @Test
    fun `worker input contract contains no credential field`() {
        assertEquals("account_scope", SyncWorkContract.ACCOUNT_SCOPE_KEY)
        assertEquals("authority_lease", SyncWorkContract.AUTHORITY_LEASE_KEY)
        assertTrue(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("scope"))
        assertFalse(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("token"))
        assertFalse(SyncWorkContract.ACCOUNT_SCOPE_KEY.contains("password"))
        assertFalse(SyncWorkContract.AUTHORITY_LEASE_KEY.contains("token"))
        assertFalse(SyncWorkContract.AUTHORITY_LEASE_KEY.contains("password"))
    }

    @Test
    fun `work lease is bound to one process and unlock generation`() {
        val process = UUID.randomUUID().toString()
        val nextProcess = UUID.randomUUID().toString()
        val lease = UUID.randomUUID().toString()
        val nextUnlock = UUID.randomUUID().toString()
        val persisted = SyncWorkLeasePolicy.encode(process, lease)

        assertTrue(SyncWorkLeasePolicy.owns(persisted, process, lease))
        assertFalse(SyncWorkLeasePolicy.owns(persisted, nextProcess, lease))
        assertFalse(SyncWorkLeasePolicy.owns(persisted, process, nextUnlock))
        assertEquals(lease, SyncWorkLeasePolicy.currentLease(persisted, process))
        assertEquals(null, SyncWorkLeasePolicy.currentLease(persisted, nextProcess))
    }

    @Test
    fun `legacy boolean entitlement and malformed worker lease fail closed`() {
        val process = UUID.randomUUID().toString()

        assertEquals(null, SyncWorkLeasePolicy.currentLease(true, process))
        assertFalse(SyncWorkLeasePolicy.owns(true, process, UUID.randomUUID().toString()))
        assertFalse(SyncWorkContract.isValidLeaseId("not-a-lease"))
        assertTrue(SyncWorkContract.isValidScopeId("a".repeat(64)))
        assertFalse(SyncWorkContract.isValidScopeId("../account"))
    }

    @Test
    fun `process restart lock and account switch cannot reuse an old continuation lease`() {
        val oldProcess = UUID.randomUUID().toString()
        val restartedProcess = UUID.randomUUID().toString()
        val oldLease = UUID.randomUUID().toString()
        val nextUnlockLease = UUID.randomUUID().toString()
        val oldPersistedLease = SyncWorkLeasePolicy.encode(oldProcess, oldLease)

        assertFalse(SyncWorkLeasePolicy.owns(oldPersistedLease, restartedProcess, oldLease))
        assertFalse(SyncWorkLeasePolicy.owns(null, oldProcess, oldLease))
        assertFalse(SyncWorkLeasePolicy.owns(oldPersistedLease, oldProcess, nextUnlockLease))
        assertFalse(
            SyncWorkContract.uniqueName("a".repeat(64), oldLease) ==
                SyncWorkContract.uniqueName("b".repeat(64), oldLease),
        )
    }

    @Test
    fun `unlocking a new account atomically replaces every old authority`() {
        val oldKey = "allowed.${"a".repeat(64)}"
        val newKey = "allowed.${"b".repeat(64)}"
        val oldValues = SyncWorkAuthorityPolicy.replacement(oldKey, "old-process:old-lease")
        val replacement = SyncWorkAuthorityPolicy.replacement(newKey, "new-process:new-lease")

        assertTrue(oldKey in oldValues)
        assertFalse(oldKey in replacement)
        assertEquals(setOf(newKey), replacement.keys)
    }

    @Test
    fun `worker honors server delay and never retries permanent rejection`() {
        assertEquals(
            SyncWorkerFailureDecision.RetryAfter(120),
            SyncWorkerFailurePolicy.decide(syncError(OrbitErrorCode.RemoteRateLimited, 120)),
        )
        assertEquals(
            SyncWorkerFailureDecision.RetryWithSystemBackoff,
            SyncWorkerFailurePolicy.decide(syncError(OrbitErrorCode.NetworkUnavailable)),
        )
        assertEquals(
            SyncWorkerFailureDecision.Stop,
            SyncWorkerFailurePolicy.decide(syncError(OrbitErrorCode.RemoteRequestRejected)),
        )
    }
}
