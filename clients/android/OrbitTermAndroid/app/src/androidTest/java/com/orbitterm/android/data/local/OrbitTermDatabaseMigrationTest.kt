package com.orbitterm.android.data.local

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OrbitTermDatabaseMigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        requireNotNull(OrbitTermDatabase::class.java.canonicalName),
        FrameworkSQLiteOpenHelperFactory(),
    )

    @Test
    fun migratesVersion1ToCurrentWithoutDestructiveFallback() {
        helper.createDatabase(TEST_DATABASE, 1).apply {
            execSQL(
                "INSERT INTO server_assets (id, credentialID, name, groupName, host, port, username, authMethod, transport, networkDeviceProfile, allowPasswordFallback, createdAtUnix) " +
                    "VALUES ('legacy-id', 'legacy-credential', 'Legacy', '', '127.0.0.1', 22, 'root', 'key', 'ssh', 'auto', 0, 1)",
            )
            close()
        }

        val migrated = helper.runMigrationsAndValidate(
            TEST_DATABASE,
            11,
            true,
            OrbitTermMigrations.V1_TO_V2,
            OrbitTermMigrations.V2_TO_V3,
            OrbitTermMigrations.V3_TO_V4,
            OrbitTermMigrations.V4_TO_V5,
            OrbitTermMigrations.V5_TO_V6,
            OrbitTermMigrations.V6_TO_V7,
            OrbitTermMigrations.V7_TO_V8,
            OrbitTermMigrations.V8_TO_V9,
            OrbitTermMigrations.V9_TO_V10,
            OrbitTermMigrations.V10_TO_V11,
        )

        migrated.query(
            "SELECT accountScope, id, credentialID, host, port FROM server_assets WHERE id = 'legacy-id'",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            // A pre-account row must survive, but the migration must never
            // guess which later signed-in account owns it.
            assertEquals("", cursor.getString(0))
            assertEquals("legacy-id", cursor.getString(1))
            assertEquals("legacy-credential", cursor.getString(2))
            assertEquals("127.0.0.1", cursor.getString(3))
            assertEquals(22, cursor.getInt(4))
            assertFalse(cursor.moveToNext())
        }
        migrated.query("SELECT COUNT(*) FROM asset_sync_outbox").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(0, cursor.getInt(0))
        }
        migrated.close()
    }

    @Test
    fun migratesPendingVersion8IntentWithOneDurableReplayIdentity() {
        helper.createDatabase(REPLAY_DATABASE, 8).apply {
            execSQL(
                "INSERT INTO asset_sync_outbox (accountScope, assetId, operation, enqueuedAtUnix) " +
                    "VALUES ('account', 'asset', 'MOVE_TO_TRASH', 7)",
            )
            close()
        }

        val migrated = helper.runMigrationsAndValidate(
            REPLAY_DATABASE,
            11,
            true,
            OrbitTermMigrations.V8_TO_V9,
            OrbitTermMigrations.V9_TO_V10,
            OrbitTermMigrations.V10_TO_V11,
        )
        val firstIdentity = migrated.query(
            "SELECT operationId FROM asset_sync_outbox WHERE accountScope = 'account' AND assetId = 'asset'",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getString(0)
        }
        assertTrue(firstIdentity.matches(Regex("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")))
        migrated.close()

        val reopened = helper.runMigrationsAndValidate(REPLAY_DATABASE, 11, true)
        reopened.query("SELECT operationId FROM asset_sync_outbox").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(firstIdentity, cursor.getString(0))
        }
        reopened.close()
    }

    @Test
    fun migratesVersion9IntentAsReadyWithoutInventingFailureState() {
        helper.createDatabase(DISPOSITION_DATABASE, 9).apply {
            execSQL(
                "INSERT INTO asset_sync_outbox " +
                    "(accountScope, assetId, operation, operationId, enqueuedAtUnix) " +
                    "VALUES ('account', 'asset', 'UPSERT', 'operation', 9)",
            )
            close()
        }

        val migrated = helper.runMigrationsAndValidate(
            DISPOSITION_DATABASE,
            11,
            true,
            OrbitTermMigrations.V9_TO_V10,
            OrbitTermMigrations.V10_TO_V11,
        )
        migrated.query(
            "SELECT deliveryDisposition, failureCode, attemptCount FROM asset_sync_outbox",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals("READY", cursor.getString(0))
            assertTrue(cursor.isNull(1))
            assertEquals(0, cursor.getInt(2))
        }
        migrated.close()
    }

    @Test
    fun migratesVersion10RetryStateWithoutInventingServerDelay() {
        helper.createDatabase(RETRY_AFTER_DATABASE, 10).apply {
            execSQL(
                "INSERT INTO asset_sync_outbox " +
                    "(accountScope, assetId, operation, operationId, enqueuedAtUnix, " +
                    "deliveryDisposition, failureCode, attemptCount) " +
                    "VALUES ('account', 'asset', 'UPSERT', 'operation', 10, " +
                    "'READY', 'remote_service_unavailable', 2)",
            )
            close()
        }

        val migrated = helper.runMigrationsAndValidate(
            RETRY_AFTER_DATABASE,
            11,
            true,
            OrbitTermMigrations.V10_TO_V11,
        )
        migrated.query("SELECT nextAttemptAtUnix, attemptCount FROM asset_sync_outbox").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(0L, cursor.getLong(0))
            assertEquals(2, cursor.getInt(1))
        }
        migrated.close()
    }

    private companion object {
        const val TEST_DATABASE = "orbit-migration-test"
        const val REPLAY_DATABASE = "orbit-replay-migration-test"
        const val DISPOSITION_DATABASE = "orbit-disposition-migration-test"
        const val RETRY_AFTER_DATABASE = "orbit-retry-after-migration-test"
    }
}
