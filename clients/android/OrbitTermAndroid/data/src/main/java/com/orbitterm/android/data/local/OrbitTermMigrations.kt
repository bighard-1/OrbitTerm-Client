package com.orbitterm.android.data.local

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

object OrbitTermMigrations {
    /** Preserve v1 rows in an unassigned partition; never guess an account owner. */
    val V1_TO_V2 = object : Migration(1, 2) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE server_assets RENAME TO server_assets_v1")
            db.execSQL("CREATE TABLE IF NOT EXISTS server_assets (accountScope TEXT NOT NULL, id TEXT NOT NULL, credentialID TEXT NOT NULL, name TEXT NOT NULL, groupName TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL, username TEXT NOT NULL, authMethod TEXT NOT NULL, transport TEXT NOT NULL, networkDeviceProfile TEXT NOT NULL, allowPasswordFallback INTEGER NOT NULL, createdAtUnix INTEGER NOT NULL, PRIMARY KEY(accountScope, id))")
            db.execSQL("INSERT INTO server_assets (accountScope, id, credentialID, name, groupName, host, port, username, authMethod, transport, networkDeviceProfile, allowPasswordFallback, createdAtUnix) SELECT '', id, credentialID, name, groupName, host, port, username, authMethod, transport, networkDeviceProfile, allowPasswordFallback, createdAtUnix FROM server_assets_v1")
            db.execSQL("DROP TABLE server_assets_v1")
        }
    }

    /** Metadata is intentionally introduced separately from user-visible assets. */
    val V2_TO_V3 = object : Migration(2, 3) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS asset_sync_metadata (accountScope TEXT NOT NULL, assetId TEXT NOT NULL, remoteConfigId INTEGER, vectorClock TEXT NOT NULL, serverRevision INTEGER, syncedPayloadDigest TEXT NOT NULL, syncedAtUnix INTEGER NOT NULL, PRIMARY KEY(accountScope, assetId))",
            )
        }
    }

    val V3_TO_V4 = object : Migration(3, 4) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS asset_sync_outbox (accountScope TEXT NOT NULL, assetId TEXT NOT NULL, operation TEXT NOT NULL, enqueuedAtUnix INTEGER NOT NULL, PRIMARY KEY(accountScope, assetId))",
            )
        }
    }

    val V4_TO_V5 = object : Migration(4, 5) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE asset_sync_metadata ADD COLUMN remoteState TEXT NOT NULL DEFAULT 'active'")
        }
    }

    val V5_TO_V6 = object : Migration(5, 6) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE asset_sync_metadata ADD COLUMN syncedSafeShadow TEXT NOT NULL DEFAULT ''")
        }
    }

    /** Jump credentials remain in Keystore; this column stores metadata only. */
    val V6_TO_V7 = object : Migration(6, 7) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE server_assets ADD COLUMN jumpHostJson TEXT")
        }
    }

    /** Tags are plain metadata and intentionally remain outside the credential store. */
    val V7_TO_V8 = object : Migration(7, 8) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE server_assets ADD COLUMN tagsJson TEXT NOT NULL DEFAULT '[]'")
        }
    }
}
