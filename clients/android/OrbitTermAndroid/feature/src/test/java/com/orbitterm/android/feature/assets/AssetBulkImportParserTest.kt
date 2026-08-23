package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.ServerAuthMethod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AssetBulkImportParserTest {
    @Test
    fun `parses quoted csv without exposing rejected credential content`() {
        val result = AssetBulkImportParser.parse(
            "名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容,标签\n" +
                "\"Web, 01\",生产,10.0.0.1,22,root,secret,ssh,password,,\"web|prod\"\n" +
                "Bad,生产,10.0.0.2,70000,root,do-not-echo,ssh,password,,",
        )

        assertEquals(1, result.rows.size)
        assertEquals("Web, 01", result.rows.single().name)
        assertEquals(listOf("web", "prod"), result.rows.single().tags)
        assertTrue(result.issues.single().message.contains("端口"))
        assertTrue(result.issues.none { it.message.contains("do-not-echo") })
    }

    @Test
    fun `supports tab key import and rejects unsupported mobile transport`() {
        val key = "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----"
        val result = AssetBulkImportParser.parse(
            "Key\tOps\thost.example\t22\troot\t\tssh\tkey\t$key\n" +
                "Legacy\tOps\tlegacy.example\t23\troot\tpass\ttelnet\tpassword\t",
        )

        assertEquals(ServerAuthMethod.key, result.rows.single().authMethod)
        assertTrue(result.rows.single().privateKeyContent.contains('\n'))
        assertEquals(1, result.issues.size)
    }
}
