import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

public enum StreamChunk: Sendable, Equatable {
    case opened
    case data(Data)
}

/// The network seam. The app target has a URLSession version; tests and demo mode use fakes.
public protocol HTTPTransport: Sendable {
    /// A normal request. Throws `ChatAPIError.network` or `.timeout`.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// A request with a body that reports progress from 0 to 1. Cancelling the task cancels the upload.
    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse
    /// An SSE stream. Yields `.opened` for a 2xx response, then bytes. Throws `ChatAPIError.http` for other statuses.
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error>
}

public struct ChatAPIConfig: Sendable {
    public var baseURL: URL
    public var appKey: String
    public var platform: String
    public var sdkVersion: String
    public var wrapper: String?

    public init(baseURL: URL, appKey: String, platform: String = SDKInfo.platform, sdkVersion: String = SDKInfo.version, wrapper: String? = nil) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.wrapper = wrapper
    }
}

/// Typed calls to contract v1. The session token comes in per call.
public final class ChatAPI: @unchecked Sendable {
    public let config: ChatAPIConfig
    private let transport: HTTPTransport

    public static let connectTimeout: TimeInterval = 10
    public static let readTimeout: TimeInterval = 30
    public static let uploadTimeout: TimeInterval = 120

    public init(config: ChatAPIConfig, transport: HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    // MARK: Request building

    func makeRequest(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, token: String?, timeout: TimeInterval = ChatAPI.readTimeout, contentType: String? = nil) -> HTTPRequest {
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var text = base + SDKInfo.apiPath + path
        if !query.isEmpty {
            var components = URLComponents()
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            if let encoded = components.percentEncodedQuery { text += "?" + encoded }
        }
        let url = URL(string: text) ?? config.baseURL
        var headers: [String: String] = [
            "x-zee-app-key": config.appKey,
            "x-zee-sdk": "\(config.platform)/\(config.sdkVersion)",
            "accept": "application/json",
        ]
        if let wrapper = config.wrapper { headers["x-zee-sdk-wrapper"] = wrapper }
        if let token = token { headers["x-zee-session-token"] = token }
        if body != nil { headers["content-type"] = contentType ?? "application/json" }
        return HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeout)
    }

    private func json(_ object: [String: Any?]) -> Data? {
        var clean: [String: Any] = [:]
        for (key, value) in object { if let value = value { clean[key] = value } }
        return try? JSONSerialization.data(withJSONObject: clean)
    }

    // MARK: Response handling

    static func checked(_ response: HTTPResponse) throws -> Data {
        if (200..<300).contains(response.status) { return response.body }
        let retry = response.header("retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        throw ChatAPIError.http(status: response.status, code: ErrorPolicy.parseCode(from: response.body), retryAfter: retry)
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    static func unwrap<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do { return try JSONDecoder().decode(Envelope<T>.self, from: body).data } catch { throw ChatAPIError.decoding }
    }

    private func call<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) async throws -> T {
        let response = try await transport.send(request)
        return try ChatAPI.unwrap(type, try ChatAPI.checked(response))
    }

    // MARK: Endpoints

    public func fetchConfig() async throws -> ChatConfig {
        let response = try await transport.send(makeRequest("GET", "/config", token: nil))
        return try ChatConfig.parse(try ChatAPI.checked(response))
    }

    /// The raw body of GET /config, for the cache.
    public func fetchConfigBody() async throws -> Data {
        let response = try await transport.send(makeRequest("GET", "/config", token: nil))
        return try ChatAPI.checked(response)
    }

    public func createSession(installId: String, locale: ChatLocale, identityToken: String?) async throws -> SessionInfo {
        let body = json(["installId": installId, "platform": config.platform, "locale": locale.rawValue, "identityToken": identityToken])
        return try await call(SessionInfo.self, makeRequest("POST", "/session", body: body, token: nil))
    }

    public func identify(identityToken: String, token: String) async throws -> SessionInfo {
        try await call(SessionInfo.self, makeRequest("POST", "/session/identify", body: json(["identityToken": identityToken]), token: token))
    }

    public func logout(token: String) async throws {
        let response = try await transport.send(makeRequest("POST", "/session/logout", body: Data("{}".utf8), token: token))
        _ = try ChatAPI.checked(response)
    }

    public func conversations(cursor: String?, limit: Int = 20, token: String) async throws -> ConversationsPage {
        var query: [(String, String)] = [("limit", String(min(50, max(1, limit))))]
        if let cursor = cursor { query.append(("cursor", cursor)) }
        return try await call(ConversationsPage.self, makeRequest("GET", "/conversations", query: query, token: token))
    }

    public func messages(conversationId: String, before: String? = nil, after: String? = nil, limit: Int = 50, token: String) async throws -> MessagesPage {
        var query: [(String, String)] = [("limit", String(min(100, max(1, limit))))]
        // Never both cursors.
        if let before = before, after == nil { query.append(("before", before)) }
        if let after = after { query.append(("after", after)) }
        let encodedId = conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId
        return try await call(MessagesPage.self, makeRequest("GET", "/conversations/\(encodedId)/messages", query: query, token: token))
    }

    public func sendMessage(text: String, clientMessageId: String, attachmentIds: [String], context: ChatContext?, token: String) async throws -> SendReceipt {
        var object: [String: Any] = ["text": text.clipped(toUTF16: 4000), "clientMessageId": clientMessageId]
        if !attachmentIds.isEmpty { object["attachmentIds"] = attachmentIds }
        if let context = context?.sanitized(), let data = try? JSONEncoder().encode(context),
           let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["context"] = dictionary
        }
        let body = try? JSONSerialization.data(withJSONObject: object)
        return try await call(SendReceipt.self, makeRequest("POST", "/messages", body: body, token: token))
    }

    public func uploadAttachment(data: Data, fileName: String, mimeType: String, token: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Attachment {
        let boundary = "zee-" + UUID().uuidString
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")
        let request = makeRequest("POST", "/attachments", body: body, token: token, timeout: ChatAPI.uploadTimeout, contentType: "multipart/form-data; boundary=\(boundary)")
        let response = try await transport.upload(request, progress: progress)
        return try ChatAPI.unwrap(Attachment.self, try ChatAPI.checked(response))
    }

    public func markRead(conversationId: String, upTo: String, token: String) async throws -> Int {
        let body = json(["conversationId": conversationId, "upTo": upTo])
        return try await call(UnreadBody.self, makeRequest("POST", "/read", body: body, token: token)).unreadTotal
    }

    public func unread(token: String) async throws -> Int {
        try await call(UnreadBody.self, makeRequest("GET", "/unread", token: token)).unreadTotal
    }

    public func registerDevice(provider: String, pushToken: String, environment: String?, locale: ChatLocale, appVersion: String?, token: String) async throws {
        let body = json(["provider": provider, "pushToken": pushToken, "environment": environment, "locale": locale.rawValue, "appVersion": appVersion])
        let response = try await transport.send(makeRequest("PUT", "/device", body: body, token: token))
        _ = try ChatAPI.checked(response)
    }

    public func deleteDevice(token: String) async throws {
        let response = try await transport.send(makeRequest("DELETE", "/device", token: token))
        _ = try ChatAPI.checked(response)
    }

    public func eventsRequest(token: String) -> HTTPRequest {
        var request = makeRequest("GET", "/events", token: token, timeout: 0)
        request.headers["accept"] = "text/event-stream"
        return request
    }

    public func openStream(token: String) -> AsyncThrowingStream<StreamChunk, Error> {
        transport.stream(eventsRequest(token: token))
    }
}

private struct UnreadBody: Decodable {
    let unreadTotal: Int
    private enum CodingKeys: String, CodingKey { case unreadTotal }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unreadTotal = c.lenient(Int.self, .unreadTotal) ?? 0
    }
}
