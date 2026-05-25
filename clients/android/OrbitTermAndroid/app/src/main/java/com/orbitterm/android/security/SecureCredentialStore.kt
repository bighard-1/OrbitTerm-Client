package com.orbitterm.android.security

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.orbitterm.android.data.ServerCredentials
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class SecureCredentialStore(context: Context) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "orbitterm_credentials",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    fun save(credentialID: String, credentials: ServerCredentials) {
        prefs.edit().putString(credentialID, json.encodeToString(credentials)).apply()
    }

    fun read(credentialID: String): ServerCredentials? {
        val raw = prefs.getString(credentialID, null) ?: return null
        return runCatching { json.decodeFromString<ServerCredentials>(raw) }.getOrNull()
    }

    fun delete(credentialID: String) {
        prefs.edit().remove(credentialID).apply()
    }
}
