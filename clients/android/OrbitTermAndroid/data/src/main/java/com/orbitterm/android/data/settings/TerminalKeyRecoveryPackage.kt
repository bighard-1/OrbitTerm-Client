package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyEnvelope
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** Credential-free portable v1. Run expensive crypto off the UI thread. */
object TerminalKeyRecoveryPackage {
    private val magic = "OTKEYBK1".toByteArray(Charsets.US_ASCII)
    const val MAX_BYTES = TerminalCustomKeyContract.MAX_BYTES + 52
    const val ITERATIONS = 600_000
    private val rescueMagic = "OTKEYRS1".toByteArray(Charsets.US_ASCII)
    const val MAX_RESCUE_PLAINTEXT = 4 * 1024 * 1024 + 85
    const val MAX_RESCUE_BYTES = MAX_RESCUE_PLAINTEXT + 52
    fun validPassword(password: String): Boolean {
        val scalars = password.codePoints().toArray()
        return scalars.size >= 12 && password.toByteArray(Charsets.UTF_8).size <= 256 &&
            scalars.none { it < 32 || it in 127..159 || it in 0xD800..0xDFFF } &&
            scalars.any { !Character.isWhitespace(it) && !Character.isSpaceChar(it) }
    }
    fun seal(envelope: TerminalCustomKeyEnvelope, password: String): ByteArray {
        val random = SecureRandom()
        return seal(envelope, password, ByteArray(16).also(random::nextBytes), ByteArray(12).also(random::nextBytes))
    }
    internal fun seal(envelope: TerminalCustomKeyEnvelope, password: String, salt: ByteArray, nonce: ByteArray): ByteArray {
        val plaintext = TerminalCustomKeyContract.encode(envelope).toByteArray(Charsets.UTF_8)
        try { return sealBytes(plaintext, password, salt, nonce, magic) }
        finally { plaintext.fill(0) }
    }
    private fun sealBytes(plaintext: ByteArray, password: String, salt: ByteArray, nonce: ByteArray, magic: ByteArray): ByteArray {
        require(salt.size == 16 && nonce.size == 12)
        val key = derive(password, salt)
        try {
            val header = magic + salt + nonce
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(header)
            return header + cipher.doFinal(plaintext)
        } finally { key.fill(0) }
    }
    fun open(packageBytes: ByteArray, password: String): TerminalCustomKeyEnvelope {
        val plaintext = openBytes(packageBytes, password, magic, MAX_BYTES)
        try {
            return TerminalCustomKeyContract.decode(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(plaintext)).toString())
        } finally { plaintext.fill(0) }
    }
    private fun openBytes(packageBytes: ByteArray, password: String, magic: ByteArray, maximum: Int): ByteArray {
        require(packageBytes.size in 53..maximum && packageBytes.copyOfRange(0, 8).contentEquals(magic)) {
            "恢复文件格式不受支持或大小超限，原有配置未更改。"
        }
        val key = derive(password, packageBytes.copyOfRange(8, 24))
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, packageBytes.copyOfRange(24, 36)))
            cipher.updateAAD(packageBytes.copyOfRange(0, 36))
            cipher.doFinal(packageBytes.copyOfRange(36, packageBytes.size))
        } catch (_: java.security.GeneralSecurityException) {
            throw IllegalArgumentException("口令错误或文件已损坏，原有配置未更改。")
        } finally { key.fill(0) }
        return plaintext
    }
    data class RescueSnapshot(val platform: Int, val account: String, val sources: Map<Int, ByteArray>) {
        fun encoded(): ByteArray {
            require(account.matches(Regex("[0-9a-f]{64}")) && sources.isNotEmpty())
            require(sources.values.sumOf { it.size.toLong() } <= 4 * 1024 * 1024)
            require((platform == 1 && sources.keys == setOf(1)) ||
                (platform == 2 && setOf(2, 3, 4).containsAll(sources.keys) && (2 in sources || 3 in sources)))
            require(sources[4] == null || sources[4]!!.contentEquals(byteArrayOf(0)) || sources[4]!!.contentEquals(byteArrayOf(1)))
            require((sources[2]?.size ?: 0) % 2 == 0 && (sources[3]?.size ?: 0) % 2 == 0)
            val output = java.io.ByteArrayOutputStream()
            java.io.DataOutputStream(output).use { data ->
                data.writeByte(platform); data.write(account.toByteArray(Charsets.US_ASCII)); data.writeByte(sources.size)
                for ((tag, bytes) in sources.toSortedMap()) {
                    data.writeByte(tag); data.writeInt(bytes.size); data.write(bytes)
                }
            }
            return output.toByteArray()
        }
        companion object {
            fun decode(bytes: ByteArray): RescueSnapshot {
                require(bytes.size in 71..MAX_RESCUE_PLAINTEXT)
                val buffer = java.nio.ByteBuffer.wrap(bytes)
                val platform = buffer.get().toInt()
                val account = ByteArray(64).also(buffer::get).toString(Charsets.US_ASCII)
                val count = buffer.get().toInt(); require(count in 1..3)
                val sources = linkedMapOf<Int, ByteArray>(); var previous = 0
                repeat(count) {
                    require(buffer.remaining() >= 5)
                    val tag = buffer.get().toInt(); val length = buffer.int
                    require(tag > previous && length >= 0 && length <= buffer.remaining())
                    sources[tag] = ByteArray(length).also(buffer::get); previous = tag
                }
                require(!buffer.hasRemaining())
                return RescueSnapshot(platform, account, sources).also { it.encoded() }
            }
        }
    }
    fun sealRescue(snapshot: RescueSnapshot, password: String): ByteArray {
        val plaintext = snapshot.encoded(); val random = SecureRandom()
        try { return sealBytes(plaintext, password, ByteArray(16).also(random::nextBytes), ByteArray(12).also(random::nextBytes), rescueMagic) }
        finally { plaintext.fill(0) }
    }
    fun openRescue(bytes: ByteArray, password: String): RescueSnapshot {
        val plaintext = openBytes(bytes, password, rescueMagic, MAX_RESCUE_BYTES)
        try { return RescueSnapshot.decode(plaintext) } finally { plaintext.fill(0) }
    }
    private fun derive(password: String, salt: ByteArray): ByteArray {
        require(validPassword(password)) { "导出口令需至少 12 个字符、最多 256 个 UTF-8 字节，不能包含控制字符。" }
        val chars = password.toCharArray()
        val spec = PBEKeySpec(chars, salt, ITERATIONS, 256)
        chars.fill('\u0000')
        return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
        finally { spec.clearPassword() }
    }
}
