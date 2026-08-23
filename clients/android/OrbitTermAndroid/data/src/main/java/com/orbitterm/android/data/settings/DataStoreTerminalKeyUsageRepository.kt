package com.orbitterm.android.data.settings

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.session.TerminalKeyUsageRepository
import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private val Context.terminalKeyUsageDataStore by preferencesDataStore(name = "terminal_key_usage")

@Singleton
class DataStoreTerminalKeyUsageRepository @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val accountScopeController: ActiveAccountScopeProvider,
) : TerminalKeyUsageRepository {
    @OptIn(ExperimentalCoroutinesApi::class)
    override val usageCounts: Flow<Map<String, Int>> = accountScopeController.scope.flatMapLatest { scope ->
        scope?.let(::usageForScope) ?: flowOf(emptyMap())
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    override val customKeys: Flow<List<TerminalCustomKey>> = accountScopeController.scope.flatMapLatest { scope ->
        scope?.let(::customKeysForScope) ?: flowOf(emptyList())
    }

    override suspend fun recordUse(keyLabel: String) {
        val scope = accountScopeController.scope.value ?: return
        context.terminalKeyUsageDataStore.edit { preferences ->
            val current = preferences[Keys.usage(scope)]
                ?.let { encoded -> runCatching { Json.decodeFromString<Map<String, Int>>(encoded) }.getOrNull() }
                .orEmpty()
            val nextCount = (current[keyLabel] ?: 0).coerceAtMost(MAX_USAGE_COUNT - 1) + 1
            preferences[Keys.usage(scope)] = Json.encodeToString(current + (keyLabel to nextCount))
        }
    }

    override suspend fun saveCustomKey(key: TerminalCustomKey) {
        val scope = accountScopeController.scope.value ?: return
        context.terminalKeyUsageDataStore.edit { preferences ->
            val current = decodeCustomKeys(preferences[Keys.customKeys(scope)])
            val next = current.filterNot { it.id == key.id } + key
            preferences[Keys.customKeys(scope)] = Json.encodeToString(next.map(CustomTerminalKeyRecord::fromDomain))
        }
    }

    override suspend fun deleteCustomKey(id: String) {
        val scope = accountScopeController.scope.value ?: return
        context.terminalKeyUsageDataStore.edit { preferences ->
            val next = decodeCustomKeys(preferences[Keys.customKeys(scope)]).filterNot { it.id == id }
            preferences[Keys.customKeys(scope)] = Json.encodeToString(next.map(CustomTerminalKeyRecord::fromDomain))
        }
    }

    private fun usageForScope(scope: AccountScope): Flow<Map<String, Int>> =
        context.terminalKeyUsageDataStore.data.map { preferences ->
            preferences[Keys.usage(scope)]
                ?.let { encoded -> runCatching { Json.decodeFromString<Map<String, Int>>(encoded) }.getOrNull() }
                .orEmpty()
        }

    private fun customKeysForScope(scope: AccountScope): Flow<List<TerminalCustomKey>> =
        context.terminalKeyUsageDataStore.data.map { preferences ->
            decodeCustomKeys(preferences[Keys.customKeys(scope)])
        }

    private fun decodeCustomKeys(encoded: String?): List<TerminalCustomKey> = encoded
        ?.let { value -> runCatching { Json.decodeFromString<List<CustomTerminalKeyRecord>>(value) }.getOrNull() }
        .orEmpty()
        .mapNotNull(CustomTerminalKeyRecord::toDomain)

    private object Keys {
        fun usage(scope: AccountScope) = stringPreferencesKey("terminal_key_usage_${scope.storageId}")
        fun customKeys(scope: AccountScope) = stringPreferencesKey("terminal_custom_keys_${scope.storageId}")
    }

    @kotlinx.serialization.Serializable
    private data class CustomTerminalKeyRecord(
        val id: String,
        val label: String,
        val payload: String,
        val section: String,
    ) {
        fun toDomain(): TerminalCustomKey? {
            val parsedSection = runCatching { TerminalCustomKeySection.valueOf(section) }.getOrNull() ?: return null
            if (id.isBlank() || label.isBlank() || payload.isEmpty()) return null
            return TerminalCustomKey(id, label, payload, parsedSection)
        }

        companion object {
            fun fromDomain(key: TerminalCustomKey) = CustomTerminalKeyRecord(
                id = key.id,
                label = key.label,
                payload = key.payload,
                section = key.section.name,
            )
        }
    }

    private companion object {
        const val MAX_USAGE_COUNT = 10_000
    }
}
