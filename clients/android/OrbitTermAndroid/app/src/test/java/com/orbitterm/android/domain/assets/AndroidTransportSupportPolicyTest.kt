package com.orbitterm.android.domain.assets

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidTransportSupportPolicyTest {
    @Test
    fun telnetRequiresExplicitEnablement() {
        assertTrue(AndroidTransportSupportPolicy.allowsCheckedConnection("ssh"))
        assertFalse(AndroidTransportSupportPolicy.allowsCheckedConnection("telnet"))
        assertTrue(AndroidTransportSupportPolicy.allowsCheckedConnection("telnet", telnetEnabled = true))
        assertFalse(AndroidTransportSupportPolicy.allowsCheckedConnection("unknown"))
    }

    @Test
    fun enabledTelnetIsClearlyMarkedAsPlaintext() {
        val label = AndroidTransportSupportPolicy.compatibilityLabel("telnet")

        assertTrue(label.contains("TELNET"))
        assertTrue(label.contains("明文"))
    }

    @Test
    fun rdpMetadataIsVisibleButCannotFallBackToSsh() {
        assertFalse(AndroidTransportSupportPolicy.allowsCheckedConnection("rdp"))
        val label = AndroidTransportSupportPolicy.compatibilityLabel("rdp")
        assertTrue(label.contains("RDP"))
        assertTrue(label.contains("已同步"))
    }
}
