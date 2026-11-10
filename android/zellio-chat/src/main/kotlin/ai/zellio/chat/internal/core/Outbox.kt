package ai.zellio.chat.internal.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

@Serializable
internal enum class OutboxState { QUEUED, SENDING, ACCEPTED, FAILED }

@Serializable
internal data class OutboxAttachment(
    val path: String,
    val name: String,
    val mimeType: String,
    val size: Long,
    val uploadedId: String? = null,
    val uploadedAtMs: Long? = null,
) {
    internal val isImage: Boolean get() = mimeType.startsWith("image/")
}

/** One message the customer tapped send on. Saved before the first try; the server dedupes on [clientMessageId]. */
@Serializable
internal data class OutboxEntry(
    val clientMessageId: String,
    val conversationId: String?,
    val text: String,
    val attachments: List<OutboxAttachment> = emptyList(),
    val context: ChatContext? = null,
    val createdAtMs: Long,
    /** The 24 hour window starts here. A manual retry restarts it. */
    val windowStartMs: Long = createdAtMs,
    val state: OutboxState = OutboxState.QUEUED,
    val attempts: Int = 0,
    val nextAttemptAtMs: Long = 0,
    val failure: String? = null,
    val acceptedConversationId: String? = null,
)

/**
 * The persisted, ordered offline queue. Order is the order of [enqueue]. It survives a restart: a message that
 * was mid-send comes back as queued. After 24 hours it fails; a permanent 4xx fails it at once.
 */
internal class Outbox(private val store: KeyValueStore, private val clock: Clock = Clock.System) {
    private val flow = MutableStateFlow<List<OutboxEntry>>(emptyList())
    private val serializer = ListSerializer(OutboxEntry.serializer())

    internal val entries: StateFlow<List<OutboxEntry>> get() = flow

    @Synchronized
    internal fun load() {
        val loaded = try {
            store.read(FILE)?.let { ChatJson.decodeFromString(serializer, it) }.orEmpty()
        } catch (_: Exception) {
            emptyList()
        }
        flow.value = loaded.map { if (it.state == OutboxState.SENDING) it.copy(state = OutboxState.QUEUED) else it }
    }

    /** A second enqueue with the same id changes nothing (dedupe). Returns false for such a duplicate. */
    @Synchronized
    internal fun enqueue(entry: OutboxEntry): Boolean {
        if (flow.value.any { it.clientMessageId == entry.clientMessageId }) return false
        commit(flow.value + entry)
        return true
    }

    /** The first message that is waiting. Strict order: if it must wait for its backoff, nothing jumps ahead. */
    @Synchronized
    internal fun nextToSend(now: Long = clock.now()): OutboxEntry? {
        val head = flow.value.firstOrNull { it.state == OutboxState.QUEUED } ?: return null
        return if (head.nextAttemptAtMs <= now) head else null
    }

    @Synchronized
    internal fun nextAttemptAt(): Long? = flow.value.firstOrNull { it.state == OutboxState.QUEUED }?.nextAttemptAtMs

    @Synchronized
    internal fun get(id: String): OutboxEntry? = flow.value.firstOrNull { it.clientMessageId == id }

    @Synchronized
    internal fun update(id: String, transform: (OutboxEntry) -> OutboxEntry) {
        if (flow.value.none { it.clientMessageId == id }) return
        commit(flow.value.map { if (it.clientMessageId == id) transform(it) else it })
    }

    internal fun markSending(id: String) = update(id) { it.copy(state = OutboxState.SENDING, attempts = it.attempts + 1) }

    internal fun markAccepted(id: String, conversationId: String?) =
        update(id) { it.copy(state = OutboxState.ACCEPTED, acceptedConversationId = conversationId, failure = null) }

    internal fun markFailed(id: String, reason: String) = update(id) { it.copy(state = OutboxState.FAILED, failure = reason) }

    /** Back to the queue after a transient failure, at [atMs]. */
    internal fun retryLater(id: String, atMs: Long) = update(id) { it.copy(state = OutboxState.QUEUED, nextAttemptAtMs = atMs) }

    /** The customer taps "Try again". The 24 hour window restarts. */
    internal fun retryNow(id: String) {
        val now = clock.now()
        update(id) {
            if (it.state != OutboxState.FAILED) it
            else it.copy(state = OutboxState.QUEUED, failure = null, nextAttemptAtMs = 0, windowStartMs = now)
        }
    }

    internal fun recordUpload(id: String, index: Int, uploadedId: String) {
        val now = clock.now()
        update(id) { e ->
            e.copy(attachments = e.attachments.mapIndexed { i, a -> if (i == index) a.copy(uploadedId = uploadedId, uploadedAtMs = now) else a })
        }
    }

    internal fun forgetUpload(id: String, index: Int) {
        update(id) { e ->
            e.copy(attachments = e.attachments.mapIndexed { i, a -> if (i == index) a.copy(uploadedId = null, uploadedAtMs = null) else a })
        }
    }

    @Synchronized
    internal fun remove(id: String): OutboxEntry? {
        val entry = flow.value.firstOrNull { it.clientMessageId == id } ?: return null
        commit(flow.value.filterNot { it.clientMessageId == id })
        return entry
    }

    /** The server copy arrived (SSE or paging): the local one is dropped. */
    internal fun onServerMessages(clientMessageIds: Collection<String>): List<OutboxEntry> {
        val removed = mutableListOf<OutboxEntry>()
        for (id in clientMessageIds) remove(id)?.let(removed::add)
        return removed
    }

    /** Fails what waited longer than 24 hours. Returns the ids that expired. */
    @Synchronized
    internal fun expire(now: Long = clock.now()): List<String> {
        val expired = flow.value.filter {
            (it.state == OutboxState.QUEUED || it.state == OutboxState.SENDING) && now - it.windowStartMs >= EXPIRY_MS
        }.map { it.clientMessageId }
        if (expired.isEmpty()) return expired
        commit(flow.value.map { if (it.clientMessageId in expired) it.copy(state = OutboxState.FAILED, failure = "expired") else it })
        return expired
    }

    /** Accepted messages whose echo never came are dropped after a day, so they cannot pile up. */
    @Synchronized
    internal fun dropStaleAccepted(now: Long = clock.now()) {
        val keep = flow.value.filterNot { it.state == OutboxState.ACCEPTED && now - it.createdAtMs >= EXPIRY_MS }
        if (keep.size != flow.value.size) commit(keep)
    }

    @Synchronized
    internal fun clear() {
        flow.value = emptyList()
        store.delete(FILE)
    }

    private fun commit(list: List<OutboxEntry>) {
        flow.value = list
        try {
            store.write(FILE, ChatJson.encodeToString(serializer, list.map { if (it.state == OutboxState.SENDING) it.copy(state = OutboxState.QUEUED) else it }))
        } catch (t: Throwable) {
            Guard.report("outbox persist", t)
        }
    }

    internal companion object {
        internal const val FILE = "outbox.json"
        internal const val EXPIRY_MS = 24L * 60 * 60 * 1000
    }
}
