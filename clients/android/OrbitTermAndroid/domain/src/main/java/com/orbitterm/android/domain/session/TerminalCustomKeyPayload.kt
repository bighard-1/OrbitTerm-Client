package com.orbitterm.android.domain.session

/** v1 byte grammar shared with Apple; literals are UTF-8, never individual UTF-16 units. */
object TerminalCustomKeyPayload {
    fun decode(payload: String): ByteArray? {
        if (payload.isEmpty() || payload.length > 256) return null
        var cursor = 0
        while (cursor < payload.length) {
            val character = payload[cursor++]
            if (Character.isHighSurrogate(character)) {
                if (cursor >= payload.length || !Character.isLowSurrogate(payload[cursor++])) return null
            } else if (Character.isLowSurrogate(character)) return null
        }
        val input = payload.toByteArray(Charsets.UTF_8)
        if (input.size > 256) return null
        val output = ArrayList<Byte>(64)
        var index = 0
        while (index < input.size) {
            val byte = input[index++]
            if (byte != 92.toByte()) {
                output += byte
            } else {
                if (index >= input.size) return null
                when (input[index++].toInt()) {
                    116 -> output += 9
                    114 -> output += 13
                    110 -> output += 10
                    101 -> output += 27
                    92 -> output += 92
                    120 -> {
                        if (index + 1 >= input.size) return null
                        val high = hex(input[index++]) ?: return null
                        val low = hex(input[index++]) ?: return null
                        output += (high * 16 + low).toByte()
                    }
                    else -> return null
                }
            }
            if (output.size > 64) return null
        }
        return output.toByteArray()
    }

    private fun hex(byte: Byte): Int? = when (val value = byte.toInt()) {
        in 48..57 -> value - 48
        in 65..70 -> value - 65 + 10
        in 97..102 -> value - 97 + 10
        else -> null
    }
}
