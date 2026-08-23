package com.orbitterm.android.di

import com.orbitterm.android.data.settings.DataStoreTerminalKeyUsageRepository
import com.orbitterm.android.domain.session.TerminalKeyUsageRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class TerminalKeyUsageModule {
    @Binds
    @Singleton
    abstract fun bindTerminalKeyUsageRepository(
        repository: DataStoreTerminalKeyUsageRepository,
    ): TerminalKeyUsageRepository
}
