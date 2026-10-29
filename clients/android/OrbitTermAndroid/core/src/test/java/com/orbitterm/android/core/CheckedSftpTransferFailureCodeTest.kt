package com.orbitterm.android.core

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

class CheckedSftpTransferFailureCodeTest {
    @Test
    fun `download cancellation uses stable detail rather than broad failure code`() {
        val error = buildJsonObject {
            put("code", "sftp_download_failed")
            put("detail_code", "sftp_transfer_cancelled")
        }

        assertEquals("sftp_transfer_cancelled", checkedSftpTransferFailureCode(error))
    }

    @Test
    fun `ordinary failure keeps broad code even with unrecognized detail`() {
        val error = buildJsonObject {
            put("code", "sftp_download_failed")
            put("detail_code", "sftp_download_failed")
        }

        assertEquals("sftp_download_failed", checkedSftpTransferFailureCode(error))
    }

    @Test
    fun `missing error remains a safe generic failure`() {
        assertEquals("native_operation_failed", checkedSftpTransferFailureCode(null))
    }

    @Test
    fun `directory timeout is distinct without exposing an arbitrary detail`() {
        val timedOut = buildJsonObject {
            put("code", "sftp_list_failed")
            put("detail_code", "sftp_list_timeout")
        }
        val untrusted = buildJsonObject {
            put("code", "sftp_list_failed")
            put("detail_code", "/private/server/path")
        }

        assertEquals("sftp_list_timeout", checkedSftpListFailureCode(timedOut))
        assertEquals("sftp_list_failed", checkedSftpListFailureCode(untrusted))
    }
}
