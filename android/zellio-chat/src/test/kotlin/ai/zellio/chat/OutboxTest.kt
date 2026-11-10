package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatMessage
import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.Outbox
import ai.zellio.chat.internal.core.OutboxEntry
import ai.zellio.chat.internal.core.OutboxState
import ai.zellio.chat.internal.core.Delivery
import ai.zellio.chat.internal.core.Timeline
import ai.zellio.chat.internal.core.TimelineRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

class OutboxTest {
    private var now = 1_000_000L
    private val clock = Clock { now }
    private val store = MemoryStore()

    private fun entry(id: String, text: String = id, at: Long = now) =
        OutboxEntry(clientMessageId = id, conversationId = "c1", text = text, createdAtMs = at)

    @Test
    fun messagesLeaveInTheOrderTheyWereQueued() {
        val box = Outbox(store, clock)
        box.enqueue(entry("a"))
        box.enqueue(entry("b"))
        box.enqueue(entry("c"))
        assertEquals("a", box.nextToSend()?.clientMessageId)
        box.markSending("a")
        box.markAccepted("a", "c1")
        assertEquals("b", box.nextToSend()?.clientMessageId)
    }

    @Test
    fun aWaitingMessageHoldsBackTheOnesBehindIt() {
        val box = Outbox(store, clock)
        box.enqueue(entry("a"))
        box.enqueue(entry("b"))
        box.markSending("a")
        box.retryLater("a", now + 5_000)
        assertNull(box.nextToSend())
        now += 5_000
        assertEquals("a", box.nextToSend()?.clientMessageId)
    }

    @Test
    fun theQueueSurvivesARestartAndAMidSendMessageComesBackQueued() {
        val first = Outbox(store, clock)
        first.enqueue(entry("a"))
        first.enqueue(entry("b"))
        first.markSending("a")

        val second = Outbox(store, clock)
        second.load()
        assertEquals(listOf("a", "b"), second.entries.value.map { it.clientMessageId })
        assertEquals(OutboxState.QUEUED, second.entries.value.first().state)
    }

    @Test
    fun theSameClientMessageIdIsNeverQueuedTwice() {
        val box = Outbox(store, clock)
        assertTrue(box.enqueue(entry("a", "first")))
        assertFalse(box.enqueue(entry("a", "second")))
        assertEquals(1, box.entries.value.size)
        assertEquals("first", box.entries.value.single().text)
    }

    @Test
    fun theServerCopyReplacesTheLocalOne() {
        val box = Outbox(store, clock)
        box.enqueue(entry("a"))
        box.enqueue(entry("b"))
        val removed = box.onServerMessages(listOf("a", "unknown"))
        assertEquals(listOf("a"), removed.map { it.clientMessageId })
        assertEquals(listOf("b"), box.entries.value.map { it.clientMessageId })
    }

    @Test
    fun aMessageFailsAfterTwentyFourHours() {
        val box = Outbox(store, clock)
        box.enqueue(entry("a"))
        now += Outbox.EXPIRY_MS - 1
        assertTrue(box.expire().isEmpty())
        now += 1
        assertEquals(listOf("a"), box.expire())
        assertEquals(OutboxState.FAILED, box.get("a")?.state)
        assertNull(box.nextToSend())
    }

    @Test
    fun tryAgainRestartsTheWindow() {
        val box = Outbox(store, clock)
        box.enqueue(entry("a"))
        now += Outbox.EXPIRY_MS
        box.expire()
        box.retryNow("a")
        assertEquals(OutboxState.QUEUED, box.get("a")?.state)
        assertTrue(box.expire().isEmpty())
    }

    @Test
    fun aLocalMessageAndItsServerCopyShowAsOneBubbleWithoutAFlash() {
        val zone = TimeZone.getTimeZone("UTC")
        val server = ChatMessage("m1", "a", true, "hello", emptyList(), now, null, null)
        val pending = listOf(entry("a", "hello"), entry("b", "later"))
        val rows = Timeline.build(listOf(server), pending, emptyMap(), now, zone)
        val messages = rows.filterIsInstance<TimelineRow.Message>()
        assertEquals(listOf("a", "b"), messages.map { it.key })
        // the key of "a" is the clientMessageId in both forms, so the list item is reused (no jump)
        val onlyLocal = Timeline.build(emptyList(), pending, emptyMap(), now, zone).filterIsInstance<TimelineRow.Message>()
        assertEquals(messages.map { it.key }, onlyLocal.map { it.key })
        assertEquals("never tried yet: it is about to go", Delivery.SENDING, onlyLocal.last().delivery)
        val waiting = Timeline.build(emptyList(), listOf(entry("w").copy(attempts = 1)), emptyMap(), now, zone).filterIsInstance<TimelineRow.Message>()
        assertEquals("after a failed try it waits", Delivery.QUEUED, waiting.single().delivery)
    }
}
