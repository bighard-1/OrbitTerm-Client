package com.orbitterm.android.data.local

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
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

        helper.runMigrationsAndValidate(
            TEST_DATABASE,
            8,
            true,
            OrbitTermMigrations.V1_TO_V2,
            OrbitTermMigrations.V2_TO_V3,
            OrbitTermMigrations.V3_TO_V4,
            OrbitTermMigrations.V4_TO_V5,
            OrbitTermMigrations.V5_TO_V6,
            OrbitTermMigrations.V6_TO_V7,
            OrbitTermMigrations.V7_TO_V8,
        ).close()
    }

    private companion object { const val TEST_DATABASE = "orbit-migration-test" }
}
