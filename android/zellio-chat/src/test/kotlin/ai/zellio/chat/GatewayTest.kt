package ai.zellio.chat

import ai.zellio.chat.internal.core.ApiClient
import ai.zellio.chat.internal.core.ApiException
import ai.zellio.chat.internal.core.Blocked
import ai.zellio.chat.internal.core.ChatErrorCode
import ai.zellio.chat.internal.core.LocalData
import ai.zellio.chat.internal.core.LoginNeededException
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.MemoryVault
import ai.zellio.chat.internal.core.SessionGateway
import ai.zellio.chat.internal.core.SessionHolder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class GatewayTest {
    private val sessions = AtomicInteger(0)
    private val failSessions = AtomicInteger(0)
    private val failUnread = AtomicInteger(0)
    private var unreadError = "CHAT_SESSION_INVALID"
    private var sessionError = "CHAT_IDENTITY_INVALID"
    @Volatile
    private var rejectedToken: String? = null
    private val saved = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val blocked = mutableListOf<Blocked>()

    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/session") && r.method == "POST" -> {
                if (failSessions.getAndUpdate { (it - 1).coerceAtLeast(0) } > 0) {
                    error(401, sessionError)
                } else {
                    val identified = r.body.contains("identityToken")
                    ok("{\"sessionToken\":\"tok_${sessions.incrementAndGet()}\",\"expiresAt\":\"2099-01-01T00:00:00.000Z\",\"customer\":{\"identified\":$identified}}", 201)
                }
            }
            r.path.endsWith("/unread") ->
                if (r.headers["x-zee-session-token"] == rejectedToken) error(401, "CHAT_SESSION_INVALID")
                else if (failUnread.getAndUpdate { (it - 1).coerceAtLeast(0) } > 0) error(401, unreadError) else ok("{\"unreadTotal\":3}")
            else -> error(404, "NOPE")
        }
    }

    private val holder = SessionHolder()
    private val data = LocalData(MemoryStore(), MemoryVault())
    private val tokens = AtomicInteger(0)
    private var provider: (suspend () -> String?)? = null

    private fun gateway(): SessionGateway {
        val api = ApiClient(server.url, "key", "1.0.0", null, holder::token)
        return SessionGateway(api, holder, data, "install", { "en" }, { provider }, listener = { blocked += it }, onSessionSaved = { saved += it.token })
    }

    private fun unreadCalls() = server.requests.count { it.path.endsWith("/unread") }

    @After
    fun stop() = server.stop()

    @Test
    fun aGuestSessionIsCreatedOnceAndReused() = runBlocking {
        val g = gateway()
        assertEquals(3, g.authed { it.unread() })
        assertEquals(3, g.authed { it.unread() })
        assertEquals(1, sessions.get())
        val body = server.requests.first { it.path.endsWith("/session") }.body
        assertTrue(body.contains("\"platform\":\"android\""))
        assertTrue(body.contains("\"installId\":\"install\""))
    }

    @Test
    fun sessionInvalidDropsTheTokenCreatesANewSessionAndRetriesOnce() = runBlocking {
        val g = gateway()
        g.authed { it.unread() }
        failUnread.set(1)
        assertEquals(3, g.authed { it.unread() })
        assertEquals(2, sessions.get())
        assertEquals("tok_2", holder.token)
        assertEquals(3, unreadCalls())
    }

    @Test
    fun sessionRequiredAlsoRetriesOnce() = runBlocking {
        unreadError = "CHAT_SESSION_REQUIRED"
        val g = gateway()
        g.authed { it.unread() }
        failUnread.set(1)
        assertEquals(3, g.authed { it.unread() })
        assertEquals(2, sessions.get())
    }

    @Test
    fun aSecondFailureIsNotRetriedAgain() = runBlocking {
        val g = gateway()
        g.authed { it.unread() }
        val before = unreadCalls()
        failUnread.set(5)
        try {
            g.authed { it.unread() }
            fail("expected an error")
        } catch (e: ApiException) {
            assertEquals(ChatErrorCode.SESSION_INVALID, e.code)
        }
        assertEquals(2, unreadCalls() - before)
    }

    @Test
    fun identityInvalidAsksTheProviderAgainOnce() = runBlocking {
        provider = { "jwt-${tokens.incrementAndGet()}" }
        failSessions.set(1)
        gateway().ensureSession()
        assertEquals(2, tokens.get())
        assertEquals(2, server.requests.count { it.path.endsWith("/session") })
        assertTrue(server.requests.last { it.path.endsWith("/session") }.body.contains("jwt-2"))
    }

    @Test
    fun identityInvalidTwiceIsLoginNeeded() = runBlocking {
        provider = { "jwt-${tokens.incrementAndGet()}" }
        failSessions.set(2)
        try {
            gateway().ensureSession()
            fail("expected login needed")
        } catch (_: LoginNeededException) {
        }
        assertEquals(2, tokens.get())
        assertTrue(Blocked.LOGIN_NEEDED in blocked)
        assertNull(holder.record)
    }

    @Test
    fun guestsDisabledIsLoginNeeded() = runBlocking {
        sessionError = "CHAT_GUESTS_DISABLED"
        failSessions.set(1)
        try {
            gateway().ensureSession()
            fail("expected login needed")
        } catch (_: LoginNeededException) {
        }
        assertTrue(Blocked.LOGIN_NEEDED in blocked)
    }

    @Test
    fun appKeyInvalidIsUnavailableAndStops() = runBlocking {
        sessionError = "CHAT_APP_KEY_INVALID"
        failSessions.set(1)
        try {
            gateway().ensureSession()
            fail("expected an error")
        } catch (e: ApiException) {
            assertEquals(ChatErrorCode.APP_KEY_INVALID, e.code)
        }
        assertTrue(Blocked.UNAVAILABLE in blocked)
    }

    @Test
    fun aTokenProviderThatReturnsNothingIsLoginNeeded() = runBlocking {
        provider = { null }
        try {
            gateway().ensureSession()
            fail("expected login needed")
        } catch (_: LoginNeededException) {
        }
        assertEquals(0, server.requests.size)
    }

    @Test
    fun twoCallsThatFailOnTheSameOldTokenCreateOnlyOneNewSession() = runBlocking {
        val g = gateway()
        g.ensureSession()
        rejectedToken = "tok_1"
        val results = (1..2).map { async(Dispatchers.Default) { g.authed { it.unread() } } }.awaitAll()
        assertEquals(listOf(3, 3), results)
        assertEquals("exactly one POST /session after the first", 2, server.requests.count { it.path.endsWith("/session") })
        assertEquals("tok_2", holder.token)
    }

    @Test
    fun everyNewSessionIsReportedSoThePushTokenCanBeRegisteredAgain() = runBlocking {
        val g = gateway()
        g.authed { it.unread() }
        assertEquals(listOf("tok_1"), saved.toList())
        failUnread.set(1)
        g.authed { it.unread() }
        assertEquals(listOf("tok_1", "tok_2"), saved.toList())
    }
}
