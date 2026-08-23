package com.orbitterm.android.domain.assets

/** Encrypted credential boundary. Implementations must never persist plaintext outside secure storage. */
interface CredentialVault {
    fun save(credentialID: String, credentials: ServerCredentials)
    fun read(credentialID: String): ServerCredentials?
    fun delete(credentialID: String)
}
