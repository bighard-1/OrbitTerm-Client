package com.orbitterm.android.security

import org.junit.Assert.assertEquals
import org.junit.Test

class LoginCooldownPolicyTest {
    @Test
    fun cooldownIsProgressiveAndBounded() {
        assertEquals(0, loginCooldownSeconds(1))
        assertEquals(5, loginCooldownSeconds(3))
        assertEquals(30, loginCooldownSeconds(5))
        assertEquals(120, loginCooldownSeconds(7))
        assertEquals(300, loginCooldownSeconds(99))
    }
}
