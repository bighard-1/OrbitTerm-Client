package com.orbitterm.android.domain.session

import com.orbitterm.android.domain.auth.AccountScope
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.Serializable

@Serializable
data class CustomQuickCommand(
    val id: String,
    val title: String,
    val command: String,
    val category: String = "未分类",
    /** Empty means the snippet is available to every asset. */
    val allowedAssetIds: Set<String> = emptySet(),
    val createdAtUnix: Long = System.currentTimeMillis() / 1_000,
    val updatedAtUnix: Long = createdAtUnix,
)

interface QuickCommandRepository {
    val customCommands: Flow<List<CustomQuickCommand>>

    suspend fun save(commands: List<CustomQuickCommand>)
    fun commandsForScope(scope: AccountScope): Flow<List<CustomQuickCommand>>
    suspend fun saveForScope(commands: List<CustomQuickCommand>, scope: AccountScope)
}
