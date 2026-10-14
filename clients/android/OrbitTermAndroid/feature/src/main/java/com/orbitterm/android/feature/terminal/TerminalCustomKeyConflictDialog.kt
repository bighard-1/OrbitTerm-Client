package com.orbitterm.android.feature.terminal

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.orbitterm.android.domain.session.TerminalCustomKeyConflictReview
import com.orbitterm.android.domain.session.TerminalCustomKeyPayload
import com.orbitterm.android.domain.session.TerminalCustomKeyRevision
import com.orbitterm.android.ui.design.OrbitFormDialog

/** Native review UI. No default winner, timestamps, persistence or terminal I/O. */
@Composable
fun TerminalCustomKeyConflictDialog(
    review: TerminalCustomKeyConflictReview,
    busy: Boolean,
    error: String?,
    onResolve: (TerminalCustomKeyRevision?) -> Unit,
    onDismiss: () -> Unit,
) {
    var selected by remember(review) { mutableStateOf<Int?>(null) }
    var confirming by remember(review) { mutableStateOf(false) }
    val conflict = review.conflict
    OrbitFormDialog(
        title = "处理按键冲突", confirmLabel = "应用选择",
        confirmEnabled = selected != null && !busy,
        onConfirm = { confirming = true }, onDismiss = onDismiss,
    ) {
      Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(conflict.explanation)
        Text("版本编号仅用于区分，不表示时间先后。处理不会发送终端内容，也不会上传到云端。",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        conflict.revisions.forEachIndexed { index, revision ->
            Column {
                Text("版本 ${index + 1}", style = MaterialTheme.typography.titleSmall)
                val value = revision.value
                if (value == null) {
                    Text("此版本已删除按键")
                } else {
                    Text(value.label)
                    Text(value.payload, fontFamily = FontFamily.Monospace)
                    Text(if (value.section == "common") "常用" else "符号")
                    if (TerminalCustomKeyPayload.decode(value.payload)?.any { it == 10.toByte() || it == 13.toByte() } == true) {
                        Text("内容包含回车或换行，点击终端键栏中的按键可能立即执行命令。")
                    }
                    ResolutionOption("保留版本 ${index + 1}", selected == index, !busy,
                        "terminal_custom_key_keep_$index") { selected = index }
                }
            }
        }
        ResolutionOption("删除此按键", selected == -1, !busy, "terminal_custom_key_resolve_delete") { selected = -1 }
        Text("确认后，其他并发版本将不再作为待处理冲突保留；取消不会更改任何版本。",
            style = MaterialTheme.typography.bodySmall)
        error?.let {
            Text(it, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
      }
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("确认处理冲突？") },
            text = { Text(if (selected == -1) "将删除此按键并结束全部并发版本的冲突。" else "将保留选定版本并结束其他版本的冲突。") },
            confirmButton = {
                TextButton(enabled = !busy, onClick = {
                    val choice = selected ?: return@TextButton
                    confirming = false
                    onResolve(if (choice == -1) null else conflict.revisions[choice])
                }) { Text(if (selected == -1) "确认删除" else "确认保留") }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("取消") } },
        )
    }
}

@Composable
private fun ResolutionOption(label: String, selected: Boolean, enabled: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag)
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        Text(label)
    }
}
