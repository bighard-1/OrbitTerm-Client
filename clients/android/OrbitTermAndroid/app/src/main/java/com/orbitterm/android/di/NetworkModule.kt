package com.orbitterm.android.di

import com.orbitterm.android.sync.OrbitApi
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    @Provides @Singleton fun provideOrbitApi(): OrbitApi = OrbitApi()
}
