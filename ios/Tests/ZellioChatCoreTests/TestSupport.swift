import Foundation
import XCTest
@testable import ZellioChatCore

enum Fixtures {
    /// sdks/ios/Tests/ZellioChatCoreTests/TestSupport.swift -> sdks/
    static let sdksRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: sdksRoot.appendingPathComponent("contract/v1/fixtures/\(name).json"))
    }

    static func designStrings() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: sdksRoot.appendingPathComponent("design/strings.json"))
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }
}

final class FakeClock: ChatClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [Double] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    func sleep(seconds: Double) async throws {
        lock.lock(); recorded.append(seconds); current = current.addingTimeInterval(seconds); lock.unlock()
        await Task.yield()
    }
}

struct FixedRandom: RandomSource {
    var value: Double
    func unit() -> Double { value }
}

/// Answers requests with a closure and records them.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { self.handler = handler }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func paths() -> [String] { requests.map { "\($0.method) \($0.url.path)" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); log.append(request); lock.unlock()
        return handler(request)
    }
    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse {
        progress(1)
        return try await send(request)
    }
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

func jsonResponse(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return HTTPResponse(status: status, headers: headers, body: body)
}

func sessionBody(token: String = "tok_new") -> [String: Any] {
    ["data": ["sessionToken": token, "expiresAt": "2099-01-01T00:00:00.000Z", "customer": ["identified": false], "versionId": "ver_1"] as [String: Any]]
}

let testBaseURL = URL(string: "https://app.example") ?? URL(fileURLWithPath: "/")

func makeAPI(_ transport: HTTPTransport) -> ChatAPI {
    ChatAPI(config: ChatAPIConfig(baseURL: testBaseURL, appKey: "key_1"), transport: transport)
}

func makeJWT(sub: String) -> String {
    func b64(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(["sub": sub, "aud": "key_1"])).sig"
}

func message(_ cid: String?, _ sid: String?, from: MessageSender = .visitor, at time: String, text: String = "t", delivery: DeliveryState = .sent) -> ChatMessage {
    ChatMessage(serverId: sid, clientMessageId: cid, from: from, text: text, createdAt: time, delivery: delivery)
}

// Test-only wrappers for the `{ "data": ... }` envelope.
struct MessagesPageEnvelope: Decodable { let data: MessagesPage }
struct ConversationsEnvelope: Decodable { let data: ConversationsPage }
struct SessionEnvelope: Decodable { let data: SessionInfo }
struct AttachmentEnvelope: Decodable { let data: Attachment }
