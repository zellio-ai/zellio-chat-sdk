package ai.zellio.chat.internal.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Stable error codes of contract v1. */
internal enum class ChatErrorCode(internal val wire: String) {
    APP_KEY_INVALID("CHAT_APP_KEY_INVALID"),
    APP_DISABLED("CHAT_APP_DISABLED"),
    ENTITLEMENT_DENIED("CHAT_ENTITLEMENT_DENIED"),
    SESSION_INVALID("CHAT_SESSION_INVALID"),
    SESSION_REQUIRED("CHAT_SESSION_REQUIRED"),
    IDENTITY_INVALID("CHAT_IDENTITY_INVALID"),
    GUESTS_DISABLED("CHAT_GUESTS_DISABLED"),
    CONVERSATION_NOT_FOUND("CHAT_CONVERSATION_NOT_FOUND"),
    FILE_TOO_LARGE("CHAT_FILE_TOO_LARGE"),
    FILE_TYPE_DENIED("CHAT_FILE_TYPE_DENIED"),
    FILES_DISABLED("CHAT_FILES_DISABLED"),
    ATTACHMENT_NOT_FOUND("CHAT_ATTACHMENT_NOT_FOUND"),
    RATE_LIMITED("CHAT_RATE_LIMITED"),
    SDK_TOO_OLD("CHAT_SDK_TOO_OLD"),
    SITE_NOT_FOUND("CHAT_SITE_NOT_FOUND"),
    ;

    internal companion object {
        internal fun fromWire(code: String?): ChatErrorCode? = entries.firstOrNull { it.wire == code }
    }
}

/** Codes of the public `error(code)` event. The same words as iOS (`ChatError.eventCode`), never a server code. */
internal object PublicErrorCode {
    internal const val UNAVAILABLE: String = "unavailable"
    internal const val RATE_LIMITED: String = "rate_limited"
    internal const val SEND_FAILED: String = "send_failed"
}

/** What the SDK does about an error. One place, so every code is handled the same way everywhere. */
internal enum class Reaction {
    /** Stop. Log a developer error. Show "chat is not available". */
    UNAVAILABLE,

    /** Delete the token (if any), create a session, retry once. */
    NEW_SESSION,

    /** Ask the token provider again, once. A second failure shows the login-needed state. */
    FRESH_IDENTITY,

    /** Show the login-needed state. */
    LOGIN_NEEDED,

    /** Reload the conversation list. */
    RELOAD_CONVERSATIONS,
    FILE_TOO_LARGE,
    FILE_TYPE_DENIED,

    /** Hide the attach control. */
    HIDE_ATTACH,

    /** Back off, obey Retry-After, keep queued messages. */
    BACK_OFF,

    /** Nothing special: show a generic error. */
    NONE,
}

internal class ApiException(
    internal val status: Int,
    internal val code: ChatErrorCode?,
    internal val rawCode: String?,
    internal val retryAfterSeconds: Long? = null,
) : Exception("HTTP $status ${rawCode ?: ""}".trim()) {

    internal val reaction: Reaction
        get() = when (code) {
            ChatErrorCode.APP_KEY_INVALID, ChatErrorCode.APP_DISABLED, ChatErrorCode.ENTITLEMENT_DENIED,
            ChatErrorCode.SDK_TOO_OLD, ChatErrorCode.SITE_NOT_FOUND,
            -> Reaction.UNAVAILABLE
            ChatErrorCode.SESSION_INVALID, ChatErrorCode.SESSION_REQUIRED -> Reaction.NEW_SESSION
            ChatErrorCode.IDENTITY_INVALID -> Reaction.FRESH_IDENTITY
            ChatErrorCode.GUESTS_DISABLED -> Reaction.LOGIN_NEEDED
            ChatErrorCode.CONVERSATION_NOT_FOUND -> Reaction.RELOAD_CONVERSATIONS
            ChatErrorCode.FILE_TOO_LARGE -> Reaction.FILE_TOO_LARGE
            ChatErrorCode.FILE_TYPE_DENIED -> Reaction.FILE_TYPE_DENIED
            ChatErrorCode.FILES_DISABLED -> Reaction.HIDE_ATTACH
            // The sender uploads the file again once; after that the message fails.
            ChatErrorCode.ATTACHMENT_NOT_FOUND -> Reaction.NONE
            ChatErrorCode.RATE_LIMITED -> Reaction.BACK_OFF
            null -> when {
                status == 429 -> Reaction.BACK_OFF
                // No code at all: this came from a proxy, not from Zellio. A failed request, nothing more.
                rawCode == null -> Reaction.NONE
                status == 401 -> Reaction.NEW_SESSION
                status == 403 -> Reaction.UNAVAILABLE
                else -> Reaction.NONE
            }
        }

    /** A 4xx that is not 401 or 429 can never succeed on a retry. */
    internal val isPermanent: Boolean get() = status in 400..499 && status != 401 && status != 429 && status != 408
}

/** Transport failure (no network, timeout, reset). Always retryable. */
internal class NetworkException(cause: Throwable) : Exception(cause.javaClass.simpleName)

/** The login-needed state: the identity could not be proven or guests are disabled. */
internal class LoginNeededException : Exception("login needed")

/** Consent is required and not given yet, or the config was not read yet: no session may start. */
internal class ConsentRequiredException : Exception("consent required")

internal object ErrorBodies {
    /**
     * Reads the code from `{ "code": ... }` and from `{ "error": { "code": ... } }`.
     * Also accepts `{ "error": "CHAT_..." }`.
     */
    internal fun codeOf(body: String?): String? {
        if (body.isNullOrBlank()) return null
        val root = try {
            ChatJson.parseToJsonElement(body)
        } catch (_: Exception) {
            return null
        }
        if (root !is JsonObject) return null
        root["code"].asText()?.let { return it }
        val error = root["error"]
        if (error is JsonObject) {
            error["code"].asText()?.let { return it }
        } else {
            error.asText()?.takeIf { it.startsWith("CHAT_") }?.let { return it }
        }
        return null
    }

    private fun kotlinx.serialization.json.JsonElement?.asText(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf { it.isNotBlank() }

    internal fun parse(status: Int, body: String?, retryAfterHeader: String?): ApiException {
        val raw = codeOf(body)
        return ApiException(status, ChatErrorCode.fromWire(raw), raw, retryAfterHeader?.trim()?.toLongOrNull()?.takeIf { it >= 0 })
    }
}
