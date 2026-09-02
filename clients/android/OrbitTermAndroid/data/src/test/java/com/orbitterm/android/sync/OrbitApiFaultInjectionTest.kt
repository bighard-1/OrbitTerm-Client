package com.orbitterm.android.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import java.io.IOException
import java.net.SocketTimeoutException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbitApiFaultInjectionTest {
    @Test
    fun rateLimitUsesHeaderAndMakesExactlyOneNativeRequest() = runBlocking {
        var requestCount = 0
        val client = faultClient(HttpStatusCode.TooManyRequests, "120") { requestCount += 1 }
        try {
            val failure = captureFailure { OrbitApi(BASE_URL, client).pullConfigs("token") }

            assertEquals(OrbitErrorCode.RemoteRateLimited, failure.error.code)
            assertEquals(120L, failure.error.retryAfterSeconds)
            assertEquals(1, requestCount)
        } finally {
            client.close()
        }
    }

    @Test
    fun responseBodyCannotChangePermanentStatusClassification() = runBlocking {
        var requestCount = 0
        val client = faultClient(
            HttpStatusCode.UnprocessableEntity,
            body = """{"success":false,"error":"authentication expired; retry conflict"}""",
        ) { requestCount += 1 }
        try {
            val failure = captureFailure { OrbitApi(BASE_URL, client).pullConfigs("token") }

            assertEquals(OrbitErrorCode.RemoteRequestRejected, failure.error.code)
            assertNull(failure.error.retryAfterSeconds)
            assertEquals(1, requestCount)
        } finally {
            client.close()
        }
    }

    @Test
    fun endpointContextKeepsLoginAndRegisterUnauthorizedSemanticsDistinct() = runBlocking {
        val loginClient = faultClient(HttpStatusCode.Unauthorized)
        val registerClient = faultClient(HttpStatusCode.Unauthorized)
        try {
            assertEquals(
                OrbitErrorCode.AuthenticationFailed,
                captureFailure { OrbitApi(BASE_URL, loginClient).login("user", "password") }.error.code,
            )
            assertEquals(
                OrbitErrorCode.RemoteRequestRejected,
                captureFailure { OrbitApi(BASE_URL, registerClient).register("user", "password", "invite") }.error.code,
            )
        } finally {
            loginClient.close()
            registerClient.close()
        }
    }

    @Test
    fun oversizedRetryAfterIsBoundedThroughTheActualClientPipeline() = runBlocking {
        val client = faultClient(HttpStatusCode.ServiceUnavailable, "999999")
        try {
            val failure = captureFailure { OrbitApi(BASE_URL, client).pullConfigs("token") }

            assertEquals(OrbitErrorCode.RemoteServiceUnavailable, failure.error.code)
            assertEquals(3_600L, failure.error.retryAfterSeconds)
        } finally {
            client.close()
        }
    }

    @Test
    fun timeoutAndConnectionInterruptionUseStableTransportErrors() = runBlocking {
        val timeoutClient = faultClient(HttpStatusCode.OK, failure = SocketTimeoutException("fixture"))
        val interruptedClient = faultClient(HttpStatusCode.OK, failure = IOException("fixture"))
        try {
            assertEquals(
                OrbitErrorCode.NetworkTimeout,
                captureFailure { OrbitApi(BASE_URL, timeoutClient).pullConfigs("token") }.error.code,
            )
            assertEquals(
                OrbitErrorCode.NetworkUnavailable,
                captureFailure { OrbitApi(BASE_URL, interruptedClient).pullConfigs("token") }.error.code,
            )
        } finally {
            timeoutClient.close()
            interruptedClient.close()
        }
    }

    @Test
    fun malformedSuccessfulResponseIsBlockedProtocolViolation() = runBlocking {
        val client = faultClient(HttpStatusCode.OK, body = """{"success":true,"data":{""")
        try {
            val failure = captureFailure { OrbitApi(BASE_URL, client).pullConfigs("token") }

            assertEquals(OrbitErrorCode.RemoteProtocolViolation, failure.error.code)
            assertEquals(false, failure.error.retryable)
        } finally {
            client.close()
        }
    }

    @Test
    fun cancellationPassesThroughWithoutErrorRemapping() = runBlocking {
        var requestCount = 0
        val client = faultClient(
            HttpStatusCode.OK,
            failure = CancellationException("fixture"),
            onRequest = { requestCount += 1 },
        )
        try {
            try {
                OrbitApi(BASE_URL, client).pullConfigs("token")
                throw AssertionError("Expected cancellation")
            } catch (_: CancellationException) {
                // Expected: cancellation is a control signal, not a sync failure.
            }
            assertEquals(1, requestCount)
        } finally {
            client.close()
        }
    }

    @Test
    fun idempotencyHeaderIsStableAcrossQueueEquivalentReplays() = runBlocking {
        val capturedKeys = mutableListOf<String?>()
        val client = faultClient(
            HttpStatusCode.ServiceUnavailable,
            onRequest = { request -> capturedKeys += request.headers[SyncRequestIdentity.HEADER] },
        )
        val payload = UploadConfigRequest(
            id = 7u,
            asset_id = "asset-fixture",
            identity_fingerprint = "identity-fixture",
            encrypted_blob_base64 = "ciphertext-fixture",
            vector_clock = "{\"android\":4}",
        )
        try {
            repeat(2) {
                captureFailure { OrbitApi(BASE_URL, client).uploadConfig("token", payload) }
            }

            assertEquals(
                listOf(SyncRequestIdentity.upload(payload), SyncRequestIdentity.upload(payload)),
                capturedKeys,
            )
        } finally {
            client.close()
        }
    }

    private fun faultClient(
        status: HttpStatusCode,
        retryAfter: String? = null,
        body: String = """{"success":false,"error":"fixture"}""",
        failure: Throwable? = null,
        onRequest: (HttpRequestData) -> Unit = {},
    ): HttpClient {
        val engine = MockEngine { request ->
            onRequest(request)
            if (failure != null) throw failure
            val headers = if (retryAfter == null) {
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            } else {
                headersOf(
                    HttpHeaders.ContentType to listOf(ContentType.Application.Json.toString()),
                    HttpHeaders.RetryAfter to listOf(retryAfter),
                )
            }
            respond(body, status, headers)
        }
        return HttpClient(engine) {
            expectSuccess = true
            install(ContentNegotiation) {
                json(Json { ignoreUnknownKeys = true; encodeDefaults = true })
            }
        }
    }

    private suspend fun captureFailure(block: suspend () -> Unit): OrbitServiceFailure = try {
        block()
        throw AssertionError("Expected OrbitServiceFailure")
    } catch (failure: OrbitServiceFailure) {
        failure
    }

    private companion object {
        const val BASE_URL = "https://fault-fixture.invalid"
    }
}
