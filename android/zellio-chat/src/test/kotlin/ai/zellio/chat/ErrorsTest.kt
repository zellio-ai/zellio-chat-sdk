package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatErrorCode
import ai.zellio.chat.internal.core.ErrorBodies
import ai.zellio.chat.internal.core.Reaction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ErrorsTest {
    private val table = mapOf(
        401 to listOf("CHAT_APP_KEY_INVALID" to Reaction.UNAVAILABLE, "CHAT_SESSION_INVALID" to Reaction.NEW_SESSION, "CHAT_SESSION_REQUIRED" to Reaction.NEW_SESSION, "CHAT_IDENTITY_INVALID" to Reaction.FRESH_IDENTITY),
        403 to listOf("CHAT_APP_DISABLED" to Reaction.UNAVAILABLE, "CHAT_ENTITLEMENT_DENIED" to Reaction.UNAVAILABLE, "CHAT_GUESTS_DISABLED" to Reaction.LOGIN_NEEDED, "CHAT_FILES_DISABLED" to Reaction.HIDE_ATTACH),
        404 to listOf("CHAT_SITE_NOT_FOUND" to Reaction.UNAVAILABLE, "CHAT_CONVERSATION_NOT_FOUND" to Reaction.RELOAD_CONVERSATIONS, "CHAT_ATTACHMENT_NOT_FOUND" to Reaction.NONE),
        413 to listOf("CHAT_FILE_TOO_LARGE" to Reaction.FILE_TOO_LARGE),
        415 to listOf("CHAT_FILE_TYPE_DENIED" to Reaction.FILE_TYPE_DENIED),
        429 to listOf("CHAT_RATE_LIMITED" to Reaction.BACK_OFF),
        426 to listOf("CHAT_SDK_TOO_OLD" to Reaction.UNAVAILABLE),
    )

    @Test
    fun everyContractCodeHasItsReactionInBothBodyShapes() {
        var count = 0
        for ((status, codes) in table) for ((code, reaction) in codes) {
            val bodies = listOf("{\"code\":\"$code\",\"message\":\"m\"}", "{\"error\":{\"code\":\"$code\"}}")
            for (body in bodies) {
                val e = ErrorBodies.parse(status, body, null)
                assertEquals(code, e.rawCode)
                assertEquals(reaction, e.reaction)
            }
            count++
        }
        assertEquals(ChatErrorCode.entries.size, count)
    }

    @Test
    fun retryAfterIsRead() {
        assertEquals(7L, ErrorBodies.parse(429, "{\"code\":\"CHAT_RATE_LIMITED\"}", "7").retryAfterSeconds)
        assertNull(ErrorBodies.parse(429, "{\"code\":\"CHAT_RATE_LIMITED\"}", "soon").retryAfterSeconds)
    }

    @Test
    fun anUnknownCodeFollowsItsStatus() {
        val body = "{\"code\":\"CHAT_FUTURE_THING\"}"
        assertEquals(Reaction.NEW_SESSION, ErrorBodies.parse(401, body, null).reaction)
        assertEquals(Reaction.UNAVAILABLE, ErrorBodies.parse(403, body, null).reaction)
        assertEquals(Reaction.BACK_OFF, ErrorBodies.parse(429, body, null).reaction)
        assertEquals(Reaction.NONE, ErrorBodies.parse(500, body, null).reaction)
    }

    @Test
    fun aRefusalWithNoCodeCameFromAProxyAndChangesNothing() {
        assertEquals(Reaction.NONE, ErrorBodies.parse(401, "<html>", null).reaction)
        assertEquals(Reaction.NONE, ErrorBodies.parse(403, "<html>", null).reaction)
    }

    @Test
    fun aBareTooManyRequestsStillBacksOff() {
        assertEquals(Reaction.BACK_OFF, ErrorBodies.parse(429, "", null).reaction)
    }

    @Test
    fun permanentFailuresAreFourHundredsExceptRetryable() {
        assertTrue(ErrorBodies.parse(400, null, null).isPermanent)
        assertTrue(ErrorBodies.parse(422, null, null).isPermanent)
        assertFalse(ErrorBodies.parse(401, null, null).isPermanent)
        assertFalse(ErrorBodies.parse(429, null, null).isPermanent)
        assertFalse(ErrorBodies.parse(500, null, null).isPermanent)
    }

    @Test
    fun garbageBodiesGiveNoCode() {
        assertNull(ErrorBodies.codeOf("<html>"))
        assertNull(ErrorBodies.codeOf(null))
        assertNull(ErrorBodies.codeOf("{\"error\":\"boom\"}"))
        assertEquals("CHAT_APP_KEY_INVALID", ErrorBodies.codeOf("{\"error\":\"CHAT_APP_KEY_INVALID\"}"))
    }
}
