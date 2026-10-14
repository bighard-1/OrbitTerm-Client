package com.orbitterm.android.sync

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SupportContactApiTest {
    @Test fun readsActualPublicContractWithoutCredentials() = runBlocking {
        var count = 0
        val client = HttpClient(MockEngine { request ->
            count++
            assertEquals(HttpMethod.Get, request.method)
            assertEquals("/api/v1/auth/recovery-info", request.url.encodedPath)
            assertNull(request.headers[HttpHeaders.Authorization])
            respond("""{"success":true,"data":{"support_contact":"support@example.com","master_password_recoverable":false}}""",
                HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }) { expectSuccess = true; install(ContentNegotiation) { json(Json { ignoreUnknownKeys = true }) } }
        try {
            assertEquals("support@example.com", OrbitApi("https://contact-fixture.invalid", client).fetchSupportContact())
            assertEquals(1, count)
        } finally { client.close() }
    }

    @Test fun omissionIsDefaultButFailedEnvelopeIsNotSuccess() = runBlocking {
        for ((body, valid) in listOf("""{"success":true,"data":{}}""" to true,
            """{"success":false,"data":{"support_contact":"attacker@example.com"}}""" to false)) {
            val client = HttpClient(MockEngine { respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }) {
                install(ContentNegotiation) { json() }
            }
            try {
                val result = runCatching { OrbitApi("https://contact-fixture.invalid", client).fetchSupportContact() }
                assertEquals(valid, result.isSuccess)
                if (valid) assertNull(result.getOrThrow())
            } finally { client.close() }
        }
    }
}
