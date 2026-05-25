package com.orbitterm.android.sync

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class LoginRequest(val username: String, val password: String)

@Serializable
data class AuthResponse(val token: String, val refresh_token: String? = null)

@Serializable
data class UploadConfigRequest(
    val id: UInt? = null,
    val encrypted_blob_base64: String,
    val vector_clock: String
)

@Serializable
data class UploadConfigData(
    val id: UInt,
    val encrypted_blob_base64: String,
    val vector_clock: String,
    val updated_at: String? = null
)

class OrbitApi(private val baseUrl: String = "https://server.orbitterm.com") {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val client = HttpClient {
        install(ContentNegotiation) { json(json) }
        install(HttpTimeout) {
            requestTimeoutMillis = 15_000
            connectTimeoutMillis = 15_000
            socketTimeoutMillis = 15_000
        }
    }

    suspend fun login(username: String, password: String): AuthResponse =
        client.post("$baseUrl/api/v1/auth/login") {
            contentType(ContentType.Application.Json)
            setBody(LoginRequest(username, password))
        }.body()

    suspend fun uploadConfig(token: String, payload: UploadConfigRequest): UploadConfigData =
        client.post("$baseUrl/api/v1/config/upload") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }.body()

    suspend fun pullConfigs(token: String): List<UploadConfigData> =
        client.get("$baseUrl/api/v1/config/pull") { bearerAuth(token) }.body()
}
