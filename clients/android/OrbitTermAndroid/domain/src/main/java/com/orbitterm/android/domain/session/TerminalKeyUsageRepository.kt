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

/** Per-account user-configured terminal accessory keys, kept in their chosen order. */
interface TerminalKeyUsageRepository {
    val customKeys: Flow<List<TerminalCustomKey>>

    suspend fun saveCustomKey(key: TerminalCustomKey)
    suspend fun deleteCustomKey(id: String)
}
