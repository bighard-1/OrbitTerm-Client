package com.orbitterm.android.domain.session

import org.junit.Assert.assertEquals
import org.junit.Test

class CommandSnippetTemplateTest {
    @Test
    fun `extracts unique valid variables in first-use order`() {
        assertEquals(
            listOf("host", "user_name"),
            CommandSnippetTemplate.variables("ssh {{ host }}@{{user_name}} && echo {{host}}"),
        )
    }

    @Test
    fun `leaves malformed placeholders intact and resolves valid variables`() {
        assertEquals(
            "mkdir /srv/app {{bad-name}} {{unfinished",
            CommandSnippetTemplate.resolve(
                "mkdir {{path}} {{bad-name}} {{unfinished",
                mapOf("path" to "/srv/app"),
            ),
        )
    }

    @Test
    fun `uses an empty string for an omitted variable value`() {
        assertEquals("echo ", CommandSnippetTemplate.resolve("echo {{value}}", emptyMap()))
    }
}
