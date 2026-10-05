package com.orbitterm.android.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AuthValidationTest {
    @Test
    fun `login reports each local input problem before network submission`() {
        assertEquals("请输入邮箱账号。", loginValidationError("", "secret"))
        assertEquals(
            "请输入有效的邮箱账号，例如 name@example.com。",
            loginValidationError("invalid", "secret"),
        )
        assertEquals("请输入登录密码。", loginValidationError("user@example.com", ""))
        assertNull(loginValidationError("user@example.com", "secret"))
    }

    @Test
    fun `registration accepts the shared mobile password policy`() {
        assertNull(registrationValidationError("user@example.com", "StrongPass1!", "INVITE"))
    }

    @Test
    fun `registration rejects invalid email before network submission`() {
        assertEquals(
            "请输入有效的邮箱账号。",
            registrationValidationError("invalid", "StrongPass1!", "INVITE"),
        )
    }

    @Test
    fun `registration rejects incomplete password composition`() {
        assertEquals(
            "密码至少 12 位，并包含大小写字母、数字和特殊字符。",
            registrationValidationError("user@example.com", "weakpassword", "INVITE"),
        )
    }
}
