package com.orbitterm.android.data.local

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
    entities = [ServerAssetEntity::class, AssetSyncMetadataEntity::class, AssetSyncOutboxEntity::class],
    version = 11,
    exportSchema = true,
)
abstract class OrbitTermDatabase : RoomDatabase() {
    abstract fun serverAssetDao(): ServerAssetDao
    abstract fun assetSyncMetadataDao(): AssetSyncMetadataDao
    abstract fun assetSyncOutboxDao(): AssetSyncOutboxDao
}
