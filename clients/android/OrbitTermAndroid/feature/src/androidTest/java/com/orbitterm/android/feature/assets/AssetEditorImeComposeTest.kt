package com.orbitterm.android.feature.assets

import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.core.view.WindowCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AssetEditorImeComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun passwordFieldRemainsAboveKeyboardAndAcceptsInput() {
        compose.runOnUiThread {
            compose.activity.window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            WindowCompat.setDecorFitsSystemWindows(compose.activity.window, false)
        }
        var editor by mutableStateOf(
            AssetEditorUiState(
                id = "disposable-asset",
                credentialID = "disposable-credential",
                isNew = true,
                createdAtUnix = 1,
            ),
        )
        compose.setContent {
            MaterialTheme {
                AssetEditor(
                    state = editor,
                    telnetEnabled = false,
                    modifier = Modifier.fillMaxSize(),
                    onUpdate = { change -> editor = change(editor) },
                    onSave = {},
                    onCancel = {},
                    onRequestDelete = {},
                    onConfirmDelete = {},
                    onDismissDeleteConfirmation = {},
                    onImportPrivateKey = {},
                    onPrivateKeyImportFailure = {},
                    onTestConnection = {},
                    onSubmitTestSecondFactor = {},
                    onTrustTestHostKey = {},
                    onDismissConnectionTest = {},
                )
            }
        }

        compose.onNodeWithTag("asset_editor_form").performScrollToNode(hasTestTag("asset_editor_field_密码"))
        compose.onNodeWithTag("asset_editor_field_密码").performClick()
        compose.onNodeWithTag("asset_editor_field_密码").assertIsFocused().performTextInput("dummy-only")
        compose.runOnUiThread {
            val activity = compose.activity
            activity.getSystemService(InputMethodManager::class.java)
                .showSoftInput(activity.currentFocus, InputMethodManager.SHOW_IMPLICIT)
        }
        compose.waitUntil(5_000) {
            compose.activity.window.decorView.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
        }
        compose.onNodeWithTag("asset_editor_field_密码").assertIsDisplayed()
        compose.onNodeWithTag("asset_editor_save").assertIsDisplayed()
        compose.runOnIdle { assertEquals("dummy-only", editor.password) }

        val fieldBottomPx = compose.onNodeWithTag("asset_editor_field_密码")
            .fetchSemanticsNode().boundsInWindow.bottom
        val saveBounds = compose.onNodeWithTag("asset_editor_save")
            .fetchSemanticsNode().boundsInWindow
        compose.runOnIdle {
            val decor = compose.activity.window.decorView
            val imeHeightPx = decor.rootWindowInsets.getInsets(WindowInsets.Type.ime()).bottom
            val keyboardTopPx = decor.height - imeHeightPx
            assertTrue(
                "password field bottom=$fieldBottomPx must stay above keyboard top=$keyboardTopPx",
                fieldBottomPx <= keyboardTopPx,
            )
            assertTrue(
                "save bounds=$saveBounds must stay above keyboard top=$keyboardTopPx",
                saveBounds.top >= 0 && saveBounds.bottom <= keyboardTopPx,
            )
        }
    }
}
