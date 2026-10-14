package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.orbitterm.android.domain.session.*
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.feature.terminal.TerminalCustomKeyConflictDialog
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class TerminalCustomKeyConflictComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val id = "11111111-1111-1111-1111-111111111111"
    private val a = TerminalCustomKeyRevision(id, mapOf("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" to 1L),
        TerminalCustomKeyValue("ConflictKey", "\\r", "common", 0))
    private val review = TerminalCustomKeyConflictReview("test-lease", TerminalCustomKeyConflict(id, listOf(a,
        TerminalCustomKeyRevision(id, mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), null))))

    @Test fun noDefaultWinnerAndKeepRequiresSeparateConfirmation() {
        var calls = 0
        var kept: TerminalCustomKeyRevision? = null
        compose.setContent {
            OrbitTheme(false, AppColorTheme.GlacierMint) {
                TerminalCustomKeyConflictDialog(review, false, null, { calls++; kept = it }, {})
            }
        }
        compose.onNodeWithText("应用选择").assertIsNotEnabled()
        compose.onNodeWithTag("terminal_custom_key_keep_0").performScrollTo().assertIsNotSelected().performClick().assertIsSelected()
        compose.runOnIdle { assertEquals(0, calls) }
        compose.onNodeWithText("应用选择").performClick()
        compose.onNodeWithText("确认保留").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(1, calls); assertEquals(a, kept) }
    }

    @Test fun deletionNeedsConfirmationAndCancelDoesNotMutate() {
        var calls = 0
        var kept: TerminalCustomKeyRevision? = a
        compose.setContent {
            OrbitTheme(false, AppColorTheme.GlacierMint) {
                TerminalCustomKeyConflictDialog(review, false, null, { calls++; kept = it }, {})
            }
        }
        compose.onNodeWithTag("terminal_custom_key_resolve_delete").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("应用选择").performClick()
        compose.onAllNodesWithText("取消").onLast().performClick()
        compose.runOnIdle { assertEquals(0, calls) }
        compose.onNodeWithText("应用选择").performClick()
        compose.onNodeWithText("确认删除").performClick()
        compose.runOnIdle { assertEquals(1, calls); assertNull(kept) }
    }

    @Test fun changedLeaseResetsChoiceAndBusyBlocksDuplicateSubmission() {
        val snapshot = mutableStateOf(review)
        val busy = mutableStateOf(false)
        compose.setContent {
            OrbitTheme(false, AppColorTheme.GlacierMint) {
                TerminalCustomKeyConflictDialog(snapshot.value, busy.value, "原有配置已保留。", {}, {})
            }
        }
        compose.onNodeWithTag("terminal_custom_key_keep_0").performScrollTo().performClick()
        compose.runOnIdle { busy.value = true }
        compose.onNodeWithText("应用选择").assertIsNotEnabled()
        compose.onNodeWithTag("terminal_custom_key_keep_0").assertIsNotEnabled()
        compose.runOnIdle { busy.value = false; snapshot.value = review.copy(accessToken = "new-lease") }
        compose.onNodeWithText("应用选择").assertIsNotEnabled()
        compose.onNodeWithTag("terminal_custom_key_keep_0").assertIsNotSelected()
        compose.onNodeWithText("原有配置已保留。").performScrollTo().assertIsDisplayed()
    }

    @Test fun eightVersionsAtLargeTextKeepLastChoiceAndConfirmationReachable() {
        val many = review.copy(conflict = review.conflict.copy(revisions = (0..7).map { index ->
            a.copy(clock = mapOf("00000000-0000-0000-0000-%012d".format(index) to 1L),
                value = a.value!!.copy(label = "版本${index + 1}😀"))
        }))
        compose.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, 2f)) {
                OrbitTheme(false, AppColorTheme.GlacierMint) {
                    TerminalCustomKeyConflictDialog(many, false, null, {}, {})
                }
            }
        }
        compose.onNodeWithTag("terminal_custom_key_keep_7").performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText("应用选择").assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("确认保留").assertIsDisplayed()
    }
}
