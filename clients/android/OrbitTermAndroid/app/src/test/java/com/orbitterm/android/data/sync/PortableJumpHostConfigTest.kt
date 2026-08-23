package com.orbitterm.android.data.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class PortableJumpHostConfigTest {
    @Test
    fun `telnet sync payload remains portable but does not imply Android connection support`() {
        val portable = PortableServerConfig(
            id = "portable-telnet-asset",
            name = "Imported Telnet asset",
            host = "legacy.example.invalid",
            port = 23,
            username = "operator",
            authMethod = "password",
            transport = "telnet",
            savedAtUnix = 1L,
        ).validate()

        assertEquals("telnet", portable.transport)
    }

    @Test
    fun `rdp sync payload is preserved for future native remote desktop support`() {
        val portable = PortableServerConfig(
            id = "portable-rdp-asset",
            name = "Windows desktop",
            host = "10.0.1.25",
            port = 3389,
            username = "Administrator",
            authMethod = "password",
            transport = "rdp",
            password = "rdp-secret",
            savedAtUnix = 1L,
        ).validate()

        assertEquals("rdp", portable.transport)
        assertEquals(3389, portable.port)
    }

    @Test
    fun `valid jump configuration keeps separate credential metadata`() {
        val jump = PortableJumpHostConfig(
            credentialID = "asset-1-jump",
            host = "bastion.example.net",
            port = 2222,
            username = "ops",
            authMethod = "key",
            allowPasswordFallback = false,
            privateKeyContent = "-----BEGIN OPENSSH PRIVATE KEY-----\\nkey",
        ).validate()

        assertEquals("asset-1-jump", jump.toConfiguration().credentialID)
        assertEquals("bastion.example.net", jump.toConfiguration().host)
        assertEquals(2222, jump.toConfiguration().port)
    }

    @Test
    fun `portable asset and credential identities use one cross-platform casing`() {
        val portable = PortableServerConfig(
            id = "ABCDEF00-1234-5678-9ABC-DEF012345678",
            credentialID = "ABCDEF00-1234-5678-9ABC-DEF012345679",
            name = "Cross-platform asset",
            host = "host.example.invalid",
            port = 22,
            username = "operator",
            authMethod = "password",
            savedAtUnix = 1L,
        ).validate()

        assertEquals("abcdef00-1234-5678-9abc-def012345678", portable.id)
        assertEquals("abcdef00-1234-5678-9abc-def012345679", portable.credentialID)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `jump configuration rejects absent authentication material`() {
        PortableJumpHostConfig(
            credentialID = "asset-1-jump",
            host = "bastion.example.net",
            port = 22,
            username = "ops",
            authMethod = "password",
        ).validate()
    }
}
