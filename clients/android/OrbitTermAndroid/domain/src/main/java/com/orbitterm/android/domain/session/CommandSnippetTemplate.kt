package com.orbitterm.android.domain.session

/**
 * Parses the small {{variable}} syntax used by command snippets.
 *
 * This deliberately avoids a platform regex implementation: snippets are edited on
 * devices running a wide Android-version range, while this grammar only needs a
 * predictable linear scan.
 */
object CommandSnippetTemplate {
    fun variables(command: String): List<String> {
        val names = linkedSetOf<String>()
        visit(command) { name, _, _ -> names += name }
        return names.toList()
    }

    fun resolve(command: String, values: Map<String, String>): String {
        val output = StringBuilder(command.length)
        var cursor = 0
        visit(command) { name, start, endExclusive ->
            output.append(command, cursor, start)
            output.append(values[name].orEmpty())
            cursor = endExclusive
        }
        output.append(command, cursor, command.length)
        return output.toString()
    }

    private inline fun visit(command: String, onVariable: (name: String, start: Int, endExclusive: Int) -> Unit) {
        var searchFrom = 0
        while (searchFrom < command.length) {
            val start = command.indexOf("{{", searchFrom)
            if (start < 0) return
            val close = command.indexOf("}}", start + 2)
            if (close < 0) return
            val name = command.substring(start + 2, close).trim()
            if (name.isSnippetIdentifier()) onVariable(name, start, close + 2)
            searchFrom = close + 2
        }
    }

    private fun String.isSnippetIdentifier(): Boolean =
        isNotEmpty() && first().let { it == '_' || it.isLetter() } &&
            drop(1).all { it == '_' || it.isLetterOrDigit() }
}
