package ai.zellio.chat.internal.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import java.io.File

internal interface SenderListener {
    fun onAccepted(entry: OutboxEntry, conversationId: String?) {}
    fun onFailed(entry: OutboxEntry, reason: String) {}
    fun onRateLimited() {}
    fun onProgress(clientMessageId: String, progress: Float?) {}
}

/**
 * Sends the queue in order. One message at a time: a message that has to wait (offline, backoff, rate limit)
 * holds back the ones behind it, so order is kept. A permanent 4xx fails only that message.
 */
internal class OutboxSender(
    private val outbox: Outbox,
    private val gateway: SessionGateway,
    private val clock: Clock = Clock.System,
    private val backoff: Backoff = Backoff(Backoff.OUTBOX_STEPS),
    private val listener: SenderListener = object : SenderListener {},
) {
    private class Active(val id: String, val job: Deferred<Unit>)

    @Volatile
    private var active: Active? = null

    /** Messages whose files were already sent again after the server said the upload was gone. */
    private val reuploaded = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** Returns when the queue is empty or blocked. The result is the time to try again, or null if nothing waits. */
    internal suspend fun drain(): Long? {
        outbox.dropStaleAccepted()
        while (true) {
            outbox.expire().forEach { id -> outbox.get(id)?.let { listener.onFailed(it, "expired") } }
            val entry = outbox.nextToSend(clock.now()) ?: return outbox.nextAttemptAt()
            outbox.markSending(entry.clientMessageId)
            when (val outcome = attempt(entry)) {
                Outcome.Done, Outcome.Failed, Outcome.Cancelled -> Unit
                is Outcome.Wait -> {
                    outbox.retryLater(entry.clientMessageId, outcome.untilMs)
                    return outcome.untilMs
                }
            }
        }
    }

    /** The customer cancels a pending message (taps the upload ring). */
    internal fun cancel(clientMessageId: String) {
        val removed = outbox.remove(clientMessageId)
        removed?.attachments?.forEach { runCatching { File(it.path).delete() } }
        active?.takeIf { it.id == clientMessageId }?.job?.cancel()
        listener.onProgress(clientMessageId, null)
    }

    private sealed interface Outcome {
        data object Done : Outcome
        data object Failed : Outcome
        data object Cancelled : Outcome
        data class Wait(val untilMs: Long) : Outcome
    }

    private suspend fun attempt(entry: OutboxEntry): Outcome = supervisorScope {
        val job = async { send(entry) }
        active = Active(entry.clientMessageId, job)
        try {
            job.await()
            Outcome.Done
        } catch (ce: CancellationException) {
            // The whole drain was cancelled: pass it on. Only this send was cancelled: the user removed it.
            if (!currentCoroutineContext().isActive) throw ce
            if (outbox.get(entry.clientMessageId) != null) outbox.retryLater(entry.clientMessageId, clock.now())
            Outcome.Cancelled
        } catch (e: ApiException) {
            when {
                // The upload expired or was removed. The file is still on this phone, so it goes up again, once.
                e.code == ChatErrorCode.ATTACHMENT_NOT_FOUND && reuploaded.add(entry.clientMessageId) -> {
                    entry.attachments.indices.forEach { outbox.forgetUpload(entry.clientMessageId, it) }
                    Outcome.Wait(clock.now())
                }
                e.reaction == Reaction.BACK_OFF -> {
                    listener.onRateLimited()
                    Outcome.Wait(clock.now() + (e.retryAfterSeconds ?: 60L).coerceIn(1, 3600) * 1000)
                }
                e.isPermanent -> {
                    val reason = e.rawCode ?: "HTTP_${e.status}"
                    outbox.markFailed(entry.clientMessageId, reason)
                    outbox.get(entry.clientMessageId)?.let { listener.onFailed(it, reason) }
                    Outcome.Failed
                }
                else -> Outcome.Wait(clock.now() + backoff.nextDelayMs())
            }
        } catch (_: NetworkException) {
            Outcome.Wait(clock.now() + backoff.nextDelayMs())
        } catch (_: LoginNeededException) {
            Outcome.Wait(clock.now() + 60_000)
        } finally {
            active = null
            listener.onProgress(entry.clientMessageId, null)
        }
    }

    private suspend fun send(entry: OutboxEntry) {
        val total = entry.attachments.size
        for ((i, a) in entry.attachments.withIndex()) {
            val uploadedAt = a.uploadedAtMs
            // An attachment id works for 24 hours: upload again if it is about to expire.
            if (a.uploadedId != null && uploadedAt != null && clock.now() - uploadedAt < ATTACHMENT_REUSE_MS) continue
            val uploaded = gateway.authed { api ->
                api.uploadAttachment(File(a.path), a.name, a.mimeType) { p ->
                    listener.onProgress(entry.clientMessageId, ((i + p) / total).coerceIn(0f, 1f))
                }
            }
            outbox.recordUpload(entry.clientMessageId, i, uploaded.id)
        }
        val current = outbox.get(entry.clientMessageId) ?: return
        val ids = current.attachments.mapNotNull { it.uploadedId }
        val result = gateway.authed { api ->
            api.send(SendRequest(current.text, current.clientMessageId, ids, current.context))
        }
        outbox.markAccepted(entry.clientMessageId, result.conversationId)
        outbox.get(entry.clientMessageId)?.let { listener.onAccepted(it, result.conversationId) }
        backoff.reset()
    }

    internal companion object {
        internal const val ATTACHMENT_REUSE_MS = 23L * 60 * 60 * 1000
    }
}
