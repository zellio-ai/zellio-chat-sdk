package ai.zellio.chat.internal.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/** The brand's async token provider. Returns a JWT, or null when the customer is logged out. */
internal typealias IdentityProvider = suspend () -> String?

internal class SessionHolder {
    @Volatile
    internal var record: SessionRecord? = null
    internal val token: String? get() = record?.token
}

internal enum class Blocked { NONE, LOGIN_NEEDED, UNAVAILABLE }

internal fun interface GatewayListener {
    fun onBlocked(state: Blocked)
}

/** Reads `sub` from a JWT without verifying it (the server verifies). Only used to notice a switch of customer. */
internal object Jwt {
    internal fun subject(token: String): String? = try {
        val payload = token.split('.').getOrNull(1) ?: return null
        val json = ChatJson.parseToJsonElement(String(decodeBase64Url(payload), Charsets.UTF_8))
        ((json as? JsonObject)?.get("sub"))?.jsonPrimitive?.content?.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    internal fun decodeBase64Url(input: String): ByteArray {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        val out = java.io.ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (ch in input.trimEnd('=')) {
            val v = alphabet.indexOf(if (ch == '+') '-' else if (ch == '/') '_' else ch)
            require(v >= 0) { "bad base64" }
            buffer = (buffer shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }
}

/**
 * Sessions and the retry rules of the contract:
 * - `CHAT_SESSION_INVALID` / `CHAT_SESSION_REQUIRED`: (delete the token,) create a session, retry once.
 * - `CHAT_IDENTITY_INVALID`: ask the token provider again once; a second failure is the login-needed state.
 * - `CHAT_GUESTS_DISABLED`: login needed.
 * - app key, disabled, entitlement, SDK too old: unavailable.
 */
internal class SessionGateway(
    internal val api: ApiClient,
    private val holder: SessionHolder,
    private val data: LocalData,
    private val installId: String,
    private val localeTag: () -> String,
    private val identity: () -> IdentityProvider?,
    private val listener: GatewayListener = GatewayListener { },
    /** Runs before a session is created: fresh config read and consent given, or it throws. */
    private val beforeCreate: suspend () -> Unit = {},
    /** Runs after every new session is saved (the server forgets the push token of a plain new session). */
    private val onSessionSaved: (SessionRecord) -> Unit = {},
) {
    private val mutex = Mutex()

    internal fun current(): SessionRecord? = holder.record

    internal fun restore() {
        holder.record = data.loadSession()
    }

    /**
     * Returns the saved session, or creates one. A session is kept until the server answers CHAT_SESSION_INVALID: every
     * send moves its expiry forward and the client is not told, and a guest with a new session loses the old thread.
     */
    internal suspend fun ensureSession(): SessionRecord {
        holder.record?.let { return it }
        return mutex.withLock { holder.record ?: create() }
    }

    /** Runs [block] with a valid session. See the class comment for the retry rules. */
    internal suspend fun <T> authed(block: suspend (ApiClient) -> T): T {
        val used = ensureSession().token
        try {
            return block(api).also { listener.onBlocked(Blocked.NONE) }
        } catch (e: ApiException) {
            when (e.reaction) {
                Reaction.NEW_SESSION -> {
                    // Only the call that used the current token may drop it: a concurrent call may already have
                    // replaced it, and that new session must stay.
                    mutex.withLock {
                        if (holder.token == used) {
                            if (e.code == ChatErrorCode.SESSION_INVALID) dropToken()
                            holder.record = null
                        }
                    }
                    ensureSession()
                    return retryOnce(block)
                }
                else -> throw classify(e)
            }
        }
    }

    private suspend fun <T> retryOnce(block: suspend (ApiClient) -> T): T =
        try {
            block(api).also { listener.onBlocked(Blocked.NONE) }
        } catch (e: ApiException) {
            throw classify(e)
        }

    private fun classify(e: ApiException): ApiException {
        when (e.reaction) {
            Reaction.UNAVAILABLE -> listener.onBlocked(Blocked.UNAVAILABLE)
            Reaction.LOGIN_NEEDED -> listener.onBlocked(Blocked.LOGIN_NEEDED)
            else -> Unit
        }
        return e
    }

    private fun dropToken() {
        holder.record = null
        data.clearSession()
    }

    private suspend fun fetchToken(provider: IdentityProvider): String {
        val token = try {
            provider()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            Guard.report("token provider", t)
            null
        }
        if (token.isNullOrBlank()) {
            listener.onBlocked(Blocked.LOGIN_NEEDED)
            throw LoginNeededException()
        }
        return token
    }

    private suspend fun create(): SessionRecord {
        beforeCreate()
        val provider = identity()
        var token = provider?.let { fetchToken(it) }
        val data = try {
            api.createSession(request(token))
        } catch (e: ApiException) {
            when (e.reaction) {
                Reaction.FRESH_IDENTITY -> {
                    // One more token from the provider. If that fails too, the customer must log in.
                    token = fetchToken(provider ?: throw loginNeeded())
                    try {
                        api.createSession(request(token))
                    } catch (second: ApiException) {
                        if (second.reaction == Reaction.FRESH_IDENTITY || second.reaction == Reaction.LOGIN_NEEDED) throw loginNeeded()
                        throw classify(second)
                    }
                }
                Reaction.LOGIN_NEEDED -> throw loginNeeded()
                else -> throw classify(e)
            }
        }
        return save(data, token).also { listener.onBlocked(Blocked.NONE) }
    }

    /** Turns the guest session into a customer session with a new token (the old one stops working). */
    internal suspend fun identify(provider: IdentityProvider): SessionRecord {
        val first = fetchToken(provider)
        val result = try {
            authed { it.identify(first) }
        } catch (e: ApiException) {
            if (e.reaction != Reaction.FRESH_IDENTITY) throw e
            val second = fetchToken(provider)
            try {
                return save(authed { it.identify(second) }, second)
            } catch (again: ApiException) {
                if (again.reaction == Reaction.FRESH_IDENTITY) throw loginNeeded()
                throw again
            }
        }
        return save(result, first)
    }

    private fun loginNeeded(): LoginNeededException {
        listener.onBlocked(Blocked.LOGIN_NEEDED)
        return LoginNeededException()
    }

    private fun request(token: String?) = SessionRequest(installId, "android", localeTag(), token)

    private fun save(session: SessionData, token: String?): SessionRecord {
        if (session.sessionToken.isBlank()) throw ApiException(201, null, "BAD_BODY")
        val record = SessionRecord(
            token = session.sessionToken,
            identified = session.customer.identified,
            name = session.customer.name,
            sub = token?.let { Jwt.subject(it) },
        )
        holder.record = record
        data.saveSession(record)
        try {
            onSessionSaved(record)
        } catch (t: Throwable) {
            Guard.report("session saved", t)
        }
        return record
    }

    /** Ends the session on the server (best effort) and deletes the token. Local data is wiped by the caller. */
    internal suspend fun logout() {
        if (holder.token != null) {
            try {
                api.logout()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // the local data is deleted anyway
            }
        }
        holder.record = null
        data.clearSession()
    }
}
