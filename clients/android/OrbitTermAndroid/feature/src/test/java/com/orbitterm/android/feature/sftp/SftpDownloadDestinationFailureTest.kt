package com.orbitterm.android.feature.sftp

import com.orbitterm.android.core.CheckedSftpTransferResult
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import kotlin.io.path.createTempFile

class SftpDownloadDestinationFailureTest {
    private val completed = CheckedSftpTransferResult.Completed(4)
    private val failure = CheckedSftpTransferResult.Failure("destination_unwritable")

    private inline fun withStaging(block: (java.io.File) -> Unit) {
        val staging = createTempFile("sftp-destination-test-").toFile()
        try {
            staging.writeBytes(byteArrayOf(1, 2, 3, 4))
            block(staging)
        } finally {
            staging.delete()
        }
    }

    @Test fun successfulWriteReturnsCompletion() = withStaging { staging ->
        val target = ByteArrayOutputStream()
        assertEquals(completed, copyDownloadedStagingToDestination(staging, completed) { target })
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), target.toByteArray())
    }

    @Test fun providerRefusalAndNullStreamReturnStorageFailure() = withStaging { staging ->
        assertEquals(failure, copyDownloadedStagingToDestination(staging, completed) { null })
        assertEquals(failure, copyDownloadedStagingToDestination(staging, completed) {
            throw SecurityException("test provider refused access")
        })
    }

    @Test fun partialWriteFailureLeavesTargetUntouchedByCleanup() = withStaging { staging ->
        val target = ByteArrayOutputStream()
        val failing = object : OutputStream() {
            override fun write(value: Int) {
                if (target.size() == 2) throw IOException("test provider write failure")
                target.write(value)
            }
        }
        assertEquals(failure, copyDownloadedStagingToDestination(staging, completed) { failing })
        assertArrayEquals(byteArrayOf(1, 2), target.toByteArray())
    }

    @Test fun closeFailureReturnsStorageFailure() = withStaging { staging ->
        val failing = object : ByteArrayOutputStream() {
            override fun close() { throw IOException("test provider close failure") }
        }
        assertEquals(failure, copyDownloadedStagingToDestination(staging, completed) { failing })
    }

    @Test fun cancellationIsNotMistakenForStorageFailure() = withStaging { staging ->
        assertThrows(CancellationException::class.java) {
            copyDownloadedStagingToDestination(staging, completed) {
                throw CancellationException("test cancellation")
            }
        }
    }

    @Test fun failedDownloadMustAlwaysReselectDestination() {
        assertFalse(canRetrySftpTransferWithSelectedTarget("下载"))
        assertFalse(canRetrySftpTransferWithSelectedTarget("打包下载"))
        assertTrue(canRetrySftpTransferWithSelectedTarget("上传"))
        assertEquals(
            " 已选目标可能包含不完整内容，请检查并重新选择保存位置。",
            downloadTargetFailureGuidance("destination_unwritable"),
        )
        assertEquals(
            " 已选目标可能保留内容，请在保存位置检查；重新下载时请重新选择保存位置。",
            downloadTargetFailureGuidance("sftp_operation_failed"),
        )
    }

    @Test fun removedEmptyPickerTargetMustBeReselectedAfterNativeFailure() {
        assertFalse(canRetrySftpTransferWithSelectedTarget("下载"))
        assertEquals(
            " 已清理系统新建的空目标文件；重新建立会话后请选择保存位置重试。",
            downloadTargetFailureGuidance("sftp_operation_failed", emptyDestinationRemoved = true),
        )
    }
}
