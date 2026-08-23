package com.orbitterm.android.domain.session

import kotlinx.coroutines.flow.Flow

enum class TerminalCustomKeySection { Common, Symbols }

/** Account-scoped terminal accessory item. Payload uses the small escaped-byte grammar validated by the UI. */
data class TerminalCustomKey(
    val id: String,
    val label: String,
    val payload: String,
    val section: TerminalCustomKeySection,
)

/** Per-account usage counts for the terminal's explicitly tapped extension keys. */
interface TerminalKeyUsageRepository {
    val usageCounts: Flow<Map<String, Int>>
    val customKeys: Flow<List<TerminalCustomKey>>

    suspend fun recordUse(keyLabel: String)
    suspend fun saveCustomKey(key: TerminalCustomKey)
    suspend fun deleteCustomKey(id: String)
}
