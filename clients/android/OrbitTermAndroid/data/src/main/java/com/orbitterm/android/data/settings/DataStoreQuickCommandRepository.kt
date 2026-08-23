package com.orbitterm.android.data.settings

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.session.CustomQuickCommand
import com.orbitterm.android.domain.session.QuickCommandRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private val Context.quickCommandsDataStore by preferencesDataStore(name = "quick_commands")

@Singleton
class DataStoreQuickCommandRepository @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val accountScopeController: ActiveAccountScopeProvider,
) : QuickCommandRepository {
    private val migrationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        accountScopeController.scope
            .filterNotNull()
            .onEach(::migrateLegacyCommandsIfNeeded)
            .launchIn(migrationScope)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override val customCommands: Flow<List<CustomQuickCommand>> = accountScopeController.scope.flatMapLatest { scope ->
        scope?.let(::commandsForScope) ?: flowOf(emptyList())
    }

    override suspend fun save(commands: List<CustomQuickCommand>) {
        val scope = accountScopeController.scope.value ?: return
        saveForScope(commands, scope)
    }

    override fun commandsForScope(scope: AccountScope): Flow<List<CustomQuickCommand>> =
        context.quickCommandsDataStore.data.map { preferences ->
            preferences[Keys.commands(scope)]
                ?.let { encoded -> runCatching { Json.decodeFromString<List<CustomQuickCommand>>(encoded) }.getOrNull() }
                ?: emptyList()
        }

    override suspend fun saveForScope(commands: List<CustomQuickCommand>, scope: AccountScope) {
        context.quickCommandsDataStore.edit { preferences ->
            preferences[Keys.commands(scope)] = Json.encodeToString(commands)
        }
    }

    /** Moves the pre-account-scoping collection only once, preventing cross-account leakage. */
    private suspend fun migrateLegacyCommandsIfNeeded(scope: AccountScope) {
        context.quickCommandsDataStore.edit { preferences ->
            if (preferences[Keys.legacyMigrated] == true) return@edit
            val destination = Keys.commands(scope)
            if (preferences[destination] == null) {
                preferences[Keys.legacyCommands]?.let { preferences[destination] = it }
            }
            preferences[Keys.legacyMigrated] = true
        }
    }

    private object Keys {
        val legacyCommands = stringPreferencesKey("custom_commands")
        val legacyMigrated = booleanPreferencesKey("custom_commands_account_scope_migrated_v1")
        fun commands(scope: AccountScope) = stringPreferencesKey("custom_commands_${scope.storageId}")
    }
}
