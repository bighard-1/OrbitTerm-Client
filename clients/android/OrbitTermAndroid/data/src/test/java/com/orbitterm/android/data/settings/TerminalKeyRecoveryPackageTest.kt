package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class TerminalKeyRecoveryPackageTest {
    private val rescueVector = Base64.getDecoder().decode("T1RLRVlSUzEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobV7JDvv5jZdHTowVJ+qDBVEPiFP+34k6U0hjG2eK6ZCJ3pI4Pz/06jSQjcsuK9TmuTSdBmtTvVBGxrOosc7Vws4nyJ7t/KsvD9TD8Ue9kzy0Iap/kSbb6ooz3OKk6wZ1qOLHmJW4G8tPYIEnNy7yfNTK/8kUReqKZ3BQyNyBa31eAE2MslIa61A==")
    @Test fun rescueIndependentVectorPreservesMalformedUTF16AndIsNotImportable() {
        val snapshot = TerminalKeyRecoveryPackage.openRescue(rescueVector, "rescue-passphrase-2026")
        assertEquals(2, snapshot.platform); assertEquals("a".repeat(64), snapshot.account)
        assertArrayEquals(byteArrayOf(0xd8.toByte(), 0), snapshot.sources.getValue(2).takeLast(2).toByteArray())
        assertEquals("AmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEDAgAAABAAaQBuAHYAYQBsAGkAZNgAAwAAABYAWwB7AHQAcgB1AG4AYwBhAHQAZQBkBAAAAAEB", Base64.getEncoder().encodeToString(snapshot.encoded()))
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.open(rescueVector, "rescue-passphrase-2026") }
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.openRescue(vector.bytes("swift"), vector.string("password")) }
    }
    @Test fun rescueAppleRawBytesArePreservedAndExportsRandomized() {
        val snapshot = TerminalKeyRecoveryPackage.RescueSnapshot(1, "b".repeat(64), mapOf(1 to byteArrayOf(0xff.toByte(), 0, 0xc0.toByte(), 0x80.toByte())))
        val a = TerminalKeyRecoveryPackage.sealRescue(snapshot, "rescue-passphrase-2026")
        val b = TerminalKeyRecoveryPackage.sealRescue(snapshot, "rescue-passphrase-2026")
        assertFalse(a.contentEquals(b))
        assertArrayEquals(snapshot.encoded(), TerminalKeyRecoveryPackage.openRescue(a, "rescue-passphrase-2026").encoded())
    }
    @Test fun rescueTamperingBoundsAndUnknownSourcesFailClosed() {
        for (offset in listOf(0, 8, 24, 36, rescueVector.lastIndex)) {
            val bad = rescueVector.copyOf(); bad[offset] = (bad[offset].toInt() xor 1).toByte()
            assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.openRescue(bad, "rescue-passphrase-2026") }
        }
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.openRescue(rescueVector, "wrong-passphrase-2026") }
        val source = TerminalKeyRecoveryPackage.RescueSnapshot(1, "b".repeat(64), mapOf(1 to byteArrayOf())).encoded()
        for (bad in listOf(source + 0.toByte(), source.copyOf(source.size - 1))) {
            assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.RescueSnapshot.decode(bad) }
        }
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.RescueSnapshot(1, "b".repeat(64), mapOf(2 to byteArrayOf())).encoded() }
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.RescueSnapshot(1, "b".repeat(64), mapOf(1 to ByteArray(4 * 1024 * 1024 + 1))).encoded() }
    }
    private val vector get() = Json.parseToJsonElement(javaClass.getResourceAsStream("/key-recovery-v1-vector.json")!!.bufferedReader().use { it.readText() }).jsonObject
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.bytes(key: String) = Base64.getDecoder().decode(string(key))
    @Test fun independentKnownAnswerAndBothNativeWireOrders() {
        val v = vector
        val envelope = TerminalCustomKeyContract.decode(v.getValue("envelope").toString())
        assertArrayEquals(v.bytes("kotlin"), TerminalKeyRecoveryPackage.seal(envelope, v.string("password"), v.bytes("salt"), v.bytes("nonce")))
        for (key in listOf("swift", "kotlin")) assertEquals(envelope, TerminalKeyRecoveryPackage.open(v.bytes(key), v.string("password")))
    }
    @Test fun allAuthenticatedFieldsAndWrongPasswordsFailClosed() {
        val v = vector; val original = v.bytes("swift"); val password = v.string("password")
        for (offset in listOf(0, 8, 24, 36, original.lastIndex)) {
            val bytes = original.copyOf(); bytes[offset] = (bytes[offset].toInt() xor 1).toByte()
            assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.open(bytes, password) }
        }
        assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.open(original, "$password ") }
        for (bytes in listOf(byteArrayOf(), original.copyOf(52), original + 0.toByte(), ByteArray(TerminalKeyRecoveryPackage.MAX_BYTES + 1))) {
            assertThrows(IllegalArgumentException::class.java) { TerminalKeyRecoveryPackage.open(bytes, password) }
        }
    }
    @Test fun randomizedExportsPreserveConflictsAndTombstones() {
        val v = vector; val first = TerminalCustomKeyContract.decode(v.getValue("envelope").toString()).revisions.single()
        val envelope = TerminalCustomKeyEnvelope.v1(listOf(first, first.copy(clock = mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), value = null)))
        val a = TerminalKeyRecoveryPackage.seal(envelope, v.string("password"))
        val b = TerminalKeyRecoveryPackage.seal(envelope, v.string("password"))
        assertFalse(a.contentEquals(b))
        assertFalse(String(a, Charsets.UTF_8).contains("测试"))
        assertEquals(envelope, TerminalKeyRecoveryPackage.open(a, v.string("password")))
    }
    @Test fun passwordBoundsUseScalarsWithoutTrimmingOrReplacement() {
        for (p in listOf("123456789012", "😀".repeat(64), "            a")) assertTrue(TerminalKeyRecoveryPackage.validPassword(p))
        for (p in listOf("12345678901", "😀".repeat(65), "            ", "123456789012\n", "123456789012\uD800")) assertFalse(TerminalKeyRecoveryPackage.validPassword(p))
    }
}
