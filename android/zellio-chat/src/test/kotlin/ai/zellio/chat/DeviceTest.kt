package ai.zellio.chat

import ai.zellio.chat.internal.core.ApiClient
import ai.zellio.chat.internal.core.CappedCopy
import ai.zellio.chat.internal.core.DeviceRegistrar
import ai.zellio.chat.internal.core.FileNames
import ai.zellio.chat.internal.core.LocalData
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.MemoryVault
import ai.zellio.chat.internal.core.PushRegistration
import ai.zellio.chat.internal.core.SessionGateway
import ai.zellio.chat.internal.core.SessionHolder
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger

class DeviceTest {
    private val sessions = AtomicInteger(0)

    @Volatile
    private var rejected: String? = null
    private val server = FakeServer { r ->
        when {
            r.path.endsWith("/session") -> ok("{\"sessionToken\":\"tok_${sessions.incrementAndGet()}\",\"expiresAt\":\"2099-01-01T00:00:00.000Z\",\"customer\":{\"identified\":false}}", 201)
            r.path.endsWith("/device") ->
                if (r.headers["x-zee-session-token"] == rejected) error(401, "CHAT_SESSION_INVALID") else ok("{}")
            else -> error(404, "NOPE")
        }
    }
    private val holder = SessionHolder()
    private var push: PushRegistration? = PushRegistration("fcm", "push-1")
    private val gateway = SessionGateway(
        ApiClient(server.url, "key", "1.0.0", null, holder::token),
        holder, LocalData(MemoryStore(), MemoryVault()), "install", { "en" }, { null },
    )
    private val registrar = DeviceRegistrar(gateway, holder, { push }, { "en" }, "1.0")

    private fun puts() = server.requests.count { it.method == "PUT" && it.path.endsWith("/device") }

    @After
    fun stop() = server.stop()

    @Test
    fun openingScreensAgainDoesNotRegisterAgain() = runBlocking {
        gateway.ensureSession()
        registrar.register()
        registrar.register()
        registrar.register()
        assertEquals(1, puts())
    }

    @Test
    fun aNewPushTokenOrANewSessionRegistersAgain() = runBlocking {
        gateway.ensureSession()
        registrar.register()
        push = PushRegistration("fcm", "push-2")
        registrar.register()
        assertEquals(2, puts())
        // the session is replaced: the server forgot the push token
        rejected = "tok_1"
        holder.record = null
        gateway.ensureSession()
        rejected = null
        registrar.register()
        assertEquals(3, puts())
    }

    @Test
    fun recoveryInsideTheCallRegistersOnceOnTheNewSession() = runBlocking {
        gateway.ensureSession()
        rejected = "tok_1"
        registrar.register()
        assertEquals("tok_2", holder.token)
        assertEquals(2, puts())
        registrar.register()
        assertEquals("nothing more to do", 2, puts())
    }

    @Test
    fun resetForgetsWhatWasRegistered() = runBlocking {
        gateway.ensureSession()
        registrar.register()
        registrar.reset()
        registrar.register()
        assertEquals(2, puts())
    }

    @Test
    fun noPushTokenMeansNoCall() = runBlocking {
        push = null
        gateway.ensureSession()
        registrar.register()
        assertEquals(0, puts())
    }

    @Test
    fun aCopyStopsAtTheCap() {
        val out = ByteArrayOutputStream()
        assertTrue(CappedCopy.copy(ByteArrayInputStream(ByteArray(100)), out, 100))
        assertEquals(100, out.size())
        val big = ByteArrayOutputStream()
        assertFalse(CappedCopy.copy(ByteArrayInputStream(ByteArray(101)), big, 100))
        assertTrue("never writes past the cap", big.size() <= 100)
    }

    @Test
    fun aShrunkPhotoGetsAJpegName() {
        assertEquals("IMG_1.jpg", FileNames.withJpegExtension("IMG_1.png"))
        assertEquals("a.b.jpg", FileNames.withJpegExtension("a.b.webp"))
        assertEquals("photo.jpg", FileNames.withJpegExtension("photo"))
    }
}
