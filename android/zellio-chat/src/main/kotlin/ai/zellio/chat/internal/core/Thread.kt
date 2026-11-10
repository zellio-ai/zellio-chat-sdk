package ai.zellio.chat.internal.core

import java.util.TimeZone

/** What the SDK knows about one conversation from the server. Oldest message first. */
internal data class ThreadData(
    val messages: List<ChatMessage> = emptyList(),
    /** Cursor for the page older than [messages].first(). Null: no older page (or not known yet). */
    val nextBefore: String? = null,
    /** Cursor to catch up with `after`. */
    val latest: String? = null,
) {
    internal val newest: ChatMessage? get() = messages.lastOrNull()
}

/** Cursor paging merge. A server message with the same `clientMessageId` replaces the local copy in place. */
internal object ThreadMerge {
    private val order = compareBy<ChatMessage>({ it.createdAtMs }, { it.id })

    internal fun union(a: List<ChatMessage>, b: List<ChatMessage>): List<ChatMessage> {
        val byId = LinkedHashMap<String, ChatMessage>()
        for (m in a) byId[m.id] = m
        for (m in b) byId[m.id] = m // the newer copy wins
        // Same clientMessageId under two ids: keep the later one.
        val byClient = HashMap<String, ChatMessage>()
        val dropped = HashSet<String>()
        for (m in byId.values) {
            val cid = m.clientMessageId ?: continue
            val previous = byClient[cid]
            if (previous == null) byClient[cid] = m
            else {
                val keep = if (order.compare(previous, m) <= 0) m else previous
                dropped += (if (keep === m) previous else m).id
                byClient[cid] = keep
            }
        }
        return byId.values.filter { it.id !in dropped }.sortedWith(order)
    }

    /** The newest page (first open, or return to the foreground). */
    internal fun initial(current: ThreadData, page: MessagesPage): ThreadData {
        val pageMessages = page.messages
        if (pageMessages.isEmpty()) {
            return ThreadData(emptyList(), page.nextBefore, page.latest)
        }
        val pageOldest = pageMessages.minWith(order)
        // Cached messages older than the page have no cursor. They are dropped; older pages load again on scroll.
        val keptFromCache = current.messages.filter { order.compare(it, pageOldest) >= 0 }
        return ThreadData(union(keptFromCache, pageMessages), page.nextBefore, page.latest ?: current.latest)
    }

    internal fun older(current: ThreadData, page: MessagesPage): ThreadData =
        ThreadData(union(current.messages, page.messages), page.nextBefore, current.latest)

    internal fun newer(current: ThreadData, page: MessagesPage): ThreadData =
        ThreadData(union(current.messages, page.messages), current.nextBefore, page.latest ?: current.latest)

    internal fun add(current: ThreadData, message: ChatMessage): ThreadData =
        ThreadData(union(current.messages, listOf(message)), current.nextBefore, current.latest)
}

internal enum class Delivery { NONE, SENDING, SENT, QUEUED, FAILED }

internal data class UiAttachment(
    val key: String,
    val url: String?,
    val localPath: String?,
    val name: String,
    val mimeType: String,
    val size: Long,
    val isImage: Boolean,
    /** 0..1 while the upload runs, else null. */
    val progress: Float?,
)

internal data class UiMessage(
    val key: String,
    val clientMessageId: String?,
    val id: String?,
    val fromVisitor: Boolean,
    val text: String,
    val attachments: List<UiAttachment>,
    val timeMs: Long,
    val agentName: String?,
    val agentAvatarUrl: String?,
    val status: Delivery,
)

internal sealed interface TimelineRow {
    val key: String

    data class DateSeparator(override val key: String, val kind: DateLabels.Kind, val ms: Long) : TimelineRow

    data class Message(
        override val key: String,
        val message: UiMessage,
        val first: Boolean,
        val last: Boolean,
        val showName: Boolean,
        /** The line under the bubble: only on the newest visitor message, plus every queued or failed one. */
        val delivery: Delivery,
    ) : TimelineRow
}

internal object Timeline {
    internal const val GROUP_WINDOW_MS = 5 * 60 * 1000L

    internal fun toUi(m: ChatMessage): UiMessage = UiMessage(
        key = m.key,
        clientMessageId = m.clientMessageId,
        id = m.id,
        fromVisitor = m.fromVisitor,
        text = m.text,
        attachments = m.attachments.mapIndexed { i, a ->
            UiAttachment("${m.key}#$i", a.url, null, a.name, a.mimeType, a.size, a.isImage, null)
        },
        timeMs = m.createdAtMs,
        agentName = m.agentName,
        agentAvatarUrl = m.agentAvatarUrl,
        status = if (m.fromVisitor) Delivery.SENT else Delivery.NONE,
    )

    internal fun toUi(e: OutboxEntry, progress: Float?): UiMessage = UiMessage(
        key = e.clientMessageId,
        clientMessageId = e.clientMessageId,
        id = null,
        fromVisitor = true,
        text = e.text,
        attachments = e.attachments.mapIndexed { i, a ->
            UiAttachment("${e.clientMessageId}#$i", null, a.path, a.name, a.mimeType, a.size, a.isImage, if (a.uploadedId == null) progress else null)
        },
        timeMs = e.createdAtMs,
        agentName = null,
        agentAvatarUrl = null,
        status = when (e.state) {
            OutboxState.ACCEPTED -> Delivery.SENT
            OutboxState.FAILED -> Delivery.FAILED
            OutboxState.SENDING -> Delivery.SENDING
            // Never tried yet: it is about to go, so it reads "Sending". After a failed try it waits: clock icon.
            OutboxState.QUEUED -> if (e.attempts == 0) Delivery.SENDING else Delivery.QUEUED
        },
    )

    /** Oldest first. Pending messages follow the server messages, in queue order. */
    internal fun build(
        server: List<ChatMessage>,
        pending: List<OutboxEntry>,
        progress: Map<String, Float>,
        now: Long,
        zone: TimeZone = TimeZone.getDefault(),
    ): List<TimelineRow> {
        val serverClientIds = server.mapNotNull { it.clientMessageId }.toHashSet()
        val items = server.map(::toUi) + pending.filter { it.clientMessageId !in serverClientIds }.map { toUi(it, progress[it.clientMessageId]) }
        val newestVisitorIndex = items.indexOfLast { it.fromVisitor }

        val rows = ArrayList<TimelineRow>(items.size + 4)
        var previous: UiMessage? = null
        var previousDay = Long.MIN_VALUE
        val groupFirst = BooleanArray(items.size)
        val groupLast = BooleanArray(items.size)
        for ((i, m) in items.withIndex()) {
            val day = DateLabels.dayNumber(m.timeMs, zone)
            val sameGroup = previous != null && day == previousDay && sameSender(previous, m) &&
                m.timeMs - previous.timeMs in 0..GROUP_WINDOW_MS
            groupFirst[i] = !sameGroup
            if (i > 0 && sameGroup) groupLast[i - 1] = false
            groupLast[i] = true
            previous = m
            previousDay = day
        }
        previousDay = Long.MIN_VALUE
        for ((i, m) in items.withIndex()) {
            val day = DateLabels.dayNumber(m.timeMs, zone)
            if (day != previousDay) {
                rows += TimelineRow.DateSeparator("day-$day", DateLabels.dayKind(m.timeMs, now, zone), m.timeMs)
                previousDay = day
            }
            val delivery = when {
                !m.fromVisitor -> Delivery.NONE
                m.status == Delivery.FAILED || m.status == Delivery.QUEUED -> m.status
                i == newestVisitorIndex -> m.status
                else -> Delivery.NONE
            }
            rows += TimelineRow.Message(
                key = m.key,
                message = m,
                first = groupFirst[i],
                last = groupLast[i],
                showName = groupFirst[i] && !m.fromVisitor && !m.agentName.isNullOrBlank(),
                delivery = delivery,
            )
        }
        return rows
    }

    private fun sameSender(a: UiMessage, b: UiMessage): Boolean =
        a.fromVisitor == b.fromVisitor && (a.fromVisitor || a.agentName == b.agentName)
}

/** Detects the links in a message. Only https, mailto and tel are ever opened. */
internal object LinkDetector {
    internal data class Span(val start: Int, val end: Int, val url: String)

    private val pattern = Regex("""(?i)\b(?:https://[^\s<>"']+|mailto:[^\s<>"']+|tel:[+\d][\d\s().-]{3,}\d|[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+)""")
    private const val TRAILING = ".,;:!?)]}،؛؟…\"'"

    internal fun find(text: String): List<Span> {
        val spans = ArrayList<Span>()
        for (m in pattern.findAll(text)) {
            var end = m.range.last + 1
            while (end > m.range.first && TRAILING.indexOf(text[end - 1]) >= 0) end--
            val raw = text.substring(m.range.first, end)
            val url = when {
                raw.startsWith("https://", ignoreCase = true) -> raw
                raw.startsWith("mailto:", ignoreCase = true) -> raw
                raw.startsWith("tel:", ignoreCase = true) -> "tel:" + raw.substring(4).filter { it.isDigit() || it == '+' }
                '@' in raw -> "mailto:$raw"
                else -> continue
            }
            if (LinkPolicy.isSafe(url)) spans += Span(m.range.first, end, url)
        }
        return spans
    }
}
