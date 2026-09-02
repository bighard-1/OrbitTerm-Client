package com.orbitterm.android.data.local

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AssetSyncOutboxBatchTest {
    @Test
    fun backlogReadsOneStableBoundedFifoPageWithoutDeletingRemainder() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, OrbitTermDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        try {
            val dao = database.assetSyncOutboxDao()
            val total = RuntimeResourceBudget.SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN + 37
            repeat(total) { index ->
                dao.upsert(
                    AssetSyncOutboxEntity(
                        accountScope = ACCOUNT_SCOPE,
                        assetId = "asset-${index.toString().padStart(4, '0')}",
                        operation = AssetSyncOperation.UPSERT.name,
                        operationId = "operation-$index",
                        enqueuedAtUnix = index.toLong(),
                    ),
                )
            }

            val firstPage = dao.listBatch(
                ACCOUNT_SCOPE,
                RuntimeResourceBudget.SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN,
            )

            assertEquals(RuntimeResourceBudget.SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN, firstPage.size)
            assertEquals("asset-0000", firstPage.first().assetId)
            assertEquals("asset-0099", firstPage.last().assetId)
            assertEquals(total, dao.count(ACCOUNT_SCOPE))
            assertTrue(dao.listBatch("different-account", 100).isEmpty())
        } finally {
            database.close()
        }
    }

    @Test
    fun processEquivalentDatabaseReopenPreservesUnfinishedBacklogAndAccountIsolation() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteDatabase(TEST_DATABASE)
        try {
            val database = Room.databaseBuilder(context, OrbitTermDatabase::class.java, TEST_DATABASE).build()
            try {
                val dao = database.assetSyncOutboxDao()
                repeat(237) { index ->
                    dao.upsert(
                        AssetSyncOutboxEntity(
                            accountScope = ACCOUNT_SCOPE,
                            assetId = "asset-${index.toString().padStart(4, '0')}",
                            operation = AssetSyncOperation.UPSERT.name,
                            operationId = "operation-$index",
                            enqueuedAtUnix = index.toLong(),
                        ),
                    )
                }
                dao.upsert(
                    AssetSyncOutboxEntity(
                        accountScope = OTHER_ACCOUNT_SCOPE,
                        assetId = "other-account-asset",
                        operation = AssetSyncOperation.UPSERT.name,
                        operationId = "other-operation",
                        enqueuedAtUnix = 0,
                    ),
                )
                dao.listBatch(ACCOUNT_SCOPE, 100).forEach { dao.delete(ACCOUNT_SCOPE, it.assetId) }
            } finally {
                database.close()
            }

            val reopened = Room.databaseBuilder(context, OrbitTermDatabase::class.java, TEST_DATABASE).build()
            try {
                val dao = reopened.assetSyncOutboxDao()
                assertEquals(137, dao.count(ACCOUNT_SCOPE))
                assertEquals("asset-0100", dao.listBatch(ACCOUNT_SCOPE, 100).first().assetId)
                assertEquals(1, dao.count(OTHER_ACCOUNT_SCOPE))
                assertEquals("other-account-asset", dao.listBatch(OTHER_ACCOUNT_SCOPE, 100).single().assetId)
            } finally {
                reopened.close()
            }
        } finally {
            context.deleteDatabase(TEST_DATABASE)
        }
    }

    @Test
    fun lateResponseCannotDeleteANewerCoalescedIntent() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, OrbitTermDatabase::class.java).build()
        try {
            val dao = database.assetSyncOutboxDao()
            dao.upsert(
                AssetSyncOutboxEntity(
                    accountScope = ACCOUNT_SCOPE,
                    assetId = "asset",
                    operation = AssetSyncOperation.MOVE_TO_TRASH.name,
                    operationId = "first-operation",
                    enqueuedAtUnix = 1,
                ),
            )
            val inFlight = dao.list(ACCOUNT_SCOPE).single()
            dao.upsert(
                inFlight.copy(
                    operation = AssetSyncOperation.RESTORE_FROM_TRASH.name,
                    operationId = "newer-operation",
                    enqueuedAtUnix = 2,
                ),
            )

            dao.deleteCompleted(ACCOUNT_SCOPE, inFlight.assetId, inFlight.operationId)

            val retained = dao.list(ACCOUNT_SCOPE).single()
            assertEquals("newer-operation", retained.operationId)
            assertEquals(AssetSyncOperation.RESTORE_FROM_TRASH.name, retained.operation)
        } finally {
            database.close()
        }
    }

    @Test
    fun blockedIntentIsDurableExcludedAndDiscardedOnlyByExplicitBlockedQuery() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, OrbitTermDatabase::class.java).build()
        try {
            val dao = database.assetSyncOutboxDao()
            val blocked = AssetSyncOutboxEntity(
                accountScope = ACCOUNT_SCOPE,
                assetId = "blocked-asset",
                operation = AssetSyncOperation.UPSERT.name,
                operationId = "blocked-operation",
                enqueuedAtUnix = 1,
            )
            val ready = blocked.copy(assetId = "ready-asset", operationId = "ready-operation", enqueuedAtUnix = 2)
            val conflict = blocked.copy(assetId = "conflict-asset", operationId = "conflict-operation", enqueuedAtUnix = 3)
            dao.upsert(blocked)
            dao.upsert(ready)
            dao.upsert(conflict)

            assertEquals(
                1,
                dao.markFailure(
                    ACCOUNT_SCOPE,
                    blocked.assetId,
                    blocked.operationId,
                    SyncDeliveryDisposition.BLOCKED.name,
                    "unknown",
                    0,
                ),
            )
            dao.markFailure(
                ACCOUNT_SCOPE,
                conflict.assetId,
                conflict.operationId,
                SyncDeliveryDisposition.NEEDS_USER_ACTION.name,
                "sync_conflict",
                0,
            )

            assertEquals(listOf("ready-asset"), dao.listReadyBatch(ACCOUNT_SCOPE, 10, 100).map { it.assetId })
            assertEquals(1, dao.countByDisposition(ACCOUNT_SCOPE, SyncDeliveryDisposition.BLOCKED.name))
            assertEquals(1, dao.deleteBlocked(ACCOUNT_SCOPE))
            assertEquals(setOf("ready-asset", "conflict-asset"), dao.list(ACCOUNT_SCOPE).map { it.assetId }.toSet())
        } finally {
            database.close()
        }
    }

    @Test
    fun retryAfterSurvivesStorageAndPreventsEarlySelection() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteDatabase(RETRY_DATABASE)
        try {
            val database = Room.databaseBuilder(context, OrbitTermDatabase::class.java, RETRY_DATABASE).build()
            try {
                val dao = database.assetSyncOutboxDao()
                val operation = AssetSyncOutboxEntity(
                    accountScope = ACCOUNT_SCOPE,
                    assetId = "rate-limited-asset",
                    operation = AssetSyncOperation.UPSERT.name,
                    operationId = "rate-limited-operation",
                    enqueuedAtUnix = 1,
                )
                dao.upsert(operation)
                dao.markFailure(
                    ACCOUNT_SCOPE,
                    operation.assetId,
                    operation.operationId,
                    SyncDeliveryDisposition.READY.name,
                    "remote_rate_limited",
                    500,
                )
                dao.upsert(
                    operation.copy(
                        assetId = "unlock-required-asset",
                        operationId = "unlock-required-operation",
                        enqueuedAtUnix = 2,
                        deliveryDisposition = SyncDeliveryDisposition.WAITING_FOR_UNLOCK.name,
                    ),
                )
                dao.upsert(
                    operation.copy(
                        accountScope = OTHER_ACCOUNT_SCOPE,
                        assetId = "other-account-asset",
                        operationId = "other-account-operation",
                        enqueuedAtUnix = 3,
                    ),
                )
            } finally {
                database.close()
            }

            val reopened = Room.databaseBuilder(context, OrbitTermDatabase::class.java, RETRY_DATABASE).build()
            try {
                val dao = reopened.assetSyncOutboxDao()
                assertTrue(dao.listReadyBatch(ACCOUNT_SCOPE, 10, 499).isEmpty())
                assertEquals(500L, dao.earliestDelayedAttempt(ACCOUNT_SCOPE, 499))
                assertEquals("remote_rate_limited", dao.earliestDelayedFailureCode(ACCOUNT_SCOPE, 499))
                assertEquals(listOf("other-account-asset"), dao.listReadyBatch(OTHER_ACCOUNT_SCOPE, 10, 499).map { it.assetId })

                dao.resetDisposition(ACCOUNT_SCOPE, SyncDeliveryDisposition.WAITING_FOR_UNLOCK.name)

                assertEquals(listOf("unlock-required-asset"), dao.listReadyBatch(ACCOUNT_SCOPE, 10, 499).map { it.assetId })
                assertEquals(
                    listOf("rate-limited-asset", "unlock-required-asset"),
                    dao.listReadyBatch(ACCOUNT_SCOPE, 10, 500).map { it.assetId },
                )
            } finally {
                reopened.close()
            }
        } finally {
            context.deleteDatabase(RETRY_DATABASE)
        }
    }

    private companion object {
        val ACCOUNT_SCOPE = "a".repeat(64)
        val OTHER_ACCOUNT_SCOPE = "b".repeat(64)
        const val TEST_DATABASE = "orbit-sync-interruption-test"
        const val RETRY_DATABASE = "orbit-sync-retry-after-test"
    }
}
