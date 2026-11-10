import XCTest
@testable import ZellioChatCore

final class PolicyTests: XCTestCase {
    // MARK: Consent

    private func config(required: Bool, version: String) throws -> ChatConfig {
        var config = try ChatConfig.parse(try Fixtures.data("config"))
        config.snapshot.behavior.consentRequired = required
        config.snapshot.versionId = version
        return config
    }

    func testConsentGate() throws {
        let storage = MemoryStorage()
        let store = ConsentStore(storage: storage)
        let required = try config(required: true, version: "v1")
        XCTAssertEqual(ConsentGate.state(config: required, store: store), .required)
        XCTAssertFalse(ConsentGate.allowsSession(config: required, store: store), "no session before Accept")
        XCTAssertFalse(ConsentGate.allowsSession(config: nil, store: store), "no session without a config")
        store.accept(ConsentTerms(behavior: required.snapshot.behavior))
        XCTAssertEqual(ConsentGate.state(config: required, store: store), .granted)
        XCTAssertTrue(ConsentGate.allowsSession(config: required, store: ConsentStore(storage: storage)), "saved per install")
        var newer = try config(required: true, version: "v2")
        XCTAssertEqual(ConsentGate.state(config: newer, store: store), .granted, "a publish with the same terms does not ask again")
        newer.snapshot.behavior.consentText.en = "We sell your messages."
        XCTAssertEqual(ConsentGate.state(config: newer, store: store), .required, "new text asks again")
        var newLink = try config(required: true, version: "v3")
        newLink.snapshot.behavior.privacyUrl = "https://brand.example/new"
        XCTAssertEqual(ConsentGate.state(config: newLink, store: store), .required, "a new privacy link asks again")
        let none = try config(required: false, version: "v3")
        XCTAssertEqual(ConsentGate.state(config: none, store: store), .notRequired)
        XCTAssertTrue(ConsentGate.allowsSession(config: none, store: store))
    }

    func testConsentTextFallsBackToTheStringsTable() throws {
        var required = try config(required: true, version: "v1")
        XCTAssertEqual(required.consentText(locale: .en), "We store your messages and share them with our support team.")
        required.snapshot.behavior.consentText = LocalizedText()
        XCTAssertEqual(required.consentText(locale: .ar), ChatStrings(locale: .ar).string("consent.default"))
    }

    // MARK: Locale

    func testLocaleChoice() {
        let both = LanguagePolicy.both(defaultLocale: .ar, startIn: "browser")
        XCTAssertEqual(LocaleChoice.choose(option: .en, policy: both, deviceLanguageCode: "ar"), .en, "the code option wins")
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: .single(.en), deviceLanguageCode: "ar"), .en, "single wins over the device")
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: both, deviceLanguageCode: "ar-EG"), .ar)
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: both, deviceLanguageCode: "en_US"), .en)
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: both, deviceLanguageCode: "fr"), .ar, "other device language: defaultLocale")
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: .both(defaultLocale: .en, startIn: "ar"), deviceLanguageCode: "en"), .ar)
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: .both(defaultLocale: .ar, startIn: "en"), deviceLanguageCode: "ar"), .en)
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: nil, deviceLanguageCode: "ar"), .ar)
        XCTAssertEqual(LocaleChoice.choose(option: nil, policy: nil, deviceLanguageCode: nil), .en)
    }

    // MARK: Contrast and palette

    func testContrastPortMatchesWebImplementation() {
        let purple = HexColor("#7D3BED") ?? .black
        XCTAssertEqual(Contrast.luminance(.white), 1, accuracy: 0.0001)
        XCTAssertEqual(Contrast.luminance(.black), 0, accuracy: 0.0001)
        XCTAssertEqual(Contrast.ratio(.black, .white), 21, accuracy: 0.0001)
        XCTAssertEqual(Contrast.readable(on: purple).foreground, .white)
        let yellow = HexColor("#FFC53D") ?? .black
        XCTAssertEqual(Contrast.readable(on: yellow).foreground, .black)
        for hex in ["#7D3BED", "#FFC53D", "#0B5D4B", "#FF5A8A", "#00A3FF", "#777777", "#FFFFFF", "#000000", "#808080"] {
            let color = HexColor(hex) ?? .black
            XCTAssertGreaterThanOrEqual(Contrast.readable(on: color).ratio, 4.5, hex)
        }
    }

    func testBrandSurfaceDarkensMidTonesUntilWhiteTextPasses() {
        let pink = HexColor("#FF5A8A") ?? .black
        let surface = Contrast.brandSurface(pink)
        XCTAssertEqual(surface.foreground, .white)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(surface.background, .white), 4.5)
        let sun = HexColor("#FFC53D") ?? .black
        XCTAssertEqual(Contrast.brandSurface(sun).foreground, .black)
        XCTAssertEqual(Contrast.brandSurface(sun).background, sun)
    }

    func testHexParsing() {
        XCTAssertEqual(HexColor("#0b5d4b")?.hex, "#0B5D4B")
        XCTAssertNil(HexColor("#12345"))
        XCTAssertNil(HexColor("red"))
        XCTAssertEqual(HexColor("#FFFFFF").map { Contrast.darken($0, percent: 18).hex }, "#D1D1D1")
    }

    func testPaletteFollowsSpecTable() {
        var appearance = Appearance()
        appearance.primaryColor = "#7D3BED"
        appearance.customerMessageColor = "#7D3BED"
        appearance.surfaceColor = "#FFFFFF"
        let light = ChatPalette.resolve(appearance: appearance, systemDark: false)
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.ink.hex, "#111426")
        XCTAssertEqual(light.ink2.hex, "#50556B")
        XCTAssertEqual(light.line.hex, "#E7E7EF")
        XCTAssertEqual(light.agentBubble.hex, "#F1F1F6")
        XCTAssertEqual(light.ok.hex, "#16A34A")
        XCTAssertEqual(light.bad.hex, "#D92D32")
        XCTAssertEqual(light.onPrimary, .white)
        let dark = ChatPalette.resolve(appearance: appearance, systemDark: true)
        XCTAssertTrue(dark.isDark)
        XCTAssertEqual(dark.bg.hex, "#0F1525")
        XCTAssertEqual(dark.bgAlt.hex, "#161D30")
        XCTAssertEqual(dark.ink.hex, "#F4F6FC")
        XCTAssertEqual(dark.agentBubble.hex, "#1E2740")
        XCTAssertEqual(dark.ok.hex, "#34D399")
        XCTAssertEqual(dark.bad.hex, "#F87171")
        // A code override wins over the system and over the snapshot.
        appearance.theme = .light
        XCTAssertFalse(ChatPalette.resolve(appearance: appearance, systemDark: true).isDark)
        XCTAssertTrue(ChatPalette.resolve(appearance: appearance, systemDark: false, override: .dark).isDark)
    }

    func testDarkSurfaceInLightModePicksLightInk() {
        var appearance = Appearance()
        appearance.surfaceColor = "#101820"
        let palette = ChatPalette.resolve(appearance: appearance, systemDark: false)
        XCTAssertFalse(palette.isDark)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(palette.ink, palette.bg), 4.5)
    }

    func testLinkColorRule() {
        var appearance = Appearance()
        appearance.primaryColor = "#7D3BED"
        XCTAssertEqual(ChatPalette.resolve(appearance: appearance, systemDark: false).link.hex, "#7D3BED", "4.5:1 on white")
        XCTAssertEqual(ChatPalette.resolve(appearance: appearance, systemDark: true).link, ChatPalette.resolve(appearance: appearance, systemDark: true).ink, "purple is under 4.5:1 on the dark bg")
        appearance.primaryColor = "#FFC53D"
        let sun = ChatPalette.resolve(appearance: appearance, systemDark: false)
        XCTAssertEqual(sun.link, sun.ink)
    }

    func testMetrics() {
        XCTAssertEqual(Metrics.bubbleRadius(.square), 8)
        XCTAssertEqual(Metrics.tailRadius(.square), 4)
        XCTAssertEqual(Metrics.bubbleRadius(.rounded), 20)
        XCTAssertEqual(Metrics.tailRadius(.rounded), 6)
        XCTAssertEqual(Metrics.senderGap(.compact), 8)
        XCTAssertEqual(Metrics.lineHeightMultiple(.ar), 1.45)
        XCTAssertEqual(Metrics.lineHeightMultiple(.en), 1.35)
    }

    // MARK: Strings

    func testStringsParityAndGeneratedTableMatchesDesignFile() throws {
        let design = try Fixtures.designStrings()
        let en = try XCTUnwrap(design["en"])
        let ar = try XCTUnwrap(design["ar"])
        XCTAssertEqual(Set(en.keys), Set(ar.keys), "English and Arabic have the same keys")
        XCTAssertEqual(ChatStrings.keys, Set(en.keys))
        XCTAssertEqual(ChatStrings.arabicKeys, Set(ar.keys))
        for (key, value) in en { XCTAssertEqual(ChatStrings(locale: .en).string(key), value, key) }
        for (key, value) in ar { XCTAssertEqual(ChatStrings(locale: .ar).string(key), value, key) }
        for (key, value) in ar { XCTAssertFalse(value.isEmpty, key) }
        XCTAssertEqual(ChatStrings(locale: .ar).string("no.such.key"), "no.such.key")
    }

    func testAccessibilitySummary() {
        XCTAssertEqual(ChatStrings(locale: .en).accessibilitySummary(sender: "Mona", text: "Hi", time: "10:00 AM", delivery: nil), "Mona, Hi, 10:00 AM")
        XCTAssertEqual(ChatStrings(locale: .en).accessibilitySummary(sender: "You", text: "Hi", time: "10:00 AM", delivery: "Sent"), "You, Hi, 10:00 AM, Sent")
    }

    // MARK: Push

    func testPushPayloadObjectAndJSONStringForms() {
        let object: [AnyHashable: Any] = ["aps": ["alert": "x"], "zellio": ["v": 1, "type": "message", "conversationId": "c1", "messageId": "m1"]]
        XCTAssertTrue(PushPayload.isZellioPush(object))
        XCTAssertEqual(PushPayload.parse(object), ZellioPush(version: 1, type: "message", conversationId: "c1", messageId: "m1"))
        let string: [AnyHashable: Any] = ["zellio": "{\"v\":1,\"type\":\"message\",\"conversationId\":\"c2\",\"messageId\":\"m2\"}"]
        XCTAssertTrue(PushPayload.isZellioPush(string))
        XCTAssertEqual(PushPayload.parse(string)?.conversationId, "c2")
        let other: [AnyHashable: Any] = ["aps": ["alert": "x"], "type": "message"]
        XCTAssertFalse(PushPayload.isZellioPush(other))
        XCTAssertNil(PushPayload.parse(other))
        XCTAssertTrue(PushPayload.isZellioPush(["zellio": "garbage"]), "only the key decides")
        XCTAssertNil(PushPayload.parse(["zellio": "garbage"]))
    }

    // MARK: Unread

    func testUnreadTrackerNotifiesOnChangeOnly() {
        let tracker = UnreadTracker()
        let seen = Locked<[Int]>([])
        let token = tracker.add { value in seen.with { $0.append(value) } }
        tracker.set(2)
        tracker.set(2)
        tracker.set(-5)
        tracker.remove(token)
        tracker.set(9)
        XCTAssertEqual(seen.snapshot, [0, 2, 0])
        XCTAssertEqual(tracker.count, 9)
    }
}
