import XCTest
@testable import ZellioChatCore

final class StreamTests: XCTestCase {
    func testParserHandlesPingMultiLineDataAndUnknownEvents() throws {
        var parser = SSEParser()
        let text = ": ping\n\nevent: ready\ndata: {\"conversationId\":\"conv_2\"}\n\nevent: typing\ndata: {\"active\":true,\ndata: \"agentName\":\"Mona\"}\n\nevent: future_thing\ndata: {\"x\":1}\n\n"
        let events = parser.feed(Data(text.utf8))
        XCTAssertEqual(events.map { $0.name }, ["ready", "typing", "future_thing"], "a comment alone makes no event")
        XCTAssertEqual(events[1].data, "{\"active\":true,\n\"agentName\":\"Mona\"}")
        XCTAssertEqual(RealtimeEventDecoder.decode(events[0]), .ready(conversationId: "conv_2"))
        XCTAssertEqual(RealtimeEventDecoder.decode(events[1]), .typing(active: true, agentName: "Mona"))
        XCTAssertNil(RealtimeEventDecoder.decode(events[2]), "unknown event is skipped")
    }

    func testParserHandlesSplitChunksCRLFAndSplitUTF8() throws {
        var parser = SSEParser()
        let full = Data("event: message\r\ndata: {\"id\":\"m1\",\"from\":\"agent\",\"text\":\"مرحبا\",\"createdAt\":\"2026-11-03T10:00:00.000Z\"}\r\n\r\n".utf8)
        var events: [SSEEvent] = []
        // One byte at a time: cuts through the Arabic characters and through CRLF.
        for byte in full { events += parser.feed(Data([byte])) }
        XCTAssertEqual(events.count, 1)
        guard case .message(let message, let conversationId)? = RealtimeEventDecoder.decode(events[0]) else { return XCTFail("message expected") }
        XCTAssertNil(conversationId)
        XCTAssertEqual(message.text, "مرحبا")
        XCTAssertEqual(message.serverId, "m1")
    }

    func testMessageFrameCarriesItsConversation() {
        let data = "{\"id\":\"m1\",\"conversationId\":\"conv_9\",\"from\":\"agent\",\"text\":\"hi\",\"createdAt\":\"2026-11-03T10:00:00.000Z\"}"
        guard case .message(_, let conversationId)? = RealtimeEventDecoder.decode(SSEEvent(name: "message", data: data, id: nil)) else { return XCTFail("message expected") }
        XCTAssertEqual(conversationId, "conv_9")
    }

    func testAllEventTypes() {
        func decode(_ name: String, _ data: String) -> RealtimeEvent? { RealtimeEventDecoder.decode(SSEEvent(name: name, data: data, id: nil)) }
        XCTAssertEqual(decode("ready", "{\"conversationId\":null}"), .ready(conversationId: nil))
        XCTAssertEqual(decode("unread", "{\"unreadTotal\":2}"), .unread(2))
        XCTAssertEqual(decode("agent_joined", "{\"agentName\":\"Mona\",\"agentAvatarUrl\":null}"), .agentJoined(agentName: "Mona", avatarUrl: nil))
        XCTAssertEqual(decode("typing", "{\"active\":false,\"agentName\":null}"), .typing(active: false, agentName: nil))
        XCTAssertNil(decode("message", "{\"from\":\"future-sender\",\"id\":\"x\"}"))
        XCTAssertNil(decode("message", "not json"))
        XCTAssertNil(decode("unread", "{}"))
    }

    func testReconnectMachine() {
        var machine = StreamMachine()
        XCTAssertEqual(machine.handle(.start), [.connect])
        XCTAssertEqual(machine.handle(.opened), [])
        XCTAssertEqual(machine.state, .open)
        // Closed by the server after 10 minutes: backoff 1, then catch up.
        XCTAssertEqual(machine.handle(.ended), [.scheduleReconnect(attempt: 0)])
        XCTAssertEqual(machine.reconnectTimerFired(), [.catchUp])
        // Fails before opening: attempts grow 1, 2, 3.
        XCTAssertEqual(machine.handle(.failed), [.scheduleReconnect(attempt: 1)])
        XCTAssertEqual(machine.reconnectTimerFired(), [.catchUp])
        XCTAssertEqual(machine.handle(.failed), [.scheduleReconnect(attempt: 2)])
        _ = machine.reconnectTimerFired()
        XCTAssertEqual(machine.handle(.opened), [])
        // A good connection resets the backoff.
        XCTAssertEqual(machine.handle(.failed), [.scheduleReconnect(attempt: 0)])
    }

    func testMachineDeadTimeoutBackgroundAndForeground() {
        var machine = StreamMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.opened)
        XCTAssertEqual(StreamMachine.deadAfter, 45)
        XCTAssertEqual(machine.handle(.deadTimeout), [.closeConnection, .scheduleReconnect(attempt: 0)])
        _ = machine.reconnectTimerFired()
        _ = machine.handle(.opened)
        XCTAssertEqual(machine.handle(.enteredBackground), [.closeConnection])
        XCTAssertEqual(machine.state, .paused)
        XCTAssertEqual(machine.handle(.ended), [], "a late close while in the background does nothing")
        XCTAssertEqual(machine.handle(.enteredForeground), [.catchUp])
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertEqual(machine.handle(.stop), [.closeConnection])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.failed), [])
        XCTAssertEqual(machine.handle(.enteredForeground), [])
    }

    func testRealtimeClientDeliversEventsAndReconnectsAfterCleanClose() async throws {
        final class Hub: @unchecked Sendable {
            let lock = NSLock()
            var opens = 0
            var events: [RealtimeEvent] = []
            var catchUps = 0
        }
        let hub = Hub()
        let transport = StreamingTransport { index in
            index == 0
                ? [.opened, .data(Data(": ping\n\nevent: unread\ndata: {\"unreadTotal\":5}\n\n".utf8))]
                : [.opened]
        }
        let client = RealtimeClient(
            api: makeAPI(transport), clock: FastClock(), random: FixedRandom(value: 0.5),
            tokenSource: { "tok" },
            onEvent: { event in hub.lock.lock(); hub.events.append(event); hub.lock.unlock() },
            catchUp: { hub.lock.lock(); hub.catchUps += 1; hub.lock.unlock() },
            onFailure: { _ in }
        )
        await client.start()
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if transport.opens >= 2 { break }
        }
        await client.stop()
        XCTAssertGreaterThanOrEqual(transport.opens, 2, "reconnected after the server closed the stream")
        hub.lock.lock(); defer { hub.lock.unlock() }
        XCTAssertEqual(hub.events.first, .unread(5))
        XCTAssertGreaterThanOrEqual(hub.catchUps, 1, "catch up runs before the stream is reopened")
    }

    func testSdkTooOldCallsOnFailureAndStopsTheStreamForGood() async throws {
        let failures = Locked<[ChatAPIError]>([])
        let transport = StreamingTransport(failure: { _ in .http(status: 426, code: "CHAT_SDK_TOO_OLD", retryAfter: nil) }) { _ in [] }
        let client = RealtimeClient(
            api: makeAPI(transport), clock: FastClock(), random: FixedRandom(value: 0.5),
            tokenSource: { "tok" }, onEvent: { _ in }, catchUp: {},
            onFailure: { error in failures.with { $0.append(error) } }
        )
        await client.start()
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if await client.state == .idle { break }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let state = await client.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(transport.opens, 1, "no reconnect after a stop reaction")
        XCTAssertEqual(failures.with { $0.count }, 1)
        XCTAssertEqual(failures.with { $0.first?.status }, 426)
        // start() opens it again later.
        await client.start()
        for _ in 0..<100 where transport.opens < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(transport.opens, 2)
        await client.stop()
    }

    func testRateLimitedWaitsRetryAfterCappedAtFiveMinutesThenReconnects() async throws {
        let clock = RecordingClock()
        let transport = StreamingTransport(failure: { index in
            index == 0 ? .http(status: 429, code: "CHAT_RATE_LIMITED", retryAfter: 1000) : nil
        }) { _ in [.opened] }
        let client = RealtimeClient(
            api: makeAPI(transport), clock: clock, random: FixedRandom(value: 0.5),
            tokenSource: { "tok" }, onEvent: { _ in }, catchUp: {}, onFailure: { _ in }
        )
        await client.start()
        for _ in 0..<200 where transport.opens < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        await client.stop()
        XCTAssertGreaterThanOrEqual(transport.opens, 2, "it reconnects after the wait")
        XCTAssertTrue(clock.sleeps.contains(300), "1000 s is capped at 300 s")
        XCTAssertFalse(clock.sleeps.contains(1000))
    }
}

/// Sleeps very briefly, so reconnect tests run fast.
struct FastClock: ChatClock {
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: 1_000_000) }
}

final class StreamingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let script: @Sendable (Int) -> [StreamChunk]
    private let failure: @Sendable (Int) -> ChatAPIError?
    init(failure: @escaping @Sendable (Int) -> ChatAPIError? = { _ in nil }, script: @escaping @Sendable (Int) -> [StreamChunk]) {
        self.script = script
        self.failure = failure
    }
    var opens: Int { lock.lock(); defer { lock.unlock() }; return count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 200) }
    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse { HTTPResponse(status: 200) }
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        lock.lock(); let index = count; count += 1; lock.unlock()
        let chunks = script(index)
        let error = failure(index)
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if let error = error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

/// Like `FastClock`, and it records every sleep.
final class RecordingClock: ChatClock, @unchecked Sendable {
    private let recorded = Locked<[Double]>([])
    var sleeps: [Double] { recorded.with { $0 } }
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws {
        recorded.with { $0.append(seconds) }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
