package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.ServerAuthMethod

internal data class AssetBulkImportRow(
    val lineNumber: Int,
    val name: String,
    val group: String,
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val authMethod: ServerAuthMethod,
    val privateKeyContent: String,
    val tags: List<String>,
)

data class AssetBulkImportIssue(
    val lineNumber: Int?,
    val message: String,
)

internal data class AssetBulkImportParseResult(
    val rows: List<AssetBulkImportRow>,
    val issues: List<AssetBulkImportIssue>,
)

/**
 * Parses the portable mobile import format without logging or echoing secret fields.
 * Quoted CSV fields and escaped private-key newlines are supported; malformed rows
 * are isolated so a single bad record cannot abort the remaining import.
 */
internal object AssetBulkImportParser {
    const val MAX_INPUT_CHARS = 1_048_576
    const val MAX_ROWS = 500

    fun parse(input: String): AssetBulkImportParseResult {
        if (input.length > MAX_INPUT_CHARS) {
            return AssetBulkImportParseResult(
                rows = emptyList(),
                issues = listOf(AssetBulkImportIssue(null, "导入内容不能超过 1 MB。")),
            )
        }
        val rows = mutableListOf<AssetBulkImportRow>()
        val issues = mutableListOf<AssetBulkImportIssue>()
        input.lineSequence().forEachIndexed { index, rawLine ->
            val lineNumber = index + 1
            val line = rawLine.trim()
            if (line.isBlank() || line.startsWith('#')) return@forEachIndexed
            if (rows.size >= MAX_ROWS) {
                if (issues.none { it.message.contains("500") }) {
                    issues += AssetBulkImportIssue(null, "单次最多导入 500 个资产。")
                }
                return@forEachIndexed
            }
            val delimiter = when {
                '\t' in line -> '\t'
                ';' in line && ',' !in line -> ';'
                else -> ','
            }
            val fields = splitDelimitedLine(line, delimiter)
            if (fields == null) {
                issues += AssetBulkImportIssue(lineNumber, "引号未闭合。")
                return@forEachIndexed
            }
            if (isHeader(fields)) return@forEachIndexed
            if (fields.size < 5) {
                issues += AssetBulkImportIssue(lineNumber, "字段不足，至少需要名称、分组、主机、端口和用户名。")
                return@forEachIndexed
            }
            val host = fields.valueAt(2).trim()
            val username = fields.valueAt(4).trim()
            val port = fields.valueAt(3).trim().ifBlank { "22" }.toIntOrNull()
            val protocol = fields.valueAt(6).trim().lowercase().ifBlank { "ssh" }
            val password = fields.valueAt(5)
            val privateKey = fields.valueAt(8).replace("\\r\\n", "\n").replace("\\n", "\n").trim()
            val authRaw = fields.valueAt(7).trim().lowercase()
            val authMethod = if (authRaw == "key" || privateKey.isNotBlank()) ServerAuthMethod.key else ServerAuthMethod.password
            val reason = when {
                host.isBlank() -> "主机地址为空。"
                username.isBlank() -> "用户名为空。"
                port !in 1..65_535 -> "端口必须在 1 到 65535 之间。"
                protocol != "ssh" -> "Android 端批量导入仅接受 SSH 资产。"
                authMethod == ServerAuthMethod.password && password.isBlank() -> "密码认证缺少密码。"
                authMethod == ServerAuthMethod.key && privateKey.isBlank() -> "私钥认证缺少私钥。"
                else -> null
            }
            if (reason != null) {
                issues += AssetBulkImportIssue(lineNumber, reason)
                return@forEachIndexed
            }
            rows += AssetBulkImportRow(
                lineNumber = lineNumber,
                name = fields.valueAt(0).trim().ifBlank { host },
                group = fields.valueAt(1).trim(),
                host = host,
                port = requireNotNull(port),
                username = username,
                password = password,
                authMethod = authMethod,
                privateKeyContent = privateKey,
                tags = fields.valueAt(9).split(',', '，', '|')
                    .map(String::trim)
                    .filter(String::isNotBlank)
                    .distinctBy(String::lowercase)
                    .take(8),
            )
        }
        return AssetBulkImportParseResult(rows, issues)
    }

    private fun isHeader(fields: List<String>): Boolean {
        val first = fields.firstOrNull()?.trim().orEmpty()
        return first.equals("name", ignoreCase = true) || first.contains("名称")
    }

    private fun splitDelimitedLine(line: String, delimiter: Char): List<String>? {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var quoted = false
        var index = 0
        while (index < line.length) {
            val char = line[index]
            when {
                char == '"' && quoted && line.getOrNull(index + 1) == '"' -> {
                    current.append('"')
                    index++
                }
                char == '"' -> quoted = !quoted
                char == delimiter && !quoted -> {
                    result += current.toString()
                    current.clear()
                }
                else -> current.append(char)
            }
            index++
        }
        if (quoted) return null
        result += current.toString()
        return result
    }

    private fun List<String>.valueAt(index: Int): String = getOrNull(index).orEmpty()
}
