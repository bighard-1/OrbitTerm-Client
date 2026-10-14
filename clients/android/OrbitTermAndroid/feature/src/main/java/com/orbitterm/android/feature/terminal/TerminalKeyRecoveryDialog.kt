package com.orbitterm.android.feature.terminal

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.orbitterm.android.data.settings.TerminalKeyRecoveryPackage
import com.orbitterm.android.data.settings.TerminalKeyRepairDecisionPlanner
import com.orbitterm.android.domain.session.*
import com.orbitterm.android.ui.design.OrbitFormDialog

@Composable
fun TerminalKeyRecoveryDialog(repository: TerminalKeyUsageRepository,
    documentInteraction: com.orbitterm.android.core.DocumentInteractionCoordinator, rescueOnly: Boolean = false, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val controller = remember(repository) { TerminalKeyRecoveryController(repository, scope) }
    val state by controller.state.collectAsState()
    val token by repository.recoveryAccessTokens.collectAsState(initial = repository.recoveryAccessToken())
    val context = LocalContext.current
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var source by remember { mutableStateOf<Uri?>(null) }
    var confirming by remember { mutableStateOf(false) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) { source = uri; controller.cancelPreview(); controller.clearRescueReview() }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        controller.writeExport(uri?.let { { context.contentResolver.openOutputStream(it, "wt") } })
    }
    DisposableEffect(controller) { onDispose { controller.close() } }
    LaunchedEffect(token) {
        if (token == null || token != controller.token) {
            password = ""; confirmation = ""; source = null; controller.close(); onDismiss()
        }
    }
    // Clear the independent passphrase after successful decryption.
    LaunchedEffect(state.preview, state.rescueReview) {
        if (state.preview != null || state.rescueReview != null) { password = ""; confirmation = "" }
    }
    OrbitFormDialog(title = if (rescueOnly) "原始配置加密救援" else "按键备份与恢复", confirmLabel = "关闭", onConfirm = onDismiss, onDismiss = onDismiss,
        usePlatformDefaultWidth = false) {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (rescueOnly) {
                Text("只读保存当前账户的按键原始配置，不修复、不覆盖、不清空。文件可能包含旧数据和自行保存的敏感内容；请使用独立强口令，忘记口令无法解密。")
                Text("救援文件不是可直接导入的按键备份。若设备加密密钥已丢失，导出也不能恢复密文内容。请保留本机应用数据和系统钥匙，勿卸载或清除数据。")
            } else {
            Text("恢复文件仅包含加密后的自定义按键及修订，不读取登录密码、主密码或服务器凭据。按键中自行保存的敏感内容也会包含在文件内。请使用独立强口令；忘记口令无法解密。")
            Text("导入会合并到当前已解锁账户，可能带入删除记录或产生冲突。不会发送命令，也不会同步到云端。",
                style = MaterialTheme.typography.bodySmall)
            Text("建议先导出当前配置；合并成功后无法一键撤销。", style = MaterialTheme.typography.bodySmall)
            }
            OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth().testTag("terminal_recovery_password"),
                enabled = !state.busy, label = { Text("独立导出口令（至少 12 个字符）") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            Text(if (rescueOnly) "最多 256 个 UTF-8 字节；建议使用较长的随机口令，并将口令与救援文件分开保管。"
                else "最多 256 个 UTF-8 字节；建议使用较长的随机口令。导入时填写文件原来的导出口令。", style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(confirmation, { confirmation = it }, Modifier.fillMaxWidth().testTag("terminal_recovery_confirm_password"), enabled = !state.busy,
                label = { Text("导出时再次输入口令") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            TextButton(enabled = !state.busy && TerminalKeyRecoveryPackage.validPassword(password) && password == confirmation,
                onClick = { controller.export(password, rescue = rescueOnly) {
                    password = ""; confirmation = ""
                    if (!TerminalKeyRecoveryController.launchPicker(documentInteraction) { exporter.launch(if (rescueOnly) "OrbitTerm-key-rescue.orbrescue" else "OrbitTerm-keys.orbkeys") }) controller.pickerFailed()
                } }) {
                Text("加密并导出文件")
            }
            if (!rescueOnly) {
                TextButton(enabled = !state.busy, onClick = {
                    if (!TerminalKeyRecoveryController.launchPicker(documentInteraction) {
                        importer.launch(arrayOf("application/octet-stream", "*/*"))
                    }) controller.pickerFailed()
                }) { Text(if (source == null) "选择恢复文件" else "重新选择恢复文件") }
                if (source != null) Text("已选择恢复文件（未导入）")
                TextButton(enabled = !state.busy && source != null && TerminalKeyRecoveryPackage.validPassword(password),
                    onClick = { source?.let { uri ->
                        controller.preview(password) { context.contentResolver.openInputStream(uri) }
                    } }) { Text("解密并预览") }
                state.preview?.plan?.let { plan ->
                    Text("合并预览", style = MaterialTheme.typography.titleMedium)
                    Text("${plan.changes.size} 项变化；合并后 ${plan.activeCount} 个可用按键，${plan.conflictCount} 项冲突。")
                    if (plan.changes.isEmpty()) Text("文件中的版本已包含在本机，无需写入。")
                    Text("文件中缺少的本机按键不会被删除；文件内较新的删除记录会参与合并。请逐项检查后再确认。")
                    plan.changes.forEach { change ->
                        Text("按键 · ${change.id.takeLast(8)}", style = MaterialTheme.typography.titleSmall)
                        Text("当前"); RevisionRows(change.before)
                        Text("合并后"); RevisionRows(change.after)
                    }
                    TextButton(enabled = !state.busy && plan.changes.isNotEmpty(), onClick = { confirming = true }) {
                        Text("确认合并到当前账户")
                    }
                    TextButton(enabled = !state.busy, onClick = { controller.cancelPreview(); source = null }) { Text("取消预览") }
                }
            } else {
                HorizontalDivider()
                Text("回读核验", style = MaterialTheme.typography.titleMedium)
                Text("重新选择已导出的救援文件并输入该文件的独立口令。核验只读取文件和当前存储，不修复或写回。",
                    style = MaterialTheme.typography.bodySmall)
                TextButton(enabled = !state.busy, onClick = {
                    if (!TerminalKeyRecoveryController.launchPicker(documentInteraction) {
                        importer.launch(arrayOf("application/octet-stream", "*/*"))
                    }) controller.pickerFailed()
                }) { Text(if (source == null) "选择救援文件" else "重新选择救援文件") }
                if (source != null) Text(if (state.rescueReview == null) "已选择救援文件（未核验）" else "已选择救援文件（已完成本次只读核验）")
                TextButton(enabled = !state.busy && source != null && TerminalKeyRecoveryPackage.validPassword(password),
                    onClick = { source?.let { uri ->
                        controller.inspectRescue(password) { context.contentResolver.openInputStream(uri) }
                    } }) { Text("解密并核验") }
                state.rescueReview?.let { TerminalKeyRescueReview(it) }
            }
            if (state.busy) CircularProgressIndicator()
            state.message?.let { Text(it, Modifier.testTag("terminal_recovery_message")) }
        }
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false }, title = { Text("确认合并恢复文件？") },
        text = { Text("将按预览更新当前账户的本机按键配置。此操作不会发送命令。") },
        confirmButton = { TextButton(enabled = !state.busy, onClick = { confirming = false; controller.commit() }) { Text("确认合并") } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text("取消") } })
}

@Composable
fun TerminalKeyRescueReview(review: TerminalKeyRescueReview) {
    var decisions by remember(review.decisionSessionToken) {
        mutableStateOf<Map<Int, TerminalKeyRepairDecision>>(emptyMap())
    }
    var corrections by remember(review.decisionSessionToken) {
        mutableStateOf<Map<Int, TerminalKeyRepairCorrection>>(emptyMap())
    }
    var acceptsDataLoss by remember(review.decisionSessionToken) { mutableStateOf(false) }
    var shownBaseline by remember(review.decisionSessionToken) { mutableStateOf<String?>(null) }
    Text("只读核验结果", style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.testTag("terminal_rescue_review"))
    Text("来源平台：${if (review.platform == TerminalKeyRescuePlatform.Apple) "Apple" else "Android"}")
    Text(if (review.accountMatches) "账户归属：与当前账户一致" else "账户归属：与当前账户不一致，请勿用于当前账户修复")
    Text("当前存储：${when (review.storageMatch) {
        TerminalKeyRescueStorageMatch.Exact -> "与救援文件逐字节一致"
        TerminalKeyRescueStorageMatch.Different -> "已发生变化，需要重新导出或重新评估"
        TerminalKeyRescueStorageMatch.Missing -> "当前来源不存在或不可读取"
        TerminalKeyRescueStorageMatch.NotComparable -> "不同平台，无法与本机原始字段直接比较"
    }}")
    review.sources.forEach { source ->
        val name = when (source.kind) { 1 -> "Apple Keychain 原始项"; 2 -> "Android 加密字段"; 3 -> "Android 旧配置"; else -> "Android 迁移标记" }
        val status = when (source.status) {
            TerminalKeyRescueSourceStatus.ValidProtectedLibrary -> "可在本设备解密并通过有效库校验"
            TerminalKeyRescueSourceStatus.ValidLegacyLibrary -> "旧配置结构完整，可迁移"
            TerminalKeyRescueSourceStatus.InvalidStructure -> "结构不完整或字段未知，不能猜测修复"
            TerminalKeyRescueSourceStatus.DuplicateId -> "存在重复 ID，需要逐项审核"
            TerminalKeyRescueSourceStatus.ContractRejected -> "结构可读但违反按键契约，需要逐项审核"
            TerminalKeyRescueSourceStatus.ProtectedUnreadable -> "本设备无法解密或验证；可能密钥不可用或密文损坏"
            TerminalKeyRescueSourceStatus.OpaqueForeignSource -> "已认证的外部平台原始项，本平台不解释"
            TerminalKeyRescueSourceStatus.PauseMarker -> "迁移暂停标记完整"
        }
        Text("$name · ${source.byteCount} 字节")
        Text(status, style = MaterialTheme.typography.bodySmall)
    }
    review.repairPreview?.let { preview ->
        Spacer(Modifier.height(8.dp))
        HorizontalDivider()
        Text("逐条修复预览（只读）", style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.testTag("terminal_repair_preview"))
        Text("仅诊断与当前存储逐字节一致、可安全枚举的旧配置；不会生成替换文件，也不会写回。",
            style = MaterialTheme.typography.bodySmall)
        if (preview.protectedSourcePresent) Text(
            "同时存在加密字段：后续不得直接覆盖，必须先解决来源优先级。",
            color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        preview.blockedReason?.let { reason ->
            Text("无法逐条预览：${when (reason) {
                TerminalKeyRepairBlockedReason.MalformedOrAmbiguous -> "JSON 损坏、截断或键名重复，禁止猜测"
                TerminalKeyRepairBlockedReason.RootNotEnumerable -> "根结构不是可枚举的项目数组"
                TerminalKeyRepairBlockedReason.TooManyItems -> "项目超过 256 条的安全审查上限"
            }}", color = MaterialTheme.colorScheme.error)
        }
        if (preview.blockedReason == null) {
            if (preview.items.isEmpty()) Text("未发现可枚举项目。")
            val unchanged = preview.items.count { it.disposition == TerminalKeyRepairDisposition.KeepUnchanged }
            val manual = preview.items.count { it.disposition == TerminalKeyRepairDisposition.ManualCorrectionRequired ||
                it.disposition == TerminalKeyRepairDisposition.CannotInterpret }
            val capacity = preview.items.count { it.disposition == TerminalKeyRepairDisposition.CapacitySelectionRequired }
            Text("共 ${preview.items.size} 项 · 可原样保留 $unchanged · 需人工处理 $manual · 需容量取舍 $capacity",
                style = MaterialTheme.typography.bodySmall)
            preview.items.forEach { item ->
                Spacer(Modifier.height(6.dp))
                Text("项目 ${item.index + 1} · ${repairDisposition(item.disposition)}",
                    style = MaterialTheme.typography.labelLarge)
                item.idSummary?.let { Text("ID：$it", style = MaterialTheme.typography.bodySmall) }
                item.labelSummary?.let { Text("名称：$it", style = MaterialTheme.typography.bodySmall) }
                item.sectionSummary?.let { Text("分组：$it", style = MaterialTheme.typography.bodySmall) }
                item.payloadUtf8Bytes?.let { Text("发送内容：$it UTF-8 字节（内容不展示）", style = MaterialTheme.typography.bodySmall) }
                if (item.issues.isNotEmpty()) Text("诊断：${item.issues.joinToString("；", transform = ::repairIssue)}",
                    color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                Text("处理决定", style = MaterialTheme.typography.labelMedium)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    RepairDecisionButton("保留原行", decisions[item.index]?.choice == TerminalKeyRepairChoice.Keep,
                        Modifier.weight(1f).testTag("terminal_repair_keep_${item.index}")) {
                        decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Keep))
                        shownBaseline = null; acceptsDataLoss = false
                    }
                    RepairDecisionButton("输入修正值", decisions[item.index]?.choice == TerminalKeyRepairChoice.Correct,
                        Modifier.weight(1f).testTag("terminal_repair_correct_${item.index}")) {
                        val correction = corrections[item.index] ?: TerminalKeyRepairCorrection()
                        corrections = corrections + (item.index to correction)
                        decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct, correction))
                        shownBaseline = null; acceptsDataLoss = false
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    RepairDecisionButton("明确排除", decisions[item.index]?.choice == TerminalKeyRepairChoice.Exclude,
                        Modifier.weight(1f).testTag("terminal_repair_exclude_${item.index}")) {
                        decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Exclude))
                        shownBaseline = null; acceptsDataLoss = false
                    }
                    if (TerminalKeyRepairIssue.CapacitySelectionRequired in item.issues) {
                        RepairDecisionButton("因容量排除", decisions[item.index]?.choice == TerminalKeyRepairChoice.CapacityExclude,
                            Modifier.weight(1f).testTag("terminal_repair_capacity_exclude_${item.index}")) {
                            decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.CapacityExclude))
                            shownBaseline = null; acceptsDataLoss = false
                        }
                    } else Spacer(Modifier.weight(1f))
                }
                if (decisions[item.index]?.choice == TerminalKeyRepairChoice.Correct) {
                    Text("修正沿用已验证的源 ID；ID 或版本时钟不可解释的行只能明确排除。不会回显原发送内容。",
                        style = MaterialTheme.typography.bodySmall)
                    val correction = corrections[item.index] ?: TerminalKeyRepairCorrection()
                    OutlinedTextField(correction.label, { value ->
                        val next = correction.copy(label = value); corrections = corrections + (item.index to next)
                        decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct, next))
                        shownBaseline = null; acceptsDataLoss = false
                    }, Modifier.fillMaxWidth().testTag("terminal_repair_label_${item.index}"), singleLine = true,
                        label = { Text("修正后的名称") })
                    OutlinedTextField(correction.payload, { value ->
                        val next = correction.copy(payload = value); corrections = corrections + (item.index to next)
                        decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct, next))
                        shownBaseline = null; acceptsDataLoss = false
                    }, Modifier.fillMaxWidth().testTag("terminal_repair_payload_${item.index}"), singleLine = true,
                        label = { Text("重新输入发送内容") }, fontFamily = FontFamily.Monospace)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf("common" to "常用", "symbols" to "符号").forEach { (section, label) ->
                            RepairDecisionButton(label, correction.section == section, Modifier.weight(1f)) {
                                val next = correction.copy(section = section); corrections = corrections + (item.index to next)
                                decisions = decisions + (item.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct, next))
                                shownBaseline = null; acceptsDataLoss = false
                            }
                        }
                    }
                }
            }
            val plan = TerminalKeyRepairDecisionPlanner.make(preview, review.decisionSessionToken, decisions)
            HorizontalDivider()
            Text("修复决策草案（仍为只读）", style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.testTag("terminal_repair_decision_draft"))
            Text("决策进度：${plan.decidedCount}/${plan.totalCount}；保留 ${plan.keptCount}，修正 ${plan.correctedCount}，排除 ${plan.excludedCount}，预计活动 ID ${plan.activeIdentityCount}。",
                style = MaterialTheme.typography.bodySmall)
            repairDecisionProblems(plan).forEach { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            if (plan.requiresDataLossAcknowledgement) Row(Modifier.fillMaxWidth()) {
                Checkbox(acceptsDataLoss, { acceptsDataLoss = it; shownBaseline = null },
                    Modifier.testTag("terminal_repair_ack_exclusions"))
                Text("我理解排除项目可能造成数据丢失", modifier = Modifier.padding(top = 12.dp))
            }
            TextButton(onClick = { shownBaseline = plan.confirmationBaseline },
                enabled = plan.isReadyForSecondConfirmation && (!plan.requiresDataLossAcknowledgement || acceptsDataLoss),
                modifier = Modifier.testTag("terminal_repair_prepare_confirmation")) {
                Text("生成二次确认清单")
            }
            if (shownBaseline != null && shownBaseline == plan.confirmationBaseline) {
                Text("二次确认清单（未写回）", style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.testTag("terminal_repair_confirmation_preview"))
                Text("确认基线：${shownBaseline}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                plan.rows.forEach { row ->
                    Text("项目 ${row.index + 1} · ${repairChoice(row.choice)} · ${if (row.included) "纳入候选" else "排除"}",
                        style = MaterialTheme.typography.labelLarge)
                    row.idSummary?.let { Text("ID：$it", style = MaterialTheme.typography.bodySmall) }
                    row.labelSummary?.let { Text("名称：$it", style = MaterialTheme.typography.bodySmall) }
                    row.sectionSummary?.let { Text("分组：$it", style = MaterialTheme.typography.bodySmall) }
                    row.payloadUtf8Bytes?.let { Text("发送内容：$it UTF-8 字节（内容不展示）", style = MaterialTheme.typography.bodySmall) }
                }
                Text("此清单只绑定本次内存决策，不是修复授权；当前仍没有写回、替换或清库入口。",
                    style = MaterialTheme.typography.bodySmall)
            }
        }
    }
    Text("本结果没有修改任何按键。未知版本、截断数据或不可用密钥不能自动重建。",
        style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun RepairDecisionButton(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, modifier = modifier) { Text(if (selected) "✓ $label" else label) }
}

private fun repairChoice(value: TerminalKeyRepairChoice) = when (value) {
    TerminalKeyRepairChoice.Keep -> "保留原行"
    TerminalKeyRepairChoice.Correct -> "采用修正值"
    TerminalKeyRepairChoice.Exclude -> "明确排除"
    TerminalKeyRepairChoice.CapacityExclude -> "因容量排除"
}

private fun repairDecisionProblems(plan: TerminalKeyRepairDecisionPlan): List<String> = buildList {
    val missing = plan.issues.count { it is TerminalKeyRepairDecisionIssue.MissingDecision }
    val invalid = plan.issues.count { it is TerminalKeyRepairDecisionIssue.InvalidChoice || it is TerminalKeyRepairDecisionIssue.InvalidCorrection }
    if (missing > 0) add("尚有 $missing 项未作决定。")
    if (invalid > 0) add("尚有 $invalid 项决定或修正值无效。")
    if (TerminalKeyRepairDecisionIssue.SourceBlocked in plan.issues) add("来源整体不可枚举，不能建立决策清单。")
    if (TerminalKeyRepairDecisionIssue.ProtectedSourceConflict in plan.issues) add("受保护来源并存，必须先解决来源优先级。")
    if (TerminalKeyRepairDecisionIssue.DocumentMetadataBlocked in plan.issues) add("文档元数据异常，当前阶段不允许重建。")
    if (plan.issues.any { it is TerminalKeyRepairDecisionIssue.DuplicateRetainedIdentity })
        add("Android 旧配置仍保留重复 ID，必须明确排除到每个 ID 只剩一项。")
    if (plan.issues.any { it is TerminalKeyRepairDecisionIssue.TooManyVersions }) add("同一 Apple ID 仍保留超过 8 个版本。")
    plan.issues.filterIsInstance<TerminalKeyRepairDecisionIssue.CapacityExceeded>().firstOrNull()?.let {
        add("候选活动 ID 为 ${it.count}，仍超过 64 项容量。")
    }
}

private fun repairDisposition(value: TerminalKeyRepairDisposition) = when (value) {
    TerminalKeyRepairDisposition.KeepUnchanged -> "可原样保留"
    TerminalKeyRepairDisposition.ManualCorrectionRequired -> "需要人工修正"
    TerminalKeyRepairDisposition.CapacitySelectionRequired -> "需要人工取舍"
    TerminalKeyRepairDisposition.CannotInterpret -> "无法解释"
}

private fun repairIssue(value: TerminalKeyRepairIssue) = when (value) {
    TerminalKeyRepairIssue.RowNotObject -> "项目不是对象"
    TerminalKeyRepairIssue.UnknownFields -> "字段集合不符合契约"
    TerminalKeyRepairIssue.MissingOrWrongId -> "ID 缺失或类型错误"
    TerminalKeyRepairIssue.InvalidId -> "ID 不合法"
    TerminalKeyRepairIssue.DuplicateId -> "ID 重复"
    TerminalKeyRepairIssue.MissingOrWrongLabel -> "名称缺失或类型错误"
    TerminalKeyRepairIssue.InvalidLabel -> "名称不合法"
    TerminalKeyRepairIssue.MissingOrWrongPayload -> "发送内容缺失或类型错误"
    TerminalKeyRepairIssue.InvalidPayload -> "发送内容不合法"
    TerminalKeyRepairIssue.MissingOrWrongSection -> "分组缺失或类型错误"
    TerminalKeyRepairIssue.InvalidSection -> "分组值不合法"
    TerminalKeyRepairIssue.InvalidClock -> "版本时钟不合法"
    TerminalKeyRepairIssue.InvalidValue -> "项目值不合法"
    TerminalKeyRepairIssue.InvalidDocumentMetadata -> "文档元数据不合法"
    TerminalKeyRepairIssue.RevisionCollision -> "版本标识冲突"
    TerminalKeyRepairIssue.TooManyVersions -> "同一项目版本过多"
    TerminalKeyRepairIssue.CapacitySelectionRequired -> "超过 64 项容量，需要人工取舍"
}

@Composable
private fun RevisionRows(rows: List<TerminalCustomKeyRevision>) {
    if (rows.isEmpty()) Text("无")
    rows.forEach { row ->
        val value = row.value
        if (value == null) Text("删除记录") else {
            Text("${value.label} · ${if (value.section == "common") "常用" else "符号"} · 顺序 ${value.order}")
            Text(value.payload, fontFamily = FontFamily.Monospace)
        }
    }
}
