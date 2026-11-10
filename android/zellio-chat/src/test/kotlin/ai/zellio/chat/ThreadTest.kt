package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatMessage
import ai.zellio.chat.internal.core.DateLabels
import ai.zellio.chat.internal.core.LinkDetector
import ai.zellio.chat.internal.core.MessagesPage
import ai.zellio.chat.internal.core.ThreadData
import ai.zellio.chat.internal.core.ThreadMerge
import ai.zellio.chat.internal.core.Timeline
import ai.zellio.chat.internal.core.TimelineRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

class ThreadTest {
    private fun m(id: String, at: Long, from: Boolean = false, cid: String? = null, text: String = id) =
        ChatMessage(id, cid, from, text, emptyList(), at, null, null)

    private fun page(vararg messages: ChatMessage, before: String? = null, latest: String? = null) =
        MessagesPage("c1", messages.toList(), before, latest)

    @Test
    fun theFirstPageThenOlderPagesMergeInOrderWithoutDuplicates() {
        val first = ThreadMerge.initial(ThreadData(emptyList(), null, null), page(m("3", 30), m("4", 40), before = "b1", latest = "l1"))
        assertEquals("b1", first.nextBefore)
        val older = ThreadMerge.older(first, page(m("1", 10), m("2", 20), m("3", 30), before = null))
        assertEquals(listOf("1", "2", "3", "4"), older.messages.map { it.id })
        assertEquals(null, older.nextBefore)
        assertEquals("l1", older.latest)
    }

    @Test
    fun theNewerPageMovesTheLatestCursor() {
        val start = ThreadData(listOf(m("1", 10)), "b", "l1")
        val next = ThreadMerge.newer(start, page(m("2", 20), latest = "l2"))
        assertEquals(listOf("1", "2"), next.messages.map { it.id })
        assertEquals("l2", next.latest)
        assertEquals("b", next.nextBefore)
    }

    @Test
    fun aServerMessageWithTheSameClientMessageIdReplacesTheLocalCopy() {
        val withLocalId = ThreadData(listOf(m("tmp", 10, true, "cid")), null, null)
        val merged = ThreadMerge.add(withLocalId, m("srv", 11, true, "cid"))
        assertEquals(listOf("srv"), merged.messages.map { it.id })
        assertEquals("cid", merged.messages.single().key)
    }

    @Test
    fun cachedMessagesOlderThanTheFreshPageAreDroppedBecauseTheyHaveNoCursor() {
        val cached = ThreadData(listOf(m("1", 10), m("2", 20)), null, null)
        val result = ThreadMerge.initial(cached, page(m("5", 50), m("6", 60), before = "b"))
        assertEquals(listOf("5", "6"), result.messages.map { it.id })
    }

    @Test
    fun messagesFromTheSameSenderGroupAndDatesSeparate() {
        val zone = TimeZone.getTimeZone("UTC")
        val day = 86_400_000L
        val now = 10 * day + 12 * 3_600_000L
        val list = listOf(
            m("1", 8 * day, true), m("2", 8 * day + 60_000, true), m("3", 9 * day, false),
            m("4", now - 1000, true),
        )
        val rows = Timeline.build(list, emptyList(), emptyMap(), now, zone)
        val separators = rows.filterIsInstance<TimelineRow.DateSeparator>()
        assertEquals(listOf(DateLabels.Kind.DATE, DateLabels.Kind.YESTERDAY, DateLabels.Kind.TODAY), separators.map { it.kind })
        val messages = rows.filterIsInstance<TimelineRow.Message>()
        assertTrue(messages[0].first && !messages[0].last)
        assertTrue(!messages[1].first && messages[1].last)
    }

    @Test
    fun onlyHttpsMailAndTelAreLinks() {
        val spans = LinkDetector.find("see https://shop.example/a?b=1, mail me@shop.example or tel:+20 100 123 4567 and http://bad.example javascript:alert(1)")
        val urls = spans.map { it.url }
        assertTrue("https://shop.example/a?b=1" in urls)
        assertTrue("mailto:me@shop.example" in urls)
        assertTrue(urls.any { it.startsWith("tel:+20") })
        assertTrue(urls.none { it.startsWith("http://") || it.startsWith("javascript") })
    }
}
