import XCTest
@testable import ZellioChatCore

final class ErrorCodeTests: XCTestCase {
    private let table: [(Int, String, ErrorReaction, ChatError)] = [
        (401, "CHAT_APP_KEY_INVALID", .stopUnavailable, .unavailable),
        (403, "CHAT_APP_DISABLED", .stopUnavailable, .unavailable),
        (403, "CHAT_ENTITLEMENT_DENIED", .stopUnavailable, .unavailable),
        (401, "CHAT_SESSION_INVALID", .recreateSessionThenRetry, .loginNeeded),
        (401, "CHAT_SESSION_REQUIRED", .recreateSessionThenRetry, .loginNeeded),
        (401, "CHAT_IDENTITY_INVALID", .refreshIdentityOnce, .loginNeeded),
        (403, "CHAT_GUESTS_DISABLED", .showLoginNeeded, .loginNeeded),
        (404, "CHAT_CONVERSATION_NOT_FOUND", .reloadConversationList, .conversationNotFound),
        (413, "CHAT_FILE_TOO_LARGE", .showFileTooLarge, .fileTooLarge),
        (415, "CHAT_FILE_TYPE_DENIED", .showFileTypeDenied, .fileTypeDenied),
        (403, "CHAT_FILES_DISABLED", .hideAttach, .filesDisabled),
        (404, "CHAT_ATTACHMENT_NOT_FOUND", .none, .server(status: 404)),
        (429, "CHAT_RATE_LIMITED", .backOff, .rateLimited(retryAfter: 7)),
        (426, "CHAT_SDK_TOO_OLD", .stopUnavailable, .unavailable),
        (404, "CHAT_SITE_NOT_FOUND", .stopUnavailable, .unavailable),
    ]

    func testEveryContractCodeWithTopLevelAndNestedShape() throws {
        XCTAssertEqual(table.count, 15)
        for (status, code, reaction, mapped) in table {
            let shapes: [[String: Any]] = [
                ["code": code, "message": "x"],
                ["error": ["code": code, "message": "x"] as [String: Any]],
            ]
            for shape in shapes {
                let response = jsonResponse(status, shape, headers: ["Retry-After": "7"])
                XCTAssertEqual(ErrorPolicy.parseCode(from: response.body), code, code)
                XCTAssertThrowsError(try ChatAPI.checked(response), code) { error in
                    XCTAssertEqual(error as? ChatAPIError, .http(status: status, code: code, retryAfter: 7), code)
                    XCTAssertEqual(ErrorPolicy.reaction(for: error), reaction, code)
                    XCTAssertEqual(ErrorPolicy.map(error), mapped, code)
                }
            }
        }
    }

    func testErrorBodyFixtureGivesItsCode() throws {
        XCTAssertEqual(ErrorPolicy.parseCode(from: try Fixtures.data("error")), "CHAT_SESSION_INVALID")
    }

    func testUnknownCodeAndNoBody() {
        XCTAssertEqual(ErrorPolicy.reaction(forCode: "CHAT_FUTURE_THING"), ErrorReaction.none)
        XCTAssertNil(ErrorPolicy.parseCode(from: Data("not json".utf8)))
        XCTAssertNil(ErrorPolicy.parseCode(from: nil))
        XCTAssertEqual(ErrorPolicy.map(ChatAPIError.http(status: 500, code: nil, retryAfter: nil)), .server(status: 500))
        XCTAssertEqual(ErrorPolicy.map(ChatAPIError.network), .network)
    }

    func testUnknownCodeFallsBackToTheStatusAndNoCodeStaysNone() {
        XCTAssertEqual(ErrorPolicy.reaction(status: 401, code: "CHAT_FUTURE"), .recreateSessionThenRetry)
        XCTAssertEqual(ErrorPolicy.reaction(status: 403, code: "CHAT_FUTURE"), .stopUnavailable)
        XCTAssertEqual(ErrorPolicy.reaction(status: 429, code: "CHAT_FUTURE"), .backOff)
        XCTAssertEqual(ErrorPolicy.reaction(status: 500, code: "CHAT_FUTURE"), ErrorReaction.none)
        XCTAssertEqual(ErrorPolicy.reaction(status: 401, code: nil), ErrorReaction.none, "a proxy 401 is not a Zellio answer")
        XCTAssertEqual(ErrorPolicy.reaction(status: 403, code: nil), ErrorReaction.none)
        XCTAssertEqual(ErrorPolicy.reaction(status: 429, code: nil), .backOff, "a bare 429 still backs off")
        XCTAssertEqual(ErrorPolicy.reaction(status: 401, code: "CHAT_APP_KEY_INVALID"), .stopUnavailable, "a known code wins over the status")
        XCTAssertEqual(ErrorPolicy.map(ChatAPIError.http(status: 403, code: "CHAT_FUTURE", retryAfter: nil)), .unavailable)
        XCTAssertEqual(ErrorPolicy.map(ChatAPIError.http(status: 403, code: nil, retryAfter: nil)), .server(status: 403))
        XCTAssertEqual(ErrorPolicy.map(ChatAPIError.http(status: 429, code: nil, retryAfter: 3)), .rateLimited(retryAfter: 3))
    }

    func testHeadersAndPathsOfRequests() async throws {
        let transport = ScriptedTransport { _ in jsonResponse(200, ["data": ["unreadTotal": 3]]) }
        let api = ChatAPI(config: ChatAPIConfig(baseURL: URL(string: "https://app.example/") ?? testBaseURL, appKey: "key_1", wrapper: "flutter/1.0.0"), transport: transport)
        let total = try await api.unread(token: "tok")
        XCTAssertEqual(total, 3)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://app.example/api/v1/zeechat/mobile/unread")
        XCTAssertEqual(request.headers["x-zee-app-key"], "key_1")
        XCTAssertEqual(request.headers["x-zee-sdk"], "ios/\(SDKInfo.version)")
        XCTAssertEqual(request.headers["x-zee-sdk-wrapper"], "flutter/1.0.0")
        XCTAssertEqual(request.headers["x-zee-session-token"], "tok")
        _ = try? await api.messages(conversationId: "c 1", before: "b", after: "a", token: "tok")
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertTrue(last.url.absoluteString.contains("after=a"))
        XCTAssertFalse(last.url.absoluteString.contains("before="), "never both cursors")
    }
}
