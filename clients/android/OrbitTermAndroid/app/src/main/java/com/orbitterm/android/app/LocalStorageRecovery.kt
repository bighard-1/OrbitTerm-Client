package com.orbitterm.android.app

import android.database.sqlite.SQLiteCantOpenDatabaseException
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.database.sqlite.SQLiteDiskIOException
import android.database.sqlite.SQLiteFullException
import com.orbitterm.android.data.local.OrbitTermDatabase
import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.security.SecureCredentialStore
import java.security.GeneralSecurityException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException

enum class LocalStorageFailureKind {
    DATABASE_CORRUPTED,
    STORAGE_FULL,
    DATABASE_UNAVAILABLE,
    SECURE_STORAGE_UNAVAILABLE,
    MIGRATION_INTERRUPTED,
}

data class LocalStorageRecoveryPresentation(
    val kind: LocalStorageFailureKind,
    val title: String,
    val message: String,
    val actionLabel: String = "重新检查",
)

internal object LocalStorageRecoveryPolicy {
    fun presentation(kind: LocalStorageFailureKind): LocalStorageRecoveryPresentation = when (kind) {
        LocalStorageFailureKind.DATABASE_CORRUPTED -> LocalStorageRecoveryPresentation(
            kind,
            "本地数据库需要处理",
            "检测到本地数据库完整性异常。OrbitTerm 已暂停读取和写入，不会自动删除任何数据。",
        )
        LocalStorageFailureKind.STORAGE_FULL -> LocalStorageRecoveryPresentation(
            kind,
            "设备存储空间不足",
            "本地数据无法安全提交。请释放设备空间后重新检查，未提交的数据不会被自动清除。",
        )
        LocalStorageFailureKind.DATABASE_UNAVAILABLE -> LocalStorageRecoveryPresentation(
            kind,
            "暂时无法访问本地数据",
            "OrbitTerm 已暂停本地数据操作，不会删除现有数据。请确认系统存储可用后重新检查。",
        )
        LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE -> LocalStorageRecoveryPresentation(
            kind,
            "暂时无法访问安全存储",
            "Android Keystore 中的登录状态当前无法验证。应用不会将此情况视为退出登录，也不会覆盖现有凭据。",
        )
        LocalStorageFailureKind.MIGRATION_INTERRUPTED -> LocalStorageRecoveryPresentation(
            kind,
            "本地数据升级未完成",
            "本地数据库升级未能安全提交。OrbitTerm 已停止继续写入，请重新检查；现有数据不会被自动重建或删除。",
        )
    }

    fun classify(error: Throwable): LocalStorageFailureKind = when (error) {
        is SQLiteDatabaseCorruptException, is DatabaseIntegrityException -> LocalStorageFailureKind.DATABASE_CORRUPTED
        is SQLiteFullException -> LocalStorageFailureKind.STORAGE_FULL
        is SQLiteCantOpenDatabaseException, is SQLiteDiskIOException -> LocalStorageFailureKind.DATABASE_UNAVAILABLE
        is GeneralSecurityException, is SerializationException -> LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE
        is IllegalStateException -> if (error.message.orEmpty().contains("migration", ignoreCase = true)) {
            LocalStorageFailureKind.MIGRATION_INTERRUPTED
        } else {
            LocalStorageFailureKind.DATABASE_UNAVAILABLE
        }
        else -> LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE
    }
}

private class DatabaseIntegrityException : IllegalStateException()

internal object LocalStorageProbe {
    fun verifyDatabase(database: OrbitTermDatabase) {
        database.openHelper.writableDatabase.query("PRAGMA quick_check(1)").use { cursor ->
            if (!cursor.moveToFirst() || cursor.getString(0) != "ok") {
                throw DatabaseIntegrityException()
            }
        }
    }
}

/** Runs before auth routing so storage faults never masquerade as logout. */
internal suspend fun checkLocalStorage(
    database: OrbitTermDatabase,
    secureStore: SecureCredentialStore,
): Result<AuthSession?> = withContext(Dispatchers.IO) {
    runCatching {
        LocalStorageProbe.verifyDatabase(database)
        secureStore.readAuthSessionChecked()
    }
}
