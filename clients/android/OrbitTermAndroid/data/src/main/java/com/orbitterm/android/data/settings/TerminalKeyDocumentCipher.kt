package com.orbitterm.android.data.settings

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.inject.Inject
import javax.inject.Singleton

interface TerminalKeyDocumentCipher {
    fun encrypt(account: String, plaintext: String): String
    fun decrypt(account: String, ciphertext: String): String
}

/** Dedicated local-at-rest key, never the master password or a cloud sync key. */
@Singleton
class KeystoreTerminalKeyDocumentCipher @Inject constructor() : TerminalKeyDocumentCipher {
    @Synchronized
    override fun encrypt(account: String, plaintext: String): String {
        val alias = alias(account)
        val key = existing(alias) ?: KeyGenerator.getInstance("AES", "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
        val bytes = plaintext.toByteArray(Charsets.UTF_8)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(aad(account))
            check(cipher.iv.size == 12)
            return Base64.getEncoder().encodeToString(byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes))
        } finally { bytes.fill(0) }
    }

    override fun decrypt(account: String, ciphertext: String): String {
        require(ciphertext.length <= 1_500_000)
        val key = checkNotNull(existing(alias(account))) { "Terminal key encryption key unavailable" }
        // A missing key is an error, never a reason to generate a replacement.
        val bytes = Base64.getDecoder().decode(ciphertext)
        require(bytes.size >= 29 && bytes[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD(aad(account))
        val plaintext = cipher.doFinal(bytes, 13, bytes.size - 13)
        return try {
            // Authenticated does not imply textually valid. Replacement decoding
            // would silently change the protected bytes before strict JSON checks.
            Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(plaintext)).toString()
        } finally { plaintext.fill(0) }
    }

    private fun alias(account: String): String {
        require(Regex("[0-9a-f]{64}").matches(account))
        return "orbitterm.terminal-keys.local.v1.$account"
    }
    private fun aad(account: String) = "OrbitTerm/terminal-keys/local/v1/$account".toByteArray(Charsets.UTF_8)
    private fun existing(alias: String) = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(alias, null) as? SecretKey
}
