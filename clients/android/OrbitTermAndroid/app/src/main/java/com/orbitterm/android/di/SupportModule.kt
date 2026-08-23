package com.orbitterm.android.di

import com.orbitterm.android.data.support.DefaultAdministratorContactRepository
import com.orbitterm.android.domain.support.AdministratorContactRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class SupportModule {
    @Binds
    @Singleton
    abstract fun bindAdministratorContactRepository(
        repository: DefaultAdministratorContactRepository,
    ): AdministratorContactRepository
}
