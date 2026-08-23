package com.orbitterm.android.domain.auth

import kotlinx.serialization.Serializable

@Serializable
data class AuthSession(
    val username: String,
    val accessToken: String,
    val refreshToken: String? = null,
)
