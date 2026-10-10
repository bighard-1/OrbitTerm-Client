package com.orbitterm.android.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in live HTTP test. The endpoint is deliberately limited to loopback. */
class OrbitApiIsolatedServerContractTest {
    @Test
    fun registrationRefreshRotationAndCurrentDeviceLogout() = runBlocking {
        val endpoint = System.getenv("ORBITTERM_ISOLATED_CONTRACT_URL")
        val inviteCode = System.getenv("ORBITTERM_ISOLATED_INVITE_CODE")
        assumeTrue("isolated server fixture is not configured", endpoint != null && inviteCode != null)
        require(endpoint!!.matches(Regex("http://127\\.0\\.0\\.1:[0-9]+"))) {
            "isolated server test only accepts a loopback HTTP endpoint"
        }
        require(!inviteCode.isNullOrBlank()) { "isolated invite is missing" }

        val api = OrbitApi(endpoint)
        val username = "contract-${UUID.randomUUID()}@qq.com"
        val password = "Qa-${UUID.randomUUID()}-aA1!"
        api.register(username, password, inviteCode)

        val first = api.login(username, password)
        val secondDevice = api.login(username, password)
        assertTrue(first.accessTokenValue.isNotBlank())
        assertTrue(first.refresh_token?.isNotBlank() == true)
        assertEquals(false, first.must_change_password)

        val rotated = api.refresh(first.refresh_token!!)
        assertTrue(rotated.accessTokenValue.isNotBlank())
        assertTrue(rotated.refresh_token?.isNotBlank() == true)
        assertNotEquals(first.refresh_token, rotated.refresh_token)
        assertEquals(false, rotated.must_change_password)

        val replay = expectFailure { api.refresh(first.refresh_token!!) }
        assertEquals(OrbitErrorCode.RefreshInProgress, replay.error.code)

        api.logoutCurrent(rotated.accessTokenValue)
        val revoked = expectFailure { api.pullConfigs(rotated.accessTokenValue) }
        assertEquals(OrbitErrorCode.AuthenticationExpired, revoked.error.code)
        assertTrue(api.pullConfigs(secondDevice.accessTokenValue).isEmpty())
    }

    private suspend fun expectFailure(block: suspend () -> Unit): OrbitServiceFailure = try {
        block()
        throw AssertionError("Expected an OrbitServiceFailure")
    } catch (failure: OrbitServiceFailure) {
        failure
    }
}
