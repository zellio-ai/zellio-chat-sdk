import Foundation
import ZellioChatCore

/// An in-process server for demo mode. It answers every contract call with the files from
/// `sdks/contract/v1/fixtures`, which the project copies into the app bundle. No network.
final class DemoTransport: HTTPTransport, @unchecked Sendable {
    private func fixture(_ name: String) -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures")
            ?? Bundle.main.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url) else { return Data("{\"data\":{}}".utf8) }
        return data
    }

    private func ok(_ data: Data) -> HTTPResponse { HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 250_000_000)
        let path = request.url.path.replacingOccurrences(of: "/api/v1/zeechat/mobile", with: "")
        switch (request.method, path) {
        case ("GET", "/config"):
            let config = fixture("config")
            guard UserDefaults.standard.bool(forKey: "demoNoConsent") else { return ok(config) }
            let open = String(decoding: config, as: UTF8.self).replacingOccurrences(of: "\"consentRequired\": true", with: "\"consentRequired\": false")
            return ok(Data(open.utf8))
        case ("POST", "/session"), ("POST", "/session/identify"): return ok(fixture("session"))
        case ("POST", "/session/logout"), ("PUT", "/device"), ("DELETE", "/device"): return ok(Data("{\"data\":{}}".utf8))
        case ("GET", "/conversations"): return ok(fixture("conversations"))
        case ("GET", "/unread"), ("POST", "/read"): return ok(Data("{\"data\":{\"unreadTotal\":0}}".utf8))
        case ("POST", "/messages"):
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let id = body?["clientMessageId"] as? String ?? UUID().uuidString
            let reply = ["data": ["clientMessageId": id, "accepted": true, "conversationId": "conv_2"] as [String: Any]]
            return ok((try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
        default:
            if request.method == "GET", path.hasPrefix("/conversations/"), path.hasSuffix("/messages") { return ok(fixture("messages")) }
            return HTTPResponse(status: 404, body: Data("{\"code\":\"CHAT_NOT_FOUND\"}".utf8))
        }
    }

    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse {
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 120_000_000)
            progress(Double(step) / 5)
        }
        return ok(fixture("attachment"))
    }

    /// Opens, then stays quiet until the task is cancelled.
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.opened)
            continuation.yield(.data(Data("event: ready\ndata: {\"conversationId\":\"conv_2\"}\n\n".utf8)))
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    continuation.yield(.data(Data(": ping\n\n".utf8)))
                }
            }
            continuation.onTermination = { _ in keepAlive.cancel() }
        }
    }
}
