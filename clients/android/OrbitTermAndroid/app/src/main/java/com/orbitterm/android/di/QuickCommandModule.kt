package com.orbitterm.android.di

import com.orbitterm.android.data.settings.DataStoreQuickCommandRepository
import com.orbitterm.android.domain.session.QuickCommandRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class QuickCommandModule {
    @Binds
    @Singleton
    abstract fun bindQuickCommandRepository(repository: DataStoreQuickCommandRepository): QuickCommandRepository
}
