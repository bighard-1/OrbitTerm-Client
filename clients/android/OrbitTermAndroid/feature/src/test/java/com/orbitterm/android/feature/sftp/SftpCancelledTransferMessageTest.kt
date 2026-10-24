package com.orbitterm.android.feature.sftp

import org.junit.Assert.assertEquals
import org.junit.Test

class SftpCancelledTransferMessageTest {
    @Test
    fun `download cancellation warns about system destination placeholder`() {
        assertEquals(
            "下载已取消。系统创建的目标文件可能为空，请在保存位置检查。",
            cancelledSftpTransferMessage("下载"),
        )
    }

    @Test
    fun `upload cancellation does not imply a local destination file`() {
        assertEquals("上传已取消", cancelledSftpTransferMessage("上传"))
    }

    @Test
    fun `download cancellation reports when a new empty target was removed`() {
        assertEquals(
            "下载已取消，已清理系统新建的空目标文件。",
            cancelledSftpTransferMessage("下载", emptyDestinationRemoved = true),
        )
    }
}
