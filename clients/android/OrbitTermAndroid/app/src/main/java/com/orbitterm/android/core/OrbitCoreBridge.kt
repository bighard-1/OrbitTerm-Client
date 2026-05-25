package com.orbitterm.android.core

import android.util.Base64

object OrbitCoreBridge {
    init {
        runCatching { System.loadLibrary("orbit_core") }
    }

    external fun orbitEncryptConfig(masterPassword: String, plaintext: ByteArray, plaintextLen: Long): String
    external fun orbitDecryptConfig(masterPassword: String, encryptedBase64: String): String
    external fun orbitPortableValidate(portableJson: String): String
    external fun orbitPortableChangedFields(baseJson: String, newerJson: String): String
    external fun orbitPortableMerge(remoteJson: String, localJson: String, localChangedFieldsJson: String): String
    external fun orbitVectorClockBump(vectorClockJson: String, actor: String): String

    fun encryptConfig(masterPassword: String, plaintext: String): String {
        val result = orbitEncryptConfig(masterPassword, plaintext.toByteArray(Charsets.UTF_8), plaintext.toByteArray(Charsets.UTF_8).size.toLong())
        return result.unwrapOrbitResult()
    }

    fun decryptConfig(masterPassword: String, encryptedBase64: String): String {
        val raw = orbitDecryptConfig(masterPassword, encryptedBase64).unwrapOrbitResult()
        val bytes = Base64.decode(raw, Base64.DEFAULT)
        return bytes.toString(Charsets.UTF_8)
    }

    fun unwrapResult(value: String): String = value.unwrapOrbitResult()

    private fun String.unwrapOrbitResult(): String = when {
        startsWith("OK:") -> drop(3)
        startsWith("ERR:") -> throw IllegalStateException(drop(4))
        else -> throw IllegalStateException("Unexpected orbit-core response")
    }
}
