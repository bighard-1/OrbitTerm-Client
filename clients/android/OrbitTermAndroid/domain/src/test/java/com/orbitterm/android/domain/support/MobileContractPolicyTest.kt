package com.orbitterm.android.domain.support

import com.orbitterm.android.domain.session.TerminalCustomKeyPayload
import com.orbitterm.android.domain.session.TerminalCustomKeySyncCompatibility
import com.orbitterm.android.domain.session.TerminalCustomKeySyncCompatibility.Routing
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import org.junit.Assert.*
import org.junit.Test

class MobileContractPolicyTest {
    @Test fun reservedCustomKeyRoutingNeverUsesAssetIdentity() {
        val rows = javaClass.getResourceAsStream("/custom-key-routing-vectors.json")!!.bufferedReader().use {
            Json.parseToJsonElement(it.readText()).jsonArray
        }
        for (entry in rows) {
            val row = entry.jsonObject
            val plaintext = row.getValue("plaintext").jsonPrimitive.content
            val reserved = row.getValue("reserved").jsonPrimitive.content == "true"
            assertEquals(if (reserved) Routing.DEFERRED else Routing.UNRELATED,
                TerminalCustomKeySyncCompatibility.routing(plaintext, null))
            for (identity in listOf("", "not-an-id", "11111111-2222-3333-4444-555555555555")) {
                assertEquals(if (reserved) Routing.INVALID_ASSET_IDENTITY else Routing.UNRELATED,
                    TerminalCustomKeySyncCompatibility.routing(plaintext, identity))
            }
        }
    }

    private fun vectors() = javaClass.getResourceAsStream("/v1-vectors.json")!!.bufferedReader().use {
        Json.parseToJsonElement(it.readText()).jsonObject
    }

    @Test fun sharedPayloadVectors() {
        for (entry in vectors().getValue("payloads").jsonArray) {
            val row = entry.jsonObject
            val expected = row.getValue("bytes").takeUnless { it == JsonNull }?.jsonArray?.map { it.jsonPrimitive.int }
            assertEquals(expected, TerminalCustomKeyPayload.decode(row.getValue("input").jsonPrimitive.content)?.map { it.toInt() and 255 })
        }
    }

    @Test fun decodedByteLimitsAndInvalidUtf16() {
        assertEquals(64, TerminalCustomKeyPayload.decode("\\xFF".repeat(64))?.size)
        assertEquals(64, TerminalCustomKeyPayload.decode("😀".repeat(16))?.size)
        assertNull(TerminalCustomKeyPayload.decode("😀".repeat(17)))
        assertNull(TerminalCustomKeyPayload.decode("a".repeat(65)))
        assertNull(TerminalCustomKeyPayload.decode("\\xFF".repeat(65)))
        assertNull(TerminalCustomKeyPayload.decode("\uD83D"))
        assertNull(TerminalCustomKeyPayload.decode("\uDE00"))
    }

    @Test fun sharedContactVectors() {
        for (entry in vectors().getValue("contacts").jsonArray) {
            val row = entry.jsonObject
            val input = row.getValue("input").jsonPrimitive.content
            val expected = row.getValue("email").takeUnless { it == JsonNull }?.jsonPrimitive?.content
            assertEquals(expected, AdministratorContactPolicy.validatedEmail(input))
            assertEquals(expected ?: AdministratorContactPolicy.DEFAULT_EMAIL, AdministratorContactPolicy.emailOrDefault(input))
        }
    }

    @Test fun contactBoundsAndOfflineFallback() {
        assertNull(AdministratorContactPolicy.validatedEmail("a".repeat(65) + "@example.com"))
        assertNull(AdministratorContactPolicy.validatedEmail("a@" + "b".repeat(64) + ".com"))
        assertEquals("orbitterm@163.com", AdministratorContactPolicy.emailOrDefault(null))
    }
}
