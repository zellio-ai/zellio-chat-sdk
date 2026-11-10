import XCTest
@testable import ZellioChatCore

final class QueueTests: XCTestCase {
    func testQueueKeepsOrderAndSurvivesRestart() {
        let storage = MemoryStorage()
        let clock = FakeClock()
        let queue = OfflineQueue(storage: storage, clock: clock)
        queue.enqueue(clientMessageId: "a", text: "one", context: nil, conversationId: nil)
        queue.enqueue(clientMessageId: "b", text: "two", context: ChatContext(screen: "Cart"), conversationId: nil)
        queue.enqueue(clientMessageId: "c", text: "three", context: nil, conversationId: nil)
        queue.markFailed("b", reason: "http_400")

        let restarted = OfflineQueue(storage: storage, clock: clock)
        XCTAssertEqual(restarted.all.map { $0.clientMessageId }, ["a", "b", "c"])
        XCTAssertEqual(restarted.pending.map { $0.clientMessageId }, ["a", "c"])
        XCTAssertEqual(restarted.item("b")?.status, .failed)
        XCTAssertEqual(restarted.item("b")?.context?.screen, "Cart")
        // Try again puts it back in its old place.
        restarted.retry("b")
        XCTAssertEqual(restarted.pending.map { $0.clientMessageId }, ["a", "b", "c"])
    }

    func testPendingMessagesFailAfter24Hours() {
        let clock = FakeClock()
        let queue = OfflineQueue(storage: MemoryStorage(), clock: clock)
        queue.enqueue(clientMessageId: "old", text: "x", context: nil, conversationId: nil)
        clock.advance(OfflineQueue.expiry - 60)
        queue.enqueue(clientMessageId: "new", text: "y", context: nil, conversationId: nil)
        XCTAssertTrue(queue.expireOld().isEmpty)
        clock.advance(61)
        XCTAssertEqual(queue.expireOld(), ["old"])
        XCTAssertEqual(queue.item("old")?.status, .failed)
        XCTAssertEqual(queue.item("old")?.failureReason, "expired")
        XCTAssertEqual(queue.pending.map { $0.clientMessageId }, ["new"])
    }

    func testOutcomeRules() {
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.http(status: 400, code: nil, retryAfter: nil)), .failedPermanently(reason: "http_400"))
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.http(status: 413, code: "CHAT_FILE_TOO_LARGE", retryAfter: nil)), .failedPermanently(reason: "http_413"))
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.http(status: 401, code: nil, retryAfter: nil)), .retryLater(after: nil))
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.http(status: 429, code: "CHAT_RATE_LIMITED", retryAfter: 12)), .retryLater(after: 12))
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.http(status: 503, code: nil, retryAfter: nil)), .retryLater(after: nil))
        XCTAssertEqual(OutboxPolicy.classify(ChatAPIError.network), .retryLater(after: nil))
    }

    func testDrainSendsInOrderStopsOnOutageAndFailsHardErrors() async {
        let clock = FakeClock()
        let queue = OfflineQueue(storage: MemoryStorage(), clock: clock)
        for id in ["a", "b", "c", "d"] { queue.enqueue(clientMessageId: id, text: id, context: nil, conversationId: nil) }
        let sentOrder = Locked<[String]>([])
        let attemptsOfB = Locked(0)
        let outbox = Outbox(queue: queue, clock: clock, random: FixedRandom(value: 0.5)) { item in
            if item.clientMessageId == "b" {
                // Offline twice, then it works.
                let n = attemptsOfB.with { $0 += 1; return $0 }
                if n <= 2 { throw ChatAPIError.network }
            }
            if item.clientMessageId == "c" { throw ChatAPIError.http(status: 422, code: nil, retryAfter: nil) }
            sentOrder.with { $0.append(item.clientMessageId) }
            return SendReceipt(clientMessageId: item.clientMessageId, accepted: true, conversationId: "conv_1")
        }
        let updates = Locked<[Outbox.Update]>([])
        await outbox.setListener { update in updates.with { $0.append(update) } }
        await outbox.drain()
        XCTAssertEqual(sentOrder.snapshot, ["a", "b", "d"], "order kept; b waited for the network; c failed for good")
        XCTAssertEqual(queue.item("c")?.status, .failed)
        XCTAssertNil(queue.item("a"))
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(clock.sleeps, [1.0, 2.0], "backoff 1 s then 2 s with centered jitter")
        XCTAssertTrue(updates.snapshot.contains(.failed(clientMessageId: "c", reason: "http_422")))
    }

    func testRateLimitObeysRetryAfter() async {
        let clock = FakeClock()
        let queue = OfflineQueue(storage: MemoryStorage(), clock: clock)
        queue.enqueue(clientMessageId: "a", text: "a", context: nil, conversationId: nil)
        let tries = Locked(0)
        let outbox = Outbox(queue: queue, clock: clock) { item in
            let n = tries.with { $0 += 1; return $0 }
            if n == 1 { throw ChatAPIError.http(status: 429, code: "CHAT_RATE_LIMITED", retryAfter: 42) }
            return SendReceipt(clientMessageId: item.clientMessageId, accepted: true, conversationId: nil)
        }
        await outbox.drain()
        XCTAssertEqual(clock.sleeps, [42.0])
        XCTAssertTrue(queue.all.isEmpty, "a rate limit keeps the message")
    }

    func testExpiredMessagesAreFailedByDrain() async {
        let clock = FakeClock()
        let queue = OfflineQueue(storage: MemoryStorage(), clock: clock)
        queue.enqueue(clientMessageId: "a", text: "a", context: nil, conversationId: nil)
        clock.advance(OfflineQueue.expiry + 1)
        let outbox = Outbox(queue: queue, clock: clock) { _ in throw ChatAPIError.network }
        await outbox.drain()
        XCTAssertEqual(queue.item("a")?.failureReason, "expired")
    }

    func testBackoffSteps() {
        XCTAssertEqual(Backoff.steps, [1, 2, 4, 8, 16, 30])
        let mid = FixedRandom(value: 0.5)
        XCTAssertEqual((0..<8).map { Backoff.delay(attempt: $0, random: mid) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(Backoff.delay(attempt: 2, random: FixedRandom(value: 0)), 3.0, accuracy: 0.0001)   // 4 s minus 25 percent
        XCTAssertEqual(Backoff.delay(attempt: 2, random: FixedRandom(value: 0.999999)), 5.0, accuracy: 0.001)
        XCTAssertEqual(Backoff.delay(attempt: -3, random: mid), 1)
    }
}
