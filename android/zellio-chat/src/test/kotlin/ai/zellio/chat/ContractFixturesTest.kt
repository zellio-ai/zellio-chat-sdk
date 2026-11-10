package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatJson
import ai.zellio.chat.internal.core.ConfigData
import ai.zellio.chat.internal.core.ConversationsData
import ai.zellio.chat.internal.core.Decoders
import ai.zellio.chat.internal.core.HomeModule
import ai.zellio.chat.internal.core.MessagesData
import ai.zellio.chat.internal.core.SessionData
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContractFixturesTest {
    private val config = ChatJson.decodeFromJsonElement(ConfigData.serializer(), Fixtures.data("config"))

    @Test
    fun configIgnoresUnknownFieldsAndReadsTheSnapshot() {
        val snapshot = config.snapshot!!
        assertEquals("ver_1", snapshot.versionId)
        assertEquals("Nile Store", snapshot.appearance.brandName)
        assertTrue(snapshot.behavior.consentRequired)
        assertEquals("https://shop.example/privacy", snapshot.behavior.privacyUrl)
    }

    @Test
    fun unknownHomeModuleIsSkippedAndTheRestKeepOrder() {
        val modules = Decoders.modules(config.snapshot!!.modules)
        assertEquals(listOf("m1", "m2", "m3"), modules.map { it.id })
        assertTrue(modules[0] is HomeModule.StartConversation)
        assertTrue(modules[1] is HomeModule.Announcement)
        assertTrue(modules[2] is HomeModule.ExternalLink)
    }

    @Test
    fun aBrokenModuleDoesNotHideTheOthers() {
        val broken = JsonArray(
            listOf(
                JsonPrimitive("not an object"),
                JsonObject(mapOf("type" to JsonPrimitive("external-link"), "id" to JsonPrimitive("x"), "href" to JsonPrimitive("javascript:alert(1)"))),
            ) + config.snapshot!!.modules,
        )
        val modules = Decoders.modules(broken)
        assertEquals(listOf("m1", "m2", "m3"), modules.map { it.id })
    }

    @Test
    fun unknownFromValueIsSkippedAndUnknownFieldsAreIgnored() {
        val data = ChatJson.decodeFromJsonElement(MessagesData.serializer(), Fixtures.data("messages"))
        val page = Decoders.messages(data)
        assertEquals(listOf("msg_1", "msg_2"), page.messages.map { it.id })
        assertEquals("cursor_older", page.nextBefore)
        assertEquals("cursor_latest", page.latest)
        assertTrue(page.messages[0].fromVisitor)
        assertEquals("6f1c2a10-7a55-4f0c-9c55-1a2b3c4d5e6f", page.messages[0].clientMessageId)
        assertEquals("receipt.jpg", page.messages[1].attachments.single().name)
        assertTrue(page.messages[1].attachments.single().isImage)
    }

    @Test
    fun conversationsDecode() {
        val page = Decoders.conversations(ChatJson.decodeFromJsonElement(ConversationsData.serializer(), Fixtures.data("conversations")))
        assertEquals(2, page.items.size)
        assertEquals(1, page.unreadTotal)
        assertEquals("conv_2", page.items[0].id)
        assertEquals(1, page.items[0].unread)
        assertTrue(page.items[1].lastHasAttachment)
        assertEquals("image", page.items[1].lastAttachmentKind)
        assertNull(page.items[0].lastAttachmentKind)
        assertTrue(page.items[1].lastFromVisitor)
        assertNull(page.nextCursor)
    }

    @Test
    fun sessionDecodes() {
        val s = ChatJson.decodeFromJsonElement(SessionData.serializer(), Fixtures.data("session"))
        assertEquals("tok_abc", s.sessionToken)
        assertTrue(s.customer.identified)
        assertEquals("Mona Adel", s.customer.name)
        assertFalse(s.sessionToken.isBlank())
    }
}
