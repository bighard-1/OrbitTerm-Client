package com.orbitterm.android.security

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.assets.CredentialVault
import com.orbitterm.android.domain.auth.AuthSession
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Stores credential JSON encrypted with an AES-GCM key that never leaves the
 * Android Keystore. Room and the preferences file only ever contain metadata
 * or ciphertext, respectively.
 */
@Singleton
class SecureCredentialStore @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : CredentialVault {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun save(credentialID: String, credentials: ServerCredentials) {
        require(credentialID.isNotBlank()) { "credentialID is required" }
        val plaintext = json.encodeToString(credentials).toByteArray(Charsets.UTF_8)
        val encrypted = encrypt(plaintext)
        check(preferences.edit().putString(credentialID, encrypted).commit()) {
            "credential write failed"
        }
    }

    override fun read(credentialID: String): ServerCredentials? {
        val encrypted = preferences.getString(credentialID, null) ?: return null
        return runCatching {
            val plaintext = decrypt(encrypted)
            json.decodeFromString<ServerCredentials>(plaintext.toString(Charsets.UTF_8))
        }.getOrNull()
    }

    override fun delete(credentialID: String) {
        check(preferences.edit().remove(credentialID).commit()) { "credential delete failed" }
    }

    fun saveAuthSession(session: AuthSession) {
        require(session.username.isNotBlank() && session.accessToken.isNotBlank())
        val encrypted = encrypt(json.encodeToString(session).toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(AUTH_SESSION_KEY, encrypted).commit()) { "auth session write failed" }
    }

    /**
     * Strict startup read used by the storage health gate. A missing record is
     * a legitimate signed-out state; an unreadable record must remain an
     * error, otherwise a transient Keystore failure is indistinguishable from
     * logout and can lead the user to overwrite recoverable local state.
     */
    fun readAuthSessionChecked(): AuthSession? = preferences.getString(AUTH_SESSION_KEY, null)?.let { encrypted ->
        json.decodeFromString<AuthSession>(decrypt(encrypted).toString(Charsets.UTF_8))
    }

    /** Best-effort reads remain available to non-UI background consumers. */
    fun readAuthSession(): AuthSession? = runCatching(::readAuthSessionChecked).getOrNull()

    fun deleteAuthSession() {
        check(preferences.edit().remove(AUTH_SESSION_KEY).commit()) { "auth session delete failed" }
    }

    fun loginRetryAfterSeconds(username: String, nowMillis: Long = System.currentTimeMillis()): Int {
        val key = loginThrottleKey(username)
        val until = preferences.getLong("${key}_until", 0L)
        return (((until - nowMillis).coerceAtLeast(0L) + 999L) / 1_000L).toInt()
    }

    fun recordLoginFailure(username: String, nowMillis: Long = System.currentTimeMillis()): Int {
        val key = loginThrottleKey(username)
        val failures = preferences.getInt("${key}_count", 0) + 1
        val delaySeconds = loginCooldownSeconds(failures)
        check(
            preferences.edit()
                .putInt("${key}_count", failures)
                .putLong("${key}_until", nowMillis + delaySeconds * 1_000L)
                .commit(),
        ) { "login throttle write failed" }
        return delaySeconds
    }

    fun clearLoginFailures(username: String) {
        val key = loginThrottleKey(username)
        preferences.edit().remove("${key}_count").remove("${key}_until").apply()
    }

    private fun loginThrottleKey(username: String): String {
        val canonical = username.trim().lowercase()
        val digest = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8))
        return "__login_throttle_v1_${digest.joinToString("") { "%02x".format(it) }}"
    }

    /** Account-isolated opaque document used by the portable port-forward profile library. */
    fun savePortForwardProfileDocument(accountStorageId: String, plaintextJson: String) {
        require(accountStorageId.isNotBlank())
        val encrypted = encrypt(plaintextJson.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(portForwardProfileKey(accountStorageId), encrypted).commit()) {
            "port-forward profile write failed"
        }
    }

    fun readPortForwardProfileDocument(accountStorageId: String): String? =
        preferences.getString(portForwardProfileKey(accountStorageId), null)?.let { encrypted ->
            runCatching { decrypt(encrypted).toString(Charsets.UTF_8) }.getOrNull()
        }

    fun deletePortForwardProfileDocument(accountStorageId: String) {
        check(preferences.edit().remove(portForwardProfileKey(accountStorageId)).commit()) {
            "port-forward profile removal failed"
        }
    }

    fun saveSshKeyLibraryDocument(accountStorageId: String, plaintextJson: String) {
        require(accountStorageId.isNotBlank())
        val encrypted = encrypt(plaintextJson.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(sshKeyLibraryKey(accountStorageId), encrypted).commit()) {
            "ssh key library write failed"
        }
    }

    fun readSshKeyLibraryDocument(accountStorageId: String): String? =
        preferences.getString(sshKeyLibraryKey(accountStorageId), null)?.let { encrypted ->
            runCatching { decrypt(encrypted).toString(Charsets.UTF_8) }.getOrNull()
        }

    fun deleteSshKeyLibraryDocument(accountStorageId: String) {
        check(preferences.edit().remove(sshKeyLibraryKey(accountStorageId)).commit()) {
            "ssh key library removal failed"
        }
    }

    fun hasMasterPassword(accountStorageId: String): Boolean {
        migrateLegacyMasterPasswordIfNeeded(accountStorageId)
        return preferences.contains(masterVerifierKey(accountStorageId))
    }

    fun setupMasterPassword(accountStorageId: String, value: String) {
        require(value.isNotBlank())
        val salt = ByteArray(MASTER_SALT_BYTES).also(SecureRandom()::nextBytes)
        val verifier = deriveMasterVerifier(value.toCharArray(), salt)
        val record = Base64.encodeToString(salt, Base64.NO_WRAP) + ":" + Base64.encodeToString(verifier, Base64.NO_WRAP)
        check(
            preferences.edit()
                .putString(masterVerifierKey(accountStorageId), record)
                .putString(masterBlobKey(accountStorageId), encrypt(value.toByteArray()))
                .commit(),
        )
    }

    /**
     * Prepares an encrypted replacement before the server accepts a key
     * rotation. The staged values contain no plaintext and survive a process
     * death, so a completed remote rotation can always be finalized locally.
     */
    fun stageMasterPasswordRotation(accountStorageId: String, value: String) {
        require(value.isNotBlank())
        val salt = ByteArray(MASTER_SALT_BYTES).also(SecureRandom()::nextBytes)
        val verifier = deriveMasterVerifier(value.toCharArray(), salt)
        val record = Base64.encodeToString(salt, Base64.NO_WRAP) + ":" + Base64.encodeToString(verifier, Base64.NO_WRAP)
        check(
            preferences.edit()
                .putString(stagedMasterVerifierKey(accountStorageId), record)
                .putString(stagedMasterBlobKey(accountStorageId), encrypt(value.toByteArray()))
                .remove(acceptedMasterRotationKey(accountStorageId))
                .commit(),
        ) { "staged master password write failed" }
    }

    fun hasStagedMasterPasswordRotation(accountStorageId: String): Boolean =
        preferences.contains(stagedMasterVerifierKey(accountStorageId)) &&
            preferences.contains(stagedMasterBlobKey(accountStorageId))

    /**
     * Records the only state in which a staged password may be finalized
     * without contacting the server again: a typed success response has been
     * received from the atomic rotation endpoint.
     */
    fun markStagedMasterPasswordRotationAccepted(accountStorageId: String) {
        check(hasStagedMasterPasswordRotation(accountStorageId)) { "staged master password missing" }
        check(
            preferences.edit()
                .putBoolean(acceptedMasterRotationKey(accountStorageId), true)
                .commit(),
        ) { "accepted master password rotation marker write failed" }
    }

    fun hasAcceptedStagedMasterPasswordRotation(accountStorageId: String): Boolean =
        hasStagedMasterPasswordRotation(accountStorageId) &&
            preferences.getBoolean(acceptedMasterRotationKey(accountStorageId), false)

    /** Returns plaintext only for an accepted recovery record and only in memory. */
    fun readAcceptedStagedMasterPassword(accountStorageId: String): String? = runCatching {
        if (!hasAcceptedStagedMasterPasswordRotation(accountStorageId)) return null
        val encrypted = preferences.getString(stagedMasterBlobKey(accountStorageId), null) ?: return null
        decrypt(encrypted).toString(Charsets.UTF_8).takeIf(String::isNotBlank)
    }.getOrNull()

    /** Commits a staged replacement after the server atomically accepts all ciphertext. */
    fun commitStagedMasterPasswordRotation(accountStorageId: String) {
        val stagedVerifier = preferences.getString(stagedMasterVerifierKey(accountStorageId), null)
            ?: error("staged master verifier missing")
        val stagedBlob = preferences.getString(stagedMasterBlobKey(accountStorageId), null)
            ?: error("staged master password missing")
        val hadBiometricUnlock = isBiometricUnlockEnabled(accountStorageId)
        check(
            preferences.edit()
                .putString(masterVerifierKey(accountStorageId), stagedVerifier)
                .putString(masterBlobKey(accountStorageId), stagedBlob)
                .remove(stagedMasterVerifierKey(accountStorageId))
                .remove(stagedMasterBlobKey(accountStorageId))
                .remove(acceptedMasterRotationKey(accountStorageId))
                // A biometric blob contains the old master password. It must
                // never survive a successful rotation; the user can opt in
                // again once the new password is active.
                .remove(biometricBlobKey(accountStorageId))
                .putBoolean(biometricEnabledKey(accountStorageId), false)
                .commit(),
        ) { "master password rotation commit failed" }
        if (hadBiometricUnlock) deleteBiometricKey(accountStorageId)
    }

    fun discardStagedMasterPasswordRotation(accountStorageId: String) {
        check(
            preferences.edit()
                .remove(stagedMasterVerifierKey(accountStorageId))
                .remove(stagedMasterBlobKey(accountStorageId))
                .remove(acceptedMasterRotationKey(accountStorageId))
                .commit(),
        ) { "staged master password removal failed" }
    }

    fun verifyAndReadMasterPassword(accountStorageId: String, value: String): String? {
        migrateLegacyMasterPasswordIfNeeded(accountStorageId)
        val record = preferences.getString(masterVerifierKey(accountStorageId), null) ?: return null
        val parts = record.split(":", limit = 2)
        if (parts.size != 2) return null
        val salt = Base64.decode(parts[0], Base64.NO_WRAP)
        val expected = Base64.decode(parts[1], Base64.NO_WRAP)
        val candidate = deriveMasterVerifier(value.toCharArray(), salt)
        if (!MessageDigest.isEqual(expected, candidate)) return null
        // The entered password is the only plaintext needed for manual unlock.
        // A biometric-enabled account intentionally has no ordinary decryptable
        // master blob left in preferences.
        return value
    }

    fun isBiometricUnlockEnabled(accountStorageId: String): Boolean =
        preferences.getBoolean(biometricEnabledKey(accountStorageId), false) &&
            preferences.contains(biometricBlobKey(accountStorageId))

    /**
     * Prepares enrollment without using the biometric-gated key before the OS
     * has authenticated the user. Calling doFinal before BiometricPrompt was
     * the reason fingerprint-only devices could never enable this feature.
     */
    fun biometricEnrollmentCipher(accountStorageId: String): Cipher? = runCatching {
        invalidateBiometricUnlock(accountStorageId)
        Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, getOrCreateKey(biometricKeyAlias(accountStorageId), biometricRequired = true))
        }
    }.getOrNull()

    fun completeBiometricEnrollment(accountStorageId: String, masterPassword: String, cipher: Cipher) {
        require(masterPassword.isNotBlank())
        val ciphertext = cipher.doFinal(masterPassword.toByteArray(Charsets.UTF_8))
        val encrypted = Base64.encodeToString(byteArrayOf(FORMAT_VERSION) + cipher.iv + ciphertext, Base64.NO_WRAP)
        check(
            preferences.edit()
                .putString(biometricBlobKey(accountStorageId), encrypted)
                .putBoolean(biometricEnabledKey(accountStorageId), true)
                .remove(masterBlobKey(accountStorageId))
                .commit(),
        ) { "biometric master password write failed" }
    }

    /** Restores normal Keystore wrapping when the user disables biometric unlock while unlocked. */
    fun disableBiometricUnlock(accountStorageId: String, masterPassword: String) {
        require(masterPassword.isNotBlank())
        val encrypted = encrypt(masterPassword.toByteArray(Charsets.UTF_8))
        check(
            preferences.edit()
                .putString(masterBlobKey(accountStorageId), encrypted)
                .remove(biometricBlobKey(accountStorageId))
                .putBoolean(biometricEnabledKey(accountStorageId), false)
                .commit(),
        ) { "biometric master password removal failed" }
        deleteBiometricKey(accountStorageId)
    }

    /** Cipher must be passed to BiometricPrompt; it cannot decrypt before user verification. */
    fun biometricUnlockCipher(accountStorageId: String): Cipher? = runCatching {
        if (!isBiometricUnlockEnabled(accountStorageId)) return null
        val payload = Base64.decode(preferences.getString(biometricBlobKey(accountStorageId), null) ?: return null, Base64.NO_WRAP)
        require(payload.size > 1 + IV_SIZE_BYTES && payload[0] == FORMAT_VERSION)
        Cipher.getInstance(TRANSFORMATION).apply {
            init(
                Cipher.DECRYPT_MODE,
                getExistingKey(biometricKeyAlias(accountStorageId)) ?: return null,
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, payload.copyOfRange(1, 1 + IV_SIZE_BYTES)),
            )
        }
    }.getOrNull()

    fun readMasterPasswordAfterBiometric(accountStorageId: String, cipher: Cipher): String? = runCatching {
        val payload = Base64.decode(preferences.getString(biometricBlobKey(accountStorageId), null) ?: return null, Base64.NO_WRAP)
        val candidate = cipher.doFinal(payload.copyOfRange(1 + IV_SIZE_BYTES, payload.size)).toString(Charsets.UTF_8)
        verifyAndReadMasterPassword(accountStorageId, candidate)
    }.getOrNull()

    fun invalidateBiometricUnlock(accountStorageId: String) {
        preferences.edit()
            .remove(biometricBlobKey(accountStorageId))
            .putBoolean(biometricEnabledKey(accountStorageId), false)
            .apply()
        runCatching { deleteBiometricKey(accountStorageId) }
    }

    /**
     * WorkManager never receives this value through Data or persisted input.
     * It is available only for accounts using the ordinary Keystore wrapping;
     * biometric-gated accounts must be unlocked interactively first.
     */
    fun readBackgroundSyncMasterPassword(accountStorageId: String): String? = runCatching {
        if (isBiometricUnlockEnabled(accountStorageId)) return null
        val encrypted = preferences.getString(masterBlobKey(accountStorageId), null) ?: return null
        decrypt(encrypted).toString(Charsets.UTF_8).takeIf(String::isNotBlank)
    }.getOrNull()

    /** Moves the legacy global record into the first account that unlocks after upgrade. */
    private fun migrateLegacyMasterPasswordIfNeeded(accountStorageId: String) {
        if (preferences.getBoolean(MASTER_ACCOUNT_MIGRATION_KEY, false)) return
        val verifier = preferences.getString(LEGACY_MASTER_VERIFIER_KEY, null)
        val blob = preferences.getString(LEGACY_MASTER_BLOB_KEY, null)
        if (verifier == null || blob == null) {
            preferences.edit().putBoolean(MASTER_ACCOUNT_MIGRATION_KEY, true).apply()
            return
        }
        check(
            preferences.edit()
                .putString(masterVerifierKey(accountStorageId), verifier)
                .putString(masterBlobKey(accountStorageId), blob)
                .remove(LEGACY_MASTER_VERIFIER_KEY)
                .remove(LEGACY_MASTER_BLOB_KEY)
                .putBoolean(MASTER_ACCOUNT_MIGRATION_KEY, true)
                .commit(),
        ) { "master password migration failed" }
    }

    private fun masterVerifierKey(accountStorageId: String): String = "__master_verifier_v2_$accountStorageId"
    private fun masterBlobKey(accountStorageId: String): String = "__master_blob_v2_$accountStorageId"
    private fun stagedMasterVerifierKey(accountStorageId: String): String = "__master_rotation_verifier_v1_$accountStorageId"
    private fun stagedMasterBlobKey(accountStorageId: String): String = "__master_rotation_blob_v1_$accountStorageId"
    private fun acceptedMasterRotationKey(accountStorageId: String): String = "__master_rotation_accepted_v1_$accountStorageId"
    private fun biometricEnabledKey(accountStorageId: String): String = "__master_biometric_enabled_v1_$accountStorageId"
    private fun biometricBlobKey(accountStorageId: String): String = "__master_biometric_blob_v1_$accountStorageId"
    private fun biometricKeyAlias(accountStorageId: String): String = "orbitterm.master.biometric.v1.$accountStorageId"
    private fun portForwardProfileKey(accountStorageId: String): String = "__port_forward_profiles_v1_$accountStorageId"
    private fun sshKeyLibraryKey(accountStorageId: String): String = "__ssh_key_library_v1_$accountStorageId"

    private fun deriveMasterVerifier(password: CharArray, salt: ByteArray): ByteArray =
        SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(password, salt, MASTER_ITERATIONS, MASTER_KEY_BITS))
            .encoded

    private fun encrypt(plaintext: ByteArray): String {
        return encryptWithKey(plaintext, KEY_ALIAS)
    }

    private fun encryptWithKey(plaintext: ByteArray, alias: String, biometricRequired: Boolean = false): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(alias, biometricRequired))
        val ciphertext = cipher.doFinal(plaintext)
        val payload = byteArrayOf(FORMAT_VERSION) + cipher.iv + ciphertext
        return Base64.encodeToString(payload, Base64.NO_WRAP)
    }

    private fun decrypt(encodedPayload: String): ByteArray {
        val payload = Base64.decode(encodedPayload, Base64.NO_WRAP)
        require(payload.size > 1 + IV_SIZE_BYTES) { "invalid credential payload" }
        require(payload[0] == FORMAT_VERSION) { "unsupported credential payload" }

        val iv = payload.copyOfRange(1, 1 + IV_SIZE_BYTES)
        val ciphertext = payload.copyOfRange(1 + IV_SIZE_BYTES, payload.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun getOrCreateKey(): SecretKey {
        return getOrCreateKey(KEY_ALIAS)
    }

    @Suppress("DEPRECATION") // API 26–29 use the legacy per-operation authentication API.
    private fun getOrCreateKey(alias: String, biometricRequired: Boolean = false): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        val keySpec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .apply {
                if (biometricRequired) {
                    setUserAuthenticationRequired(true)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                    } else {
                        setUserAuthenticationValidityDurationSeconds(-1)
                    }
                    setInvalidatedByBiometricEnrollment(true)
                }
            }
            .build()
        keyGenerator.init(keySpec)
        return keyGenerator.generateKey()
    }

    private fun getExistingKey(alias: String): SecretKey? =
        (KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }.getKey(alias, null) as? SecretKey)

    private fun deleteBiometricKey(accountStorageId: String) {
        KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null); deleteEntry(biometricKeyAlias(accountStorageId)) }
    }

    private companion object {
        const val PREFERENCES_NAME = "orbitterm_credentials_v2"
        const val AUTH_SESSION_KEY = "__auth_session_v1"
        const val LEGACY_MASTER_VERIFIER_KEY = "__master_verifier_v1"
        const val LEGACY_MASTER_BLOB_KEY = "__master_blob_v1"
        const val MASTER_ACCOUNT_MIGRATION_KEY = "__master_password_account_scope_migrated_v2"
        const val MASTER_SALT_BYTES = 16
        const val MASTER_ITERATIONS = 210_000
        const val MASTER_KEY_BITS = 256
        const val KEY_ALIAS = "orbitterm.credentials.v2"
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT_VERSION: Byte = 1
        const val IV_SIZE_BYTES = 12
        const val GCM_TAG_LENGTH_BITS = 128
    }
}

internal fun loginCooldownSeconds(failureCount: Int): Int = when (failureCount) {
    in Int.MIN_VALUE..2 -> 0
    3 -> 5
    4 -> 15
    5 -> 30
    6 -> 60
    7 -> 120
    else -> 300
}
