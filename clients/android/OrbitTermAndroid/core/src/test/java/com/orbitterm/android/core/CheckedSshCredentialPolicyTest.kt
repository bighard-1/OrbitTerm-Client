package com.orbitterm.android.core

import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerCredentials
import org.junit.Assert.assertEquals
import org.junit.Test

class CheckedSshCredentialPolicyTest {
    private val credentials = ServerCredentials(
        password = "fallback-secret",
        privateKeyContent = "private-key",
        privateKeyPassphrase = "key-passphrase",
    )

    @Test
    fun `key authentication carries password only when fallback is allowed`() {
        assertEquals(
            "fallback-secret",
            credentials.forAuthMethod(ServerAuthMethod.key.name, allowPasswordFallback = true).password,
        )
        assertEquals(
            "",
            credentials.forAuthMethod(ServerAuthMethod.key.name, allowPasswordFallback = false).password,
        )
    }

    @Test
    fun `password authentication never forwards stale key material`() {
        val selected = credentials.forAuthMethod(ServerAuthMethod.password.name, allowPasswordFallback = true)
        assertEquals("fallback-secret", selected.password)
        assertEquals("", selected.privateKeyContent)
        assertEquals("", selected.privateKeyPassphrase)
    }
}
