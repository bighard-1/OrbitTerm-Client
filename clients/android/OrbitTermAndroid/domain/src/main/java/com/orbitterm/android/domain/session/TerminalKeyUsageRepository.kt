package com.orbitterm.android.domain.session

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

enum class TerminalCustomKeySection { Common, Symbols }

/** Account-scoped terminal accessory item. Payload uses the small escaped-byte grammar validated by the UI. */
data class TerminalCustomKey(
    val id: String,
    val label: String,
    val payload: String,
    val section: TerminalCustomKeySection,
)

/** Ephemeral authorization, never persisted or uploaded with the document. */
data class TerminalCustomKeyConflictReview(val accessToken: String, val conflict: TerminalCustomKeyConflict)
data class TerminalCustomKeyState(
    val keys: List<TerminalCustomKey> = emptyList(),
    val conflicts: List<TerminalCustomKeyConflictReview> = emptyList(),
)
data class TerminalCustomKeyExport(val accessToken: String, val bytes: ByteArray)
data class TerminalCustomKeyImportReview(val accessToken: String, val storageFingerprint: String, val plan: TerminalCustomKeyImportPlan)
enum class TerminalKeyRescuePlatform { Apple, Android }
enum class TerminalKeyRescueStorageMatch { Exact, Different, Missing, NotComparable }
enum class TerminalKeyRescueSourceStatus {
    ValidProtectedLibrary, ValidLegacyLibrary, InvalidStructure, DuplicateId,
    ContractRejected, ProtectedUnreadable, OpaqueForeignSource, PauseMarker,
}
data class TerminalKeyRescueSourceReview(
    val kind: Int,
    val byteCount: Int,
    val status: TerminalKeyRescueSourceStatus,
)
data class TerminalKeyRescueReview(
    val accessToken: String,
    val platform: TerminalKeyRescuePlatform,
    val accountMatches: Boolean,
    val storageMatch: TerminalKeyRescueStorageMatch,
    val sources: List<TerminalKeyRescueSourceReview>,
    val repairPreview: TerminalKeyRepairPreview? = null,
    val decisionSessionToken: String = accessToken,
)
enum class TerminalKeyRepairSource { AppleDocument, AndroidLegacy }
enum class TerminalKeyRepairBlockedReason {
    MalformedOrAmbiguous, RootNotEnumerable, TooManyItems,
}
enum class TerminalKeyRepairIssue {
    RowNotObject, UnknownFields, MissingOrWrongId, InvalidId, DuplicateId,
    MissingOrWrongLabel, InvalidLabel, MissingOrWrongPayload, InvalidPayload,
    MissingOrWrongSection, InvalidSection, InvalidClock, InvalidValue,
    InvalidDocumentMetadata, RevisionCollision, TooManyVersions, CapacitySelectionRequired,
}
enum class TerminalKeyRepairDisposition { KeepUnchanged, ManualCorrectionRequired, CapacitySelectionRequired, CannotInterpret }
data class TerminalKeyRepairItem(
    val index: Int,
    val idSummary: String?,
    val labelSummary: String?,
    val sectionSummary: String?,
    val payloadUtf8Bytes: Int?,
    val issues: List<TerminalKeyRepairIssue>,
    val disposition: TerminalKeyRepairDisposition,
    /** Ephemeral within one preview; never persisted or shown as an identifier. */
    val identityGroup: Int?,
    val isActive: Boolean,
)
data class TerminalKeyRepairPreview(
    val source: TerminalKeyRepairSource,
    val blockedReason: TerminalKeyRepairBlockedReason? = null,
    val documentIssues: List<TerminalKeyRepairIssue> = emptyList(),
    val items: List<TerminalKeyRepairItem> = emptyList(),
    val protectedSourcePresent: Boolean = false,
)

enum class TerminalKeyRepairChoice { Keep, Correct, Exclude, CapacityExclude }
data class TerminalKeyRepairCorrection(var label: String = "", var payload: String = "", var section: String = "common")
data class TerminalKeyRepairDecision(val choice: TerminalKeyRepairChoice, val correction: TerminalKeyRepairCorrection? = null)
sealed interface TerminalKeyRepairDecisionIssue {
    data object SourceBlocked : TerminalKeyRepairDecisionIssue
    data object ProtectedSourceConflict : TerminalKeyRepairDecisionIssue
    data object DocumentMetadataBlocked : TerminalKeyRepairDecisionIssue
    data class MissingDecision(val index: Int) : TerminalKeyRepairDecisionIssue
    data class InvalidChoice(val index: Int) : TerminalKeyRepairDecisionIssue
    data class InvalidCorrection(val index: Int) : TerminalKeyRepairDecisionIssue
    data class DuplicateRetainedIdentity(val group: Int) : TerminalKeyRepairDecisionIssue
    data class TooManyVersions(val group: Int) : TerminalKeyRepairDecisionIssue
    data class CapacityExceeded(val count: Int) : TerminalKeyRepairDecisionIssue
}
data class TerminalKeyRepairDecisionRow(
    val index: Int, val choice: TerminalKeyRepairChoice, val idSummary: String?, val labelSummary: String?,
    val sectionSummary: String?, val payloadUtf8Bytes: Int?, val included: Boolean,
)
/** Summary-only result: it intentionally contains no replacement payload and grants no write authority. */
data class TerminalKeyRepairDecisionPlan(
    val totalCount: Int, val decidedCount: Int, val keptCount: Int, val correctedCount: Int,
    val excludedCount: Int, val activeIdentityCount: Int, val rows: List<TerminalKeyRepairDecisionRow>,
    val issues: List<TerminalKeyRepairDecisionIssue>, val confirmationBaseline: String?,
) {
    val isReadyForSecondConfirmation get() = issues.isEmpty() && confirmationBaseline != null
    val requiresDataLossAcknowledgement get() = excludedCount > 0
}

/** Per-account usage counts for the terminal's explicitly tapped extension keys. */
interface TerminalKeyUsageRepository {
    val customKeyStorageNotice: Flow<String?> get() = kotlinx.coroutines.flow.flowOf(null)
    val usageCounts: Flow<Map<String, Int>>
    val customKeys: Flow<List<TerminalCustomKey>>
    val customKeyState: Flow<TerminalCustomKeyState> get() = customKeys.map { TerminalCustomKeyState(it) }

    suspend fun reloadCustomKeys() {}
    fun recoveryAccessValid(token: String): Boolean = false
    fun recoveryAccessToken(): String? = null
    val recoveryAccessTokens: Flow<String?> get() = kotlinx.coroutines.flow.flowOf(null)
    suspend fun exportRecovery(password: String): TerminalCustomKeyExport = error("恢复功能不可用。")
    suspend fun exportRescue(password: String): TerminalCustomKeyExport = error("救援功能不可用。")
    suspend fun inspectRescue(bytes: ByteArray, password: String): TerminalKeyRescueReview = error("救援核验功能不可用。")
    suspend fun previewRecovery(bytes: ByteArray, password: String): TerminalCustomKeyImportReview = error("恢复功能不可用。")
    suspend fun importRecovery(review: TerminalCustomKeyImportReview) { error("恢复功能不可用。") }
    suspend fun resolveCustomKey(review: TerminalCustomKeyConflictReview, keeping: TerminalCustomKeyRevision?) {
        error("当前存储不支持冲突处理。")
    }

    suspend fun recordUse(keyLabel: String)
    suspend fun saveCustomKey(key: TerminalCustomKey)
    suspend fun deleteCustomKey(id: String)
}
