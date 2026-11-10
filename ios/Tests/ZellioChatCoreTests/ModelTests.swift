import XCTest
@testable import ZellioChatCore

final class ModelTests: XCTestCase {
    func testConfigFixtureSkipsUnknownModuleAndIgnoresUnknownFields() throws {
        let config = try ChatConfig.parse(try Fixtures.data("config"))
        XCTAssertEqual(config.snapshot.modules.map { $0.kind }, [.startConversation, .announcement, .externalLink])
        XCTAssertEqual(config.snapshot.versionId, "ver_1")
        XCTAssertEqual(config.snapshot.layout, .support)
        XCTAssertEqual(config.snapshot.appearance.primaryColor, "#7D3BED")
        XCTAssertEqual(config.snapshot.appearance.headerStyle, .gradient)
        XCTAssertTrue(config.snapshot.behavior.consentRequired)
        XCTAssertEqual(config.snapshot.behavior.privacyUrl, "https://shop.example/privacy")
        XCTAssertEqual(config.logoUrl, "https://cdn.example/logo.png")
        XCTAssertTrue(config.allowGuests)
        XCTAssertNil(config.minSdkVersion)
        XCTAssertEqual(config.snapshot.screens.heading.resolve(.ar), "إزاي نقدر نساعدك؟")
        XCTAssertEqual(config.snapshot.language, .both(defaultLocale: .ar, startIn: "browser"))
    }

    func testModuleVisibilityAndLocalizedFallback() {
        var module = HomeModule(id: "x", kind: .announcement, visibility: ModuleVisibility(locales: [.en], availability: "online", customer: "verified"))
        XCTAssertTrue(module.isVisible(locale: .en, online: true, verified: true))
        XCTAssertFalse(module.isVisible(locale: .ar, online: true, verified: true))
        XCTAssertFalse(module.isVisible(locale: .en, online: false, verified: true))
        XCTAssertFalse(module.isVisible(locale: .en, online: true, verified: false))
        module.visibility = ModuleVisibility()
        XCTAssertTrue(module.isVisible(locale: .ar, online: false, verified: false))
        XCTAssertEqual(LocalizedText(ar: "", en: "Hello").resolve(.ar), "Hello")
        XCTAssertEqual(LocalizedText(ar: "أهلاً", en: "Hello").resolve(.ar), "أهلاً")
        XCTAssertNil(LocalizedText().resolve(.en))
    }

    func testUnsafeLinkModulesAreSkipped() throws {
        let body = """
        {"data":{"snapshot":{"versionId":"v","modules":[
          {"id":"a","type":"external-link","label":{},"href":"javascript:alert(1)","visibility":{}},
          {"id":"b","type":"external-link","label":{},"href":"http://insecure.example","visibility":{}},
          {"id":"c","type":"contact-links","label":{},"links":[{"label":{"en":"Call"},"href":"tel:+20100"},{"label":{},"href":"ftp://x"}],"visibility":{}}
        ]}}}
        """
        let config = try ChatConfig.parse(Data(body.utf8))
        XCTAssertEqual(config.snapshot.modules.count, 1)
        XCTAssertEqual(config.snapshot.modules[0].links.count, 1)
        XCTAssertTrue(LinkPolicy.isSafe("mailto:a@b.co"))
        XCTAssertFalse(LinkPolicy.isSafe("http://a.co"))
    }

    func testMessagesFixtureSkipsUnknownFromAndKeepsAttachments() throws {
        let page = try JSONDecoder().decode(MessagesPageEnvelope.self, from: try Fixtures.data("messages")).data
        XCTAssertEqual(page.messages.map { $0.serverId }, ["msg_1", "msg_2"])
        XCTAssertEqual(page.messages[0].from, .visitor)
        XCTAssertEqual(page.messages[0].clientMessageId, "6f1c2a10-7a55-4f0c-9c55-1a2b3c4d5e6f")
        XCTAssertEqual(page.messages[0].stableId, "6f1c2a10-7a55-4f0c-9c55-1a2b3c4d5e6f")
        XCTAssertEqual(page.messages[1].attachments.first?.isImage, true)
        XCTAssertEqual(page.messages[1].stableId, "msg_2")
        XCTAssertEqual(page.nextBefore, "cursor_older")
        XCTAssertEqual(page.latest, "cursor_latest")
        XCTAssertEqual(page.conversationId, "conv_2")
    }

    func testBadItemsAreSkippedOneByOne() throws {
        let body = """
        {"data":{"messages":[ 42, {"id":"m1","from":"agent","text":"ok","createdAt":"2026-11-03T10:00:00.000Z"}, "x", {"from":"agent"} ],"nextBefore":null,"latest":null}}
        """
        let page = try JSONDecoder().decode(MessagesPageEnvelope.self, from: Data(body.utf8)).data
        XCTAssertEqual(page.messages.map { $0.serverId }, ["m1"])
    }

    func testConversationsFixture() throws {
        let page = try JSONDecoder().decode(ConversationsEnvelope.self, from: try Fixtures.data("conversations")).data
        XCTAssertEqual(page.conversations.count, 2)
        XCTAssertEqual(page.unreadTotal, 1)
        XCTAssertEqual(page.conversations[0].unread, 1)
        XCTAssertEqual(page.conversations[1].lastMessage?.hasAttachment, true)
        XCTAssertEqual(page.conversations[1].lastMessage?.attachmentKind, "image")
        XCTAssertNil(page.conversations[0].lastMessage?.attachmentKind)
        XCTAssertNil(page.nextCursor)
        XCTAssertNotNil(page.conversations[0].lastDate)
    }

    func testSessionAndAttachmentFixtures() throws {
        let session = try JSONDecoder().decode(SessionEnvelope.self, from: try Fixtures.data("session")).data
        XCTAssertEqual(session.sessionToken, "tok_abc")
        XCTAssertTrue(session.identified)
        XCTAssertEqual(session.customerName, "Mona Adel")
        let attachment = try JSONDecoder().decode(AttachmentEnvelope.self, from: try Fixtures.data("attachment")).data
        XCTAssertEqual(attachment.id, "att_1")
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.size, 48211)
    }

    func testContextIsSanitized() {
        let long = String(repeating: "a", count: 300)
        let clean = ChatContext(screen: long, itemType: nil, itemId: "1042", itemTitle: "T", url: "http://insecure.example").sanitized()
        XCTAssertEqual(clean?.screen?.count, 200)
        XCTAssertNil(clean?.url)
        XCTAssertEqual(clean?.itemId, "1042")
        XCTAssertNil(ChatContext().sanitized())
        XCTAssertEqual(ChatContext(url: "https://shop.example/o/1").sanitized()?.url, "https://shop.example/o/1")
    }

    func testSemVerAndMinimumVersion() {
        XCTAssertEqual(SemVer.compare("1.0.0", "1.0.1"), -1)
        XCTAssertEqual(SemVer.compare("1.2", "1.2.0"), 0)
        XCTAssertEqual(SemVer.compare("2.0.0", "1.9.9"), 1)
        var config = ChatConfig()
        config.minSdkVersion = "9.0.0"
        XCTAssertTrue(config.sdkTooOld)
        config.minSdkVersion = "1.0.0"
        XCTAssertFalse(config.sdkTooOld)
    }

    func testConfigCacheRoundTripAndCorruption() throws {
        let storage = MemoryStorage()
        let cache = ConfigCache(storage: storage)
        XCTAssertNil(cache.load())
        cache.save(body: try Fixtures.data("config"))
        XCTAssertEqual(cache.load()?.versionId, "ver_1")
        storage.write(StorageName.config, Data("garbage".utf8))
        XCTAssertNil(cache.load())
        XCTAssertNil(storage.read(StorageName.config))
    }

    func testClippingCountsUTF16UnitsAndNeverCutsACharacter() {
        let emoji = "😀"   // 2 UTF-16 units
        XCTAssertEqual(emoji.utf16.count, 2)
        let text = String(repeating: emoji, count: 150)   // 300 units
        let clipped = text.clipped(toUTF16: 201)
        XCTAssertEqual(clipped.utf16.count, 200, "the 101st emoji would pass the limit, so it is dropped whole")
        XCTAssertEqual(clipped, String(repeating: emoji, count: 100))
        XCTAssertEqual("abc".clipped(toUTF16: 10), "abc")
        XCTAssertEqual("a👨‍👩‍👧b".clipped(toUTF16: 3), "a", "a family emoji is one character and is not cut")
        let context = ChatContext(screen: text, itemTitle: "x", url: "https://shop.example/a").sanitized()
        XCTAssertEqual(context?.screen?.utf16.count, 200)
    }

    func testContextUrlNeedsLowercaseHttps() {
        XCTAssertNil(ChatContext(screen: "s", url: "HTTPS://shop.example/a").sanitized()?.url)
        XCTAssertNil(ChatContext(screen: "s", url: "http://shop.example/a").sanitized()?.url)
        XCTAssertEqual(ChatContext(screen: "s", url: "https://shop.example/a").sanitized()?.url, "https://shop.example/a")
    }
}
