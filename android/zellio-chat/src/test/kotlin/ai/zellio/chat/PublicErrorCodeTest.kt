package ai.zellio.chat

import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.LocaleOption
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.MemoryVault
import ai.zellio.chat.internal.core.ThemeOverrides
import ai.zellio.chat.internal.engine.ChatEngine
import ai.zellio.chat.internal.engine.EngineHooks
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The `error(code)` event gives the same words as iOS. A server code never reaches the host app. */
class PublicErrorCodeTest {
    private var messageReply: Reply = error(400, "CHAT_SOMETHING_ELSE")
    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/config") -> Reply(200, Fixtures.text("config"))
            r.path.endsWith("/session") -> ok("{\"sessionToken\":\"tok\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"customer\":{\"id\":\"c\",\"name\":null,\"email\":null,\"phone\":null}}")
            r.method == "POST" && r.path.endsWith("/messages") -> messageReply
            r.path.endsWith("/conversations") -> Reply(200, Fixtures.text("conversations"))
            else -> error(404, "NOPE")
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val codes = CopyOnWriteArrayList<String>()

    @After
    fun stop() {
        scope.cancel()
        server.stop()
    }

    private suspend fun sendOne() {
        val hooks = object : EngineHooks {
            override fun isForeground() = false
            override fun isChatVisible() = true
            override fun onError(code: String) {
                codes.add(code)
            }
        }
        val engine = ChatEngine(
            "k", server.url, "1.0.0", null, MemoryStore(), MemoryVault(), Clock.System, scope, LocaleOption.EN, { "en" },
            ThemeOverrides(), null, hooks,
        )
        engine.start()
        withTimeout(5_000) { while (engine.config.value == null) delay(20) }
        engine.acceptConsent()
        engine.thread(null).send("Hello", emptyList())
        withTimeout(5_000) { while (codes.isEmpty()) delay(20) }
    }

    @Test
    fun aRefusedMessageGivesSendFailed() = runBlocking {
        messageReply = error(400, "CHAT_SOMETHING_ELSE")
        sendOne()
        assertEquals("send_failed", codes.first())
    }

    @Test
    fun aRateLimitGivesRateLimited() = runBlocking {
        messageReply = error(429, "CHAT_RATE_LIMITED")
        sendOne()
        assertEquals("rate_limited", codes.first())
    }

    @Test
    fun aDisabledAppGivesUnavailableNotTheServerCode() = runBlocking {
        messageReply = error(403, "CHAT_APP_DISABLED")
        sendOne()
        assertTrue(codes.toString(), codes.contains("unavailable") || codes.contains("send_failed"))
        assertFalse(codes.toString(), codes.any { it.startsWith("CHAT_") })
    }
}
