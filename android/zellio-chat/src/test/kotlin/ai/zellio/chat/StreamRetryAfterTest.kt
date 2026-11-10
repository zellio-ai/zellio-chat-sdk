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
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** A full stream limit answers 429 with `Retry-After`: the client waits that long, or it spends its rate budget for nothing. */
class StreamRetryAfterTest {
    private val streamCalls = CopyOnWriteArrayList<Long>()
    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/config") -> Reply(200, Fixtures.text("config"))
            r.path.endsWith("/session") -> ok("{\"sessionToken\":\"tok\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"customer\":null}", 201)
            r.path.endsWith("/events") -> {
                streamCalls.add(System.currentTimeMillis())
                error(429, "CHAT_RATE_LIMITED", headers = mapOf("Retry-After" to "3"))
            }
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
    fun theStreamWaitsAsLongAsTheServerAsks() = runBlocking {
        val hooks = object : EngineHooks {
            override fun isForeground() = true
            override fun isChatVisible() = true
        }
        val engine = ChatEngine(
            "k", server.url, "1.0.0", null, MemoryStore(), MemoryVault(), Clock.System, scope, LocaleOption.EN, { "en" },
            ThemeOverrides(), null, hooks,
        )
        engine.start()
        withTimeout(5_000) { while (engine.config.value == null) delay(20) }
        engine.acceptConsent()
        assertTrue(engine.ensureSession())
        engine.startStream()
        withTimeout(10_000) { while (streamCalls.size < 2) delay(20) }
        val gap = streamCalls[1] - streamCalls[0]
        assertTrue("waited only $gap ms", gap >= 2_900)
    }
}
