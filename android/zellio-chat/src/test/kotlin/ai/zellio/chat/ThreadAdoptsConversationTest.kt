package ai.zellio.chat

import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.LocaleOption
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.MemoryVault
import ai.zellio.chat.internal.core.ThemeOverrides
import ai.zellio.chat.internal.engine.ChatEngine
import ai.zellio.chat.internal.engine.EngineHooks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The real server answers a first message with `conversationId: null` (a worker stores the message a moment later).
 * The open thread has no conversation yet, so it must adopt the one the server names, or an agent reply that comes in
 * over the stream is stored under a conversation the screen does not show.
 */
class ThreadAdoptsConversationTest {
    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/config") -> Reply(200, Fixtures.text("config"))
            r.path.endsWith("/session") -> ok("{\"sessionToken\":\"tok\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"customer\":{\"identified\":false}}", 201)
            r.method == "POST" && r.path.endsWith("/messages") -> {
                val cid = Regex("\"clientMessageId\":\"([^\"]+)\"").find(r.body)!!.groupValues[1]
                ok("{\"clientMessageId\":\"$cid\",\"accepted\":true,\"conversationId\":null}", 202)
            }
            r.path.endsWith("/conversations") -> Reply(200, Fixtures.text("conversations"))
            r.path.contains("/conversations/") && r.path.endsWith("/messages") -> Reply(200, Fixtures.text("messages"))
            else -> error(404, "NOPE")
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After
    fun stop() {
        scope.cancel()
        server.stop()
    }

    @Test
    fun anUnboundThreadThatSentAMessageAdoptsTheConversationTheServerNames() = runBlocking {
        val hooks = object : EngineHooks {
            override fun isForeground() = false
            override fun isChatVisible() = true
        }
        val engine = ChatEngine(
            "k", server.url, "1.0.0", null, MemoryStore(), MemoryVault(), Clock.System, scope, LocaleOption.EN, { "en" },
            ThemeOverrides(), null, hooks,
        )
        engine.start()
        withTimeout(5_000) { while (engine.config.value == null) delay(20) }
        engine.acceptConsent()
        val thread = engine.thread(null)
        thread.open()
        assertEquals(null, thread.conversationId.value)
        thread.send("Where is my order?", emptyList())
        withTimeout(5_000) { while (thread.conversationId.value == null) delay(20) }
        assertEquals("conv_2", thread.conversationId.value)
    }

    @Test
    fun aNewInstallMakesItsSessionBeforeAnyCallThatNeedsOne() = runBlocking {
        val hooks = object : EngineHooks {
            override fun isForeground() = false
            override fun isChatVisible() = true
        }
        val engine = ChatEngine(
            "k", server.url, "1.0.0", null, MemoryStore(), MemoryVault(), Clock.System, scope, LocaleOption.EN, { "en" },
            ThemeOverrides(), null, hooks,
        )
        engine.start()
        withTimeout(5_000) { while (engine.config.value == null) delay(20) }
        engine.acceptConsent()
        engine.refreshUnread()
        engine.loadConversations()
        val calls = server.requests.filterNot { it.path.endsWith("/config") }
        assertEquals("/api/v1/zeechat/mobile/session", calls.first().path)
        assertEquals(emptyList<String>(), calls.drop(1).filter { it.headers["x-zee-session-token"] == null }.map { it.path })
    }

    @Test
    fun aThreadThatSentNothingStaysUnbound() = runBlocking {
        val hooks = object : EngineHooks {
            override fun isForeground() = false
            override fun isChatVisible() = true
        }
        val engine = ChatEngine(
            "k", server.url, "1.0.0", null, MemoryStore(), MemoryVault(), Clock.System, scope, LocaleOption.EN, { "en" },
            ThemeOverrides(), null, hooks,
        )
        engine.start()
        withTimeout(5_000) { while (engine.config.value == null) delay(20) }
        engine.acceptConsent()
        engine.loadConversations()
        val thread = engine.thread(null)
        thread.open()
        delay(300)
        assertEquals(null, thread.conversationId.value)
    }
}
