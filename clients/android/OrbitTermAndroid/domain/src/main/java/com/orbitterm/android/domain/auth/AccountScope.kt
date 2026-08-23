package com.orbitterm.android.domain.auth

import java.security.MessageDigest

/** Stable, non-plaintext local partition key for one authenticated account. */
@JvmInline
value class AccountScope(val storageId: String) {
    companion object {
        fun fromUsername(username: String): AccountScope {
            val canonical = username.trim().lowercase()
            require(canonical.isNotBlank())
            val digest = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8))
            return AccountScope(digest.joinToString("") { "%02x".format(it) })
        }
    }
}
