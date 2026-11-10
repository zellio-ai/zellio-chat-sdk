package ai.zellio.chat

import ai.zellio.chat.internal.core.ApiClient
import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.LocalData
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.MemoryVault
import ai.zellio.chat.internal.core.Outbox
import ai.zellio.chat.internal.core.OutboxEntry
import ai.zellio.chat.internal.core.OutboxSender
import ai.zellio.chat.internal.core.OutboxState
import ai.zellio.chat.internal.core.SessionGateway
import ai.zellio.chat.internal.core.SessionHolder
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SenderTest {
    private var now = 5_000_000L
    private val clock = Clock { now }
    private var messageReply: (Recorded) -> Reply = { r ->
        val cid = Regex("\"clientMessageId\":\"([^\"]+)\"").find(r.body)!!.groupValues[1]
        ok("{\"clientMessageId\":\"$cid\",\"accepted\":true,\"conversationId\":\"c1\"}", 202)
    }
    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/session") -> ok("{\"sessionToken\":\"tok\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"customer\":{\"identified\":false}}", 201)
            r.path.endsWith("/messages") -> messageReply(r)
            r.path.endsWith("/attachments") -> uploadServerReply(r) ?: error(404, "NOPE")
            else -> error(404, "NOPE")
        }
    }
    private val outbox = Outbox(MemoryStore(), clock)
    private val accepted = mutableListOf<String>()
    private val failed = mutableListOf<Pair<String, String>>()

    private fun sender(base: String = server.url): OutboxSender {
        val holder = SessionHolder()
        val api = ApiClient(base, "k", "1.0.0", null, holder::token)
        val gateway = SessionGateway(api, holder, LocalData(MemoryStore(), MemoryVault()), "i", { "en" }, { null })
        return OutboxSender(
            outbox, gateway, clock,
            listener = object : ai.zellio.chat.internal.core.SenderListener {
                override fun onAccepted(entry: OutboxEntry, conversationId: String?) {
                    accepted += entry.clientMessageId
                }

                override fun onFailed(entry: OutboxEntry, reason: String) {
                    failed += entry.clientMessageId to reason
                }
            },
        )
    }

    private fun queue(vararg ids: String) = ids.forEach {
        outbox.enqueue(OutboxEntry(clientMessageId = it, conversationId = "c1", text = "text $it", createdAtMs = now))
    }

    @After
    fun stop() = server.stop()

    private fun queueWithFile(id: String): java.io.File {
        val file = java.io.File.createTempFile("zellio", ".jpg").apply { writeBytes(byteArrayOf(1, 2, 3)); deleteOnExit() }
        val attachment = ai.zellio.chat.internal.core.OutboxAttachment(file.path, "a.jpg", "image/jpeg", 3)
        outbox.enqueue(OutboxEntry(clientMessageId = id, conversationId = "c1", text = "", attachments = listOf(attachment), createdAtMs = now))
        return file
    }

    private fun uploadServerReply(r: Recorded): Reply? =
        if (r.path.endsWith("/attachments")) {
            ok("{\"id\":\"att_${server.requests.count { it.path.endsWith("/attachments") }}\",\"kind\":\"image\",\"name\":\"a.jpg\",\"mimeType\":\"image/jpeg\",\"size\":3,\"url\":\"https://x/a\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}", 201)
        } else {
            null
        }

    @Test
    fun aFileTheServerLostGoesUpAgainOnceThenTheMessageIsSent() = runBlocking {
        queueWithFile("a")
        var sends = 0
        messageReply = { r ->
            sends++
            if (sends == 1) {
                error(404, "CHAT_ATTACHMENT_NOT_FOUND")
            } else {
                ok("{\"clientMessageId\":\"a\",\"accepted\":true,\"conversationId\":\"c1\"}", 202)
            }
        }
        val s = sender()
        var wake = s.drain()
        var guard = 0
        while (wake != null && guard++ < 5) wake = s.drain()
        assertEquals(listOf("a"), accepted)
        assertEquals(2, server.requests.count { it.path.endsWith("/attachments") })
        assertTrue(server.requests.last { it.path.endsWith("/messages") }.body.contains("att_2"))
    }

    @Test
    fun aFileThatIsStillMissingAfterTheSecondUploadFailsTheMessage() = runBlocking {
        queueWithFile("a")
        messageReply = { _ -> error(404, "CHAT_ATTACHMENT_NOT_FOUND") }
        val s = sender()
        var wake = s.drain()
        var guard = 0
        while (wake != null && guard++ < 5) wake = s.drain()
        assertEquals(OutboxState.FAILED, outbox.get("a")?.state)
        assertEquals(listOf("a" to "CHAT_ATTACHMENT_NOT_FOUND"), failed)
        assertEquals(2, server.requests.count { it.path.endsWith("/messages") })
    }

    @Test
    fun theQueueIsSentInOrderAndEachMessageOnce() = runBlocking {
        queue("a", "b", "c")
        assertNull(sender().drain())
        assertEquals(listOf("a", "b", "c"), accepted)
        val sent = server.requests.filter { it.path.endsWith("/messages") }.map { Regex("\"clientMessageId\":\"([^\"]+)\"").find(it.body)!!.groupValues[1] }
        assertEquals(listOf("a", "b", "c"), sent)
        assertTrue(outbox.entries.value.all { it.state == OutboxState.ACCEPTED })
    }

    @Test
    fun aPermanentClientErrorFailsOnlyThatMessage() = runBlocking {
        messageReply = { r ->
            if (r.body.contains("\"a\"")) error(422, "CHAT_VALIDATION") else ok("{\"accepted\":true,\"conversationId\":\"c1\"}", 202)
        }
        queue("a", "b")
        sender().drain()
        assertEquals(listOf("b"), accepted)
        assertEquals("a", failed.single().first)
        assertEquals(OutboxState.FAILED, outbox.get("a")?.state)
    }

    @Test
    fun noNetworkKeepsTheMessageQueuedAndReturnsWhenToTryAgain() = runBlocking {
        val dead = FakeServer { ok("{}") }
        val url = dead.url
        dead.stop()
        queue("a", "b")
        val wake = sender(url).drain()
        assertNotNull(wake)
        assertTrue(wake!! > now)
        assertTrue(accepted.isEmpty())
        assertEquals(listOf("a", "b"), outbox.entries.value.map { it.clientMessageId })
        assertTrue(outbox.entries.value.all { it.state == OutboxState.QUEUED })
        assertNull("the head of the queue waits, nothing jumps ahead", outbox.nextToSend())
    }

    @Test
    fun rateLimitWaitsForRetryAfterAndKeepsTheMessage() = runBlocking {
        messageReply = { error(429, "CHAT_RATE_LIMITED", headers = mapOf("Retry-After" to "30")) }
        queue("a")
        val wake = sender().drain()
        assertNotNull(wake)
        assertTrue(wake!! >= now + 30_000)
        assertEquals(OutboxState.QUEUED, outbox.get("a")?.state)
    }
}
