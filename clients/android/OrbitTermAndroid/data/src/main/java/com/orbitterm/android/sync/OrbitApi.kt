package com.orbitterm.android.sync

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.ResponseException
import io.ktor.client.call.NoTransformationFoundException
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import io.ktor.serialization.ContentConvertException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.domain.sync.SyncHttpResponsePolicy
import java.io.IOException
import java.net.SocketTimeoutException
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException

@Serializable
data class LoginRequest(val username: String, val password: String)

@Serializable
data class RegisterRequest(
    val username: String,
    val password: String,
    val inviteCode: String,
)

@Serializable
data class AuthResponse(
    val token: String? = null,
    val access_token: String? = null,
    val refresh_token: String? = null,
) {
    val accessTokenValue: String get() = access_token ?: token.orEmpty()
}

@Serializable
data class RefreshRequest(val refresh_token: String)

@Serializable
data class ChangePasswordRequest(
    val current_password: String,
    val new_password: String,
)

@Serializable
data class UploadConfigRequest(
    val id: UInt? = null,
    val asset_id: String? = null,
    val identity_fingerprint: String? = null,
    val encrypted_blob_base64: String,
    val vector_clock: String
)

@Serializable
data class AssetMutationRequest(
    val device_id: String,
    val operation_id: String,
    val vector_clock: String,
    val confirmation: String? = null,
)

/** Opaque, deterministic request identities safe to reuse after an unknown HTTP result. */
object SyncRequestIdentity {
    const val HEADER = "Idempotency-Key"

    fun upload(payload: UploadConfigRequest): String = digest(
        listOf(
            "config-upload-v1",
            payload.id?.toString().orEmpty(),
            payload.asset_id.orEmpty(),
            payload.identity_fingerprint.orEmpty(),
            payload.encrypted_blob_base64,
            payload.vector_clock,
        ),
    )

    fun mutation(request: AssetMutationRequest): String = digest(
        listOf("asset-mutation-v1", request.operation_id),
    )

    private fun digest(parts: List<String>): String {
        val framed = buildString {
            parts.forEach { part -> append(part.length).append(':').append(part) }
        }
        return MessageDigest.getInstance("SHA-256")
            .digest(framed.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}

@Serializable
data class MasterKeyRotationItemRequest(
    val id: UInt,
    val expected_vector_clock: String,
    val encrypted_blob_base64: String,
)

@Serializable
data class MasterKeyRotationRequest(
    val current_login_password: String,
    val items: List<MasterKeyRotationItemRequest>,
)

@Serializable
data class ConfigCryptoMigrationItemRequest(
    val id: UInt,
    val expected_vector_clock: String,
    val expected_blob_sha256: String,
    val encrypted_blob_base64: String,
    val next_vector_clock: String,
)

@Serializable
data class ConfigCryptoMigrationRequest(val items: List<ConfigCryptoMigrationItemRequest>)

@Serializable
data class ConfigCryptoMigrationResponse(val migrated_count: Int)

@Serializable
data class UploadConfigData(
    val id: UInt,
    val user_id: UInt? = null,
    val asset_id: String? = null,
    val identity_fingerprint: String? = null,
    val encrypted_blob_base64: String,
    val vector_clock: String,
    val state: String? = null,
    val deleted_at: String? = null,
    val purge_after: String? = null,
    val server_revision: ULong? = null,
    val updated_at: String? = null,
)

@Serializable
data class PullConfigData(val items: List<UploadConfigData> = emptyList())

@Serializable
data class TrashConfigData(
    val items: List<UploadConfigData> = emptyList(),
    val total: Int = 0,
)

@Serializable
private data class AuthEnvelope(val success: Boolean, val data: AuthResponse? = null, val error: String? = null)

@Serializable
private data class UploadEnvelope(val success: Boolean, val data: UploadConfigData? = null, val error: String? = null)

@Serializable
private data class PullEnvelope(val success: Boolean, val data: PullConfigData? = null, val error: String? = null)

@Serializable
private data class ConfigCryptoMigrationEnvelope(
    val success: Boolean,
    val data: ConfigCryptoMigrationResponse? = null,
    val error: String? = null,
)

class OrbitApi internal constructor(
    private val baseUrl: String,
    private val client: HttpClient,
) {
    constructor(baseUrl: String = "https://server.orbitterm.com") : this(baseUrl, createClient())

    private companion object {
        fun createClient(): HttpClient = HttpClient {
            val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
            // Fail before decoding a non-2xx body so status and Retry-After remain
            // the only inputs to the delivery policy.
            expectSuccess = true
            install(ContentNegotiation) { json(json) }
            install(HttpTimeout) {
                requestTimeoutMillis = 15_000
                connectTimeoutMillis = 15_000
                socketTimeoutMillis = 15_000
            }
        }
    }

    suspend fun login(username: String, password: String): AuthResponse = apiCall(OrbitErrorCode.AuthenticationFailed) { unwrap(
        client.post("$baseUrl/api/v1/auth/login") {
            contentType(ContentType.Application.Json)
            setBody(LoginRequest(username, password))
        }.body<AuthEnvelope>(), OrbitErrorCode.AuthenticationFailed) }

    suspend fun register(username: String, password: String, inviteCode: String): AuthResponse = apiCall(
        OrbitErrorCode.RemoteServiceRejected,
        unauthorizedCode = OrbitErrorCode.RemoteRequestRejected,
    ) { unwrap(
        client.post("$baseUrl/api/v1/auth/register") {
            contentType(ContentType.Application.Json)
            setBody(RegisterRequest(username, password, inviteCode))
        }.body<AuthEnvelope>(), OrbitErrorCode.RemoteServiceRejected) }

    suspend fun refresh(refreshToken: String): AuthResponse = apiCall(OrbitErrorCode.AuthenticationExpired) { unwrap(
        client.post("$baseUrl/api/v1/auth/refresh") {
            contentType(ContentType.Application.Json)
            setBody(RefreshRequest(refreshToken))
        }.body<AuthEnvelope>(), OrbitErrorCode.AuthenticationExpired) }

    suspend fun changePassword(token: String, currentPassword: String, newPassword: String): AuthResponse = apiCall(OrbitErrorCode.AuthenticationFailed) { unwrap(
        client.post("$baseUrl/api/v1/auth/password") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            setBody(ChangePasswordRequest(currentPassword, newPassword))
        }.body<AuthEnvelope>(), OrbitErrorCode.AuthenticationFailed) }

    suspend fun uploadConfig(token: String, payload: UploadConfigRequest): UploadConfigData = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.post("$baseUrl/api/v1/config/upload") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            header(SyncRequestIdentity.HEADER, SyncRequestIdentity.upload(payload))
            setBody(payload)
        }.body<UploadEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    suspend fun pullConfigs(token: String): List<UploadConfigData> = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.get("$baseUrl/api/v1/config/pull") { bearerAuth(token) }.body<PullEnvelope>(), OrbitErrorCode.RemoteServiceRejected).items
    }

    suspend fun pullTrash(token: String, limit: Int, offset: Int): TrashConfigData = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.get("$baseUrl/api/v1/config/trash?limit=$limit&offset=$offset") {
            bearerAuth(token)
        }.body<TrashEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    suspend fun rotateMasterKey(
        token: String,
        currentLoginPassword: String,
        items: List<MasterKeyRotationItemRequest>,
    ): AuthResponse = apiCall(OrbitErrorCode.RemoteServiceRejected) { unwrap(
        client.post("$baseUrl/api/v1/config/master-key/rotate") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            setBody(MasterKeyRotationRequest(currentLoginPassword, items))
        }.body<AuthEnvelope>(), OrbitErrorCode.RemoteServiceRejected) }

    suspend fun migrateConfigCryptoV2(
        token: String,
        items: List<ConfigCryptoMigrationItemRequest>,
    ): ConfigCryptoMigrationResponse = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.post("$baseUrl/api/v1/config/crypto/migrate-v2") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            setBody(ConfigCryptoMigrationRequest(items))
        }.body<ConfigCryptoMigrationEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    suspend fun moveAssetToTrash(token: String, assetId: String, request: AssetMutationRequest): UploadConfigData = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.post("$baseUrl/api/v1/config/assets/$assetId/delete") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            header(SyncRequestIdentity.HEADER, SyncRequestIdentity.mutation(request))
            setBody(request)
        }.body<UploadEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    suspend fun restoreAsset(token: String, assetId: String, request: AssetMutationRequest): UploadConfigData = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.post("$baseUrl/api/v1/config/assets/$assetId/restore") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            header(SyncRequestIdentity.HEADER, SyncRequestIdentity.mutation(request))
            setBody(request)
        }.body<UploadEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    suspend fun purgeAsset(token: String, assetId: String, request: AssetMutationRequest): UploadConfigData = apiCall(OrbitErrorCode.RemoteServiceRejected) {
        unwrap(client.post("$baseUrl/api/v1/config/assets/$assetId/purge") {
            bearerAuth(token)
            contentType(ContentType.Application.Json)
            header(SyncRequestIdentity.HEADER, SyncRequestIdentity.mutation(request))
            setBody(request)
        }.body<UploadEnvelope>(), OrbitErrorCode.RemoteServiceRejected)
    }

    private fun unwrap(envelope: AuthEnvelope, fallback: OrbitErrorCode): AuthResponse =
        envelope.data?.takeIf { envelope.success } ?: throw OrbitServiceFailure(syncError(fallback))

    private fun unwrap(envelope: UploadEnvelope, fallback: OrbitErrorCode): UploadConfigData =
        envelope.data?.takeIf { envelope.success } ?: throw OrbitServiceFailure(syncError(fallback))

    private fun unwrap(envelope: PullEnvelope, fallback: OrbitErrorCode): PullConfigData =
        envelope.data?.takeIf { envelope.success } ?: throw OrbitServiceFailure(syncError(fallback))

    private fun unwrap(envelope: TrashEnvelope, fallback: OrbitErrorCode): TrashConfigData =
        envelope.data?.takeIf { envelope.success } ?: throw OrbitServiceFailure(syncError(fallback))

    private fun unwrap(envelope: ConfigCryptoMigrationEnvelope, fallback: OrbitErrorCode): ConfigCryptoMigrationResponse =
        envelope.data?.takeIf { envelope.success } ?: throw OrbitServiceFailure(syncError(fallback))

    private suspend fun <T> apiCall(
        fallback: OrbitErrorCode,
        unauthorizedCode: OrbitErrorCode = if (fallback == OrbitErrorCode.AuthenticationFailed) {
            OrbitErrorCode.AuthenticationFailed
        } else {
            OrbitErrorCode.AuthenticationExpired
        },
        request: suspend () -> T,
    ): T = try {
        request()
    } catch (error: OrbitServiceFailure) {
        throw error
    } catch (error: CancellationException) {
        throw error
    } catch (error: ResponseException) {
        throw OrbitServiceFailure(
            SyncHttpResponsePolicy.error(
                statusCode = error.response.status.value,
                retryAfterHeader = error.response.headers[HttpHeaders.RetryAfter],
                authenticationErrorCode = unauthorizedCode,
            ),
        )
    } catch (_: ContentConvertException) {
        throw OrbitServiceFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
    } catch (_: NoTransformationFoundException) {
        throw OrbitServiceFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
    } catch (error: IOException) {
        val code = if (
            error is SocketTimeoutException ||
            error is HttpRequestTimeoutException ||
            error is ConnectTimeoutException
        ) OrbitErrorCode.NetworkTimeout else OrbitErrorCode.NetworkUnavailable
        throw OrbitServiceFailure(syncError(code))
    } catch (_: Throwable) {
        // Never interpret a response body or exception message as a business or
        // security status. The endpoint context is the only trusted fallback.
        throw OrbitServiceFailure(syncError(fallback))
    }
}

class OrbitServiceFailure(val error: com.orbitterm.android.domain.error.OrbitError) : IllegalStateException(error.diagnosticCode)

@Serializable
private data class TrashEnvelope(val success: Boolean, val data: TrashConfigData? = null, val error: String? = null)
