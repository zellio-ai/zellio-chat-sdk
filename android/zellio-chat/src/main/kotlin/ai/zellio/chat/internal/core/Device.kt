package ai.zellio.chat.internal.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Registers the push token for the current session. The server forgets the token on every new session, so this
 * runs after each one, but a screen that opens does not cause another PUT: the last registered combination of
 * session token, push token, environment and language is remembered.
 */
internal class DeviceRegistrar(
    private val gateway: SessionGateway,
    private val holder: SessionHolder,
    private val push: () -> PushRegistration?,
    private val locale: () -> String,
    private val appVersion: String?,
) {
    private data class Key(val session: String, val push: String, val environment: String?, val locale: String)

    private val mutex = Mutex()

    @Volatile
    private var last: Key? = null

    /** Forget what was registered (logout, customer switch). */
    internal fun reset() {
        last = null
    }

    internal suspend fun register() {
        val reg = push() ?: return
        mutex.withLock {
            val session = holder.token ?: return
            val wanted = Key(session, reg.token, reg.environment, locale())
            if (last == wanted) return
            try {
                gateway.authed { it.putDevice(DeviceRequest(reg.provider, reg.token, reg.environment, wanted.locale, appVersion)) }
                // The call may have run on a newer session (recovery inside authed): remember the one it really used.
                last = holder.token?.let { Key(it, reg.token, reg.environment, wanted.locale) }
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                Log.w("device registration failed", t)
            }
        }
    }
}
