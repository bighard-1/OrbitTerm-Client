package com.orbitterm.android.di

import com.orbitterm.android.app.AccountScopeController
import com.orbitterm.android.app.AppSyncRequestBus
import com.orbitterm.android.app.ExternalActivityLockCoordinator
import com.orbitterm.android.app.SessionForegroundServiceController
import com.orbitterm.android.domain.assets.CredentialVault
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import com.orbitterm.android.domain.sync.SyncRequester
import com.orbitterm.android.core.DocumentInteractionCoordinator
import com.orbitterm.android.core.SessionForegroundController
import com.orbitterm.android.security.SecureCredentialStore
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/** App owns concrete security/session policies; lower modules receive only narrow contracts. */
@Module
@InstallIn(SingletonComponent::class)
abstract class ArchitectureBindingsModule {
    @Binds abstract fun bindActiveAccountScope(controller: AccountScopeController): ActiveAccountScopeProvider
    @Binds abstract fun bindOperationGeneration(controller: AccountScopeController): OperationGenerationProvider
    @Binds abstract fun bindCredentialVault(store: SecureCredentialStore): CredentialVault
    @Binds abstract fun bindSyncRequester(bus: AppSyncRequestBus): SyncRequester
    @Binds abstract fun bindDocumentInteraction(coordinator: ExternalActivityLockCoordinator): DocumentInteractionCoordinator
    @Binds abstract fun bindSessionForeground(controller: SessionForegroundServiceController): SessionForegroundController
}
