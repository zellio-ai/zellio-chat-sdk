package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatJson
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class StringsTest {
    private val design = File(requireNotNull(System.getProperty("zellio.design.dir")), "strings.json")
    private val module = File(requireNotNull(System.getProperty("zellio.module.dir")))
    private val all = ChatJson.parseToJsonElement(design.readText(Charsets.UTF_8)).jsonObject

    private fun locale(name: String): Map<String, String> =
        all.getValue(name).jsonObject.mapValues { it.value.jsonPrimitive.content }

    private fun placeholders(text: String) = Regex("%(\\d\\$)?[sd]|\\{[a-zA-Z]+}").findAll(text).map { it.value }.sorted().toList()

    @Test
    fun englishAndEgyptianArabicHaveTheSameKeys() {
        val en = locale("en")
        val ar = locale("ar")
        assertEquals("missing in ar: " + (en.keys - ar.keys), emptySet<String>(), en.keys - ar.keys)
        assertEquals("missing in en: " + (ar.keys - en.keys), emptySet<String>(), ar.keys - en.keys)
    }

    @Test
    fun noStringIsEmptyAndArabicIsReallyArabic() {
        val en = locale("en")
        val ar = locale("ar")
        for ((k, v) in en) assertTrue("empty en: $k", v.isNotBlank())
        for ((k, v) in ar) {
            assertTrue("empty ar: $k", v.isNotBlank())
            if (k != "common.poweredBy" && k != "attachment.photo") {
                assertTrue("ar value for $k has no Arabic letters: $v", v.any { it in '؀'..'ۿ' } || en.getValue(k).none { it.isLetter() })
            }
        }
    }

    @Test
    fun placeholdersMatchBetweenLanguages() {
        val en = locale("en")
        val ar = locale("ar")
        for (k in en.keys) assertEquals("placeholders of $k", placeholders(en.getValue(k)), placeholders(ar.getValue(k)))
    }

    @Test
    fun theGeneratedResourcesAreInSyncWithTheDesignFile() {
        for ((tag, dir) in listOf("en" to "values", "ar" to "values-ar")) {
            val xml = File(module, "src/main/res/$dir/zc_strings.xml").readText(Charsets.UTF_8)
            val names = Regex("<string name=\"([a-z0-9_]+)\"").findAll(xml).map { it.groupValues[1] }.toList()
            assertEquals("string count in $dir", locale(tag).size, names.size)
            assertTrue(xml.contains("Generated from sdks/design/strings.json"))
            assertEquals(names.size, names.toSet().size)
        }
    }
}
