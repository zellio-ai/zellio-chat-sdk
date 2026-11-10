import XCTest
@testable import ZellioChatCore

final class TimelineTests: XCTestCase {
    func testServerMessageReplacesLocalOneInPlace() {
        var timeline = Timeline()
        timeline.upsert(message("c1", nil, at: "2026-11-03T10:00:00.000Z", text: "first", delivery: .sending))
        timeline.upsert(message("c2", nil, at: "2026-11-03T10:00:05.000Z", text: "second", delivery: .sending))
        let ids = timeline.messages.map { $0.stableId }
        // The server copy of c1 has a slightly different time. It still keeps its place and its identity.
        var server = message("c1", "srv_1", at: "2026-11-03T10:00:07.000Z", text: "first")
        server.delivery = .sent
        XCTAssertTrue(timeline.upsert(server))
        XCTAssertEqual(timeline.messages.count, 2)
        XCTAssertEqual(timeline.messages.map { $0.stableId }, ids)
        XCTAssertEqual(timeline.messages[0].serverId, "srv_1")
        XCTAssertEqual(timeline.messages[0].delivery, .sent)
        XCTAssertEqual(timeline.messages[1].delivery, .sending)
        // The same server message again changes nothing.
        XCTAssertFalse(timeline.upsert(server))
    }

    func testNewServerMessagesGoByTimeAndLocalPendingStaysLast() {
        var timeline = Timeline()
        timeline.upsert(message(nil, "s1", from: .agent, at: "2026-11-03T10:00:00.000Z"))
        timeline.upsert(message("c1", nil, at: "2026-11-03T10:01:00.000Z", delivery: .waiting))
        timeline.upsert(message(nil, "s2", from: .agent, at: "2026-11-03T10:02:00.000Z"))   // later than the pending one
        XCTAssertEqual(timeline.messages.map { $0.stableId }, ["s1", "c1", "s2"])
        timeline.upsert(message(nil, "s0", from: .agent, at: "2026-11-03T09:00:00.000Z"))
        XCTAssertEqual(timeline.messages.map { $0.stableId }, ["s0", "s1", "c1", "s2"])
    }

    func testPagingMergesOlderPagesWithoutDuplicates() {
        var timeline = Timeline()
        let newest = MessagesPage(conversationId: "c", messages: [
            message(nil, "m3", from: .agent, at: "2026-11-03T10:03:00.000Z"),
            message(nil, "m4", from: .agent, at: "2026-11-03T10:04:00.000Z"),
        ], nextBefore: "cur_2", latest: "cur_latest")
        timeline.apply(page: newest, older: false, initial: true)
        XCTAssertEqual(timeline.nextBefore, "cur_2")
        XCTAssertEqual(timeline.latest, "cur_latest")
        XCTAssertTrue(timeline.hasOlder)

        let older = MessagesPage(conversationId: "c", messages: [
            message(nil, "m1", from: .agent, at: "2026-11-03T10:01:00.000Z"),
            message(nil, "m2", from: .agent, at: "2026-11-03T10:02:00.000Z"),
            message(nil, "m3", from: .agent, at: "2026-11-03T10:03:00.000Z"),   // overlap
        ], nextBefore: nil, latest: "ignored")
        timeline.apply(page: older, older: true)
        XCTAssertEqual(timeline.messages.map { $0.serverId }, ["m1", "m2", "m3", "m4"])
        XCTAssertNil(timeline.nextBefore)
        XCTAssertFalse(timeline.hasOlder)
        XCTAssertEqual(timeline.latest, "cur_latest", "an older page never moves the catch-up cursor")

        let catchUp = MessagesPage(conversationId: "c", messages: [message(nil, "m5", from: .agent, at: "2026-11-03T10:05:00.000Z")], nextBefore: "later-cursor-ignored", latest: "cur_2")
        timeline.apply(page: catchUp, older: false)
        XCTAssertEqual(timeline.messages.last?.serverId, "m5")
        XCTAssertEqual(timeline.latest, "cur_2")
        XCTAssertNil(timeline.nextBefore, "a newer page never moves the older cursor")
    }

    func testStoredHistoryIsLimitedTo200AndKeepsOnlyServerMessages() {
        var timeline = Timeline()
        for i in 0..<230 {
            let minute = String(format: "%02d", i % 60)
            let hour = String(format: "%02d", i / 60)
            timeline.upsert(message(nil, "m\(i)", from: .agent, at: "2026-11-03T\(hour):\(minute):00.000Z"))
        }
        timeline.upsert(message("local", nil, at: "2026-11-03T23:00:00.000Z", delivery: .waiting))
        let saved = timeline.persisted()
        XCTAssertEqual(saved.messages.count, 200)
        XCTAssertEqual(saved.messages.last?.serverId, "m229")
        XCTAssertFalse(saved.messages.contains { $0.clientMessageId == "local" })
        let data = try? JSONEncoder().encode(saved)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(Timeline.self, from: $0) }, saved)
    }

    func testDeliveryDoesNotChangeServerConfirmedMessages() {
        var timeline = Timeline()
        timeline.upsert(message("c1", "s1", at: "2026-11-03T10:00:00.000Z"))
        timeline.setDelivery(clientMessageId: "c1", .failed)
        XCTAssertEqual(timeline.messages[0].delivery, .sent)
    }

    func testRowsGroupWithinFiveMinutesAndShowDeliveryOnNewestVisitorOnly() {
        let zone = TimeZone(identifier: "UTC") ?? .current
        let now = ISODate.parse("2026-11-03T12:00:00.000Z") ?? Date()
        let messages = [
            message("v1", "a", from: .visitor, at: "2026-11-02T09:00:00.000Z"),
            message("v2", "b", from: .visitor, at: "2026-11-03T10:00:00.000Z"),
            message("v3", "c", from: .visitor, at: "2026-11-03T10:02:00.000Z"),
            ChatMessage(serverId: "d", clientMessageId: nil, from: .agent, text: "hi", createdAt: "2026-11-03T10:03:00.000Z", agentName: "Mona"),
            ChatMessage(serverId: "e", clientMessageId: nil, from: .agent, text: "again", createdAt: "2026-11-03T10:03:30.000Z", agentName: "Mona"),
            message("v4", "f", from: .visitor, at: "2026-11-03T10:20:00.000Z", delivery: .waiting),
        ]
        let rows = ThreadLayout.rows(messages: messages, typing: true, typingName: nil, now: now, locale: .en, timeZone: zone)
        var labels: [String] = []
        var rowsByMessage: [String: MessageRow] = [:]
        for row in rows {
            switch row {
            case .date(_, let label): labels.append(label)
            case .message(let m): rowsByMessage[m.message.stableId] = m
            case .typing: labels.append("typing")
            }
        }
        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(Array(labels.suffix(2)), ["Today", "typing"])
        XCTAssertEqual(rowsByMessage["v2"]?.startsGroup, true)
        XCTAssertEqual(rowsByMessage["v2"]?.endsGroup, false)
        XCTAssertEqual(rowsByMessage["v3"]?.startsGroup, false)
        XCTAssertEqual(rowsByMessage["v3"]?.endsGroup, true)
        XCTAssertEqual(rowsByMessage["d"]?.showsName, true)
        XCTAssertEqual(rowsByMessage["e"]?.showsName, false)
        XCTAssertEqual(rowsByMessage["e"]?.endsGroup, true)
        XCTAssertEqual(rowsByMessage["v4"]?.startsGroup, true, "a gap of more than 5 minutes starts a new group")
        XCTAssertEqual(rowsByMessage["v4"]?.showsDelivery, true)
        XCTAssertEqual(rowsByMessage["v3"]?.showsDelivery, false)
        XCTAssertEqual(rowsByMessage["v1"]?.showsDelivery, false)
    }

    func testYesterdayLabelAndLatinDigitsInArabic() {
        let zone = TimeZone(identifier: "UTC") ?? .current
        let now = ISODate.parse("2026-11-03T12:00:00.000Z") ?? Date()
        let yesterday = ISODate.parse("2026-11-02T08:00:00.000Z") ?? Date()
        XCTAssertEqual(ChatFormat.daySeparator(yesterday, now: now, locale: .en, timeZone: zone), "Yesterday")
        XCTAssertEqual(ChatFormat.daySeparator(yesterday, now: now, locale: .ar, timeZone: zone), "إمبارح")
        let time = ChatFormat.time(now, locale: .ar, timeZone: zone)
        XCTAssertTrue(time.contains("12:00"), "Latin digits: \(time)")
    }
}
