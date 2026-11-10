package ai.zellio.chat

import ai.zellio.chat.internal.core.ApiClient
import ai.zellio.chat.internal.core.ApiException
import ai.zellio.chat.internal.core.ChatContext
import ai.zellio.chat.internal.core.ChatErrorCode
import ai.zellio.chat.internal.core.HttpTimeouts
import ai.zellio.chat.internal.core.NetworkException
import ai.zellio.chat.internal.core.Reaction
import ai.zellio.chat.internal.core.SendRequest
import ai.zellio.chat.internal.core.SessionRequest
import ai.zellio.chat.internal.core.SseEvent
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class ApiClientTest {
    private var reply: (Recorded) -> Reply = { ok("{}") }
    private val server = FakeServer { reply(it) }
    private var token: String? = "tok"

    private fun client(timeouts: HttpTimeouts = HttpTimeouts(), wrapper: String? = null, base: String = server.url) =
        ApiClient(base, "app-key-1", "1.2.3", wrapper, { token }, timeouts)

    @After
    fun stop() = server.stop()

    @Test
    fun everyRequestCarriesTheAppKeyAndSdkHeaders() = runBlocking {
        reply = { Reply(200, Fixtures.text("config")) }
        val config = client(wrapper = "flutter/1.0.0").config()
        val r = server.requests.single()
        assertEquals("/api/v1/zeechat/mobile/config", r.path)
        assertEquals("app-key-1", r.headers["x-zee-app-key"])
        assertEquals("android/1.2.3", r.headers["x-zee-sdk"])
        assertEquals("flutter/1.0.0", r.headers["x-zee-sdk-wrapper"])
        assertNull("config needs no session", r.headers["x-zee-session-token"])
        assertEquals("ver_1", config.snapshot?.versionId)
    }

    @Test
    fun sessionRequestsCarryTheTokenAndNeverLogItInTheBody() = runBlocking {
        reply = { ok("{\"unreadTotal\":4}") }
        assertEquals(4, client().unread())
        assertEquals("tok", server.requests.single().headers["x-zee-session-token"])
    }

    @Test
    fun sendPostsTheContractBody() = runBlocking {
        reply = { ok("{\"clientMessageId\":\"c1\",\"accepted\":true,\"conversationId\":\"conv_2\"}", 202) }
        val result = client().send(SendRequest("hello", "c1", listOf("att_1"), ChatContext(screen = "Order", url = "https://shop.example/o")))
        assertEquals("conv_2", result.conversationId)
        val r = server.requests.single()
        assertEquals("POST", r.method)
        assertEquals("/api/v1/zeechat/mobile/messages", r.path)
        assertTrue(r.body.contains("\"clientMessageId\":\"c1\""))
        assertTrue(r.body.contains("\"attachmentIds\":[\"att_1\"]"))
        assertTrue(r.body.contains("\"screen\":\"Order\""))
    }

    @Test
    fun pagingUsesBeforeOrAfterNeverBoth() = runBlocking {
        reply = { Reply(200, Fixtures.text("messages")) }
        client().messages("conv_2", before = "cur")
        client().messages("conv_2", after = "lat")
        assertEquals("before=cur&limit=50", server.requests[0].query)
        assertEquals("after=lat&limit=50", server.requests[1].query)
        client().messages("conv_2", before = "a", after = "b")
        assertEquals("before and after are never sent together", "before=a&limit=50", server.requests[2].query)
    }

    @Test
    fun errorsCarryTheirCodeFromEitherBodyShapeAndRetryAfter() = runBlocking {
        reply = { error(429, "CHAT_RATE_LIMITED", nested = true, headers = mapOf("Retry-After" to "12")) }
        try {
            client().unread()
            fail("expected an error")
        } catch (e: ApiException) {
            assertEquals(ChatErrorCode.RATE_LIMITED, e.code)
            assertEquals(Reaction.BACK_OFF, e.reaction)
            assertEquals(12L, e.retryAfterSeconds)
        }
        reply = { error(413, "CHAT_FILE_TOO_LARGE") }
        try {
            client().unread()
            fail("expected an error")
        } catch (e: ApiException) {
            assertEquals(Reaction.FILE_TOO_LARGE, e.reaction)
        }
    }

    @Test
    fun aBodyThatIsNotTheEnvelopeIsABadBodyNotACrash() = runBlocking {
        reply = { Reply(200, "<html>captive portal</html>") }
        try {
            client().unread()
            fail("expected an error")
        } catch (e: ApiException) {
            assertEquals("BAD_BODY", e.rawCode)
        }
    }

    @Test
    fun aDeadServerIsANetworkErrorNotAnApiError() = runBlocking {
        val url = server.url
        server.stop()
        try {
            client(base = url).unread()
            fail("expected a network error")
        } catch (_: NetworkException) {
        }
    }

    @Test
    fun uploadSendsMultipartWithAFilePartAndReportsProgress() = runBlocking {
        reply = { ok("{\"id\":\"att_1\",\"kind\":\"image\",\"name\":\"p.jpg\",\"mimeType\":\"image/jpeg\",\"size\":3,\"url\":\"https://cdn/p.jpg\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}", 201) }
        val file = File.createTempFile("zcup", ".jpg").apply { writeBytes(ByteArray(300_000) { 7 }); deleteOnExit() }
        val progress = mutableListOf<Float>()
        val uploaded = client().uploadAttachment(file, "p.jpg", "image/jpeg") { progress += it }
        assertEquals("att_1", uploaded.id)
        val r = server.requests.single()
        assertTrue(r.headers["content-type"]!!.startsWith("multipart/form-data; boundary="))
        assertTrue(r.body.contains("name=\"file\"; filename=\"p.jpg\""))
        assertTrue(progress.isNotEmpty() && progress.last() >= 0.99f && progress.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test
    fun theEventStreamDeliversEventsAndIgnoresPings() = runBlocking {
        reply = {
            Reply(200, ": ping\n\nevent: ready\ndata: {\"conversationId\":\"c1\"}\n\nevent: message\ndata: {\"id\":\"m1\"}\n\n", contentType = "text/event-stream")
        }
        val events = mutableListOf<SseEvent>()
        var opened = false
        client().events(onOpen = { opened = true }, onEvent = { events += it })
        assertTrue(opened)
        assertEquals(listOf("ready", "message"), events.map { it.event })
        assertEquals("text/event-stream", server.requests.single().headers["accept"])
    }

    @Test
    fun sessionRequestShapeIsStable() {
        val body = ai.zellio.chat.internal.core.ChatJson.encodeToString(SessionRequest.serializer(), SessionRequest("i", "android", "ar", null))
        assertTrue(body.contains("\"platform\":\"android\""))
        assertFalse(body.contains("identityToken\":\"null"))
    }
}
