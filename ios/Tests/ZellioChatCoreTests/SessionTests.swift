import XCTest
@testable import ZellioChatCore

final class SessionTests: XCTestCase {
    private func make(_ transport: HTTPTransport, storage: StorageBackend = MemoryStorage(), secrets: SecretStore = MemorySecretStore(),
                      allowed: @escaping @Sendable () async throws -> Void = {}) -> SessionCoordinator {
        SessionCoordinator(api: makeAPI(transport), secrets: secrets, storage: storage, installId: "install-1", locale: { .ar }, allowed: allowed)
    }

    func testSessionInvalidMakesNewSessionAndRetriesOnce() async throws {
        let counts = Locked<[String: Int]>([:])
        let transport = ScriptedTransport { request in
            let key = "\(request.method) \(request.url.path)"
            let n = counts.with { c -> Int in c[key, default: 0] += 1; return c[key, default: 0] }
            if request.url.path.hasSuffix("/session") { return jsonResponse(201, sessionBody(token: "tok_\(n)")) }
            // The first token is refused. The second works.
            if request.headers["x-zee-session-token"] == "tok_1" { return jsonResponse(401, ["code": "CHAT_SESSION_INVALID"]) }
            return jsonResponse(200, ["data": ["unreadTotal": 4]])
        }
        let secrets = MemorySecretStore()
        let coordinator = make(transport, secrets: secrets)
        let total: Int = try await coordinator.perform { token in try await makeAPI(transport).unread(token: token) }
        XCTAssertEqual(total, 4)
        XCTAssertEqual(transport.paths(), ["POST /api/v1/zeechat/mobile/session", "GET /api/v1/zeechat/mobile/unread",
                                           "POST /api/v1/zeechat/mobile/session", "GET /api/v1/zeechat/mobile/unread"])
        XCTAssertEqual(secrets.read(SessionCoordinator.tokenKey), "tok_2")
        let body = try XCTUnwrap(transport.requests.first?.body)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["installId"] as? String, "install-1")
        XCTAssertEqual(sent["platform"] as? String, "ios")
        XCTAssertEqual(sent["locale"] as? String, "ar")
        XCTAssertNil(sent["identityToken"])
    }

    func testSessionRequiredAlsoRetriesButOnlyOnce() async throws {
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/session") { return jsonResponse(201, sessionBody()) }
            return jsonResponse(401, ["error": ["code": "CHAT_SESSION_REQUIRED"]])
        }
        let coordinator = make(transport)
        do {
            let _: Int = try await coordinator.perform { token in try await makeAPI(transport).unread(token: token) }
            XCTFail("must throw")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.errorCode, .sessionRequired)
        }
        // session, call, session, call. No third round.
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testIdentityInvalidAsksProviderOnceMoreThenLoginNeeded() async throws {
        let transport = ScriptedTransport { _ in jsonResponse(401, ["code": "CHAT_IDENTITY_INVALID"]) }
        let calls = Locked(0)
        let coordinator = make(transport)
        await coordinator.setProvider { calls.with { $0 += 1 }; return makeJWT(sub: "u1") }
        do {
            _ = try await coordinator.ensureSession()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ChatError, .loginNeeded)
        }
        XCTAssertEqual(calls.snapshot, 2)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testIdentityInvalidThenGoodTokenWorks() async throws {
        let attempts = Locked(0)
        let transport = ScriptedTransport { _ in
            let n = attempts.with { $0 += 1; return $0 }
            return n == 1 ? jsonResponse(401, ["code": "CHAT_IDENTITY_INVALID"]) : jsonResponse(201, sessionBody(token: "tok_ok"))
        }
        let coordinator = make(transport)
        await coordinator.setProvider { makeJWT(sub: "u1") }
        let token = try await coordinator.ensureSession()
        XCTAssertEqual(token, "tok_ok")
    }

    func testGuestsDisabledAndAppDisabledMapToStates() async throws {
        let guests = make(ScriptedTransport { _ in jsonResponse(403, ["code": "CHAT_GUESTS_DISABLED"]) })
        do { _ = try await guests.ensureSession(); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .loginNeeded) }
        let disabled = make(ScriptedTransport { _ in jsonResponse(403, ["code": "CHAT_APP_DISABLED"]) })
        do { _ = try await disabled.ensureSession(); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .unavailable) }
    }

    func testConsentBlocksTheSessionCall() async throws {
        let transport = ScriptedTransport { _ in jsonResponse(201, sessionBody()) }
        let coordinator = make(transport, allowed: { throw ChatError.consentRequired })
        do { _ = try await coordinator.ensureSession(); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .consentRequired) }
        XCTAssertTrue(transport.requests.isEmpty, "no session before Accept")
    }

    func testCustomerSwitchRunsLogoutPathFirst() async throws {
        let counter = Locked(0)
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/session/logout") { return jsonResponse(200, ["data": ["loggedOut": true]]) }
            let n = counter.with { $0 += 1; return $0 }
            return jsonResponse(201, sessionBody(token: "tok_\(n)"))
        }
        let storage = MemoryStorage()
        let secrets = MemorySecretStore()
        let coordinator = make(transport, storage: storage, secrets: secrets)
        let subject = Locked("alice")
        await coordinator.setProvider { makeJWT(sub: subject.snapshot) }
        _ = try await coordinator.ensureSession()
        storage.write("messages-conv_1.json", Data("[]".utf8))
        secrets.delete(SessionCoordinator.tokenKey)     // force a new session
        subject.with { $0 = "bob" }
        _ = try await coordinator.ensureSession()
        XCTAssertNil(storage.read("messages-conv_1.json"), "the first customer's data is gone")
    }

    func testLogoutDeletesLocalDataEvenWhenTheCallFails() async throws {
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/session/logout") { return jsonResponse(500, ["code": "X"]) }
            return jsonResponse(201, sessionBody())
        }
        let storage = MemoryStorage()
        let secrets = MemorySecretStore()
        let coordinator = make(transport, storage: storage, secrets: secrets)
        _ = try await coordinator.ensureSession()
        storage.write(StorageName.conversations, Data("{}".utf8))
        storage.write(StorageName.consent, Data("{}".utf8))
        await coordinator.logout()
        XCTAssertNil(secrets.read(SessionCoordinator.tokenKey))
        XCTAssertNil(storage.read(StorageName.conversations))
        XCTAssertNil(storage.read(StorageName.session))
        XCTAssertNil(storage.read(StorageName.consent), "the next person on this phone is asked again")
    }

    func testParallelCallsWithARefusedTokenMakeOneNewSession() async throws {
        let sessions = Locked(0)
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/session") {
                let n = sessions.with { $0 += 1; return $0 }
                return jsonResponse(201, sessionBody(token: "tok_\(n)"))
            }
            if request.headers["x-zee-session-token"] == "tok_old" { return jsonResponse(401, ["code": "CHAT_SESSION_INVALID"]) }
            return jsonResponse(200, ["data": ["unreadTotal": 1]])
        }
        let secrets = MemorySecretStore()
        secrets.write(SessionCoordinator.tokenKey, value: "tok_old")
        let coordinator = make(transport, secrets: secrets)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await coordinator.perform { token in try await makeAPI(transport).unread(token: token) } }
            }
            for try await total in group { XCTAssertEqual(total, 1) }
        }
        XCTAssertEqual(sessions.snapshot, 1)
        XCTAssertEqual(secrets.read(SessionCoordinator.tokenKey), "tok_1")
    }

    private func waitForDeviceCalls(_ transport: ScriptedTransport, count: Int) async {
        for _ in 0..<500 {
            if transport.paths().filter({ $0.hasSuffix("/device") }).count >= count { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testEveryNewSessionRegistersThePushTokenAgain() async throws {
        let counter = Locked(0)
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/device") { return jsonResponse(200, ["data": ["registered": true]]) }
            if request.url.path.hasSuffix("/session/logout") { return jsonResponse(200, ["data": ["loggedOut": true]]) }
            let n = counter.with { $0 += 1; return $0 }
            return jsonResponse(201, sessionBody(token: "tok_\(n)"))
        }
        let engine = ChatEngine(options: EngineOptions(baseURL: testBaseURL, appKey: "key_1", localeOption: .en),
                                transport: transport, secrets: MemorySecretStore(), storage: MemoryStorage())
        engine.setPushToken("device-token", environment: "sandbox")
        // No session yet: nothing is sent.
        XCTAssertFalse(transport.paths().contains { $0.hasSuffix("/device") })

        _ = try await engine.session.ensureSession()
        await waitForDeviceCalls(transport, count: 1)
        XCTAssertEqual(transport.paths().filter { $0.hasSuffix("/device") }.count, 1)

        // The server clears the token on a new session, so the next session sends it again.
        await engine.session.invalidateToken()
        _ = try await engine.session.ensureSession()
        await waitForDeviceCalls(transport, count: 2)
        XCTAssertEqual(transport.paths().filter { $0.hasSuffix("/device") }.count, 2)
    }

    func testLogoutKeepsTheDeviceTokenForTheNextSession() async throws {
        let counter = Locked(0)
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/device") { return jsonResponse(200, ["data": ["registered": true]]) }
            if request.url.path.hasSuffix("/session/logout") { return jsonResponse(200, ["data": ["loggedOut": true]]) }
            let n = counter.with { $0 += 1; return $0 }
            return jsonResponse(201, sessionBody(token: "tok_\(n)"))
        }
        let engine = ChatEngine(options: EngineOptions(baseURL: testBaseURL, appKey: "key_1", localeOption: .en),
                                transport: transport, secrets: MemorySecretStore(), storage: MemoryStorage())
        engine.setPushToken("device-token", environment: nil)
        _ = try await engine.session.ensureSession()
        await waitForDeviceCalls(transport, count: 1)
        await engine.logout()
        let sentBefore = transport.paths().filter { $0.hasPrefix("PUT") && $0.hasSuffix("/device") }.count
        _ = try await engine.session.ensureSession()
        for _ in 0..<500 where transport.paths().filter({ $0.hasPrefix("PUT") && $0.hasSuffix("/device") }).count == sentBefore {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transport.paths().filter { $0.hasPrefix("PUT") && $0.hasSuffix("/device") }.count, sentBefore + 1)
    }

    func testStoredTokenIsUsedEvenWhenExpiresAtIsInThePast() async throws {
        let transport = ScriptedTransport { _ in jsonResponse(201, sessionBody(token: "tok_new")) }
        let storage = MemoryStorage()
        storage.write(StorageName.session, Data(#"{"identified":false,"expiresAt":"2020-01-01T00:00:00Z"}"#.utf8))
        let secrets = MemorySecretStore()
        secrets.write(SessionCoordinator.tokenKey, value: "tok_old")
        let coordinator = make(transport, storage: storage, secrets: secrets)
        let stored = await coordinator.token
        XCTAssertEqual(stored, "tok_old")
        let ensured = try await coordinator.ensureSession()
        XCTAssertEqual(ensured, "tok_old")
        XCTAssertTrue(transport.requests.isEmpty, "the server decides when a session ends, not the local clock")
    }

    func testJWTSubject() {
        XCTAssertEqual(JWT.subject(of: makeJWT(sub: "user-42")), "user-42")
        XCTAssertNil(JWT.subject(of: "nonsense"))
    }
}
