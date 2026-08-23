package com.orbitterm.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

@Composable
fun MasterPasswordScreen(
    configured: Boolean,
    biometricEnabled: Boolean,
    error: String?,
    onSubmit: (String, String) -> Unit,
    onBiometricUnlock: () -> Unit,
) {
    var password by rememberSaveable { mutableStateOf("") }
    var confirmation by rememberSaveable { mutableStateOf("") }
    val canSubmit = password.isNotBlank() && (configured || confirmation.isNotBlank())

    AuthSurface {
        AuthLogoBadge()
        Spacer(Modifier.height(18.dp))
        Text(
            if (configured) "验证主密码" else "设置主密码",
            modifier = Modifier.semantics { heading() },
            color = MaterialTheme.colorScheme.onBackground,
            style = MaterialTheme.typography.headlineSmall,
        )
        Spacer(Modifier.height(18.dp))
        AuthGlassCard {
            AuthField(
                value = password,
                onValueChange = { password = it },
                placeholder = if (configured) "输入主密码" else "主密码",
                icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
                keyboardOptions = KeyboardOptions(imeAction = if (configured) ImeAction.Done else ImeAction.Next),
                isPassword = true,
                onSubmit = { if (configured && canSubmit) onSubmit(password, "") },
            )
            if (!configured) {
                AuthField(
                    value = confirmation,
                    onValueChange = { confirmation = it },
                    placeholder = "确认主密码",
                    icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    isPassword = true,
                    onSubmit = { if (canSubmit) onSubmit(password, confirmation) },
                )
            }
            Text(
                "主密码用于解密您的服务器资产，确保您的数据安全。",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
            error?.let { AuthErrorBanner(it) }
            Button(
                onClick = { onSubmit(password, confirmation) },
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) { Text(if (configured) "验证并解锁" else "保存并解锁") }
            if (configured && biometricEnabled) {
                OutlinedButton(
                    onClick = onBiometricUnlock,
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(14.dp),
                ) {
                    Icon(Icons.Rounded.Fingerprint, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("使用生物识别解锁")
                }
            }
        }
    }
}
