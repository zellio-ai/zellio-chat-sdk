package ai.zellio.chat.internal.engine

import ai.zellio.chat.internal.core.ApiException
import ai.zellio.chat.internal.core.ChatErrorCode
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.OutboxAttachment
import ai.zellio.chat.internal.core.OutboxEntry
import ai.zellio.chat.internal.core.ThreadData
import ai.zellio.chat.internal.core.ThreadMerge
import ai.zellio.chat.internal.core.Timeline
import ai.zellio.chat.internal.core.TimelineRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

internal enum class LoadState { LOADING, READY, FAILED }

internal data class ThreadUi(
    val conversationId: String? = null,
    val rows: List<TimelineRow> = emptyList(),
    val load: LoadState = LoadState.LOADING,
    val loadingOlder: Boolean = false,
    val hasOlder: Boolean = false,
    val typing: Boolean = false,
    val typingName: String? = null,
    val agent: AgentInfo? = null,
)

/**
 * One open conversation: server messages (from the engine's cache) plus the pending ones from the queue, as
 * timeline rows. Plain class, no Compose, so the logic runs on the JVM.
 */
internal class ThreadController(private val engine: ChatEngine, initialId: String?) {
    private val bound = MutableStateFlow(initialId)
    private val loadState = MutableStateFlow(LoadState.LOADING)
    private val loadingOlder = MutableStateFlow(false)
    private val visible = MutableStateFlow(false)
    private var observer: Job? = null
    private var lastMarked: String? = null
    private var lastExpiredReload = 0L
    @Volatile
    private var sentHere = false

    internal val conversationId: StateFlow<String?> get() = bound

    internal val ui: StateFlow<ThreadUi> = run {
        val rows = combine(bound, engine.threads, engine.outbox.entries, engine.uploadProgress) { id, threads, entries, progress ->
            val data = id?.let { threads[it] } ?: ThreadData()
            Triple(id, data, Timeline.build(data.messages, entries.filter { belongs(it, id) }, progress, System.currentTimeMillis()))
        }
        combine(rows, loadState, loadingOlder, engine.typing, engine.agents) { (id, data, timeline), load, older, typing, agents ->
            ThreadUi(
                conversationId = id,
                rows = timeline,
                load = load,
                loadingOlder = older,
                hasOlder = data.nextBefore != null,
                typing = typing.active,
                typingName = typing.agentName,
                agent = id?.let { agents[it] },
            )
        }.stateIn(engine.scope, SharingStarted.WhileSubscribed(5_000), ThreadUi(conversationId = initialId))
    }

    /** Which queued messages show in this thread. Messages with no conversation yet belong to the active one. */
    private fun belongs(entry: OutboxEntry, id: String?): Boolean = when {
        entry.conversationId != null && entry.conversationId == id -> true
        entry.acceptedConversationId != null && entry.acceptedConversationId == id -> true
        entry.conversationId == null && entry.acceptedConversationId == null -> id == null || id == engine.activeConversationId
        else -> false
    }

    internal fun draftKey(): String = bound.value ?: "new"

    /** Loads the thread: the cache at once, then the newest page. */
    internal suspend fun open() {
        observeBinding()
        val id = bound.value
        if (id == null) {
            loadState.value = LoadState.READY
            return
        }
        val cached = engine.threadData(id)
        if (cached.messages.isNotEmpty()) {
            engine.putThread(id) { it }
            loadState.value = LoadState.READY
        } else {
            loadState.value = LoadState.LOADING
        }
        if (!engine.ensureSession()) {
            if (cached.messages.isEmpty()) loadState.value = LoadState.FAILED
            return
        }
        loadInitial(id)
    }

    private suspend fun loadInitial(id: String) {
        try {
            val page = engine.fetchMessages(id)
            engine.putThread(id) { ThreadMerge.initial(it, page) }
            engine.onServerMessagesArrived(page.messages)
            loadState.value = LoadState.READY
        } catch (e: CancellationException) {
            throw e
        } catch (e: ApiException) {
            if (e.code == ChatErrorCode.CONVERSATION_NOT_FOUND) engine.loadConversations()
            if (engine.threadData(id).messages.isEmpty()) loadState.value = LoadState.FAILED
        } catch (t: Throwable) {
            if (engine.threadData(id).messages.isEmpty()) loadState.value = LoadState.FAILED
        }
    }

    internal suspend fun retryLoad() {
        loadState.value = LoadState.LOADING
        open()
    }

    internal suspend fun loadOlder() {
        val id = bound.value ?: return
        val before = engine.threadData(id).nextBefore ?: return
        if (loadingOlder.value) return
        loadingOlder.value = true
        try {
            val page = engine.fetchMessages(id, before = before)
            engine.putThread(id) { ThreadMerge.older(it, page) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            // the next scroll tries again
        } finally {
            loadingOlder.value = false
        }
    }

    /** Catch up with `after` (after a reconnect or a return to the foreground). */
    internal suspend fun refreshNewer() {
        val id = bound.value ?: return
        val latest = engine.threadData(id).latest
        if (latest == null) {
            loadInitial(id)
            return
        }
        try {
            val page = engine.fetchMessages(id, after = latest)
            engine.putThread(id) { ThreadMerge.newer(it, page) }
            engine.onServerMessagesArrived(page.messages)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
        }
    }

    /** An attachment URL answered 403 (expired): read the newest page again, at most once a minute. */
    internal suspend fun reloadExpiredUrls() {
        val id = bound.value ?: return
        val now = System.currentTimeMillis()
        if (now - lastExpiredReload < 60_000) return
        lastExpiredReload = now
        loadInitial(id)
    }

    internal fun send(text: String, attachments: List<OutboxAttachment>) {
        val clean = text.trim()
        if (clean.isEmpty() && attachments.isEmpty()) return
        if (bound.value == null) sentHere = true
        engine.enqueue(bound.value, clean, attachments)
    }

    internal fun setVisible(value: Boolean) {
        visible.value = value
    }

    /** When the queue reports a conversation id for a message sent from a new thread, the thread binds to it. */
    private fun observeBinding() {
        if (observer?.isActive == true) return
        observer = engine.scope.launch {
            launch {
                combine(engine.outbox.entries, bound) { entries, id -> entries to id }.collect { (entries, id) ->
                    if (id == null) {
                        val accepted = entries.firstNotNullOfOrNull { it.acceptedConversationId }
                        if (accepted != null) {
                            bound.value = accepted
                            Guard.run("bind thread") { launch { loadInitial(accepted) } }
                        }
                    }
                }
            }
            launch {
                // The 202 for a first message can carry no conversation (the server stores it a moment later). Once the
                // server names one (stream frame, `ready`, or the list), a thread that sent a message adopts it.
                combine(bound, engine.activeConversation) { id, active -> id to active }.collect { (id, active) ->
                    if (id == null && sentHere && active != null) {
                        bound.value = active
                        Guard.run("adopt conversation") { launch { loadInitial(active) } }
                    }
                }
            }
            launch {
                combine(bound, engine.threads, visible) { id, threads, vis -> Triple(id, threads, vis) }.collect { (id, threads, vis) ->
                    if (!vis || id == null) return@collect
                    val agentMessage = threads[id]?.messages?.lastOrNull { !it.fromVisitor } ?: return@collect
                    if (agentMessage.id != lastMarked) {
                        lastMarked = agentMessage.id
                        engine.scheduleMarkRead(id, agentMessage.id)
                    }
                }
            }
        }
    }

    internal fun close() {
        observer?.cancel()
        observer = null
        engine.releaseThread(this)
    }
}
