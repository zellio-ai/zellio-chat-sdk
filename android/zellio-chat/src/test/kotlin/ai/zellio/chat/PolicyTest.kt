package ai.zellio.chat

import ai.zellio.chat.internal.core.Appearance
import ai.zellio.chat.internal.core.Backoff
import ai.zellio.chat.internal.core.Behavior
import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.ConsentGate
import ai.zellio.chat.internal.core.Contrast
import ai.zellio.chat.internal.core.DateLabels
import ai.zellio.chat.internal.core.Gate
import ai.zellio.chat.internal.core.IsoTime
import ai.zellio.chat.internal.core.LanguagePolicy
import ai.zellio.chat.internal.core.LocaleChooser
import ai.zellio.chat.internal.core.LocaleOption
import ai.zellio.chat.internal.core.LocalizedText
import ai.zellio.chat.internal.core.Palette
import ai.zellio.chat.internal.core.PushParser
import ai.zellio.chat.internal.core.SemVer
import ai.zellio.chat.internal.core.Snapshot
import ai.zellio.chat.internal.core.SseParser
import ai.zellio.chat.internal.core.ThemeOverrides
import ai.zellio.chat.internal.engine.ChatNavigator
import ai.zellio.chat.internal.engine.Route
import ai.zellio.chat.internal.engine.StartRoute
import ai.zellio.chat.internal.engine.ViewerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.io.StringReader
import java.util.TimeZone

class PolicyTest {
    // ---- SSE ----

    private fun parse(text: String): List<Pair<String, String>> {
        val out = mutableListOf<Pair<String, String>>()
        SseParser.readAll(BufferedReader(StringReader(text))) { out += it.event to it.data }
        return out
    }

    @Test
    fun aPingCommentIsIgnored() {
        assertEquals(emptyList<Pair<String, String>>(), parse(": ping\n\n: ping\n\n"))
    }

    @Test
    fun multiLineDataJoinsWithNewlines() {
        assertEquals(listOf("message" to "a\nb"), parse("data: a\ndata: b\n\n"))
    }

    @Test
    fun namedEventsAreDeliveredAndAnUnknownOneIsStillParsedForTheCallerToSkip() {
        val events = parse("event: ready\ndata: {\"conversationId\":null}\n\nevent: from-the-future\ndata: {}\n\nevent: unread\ndata: {\"unreadTotal\":2}\n\n")
        assertEquals(listOf("ready", "from-the-future", "unread"), events.map { it.first })
    }

    @Test
    fun anEventWithoutBlankLineIsNotDeliveredAndRetryFieldsAreIgnored() {
        assertEquals(emptyList<Pair<String, String>>(), parse("event: ready\ndata: x\n"))
        assertEquals(listOf("message" to "x"), parse("retry: 3000\ndata: x\n\n"))
    }

    // ---- backoff ----

    @Test
    fun backoffFollowsTheContractSteps() {
        val b = Backoff(jitter = 0.0)
        assertEquals(listOf(1000L, 2000L, 4000L, 8000L, 16000L, 30000L, 30000L), List(7) { b.nextDelayMs() })
        b.reset()
        assertEquals(1000L, b.nextDelayMs())
    }

    @Test
    fun backoffJitterStaysInsideTwentyPercent() {
        val low = Backoff(jitter = 0.2, random = { 0.0 }).nextDelayMs()
        val high = Backoff(jitter = 0.2, random = { 1.0 }).nextDelayMs()
        assertEquals(800L, low)
        assertEquals(1200L, high)
    }

    // ---- consent ----

    private fun snapshot(
        consent: Boolean,
        version: String = "v1",
        text: String = "We save this chat.",
        link: String = "https://brand.example/privacy",
    ) = Snapshot(
        versionId = version,
        behavior = Behavior(consentRequired = consent, consentText = LocalizedText(en = text), privacyUrl = link),
    )

    @Test
    fun consentGatesTheSession() {
        assertEquals(Gate.WAITING_FOR_CONFIG, ConsentGate.state(null, null))
        assertEquals(Gate.OPEN, ConsentGate.state(snapshot(false), null))
        assertEquals(Gate.NEEDS_CONSENT, ConsentGate.state(snapshot(true), null))
        val accepted = snapshot(true).behavior.consentTerms
        assertEquals(Gate.OPEN, ConsentGate.state(snapshot(true), accepted))
    }

    @Test
    fun aNewPublishAsksAgainOnlyWhenTheTermsChanged() {
        val accepted = snapshot(true).behavior.consentTerms
        assertEquals(Gate.OPEN, ConsentGate.state(snapshot(true, version = "v2"), accepted))
        assertEquals(Gate.NEEDS_CONSENT, ConsentGate.state(snapshot(true, version = "v2", text = "We sell this chat."), accepted))
        assertEquals(Gate.NEEDS_CONSENT, ConsentGate.state(snapshot(true, version = "v2", link = "https://brand.example/new"), accepted))
    }

    // ---- locale ----

    @Test
    fun localeFollowsOptionThenPolicyThenDevice() {
        val both = LanguagePolicy(mode = "both", defaultLocale = "ar", startIn = "browser")
        assertEquals(ChatLocale.AR, LocaleChooser.choose(LocaleOption.AR, both, "en"))
        assertEquals(ChatLocale.EN, LocaleChooser.choose(LocaleOption.EN, both, "ar"))
        assertEquals(ChatLocale.EN, LocaleChooser.choose(LocaleOption.AUTO, both, "en"))
        assertEquals(ChatLocale.AR, LocaleChooser.choose(LocaleOption.AUTO, both, "fr"))
        assertEquals(ChatLocale.AR, LocaleChooser.choose(LocaleOption.AUTO, LanguagePolicy(mode = "single", locale = "ar"), "en"))
        assertEquals(ChatLocale.AR, LocaleChooser.choose(LocaleOption.AUTO, null, "ar-EG"))
        assertEquals(ChatLocale.EN, LocaleChooser.choose(LocaleOption.AUTO, null, "de"))
    }

    @Test
    fun arabicIsTheOnlyRtlLocaleAndDigitsStayLatin() {
        assertTrue(ChatLocale.AR.rtl)
        assertFalse(ChatLocale.EN.rtl)
        val zone = TimeZone.getTimeZone("UTC")
        val ms = IsoTime.parse("2026-10-20T08:30:00.000Z")!!
        val ar = DateLabels.date(ms, ChatLocale.AR, ms + 1000, zone)
        assertTrue(ar, ar.any { it in '0'..'9' } && ar.none { it in '٠'..'٩' })
    }

    // ---- colors ----

    @Test
    fun contrastMatchesTheWcagFormula() {
        assertEquals(21.0, Contrast.ratio("#000000", "#FFFFFF"), 0.001)
        assertEquals(1.0, Contrast.ratio("#777777", "#777777"), 0.001)
        assertEquals("#FFFFFF", Contrast.readable("#7D3BED").foreground)
        assertEquals("#000000", Contrast.readable("#FFE066").foreground)
        assertTrue(Contrast.readable("#808080").ratio >= 4.5)
    }

    @Test
    fun linkColorIsThePrimaryOnlyWhenItReadsOnTheBackground() {
        val readable = Palette.build(Appearance(primaryColor = "#7D3BED"), ThemeOverrides(), false)
        assertEquals("#7D3BED", readable.link.uppercase())
        val faint = Palette.build(Appearance(primaryColor = "#FFE066"), ThemeOverrides(), false)
        assertEquals(faint.ink.uppercase(), faint.link.uppercase())
        assertTrue(Contrast.ratio(faint.link, faint.bg) >= 4.5)
    }

    @Test
    fun darkModeFollowsTheSystemWhenThemeIsAutoAndTheOverrideWhenSet() {
        assertTrue(Palette.build(Appearance(theme = "auto"), ThemeOverrides(), true).dark)
        assertFalse(Palette.build(Appearance(theme = "auto"), ThemeOverrides(), false).dark)
        assertTrue(Palette.build(Appearance(theme = "auto"), ThemeOverrides(mode = "dark"), false).dark)
        assertFalse(Palette.build(Appearance(theme = "auto"), ThemeOverrides(mode = "light"), true).dark)
    }

    // ---- small helpers ----

    @Test
    fun isoTimeParses() {
        assertEquals(0L, IsoTime.parse("1970-01-01T00:00:00Z"))
        assertEquals(1_000L + 123, IsoTime.parse("1970-01-01T00:00:01.123Z"))
        assertEquals(IsoTime.parse("2026-11-03T10:00:00.000Z"), IsoTime.parse("2026-11-03T12:00:00+02:00"))
        assertNull(IsoTime.parse("yesterday"))
        assertNull(IsoTime.parse(null))
    }

    @Test
    fun semverComparesNumerically() {
        assertTrue(SemVer.compare("1.0.0", "1.0.1") < 0)
        assertTrue(SemVer.compare("1.10.0", "1.9.9") > 0)
        assertEquals(0, SemVer.compare("v2.0", "2.0.0"))
        assertEquals(0, SemVer.compare("1.2.3-beta.1", "1.2.3"))
    }

    @Test
    fun pushPayloadParsesFromAFcmStringAndFromAMap() {
        val fcm = mapOf("zellio" to "{\"v\":1,\"type\":\"message\",\"conversationId\":\"c9\",\"messageId\":\"m9\"}", "other" to "x")
        assertTrue(PushParser.isOurs(fcm))
        assertEquals("c9", PushParser.parse(fcm)?.conversationId)
        val apns = mapOf("zellio" to mapOf("v" to 1, "type" to "message", "conversationId" to "c8"))
        assertEquals("c8", PushParser.parse(apns)?.conversationId)
        assertFalse(PushParser.isOurs(mapOf("other" to "x")))
        assertFalse(PushParser.isOurs(null))
        // the key alone marks the push as ours, even when the value is broken
        assertTrue(PushParser.isOurs(mapOf("zellio" to "not json")))
        assertNull(PushParser.parse(mapOf("zellio" to "not json")))
        assertEquals("c1", PushParser.parse(PushParser.toMap("{\"zellio\":{\"conversationId\":\"c1\"}}"))?.conversationId)
    }

    // ---- navigation ----

    @Test
    fun theStartRouteFollowsTheLayoutUnlessAConversationIsAsked() {
        assertEquals(Route.Home, StartRoute.forLayout("support", null, false))
        assertEquals(Route.Thread(null, resolveLatest = true), StartRoute.forLayout("chat-only", null, false))
        assertEquals(Route.Thread("c1"), StartRoute.forLayout("support", "c1", true))
        assertEquals(Route.Thread(null), StartRoute.forLayout("chat-only", null, true))
    }

    @Test
    fun backClosesTheViewerFirstThenPopsThenLeaves() {
        val nav = ChatNavigator(Route.Home)
        nav.push(Route.Thread("c1"))
        nav.openViewer(ViewerState("https://x/y.jpg", null, "y.jpg"))
        assertTrue(nav.back())
        assertNull(nav.viewer.value)
        assertEquals(Route.Thread("c1"), nav.top)
        assertTrue(nav.back())
        assertEquals(Route.Home, nav.top)
        assertFalse(nav.back())
    }

    @Test
    fun statusIconsFollowWhatIsUnderTheBar() {
        val light = Palette.build(Appearance(), ThemeOverrides(mode = "light"), false)
        assertFalse("white text on the violet header", light.darkStatusIcons(onHomeHeader = true))
        assertTrue("a light background", light.darkStatusIcons(onHomeHeader = false))

        val dark = Palette.build(Appearance(), ThemeOverrides(mode = "dark"), false)
        assertFalse(dark.darkStatusIcons(onHomeHeader = true))
        assertFalse(dark.darkStatusIcons(onHomeHeader = false))

        val lightHeader = Palette.build(Appearance(headerStyle = "light"), ThemeOverrides(mode = "light"), false)
        assertTrue("the header has the background color", lightHeader.darkStatusIcons(onHomeHeader = true))

        val yellow = Palette.build(Appearance(primaryColor = "#FFE066", headerStyle = "solid"), ThemeOverrides(mode = "light"), false)
        assertTrue("black text on a bright brand", yellow.darkStatusIcons(onHomeHeader = true))
    }
}
