package com.orbitterm.android.data.local

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert

@Dao
interface AssetSyncOutboxDao {
    @Query("SELECT * FROM asset_sync_outbox WHERE accountScope = :accountScope ORDER BY enqueuedAtUnix ASC")
    suspend fun list(accountScope: String): List<AssetSyncOutboxEntity>

    @Query("SELECT * FROM asset_sync_outbox WHERE accountScope = :accountScope ORDER BY enqueuedAtUnix ASC LIMIT :limit")
    suspend fun listBatch(accountScope: String, limit: Int): List<AssetSyncOutboxEntity>

    @Query(
        "SELECT * FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = 'READY' AND nextAttemptAtUnix <= :nowUnix " +
            "ORDER BY enqueuedAtUnix ASC LIMIT :limit",
    )
    suspend fun listReadyBatch(accountScope: String, limit: Int, nowUnix: Long): List<AssetSyncOutboxEntity>

    @Query("SELECT COUNT(*) FROM asset_sync_outbox WHERE accountScope = :accountScope")
    suspend fun count(accountScope: String): Int

    @Query(
        "SELECT COUNT(*) FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = :disposition",
    )
    suspend fun countByDisposition(accountScope: String, disposition: String): Int

    @Query(
        "SELECT MIN(nextAttemptAtUnix) FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = 'READY' AND nextAttemptAtUnix > :nowUnix",
    )
    suspend fun earliestDelayedAttempt(accountScope: String, nowUnix: Long): Long?

    @Query(
        "SELECT failureCode FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = 'READY' AND nextAttemptAtUnix > :nowUnix " +
            "ORDER BY nextAttemptAtUnix ASC LIMIT 1",
    )
    suspend fun earliestDelayedFailureCode(accountScope: String, nowUnix: Long): String?

    @Query(
        "SELECT COUNT(*) FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = 'READY' AND nextAttemptAtUnix <= :nowUnix",
    )
    suspend fun countReadyEligible(accountScope: String, nowUnix: Long): Int

    @Upsert
    suspend fun upsert(operation: AssetSyncOutboxEntity)

    @Query("DELETE FROM asset_sync_outbox WHERE accountScope = :accountScope AND assetId COLLATE NOCASE = :assetId")
    suspend fun delete(accountScope: String, assetId: String)

    /** A late response must not remove a newer coalesced user intent. */
    @Query(
        "DELETE FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND assetId COLLATE NOCASE = :assetId AND operationId = :operationId",
    )
    suspend fun deleteCompleted(accountScope: String, assetId: String, operationId: String): Int

    /** A late failure cannot quarantine a newer coalesced user intent. */
    @Query(
        "UPDATE asset_sync_outbox SET deliveryDisposition = :disposition, failureCode = :failureCode, " +
            "nextAttemptAtUnix = :nextAttemptAtUnix, " +
            "attemptCount = attemptCount + 1 WHERE accountScope = :accountScope " +
            "AND assetId COLLATE NOCASE = :assetId AND operationId = :operationId",
    )
    suspend fun markFailure(
        accountScope: String,
        assetId: String,
        operationId: String,
        disposition: String,
        failureCode: String,
        nextAttemptAtUnix: Long,
    ): Int

    @Query(
        "UPDATE asset_sync_outbox SET deliveryDisposition = 'READY', failureCode = NULL, " +
            "attemptCount = 0, nextAttemptAtUnix = 0 " +
            "WHERE accountScope = :accountScope AND deliveryDisposition = :disposition",
    )
    suspend fun resetDisposition(accountScope: String, disposition: String): Int

    @Query(
        "DELETE FROM asset_sync_outbox WHERE accountScope = :accountScope " +
            "AND deliveryDisposition = 'BLOCKED'",
    )
    suspend fun deleteBlocked(accountScope: String): Int
}
