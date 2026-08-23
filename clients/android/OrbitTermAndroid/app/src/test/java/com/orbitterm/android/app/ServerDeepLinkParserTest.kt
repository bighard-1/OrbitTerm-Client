package com.orbitterm.android.app

import com.orbitterm.android.domain.deeplink.ServerDeepLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerDeepLinkParserTest {
    @Test
    fun `ssh links parse with default values`() {
        assertEquals(
            ServerDeepLink("example.com", 22, "root", "example.com:22"),
            ServerDeepLinkParser.parse("ssh://example.com"),
        )
    }

    @Test
    fun `orbitterm connect honors validated query values`() {
        assertEquals(
            ServerDeepLink("10.0.0.8", 2202, "ops", "核心网关"),
            ServerDeepLinkParser.parse("orbitterm://connect?host=10.0.0.8&port=2202&username=ops&name=%E6%A0%B8%E5%BF%83%E7%BD%91%E5%85%B3"),
        )
    }

    @Test
    fun `invalid deep links are rejected`() {
        assertNull(ServerDeepLinkParser.parse("ssh://host%20name"))
        assertNull(ServerDeepLinkParser.parse("ssh://user%20name@example.com"))
        assertNull(ServerDeepLinkParser.parse("orbitterm://connect?host=example.com&port=70000"))
        assertNull(ServerDeepLinkParser.parse("orbitterm://settings?host=example.com"))
    }
}
