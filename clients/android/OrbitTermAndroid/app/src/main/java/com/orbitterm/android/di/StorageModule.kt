package com.orbitterm.android.di

import android.content.Context
import androidx.room.Room
import com.orbitterm.android.data.local.OrbitTermDatabase
import com.orbitterm.android.data.local.ServerAssetDao
import com.orbitterm.android.data.local.AssetSyncMetadataDao
import com.orbitterm.android.data.local.AssetSyncOutboxDao
import com.orbitterm.android.data.local.OrbitTermMigrations
import com.orbitterm.android.data.repository.RoomAssetRepository
import com.orbitterm.android.domain.assets.AssetRepository
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class AssetRepositoryModule {
    @Binds
    @Singleton
    abstract fun bindAssetRepository(repository: RoomAssetRepository): AssetRepository
}

@Module
@InstallIn(SingletonComponent::class)
object StorageModule {
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): OrbitTermDatabase =
        Room.databaseBuilder(context, OrbitTermDatabase::class.java, "orbitterm.db")
            .addMigrations(OrbitTermMigrations.V1_TO_V2)
            .addMigrations(OrbitTermMigrations.V2_TO_V3)
            .addMigrations(OrbitTermMigrations.V3_TO_V4)
            .addMigrations(OrbitTermMigrations.V4_TO_V5)
            .addMigrations(OrbitTermMigrations.V5_TO_V6)
            .addMigrations(OrbitTermMigrations.V6_TO_V7)
            .addMigrations(OrbitTermMigrations.V7_TO_V8)
            .addMigrations(OrbitTermMigrations.V8_TO_V9)
            .addMigrations(OrbitTermMigrations.V9_TO_V10)
            .addMigrations(OrbitTermMigrations.V10_TO_V11)
            .build()

    @Provides
    fun provideServerAssetDao(database: OrbitTermDatabase): ServerAssetDao = database.serverAssetDao()

    @Provides
    fun provideAssetSyncMetadataDao(database: OrbitTermDatabase): AssetSyncMetadataDao = database.assetSyncMetadataDao()

    @Provides
    fun provideAssetSyncOutboxDao(database: OrbitTermDatabase): AssetSyncOutboxDao = database.assetSyncOutboxDao()
}
