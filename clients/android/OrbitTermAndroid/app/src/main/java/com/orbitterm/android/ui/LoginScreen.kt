package com.orbitterm.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ConfirmationNumber
import androidx.compose.material.icons.rounded.Email
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.edit
import com.orbitterm.android.app.registrationValidationError

@Composable
fun LoginScreen(
    isLoading: Boolean,
    error: String?,
    retryAfterSeconds: Int,
    onLogin: (String, String) -> Unit,
    onRegister: (String, String, String) -> Unit,
) {
    val context = LocalContext.current
    val consentPreferences = remember {
        context.getSharedPreferences("orbitterm_legal_consent", android.content.Context.MODE_PRIVATE)
    }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var inviteCode by rememberSaveable { mutableStateOf("") }
    var isLoginMode by rememberSaveable { mutableStateOf(true) }
    var isPasswordVisible by rememberSaveable { mutableStateOf(false) }
    var termsVisible by rememberSaveable { mutableStateOf(false) }
    var termsAccepted by rememberSaveable {
        mutableStateOf(consentPreferences.getString("accepted_version", null) == ORBIT_LEGAL_TERMS_VERSION)
    }
    val registrationError = if (isLoginMode) null else registrationValidationError(username.trim(), password, inviteCode)
    val canSubmit = termsAccepted && username.isNotBlank() && password.isNotBlank() &&
        (isLoginMode || registrationError == null) && retryAfterSeconds <= 0 && !isLoading

    AuthSurface {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "OrbitTerm",
                modifier = Modifier.semantics { heading() },
                color = MaterialTheme.colorScheme.onBackground,
                style = MaterialTheme.typography.headlineMedium,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                if (isLoginMode) "欢迎回来，继续你的终端旅程" else "创建账号，开启深空控制台",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Spacer(Modifier.height(24.dp))
        AuthGlassCard {
            AuthModeSwitcher(isLoginMode = isLoginMode, onModeChanged = { isLoginMode = it })
            AuthField(
                value = username,
                onValueChange = { username = it },
                placeholder = "邮箱账号",
                icon = { Icon(Icons.Rounded.Email, contentDescription = null) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            AuthField(
                value = password,
                onValueChange = { password = it },
                placeholder = "密码",
                icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
                keyboardOptions = KeyboardOptions(imeAction = if (isLoginMode) ImeAction.Done else ImeAction.Next),
                isPassword = true,
                passwordVisible = isPasswordVisible,
                onPasswordVisibilityChange = { isPasswordVisible = !isPasswordVisible },
                onSubmit = { if (canSubmit && isLoginMode) onLogin(username, password) },
            )
            if (!isLoginMode) {
                AuthField(
                    value = inviteCode,
                    onValueChange = { inviteCode = it },
                    placeholder = "管理员提供的邀请码",
                    icon = { Icon(Icons.Rounded.ConfirmationNumber, contentDescription = null) },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    onSubmit = { if (canSubmit) onRegister(username, password, inviteCode) },
                )
                Text("密码至少 12 位，且包含大小写字母、数字和特殊字符。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
            if (isLoginMode && retryAfterSeconds > 0) {
                Text(
                    "为保护账户，请在 $retryAfterSeconds 秒后重试。",
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = termsAccepted,
                    onCheckedChange = { checked ->
                        termsAccepted = checked
                        if (checked) {
                            consentPreferences.edit { putString("accepted_version", ORBIT_LEGAL_TERMS_VERSION) }
                        } else {
                            consentPreferences.edit { remove("accepted_version") }
                        }
                    },
                )
                Text(
                    "已阅读并同意",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    softWrap = false,
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = { termsVisible = true },
                    modifier = Modifier.semantics {
                        contentDescription = "查看使用条款、免责声明与隐私说明"
                    },
                    contentPadding = PaddingValues(horizontal = 8.dp),
                ) {
                    Text(
                        "查看法律条款",
                        maxLines = 1,
                        softWrap = false,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            Button(
                onClick = { if (isLoginMode) onLogin(username, password) else onRegister(username, password, inviteCode) },
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(if (isLoading) if (isLoginMode) "正在登录…" else "正在注册…" else if (isLoginMode) "登录" else "注册并登录")
            }
            error?.let { AuthErrorBanner(it) }
        }
    }

    if (termsVisible) {
        AlertDialog(
            onDismissRequest = { termsVisible = false },
            title = { Text("使用条款、免责声明与隐私说明") },
            text = {
                Text(
                    ORBIT_LEGAL_TERMS,
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                    style = MaterialTheme.typography.bodySmall,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    termsAccepted = true
                    consentPreferences.edit { putString("accepted_version", ORBIT_LEGAL_TERMS_VERSION) }
                    termsVisible = false
                }) { Text("同意并继续") }
            },
            dismissButton = { TextButton(onClick = { termsVisible = false }) { Text("返回") } },
        )
    }
}

@Composable
private fun AuthModeSwitcher(isLoginMode: Boolean, onModeChanged: (Boolean) -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f),
    ) {
        Row(modifier = Modifier.padding(4.dp)) {
            AuthModeTab("登录", isLoginMode, Modifier.weight(1f)) { onModeChanged(true) }
            AuthModeTab("注册", !isLoginMode, Modifier.weight(1f)) { onModeChanged(false) }
        }
    }
}

@Composable
private fun AuthModeTab(label: String, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Surface(
        modifier = modifier.clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else androidx.compose.ui.graphics.Color.Transparent,
        contentColor = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Text(label, modifier = Modifier.padding(vertical = 10.dp), style = MaterialTheme.typography.labelLarge, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
internal fun AuthField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    icon: @Composable () -> Unit,
    keyboardOptions: KeyboardOptions,
    isPassword: Boolean = false,
    passwordVisible: Boolean = false,
    onPasswordVisibilityChange: (() -> Unit)? = null,
    onSubmit: (() -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text(placeholder) },
        leadingIcon = icon,
        trailingIcon = if (isPassword && onPasswordVisibilityChange != null) {
            {
                IconButton(onClick = onPasswordVisibilityChange) {
                    Icon(if (passwordVisible) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, contentDescription = if (passwordVisible) "隐藏密码" else "显示密码")
                }
            }
        } else null,
        singleLine = true,
        shape = RoundedCornerShape(14.dp),
        visualTransformation = if (isPassword && !passwordVisible) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = keyboardOptions,
        keyboardActions = KeyboardActions(onDone = { onSubmit?.invoke() }),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surface,
            unfocusedContainerColor = MaterialTheme.colorScheme.surface,
            focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.7f),
            unfocusedBorderColor = MaterialTheme.colorScheme.outlineVariant,
        ),
    )
}
