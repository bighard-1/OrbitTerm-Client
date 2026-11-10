package com.orbitterm.android.ui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp

/** No asset or sync surface is reachable until the server accepts the change. */
@Composable
fun ForcedPasswordChangeScreen(
    isSubmitting: Boolean,
    error: String?,
    onChangePassword: (String, String, String) -> Unit,
    onLogout: () -> Unit,
) {
    // Passwords are intentionally not saved into the Android instance-state bundle.
    var current by remember { mutableStateOf("") }
    var next by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    AuthSurface {
        Text("需要更新登录密码", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(8.dp))
        Text(
            "管理员已重置此账户的登录密码。完成更改前，资产和同步功能将保持锁定。",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(20.dp))
        AuthGlassCard {
            AuthField(current, { current = it }, "当前临时密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
            AuthField(next, { next = it }, "新登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
            AuthField(confirmation, { confirmation = it }, "确认新登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(imeAction = ImeAction.Done), true)
            Text("新密码至少 12 位，并包含大小写字母、数字和特殊字符。", style = MaterialTheme.typography.bodySmall)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(
                onClick = { onChangePassword(current, next, confirmation) },
                enabled = !isSubmitting && current.isNotBlank() && next.isNotBlank() && confirmation.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (isSubmitting) "更新中…" else "更新密码并继续") }
            TextButton(onClick = onLogout, enabled = !isSubmitting, modifier = Modifier.fillMaxWidth()) {
                Text("退出登录")
            }
        }
    }
}
