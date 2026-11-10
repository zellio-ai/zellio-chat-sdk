package ai.zellio.chat

import ai.zellio.chat.internal.core.PushParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PublicApiTest {
    @Test
    fun bannerOptionsDefaultToOn() {
        val options = ZellioChatOptions.Builder().build()
        assertTrue(options.showsInAppBanner)
        assertTrue(options.bannerShowsPreview)
    }

    @Test
    fun bannerOptionsCanBeTurnedOff() {
        val options = ZellioChatOptions.Builder().showsInAppBanner(false).bannerShowsPreview(false).build()
        assertFalse(options.showsInAppBanner)
        assertFalse(options.bannerShowsPreview)
        assertEquals(ZellioChatOptions.DEFAULT_BASE_URL, options.baseUrl)
    }

    @Test
    fun jsonPayloadParsesLikeTheMapPayload() {
        val map = PushParser.toMap("""{"zellio":"{\"v\":1,\"conversationId\":\"conv_1\"}","other":"x"}""")
        assertTrue(PushParser.isOurs(map))
        assertEquals("conv_1", PushParser.parse(map)?.conversationId)
        assertFalse(PushParser.isOurs(PushParser.toMap("""{"other":"x"}""")))
        assertEquals(null, PushParser.toMap("not json"))
    }

    @Test
    fun anotherSdksArrayDoesNotHideOurPush() {
        val map = PushParser.toMap("""{"zellio":{"v":1,"conversationId":"conv_1"},"tags":["a","b"]}""")
        assertTrue(PushParser.isOurs(map))
        assertEquals("conv_1", PushParser.parse(map)?.conversationId)
    }
}
