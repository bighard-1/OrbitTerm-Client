package com.orbitterm.android.di

import com.orbitterm.android.data.settings.DataStoreAppSettingsRepository
import com.orbitterm.android.domain.settings.AppSettingsRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class SettingsModule {
    @Binds
    @Singleton
    abstract fun bindAppSettingsRepository(repository: DataStoreAppSettingsRepository): AppSettingsRepository
}
