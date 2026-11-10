package ai.zellio.chat.internal.core

import java.io.BufferedReader

internal data class SseEvent(val event: String, val data: String, val id: String?)

/**
 * Parser for the `text/event-stream` format. Feed one line at a time (no line terminator).
 * A comment line (`: ping`) is ignored. A blank line ends an event. `data:` lines join with a newline.
 */
internal class SseParser {
    private val data = StringBuilder()
    private var hasData = false
    private var event: String? = null
    private var id: String? = null
    private var first = true

    internal fun feed(rawLine: String): SseEvent? {
        var line = rawLine
        if (first) {
            first = false
            if (line.startsWith("﻿")) line = line.substring(1)
        }
        if (line.isEmpty()) return dispatch()
        if (line.startsWith(":")) return null
        val colon = line.indexOf(':')
        val field: String
        var value: String
        if (colon < 0) {
            field = line
            value = ""
        } else {
            field = line.substring(0, colon)
            value = line.substring(colon + 1)
            if (value.startsWith(" ")) value = value.substring(1)
        }
        when (field) {
            "event" -> event = value
            "data" -> {
                if (hasData) data.append('\n')
                data.append(value)
                hasData = true
            }
            "id" -> if ('\u0000' !in value) id = value
            else -> Unit // retry and unknown fields are ignored
        }
        return null
    }

    private fun dispatch(): SseEvent? {
        val result = if (hasData) SseEvent(event?.takeIf { it.isNotEmpty() } ?: "message", data.toString(), id) else null
        data.setLength(0)
        hasData = false
        event = null
        return result
    }

    internal companion object {
        /** Reads a whole stream. `onActivity` is called for every line, pings included. */
        internal fun readAll(reader: BufferedReader, onActivity: () -> Unit = {}, onEvent: (SseEvent) -> Unit) {
            val parser = SseParser()
            while (true) {
                val line = reader.readLine() ?: return
                onActivity()
                parser.feed(line)?.let(onEvent)
            }
        }
    }
}
