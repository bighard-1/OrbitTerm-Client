package com.orbitterm.android.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ActiveSessionNotificationPresentationTest {
    @Test
    fun publicLockScreenVersionContainsNoSessionDetails() {
        val text = activeSessionNotificationText(3)

        assertEquals("OrbitTerm 后台任务正在运行", text.publicTitle)
        assertEquals("返回应用查看详情", text.publicDetail)
        assertFalse(text.publicDetail.contains("3"))
        assertFalse(text.publicDetail.contains("SSH"))
    }

    @Test
    fun privateVersionShowsOnlyBoundedSessionCount() {
        assertEquals(
            "1 个已验证会话正在运行",
            activeSessionNotificationText(0).privateDetail,
        )
        assertEquals(
            "2 个已验证会话正在运行",
            activeSessionNotificationText(2).privateDetail,
        )
    }
}
