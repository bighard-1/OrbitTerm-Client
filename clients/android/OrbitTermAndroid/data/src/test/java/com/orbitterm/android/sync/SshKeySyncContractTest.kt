package com.orbitterm.android.sync

import java.security.MessageDigest
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SshKeySyncContractTest {
    @Test
    fun `windows v1 envelope decodes with canonical identities`() {
        val privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n"
        val fingerprint = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(privateKey.toByteArray()),
        )
        val decoded = SshKeySyncContract.decode(
            """{"kind":"orbit_ssh_keys","version":1,"updatedAtUnix":1770000000,"keys":[{"id":"ABCDEF00-1234-5678-9ABC-DEF012345678","name":"Work Key","format":"OpenSSH","materialFingerprint":"$fingerprint","createdAtUnix":1760000000,"updatedAtUnix":1770000000,"assignedAssetIds":["11111111-2222-3333-4444-555555555555"],"privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n","passphrase":""}],"tombstones":[]}""",
        )
        assertEquals("abcdef00-1234-5678-9abc-def012345678", decoded?.keys?.single()?.id)
    }

    @Test
    fun `fingerprint mismatch is rejected before secure storage`() {
        val invalid = SshKeySyncEnvelope(
            kind = SshKeySyncContract.MARKER,
            version = 1,
            updatedAtUnix = 2,
            keys = listOf(
                SshKeySyncWire(
                    id = "abcdef00-1234-5678-9abc-def012345678",
                    name = "Key",
                    format = "OpenSSH",
                    materialFingerprint = "SHA256:wrong",
                    createdAtUnix = 1,
                    updatedAtUnix = 2,
                    assignedAssetIds = emptyList(),
                    privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n",
                    passphrase = "",
                ),
            ),
            tombstones = emptyList(),
        )
        assertNull(SshKeySyncContract.decode(kotlinx.serialization.json.Json.encodeToString(invalid)))
    }
}
