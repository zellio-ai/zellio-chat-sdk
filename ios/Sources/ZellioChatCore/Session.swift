import Foundation

public typealias IdentityTokenProvider = @Sendable () async throws -> String

public enum JWT {
    /// The `sub` claim, read without checking the signature. The server checks it. Used to see a customer switch.
    public static func subject(of token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = object["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }
}

private struct SessionMeta: Codable, Equatable {
    var subject: String?       // the brand user id of the identified customer
    var identified: Bool
    var expiresAt: String?
}

/// Owns the session: creates it, keeps the token in the secret store, and applies the error-code rules.
public actor SessionCoordinator {
    public static let tokenKey = "sessionToken"

    private let api: ChatAPI
    private let secrets: SecretStore
    private let storage: StorageBackend
    private let clock: ChatClock
    private let installId: String
    private let locale: @Sendable () -> ChatLocale
    private let allowed: @Sendable () async throws -> Void
    private let onWipe: @Sendable () -> Void
    private let onSessionStarted: @Sendable () -> Void

    private var provider: IdentityTokenProvider?
    private var creating: Task<String, Error>?

    /// - Parameters:
    ///   - allowed: throws before any session call when consent or config forbids it.
    ///   - onWipe: called when local data must go (logout, customer switch).
    ///   - onSessionStarted: called after a new token is stored. The server forgets a push token on a new session.
    public init(api: ChatAPI, secrets: SecretStore, storage: StorageBackend, clock: ChatClock = SystemClock(), installId: String,
                locale: @escaping @Sendable () -> ChatLocale, allowed: @escaping @Sendable () async throws -> Void = {}, onWipe: @escaping @Sendable () -> Void = {},
                onSessionStarted: @escaping @Sendable () -> Void = {}) {
        self.api = api
        self.secrets = secrets
        self.storage = storage
        self.clock = clock
        self.installId = installId
        self.locale = locale
        self.allowed = allowed
        self.onWipe = onWipe
        self.onSessionStarted = onSessionStarted
    }

    public func setProvider(_ provider: IdentityTokenProvider?) { self.provider = provider }
    public var hasProvider: Bool { provider != nil }

    public var token: String? {
        guard let token = secrets.read(SessionCoordinator.tokenKey), !token.isEmpty else { return nil }
        // No local expiry check: the server moves expiry forward on every send and does not tell the client.
        // The token stays until the server answers CHAT_SESSION_INVALID.
        return token
    }

    /// Forget the token, for example after the stream got a 401.
    public func invalidateToken() { secrets.delete(SessionCoordinator.tokenKey) }

    public var isIdentified: Bool { storage.load(SessionMeta.self, StorageName.session)?.identified ?? false }

    /// A valid token, creating a session when needed.
    public func ensureSession() async throws -> String {
        if let token = token { return token }
        return try await createSession()
    }

    private func createSession() async throws -> String {
        if let running = creating { return try await running.value }
        let task = Task { try await self.performCreate() }
        creating = task
        defer { creating = nil }
        return try await task.value
    }

    private func performCreate() async throws -> String {
        try await allowed()
        var identityToken: String?
        if let provider = provider {
            identityToken = try await fetchIdentity(provider)
        }
        let previous = storage.load(SessionMeta.self, StorageName.session)
        let subject = identityToken.flatMap { JWT.subject(of: $0) }
        // A different customer: the logout path first.
        if let old = previous?.subject, let new = subject, old != new {
            if let stale = secrets.read(SessionCoordinator.tokenKey) { try? await api.logout(token: stale) }
            await wipe()
        }
        do {
            let info = try await api.createSession(installId: installId, locale: locale(), identityToken: identityToken)
            return store(info, subject: subject, identified: identityToken != nil && info.identified)
        } catch let error as ChatAPIError {
            if ErrorPolicy.reaction(for: error) == .refreshIdentityOnce, let provider = provider {
                // Get a new token once. If that fails too, the app must log in.
                guard let fresh = try? await provider() else { throw ChatError.loginNeeded }
                do {
                    let info = try await api.createSession(installId: installId, locale: locale(), identityToken: fresh)
                    return store(info, subject: JWT.subject(of: fresh), identified: info.identified)
                } catch {
                    throw ChatError.loginNeeded
                }
            }
            throw map(error)
        }
    }

    /// Calls the provider. A failure is tried once more; a second failure means login is needed.
    private func fetchIdentity(_ provider: @escaping IdentityTokenProvider) async throws -> String {
        if let token = try? await provider(), !token.isEmpty { return token }
        if let token = try? await provider(), !token.isEmpty { return token }
        throw ChatError.loginNeeded
    }

    private func map(_ error: ChatAPIError) -> Error {
        switch ErrorPolicy.reaction(for: error) {
        case .showLoginNeeded: return ChatError.loginNeeded
        case .stopUnavailable: return ChatError.unavailable
        default: return error
        }
    }

    private func store(_ info: SessionInfo, subject: String?, identified: Bool) -> String {
        secrets.write(SessionCoordinator.tokenKey, value: info.sessionToken)
        storage.save(SessionMeta(subject: subject, identified: identified, expiresAt: info.expiresAt), StorageName.session)
        onSessionStarted()
        return info.sessionToken
    }

    /// Turns a guest session into a customer session. Call after `identify` when a session already exists.
    public func identifyCurrentSession() async throws {
        guard let provider = provider else { return }
        let meta = storage.load(SessionMeta.self, StorageName.session)
        guard let current = token else { return }   // no session yet: it is made with the token later
        let identity = try await fetchIdentity(provider)
        let subject = JWT.subject(of: identity)
        if let old = meta?.subject, let new = subject, old != new {
            try? await api.logout(token: current)
            await wipe()
            _ = try await createSession()
            return
        }
        if meta?.identified == true && meta?.subject == subject { return }
        do {
            let info = try await api.identify(identityToken: identity, token: current)
            _ = store(info, subject: subject, identified: true)
        } catch let error as ChatAPIError {
            if ErrorPolicy.reaction(for: error) == .recreateSessionThenRetry {
                secrets.delete(SessionCoordinator.tokenKey)
                _ = try await createSession()
            } else {
                throw map(error)
            }
        }
    }

    /// Runs a call with the session token. 401 with CHAT_SESSION_INVALID or CHAT_SESSION_REQUIRED makes a new
    /// session and retries once. Every other error is passed on as it is.
    public func perform<T>(_ operation: @Sendable (String) async throws -> T) async throws -> T {
        let first = try await ensureSession()
        do {
            return try await operation(first)
        } catch let error as ChatAPIError {
            switch ErrorPolicy.reaction(for: error) {
            case .recreateSessionThenRetry:
                // Only the refused token goes. A parallel call may have stored a new one already: that one stays.
                if secrets.read(SessionCoordinator.tokenKey) == first { secrets.delete(SessionCoordinator.tokenKey) }
                let second = try await ensureSession()
                do { return try await operation(second) } catch let again as ChatAPIError { throw mapFinal(again) }
            default:
                throw mapFinal(error)
            }
        }
    }

    private func mapFinal(_ error: ChatAPIError) -> Error {
        switch ErrorPolicy.reaction(for: error) {
        case .stopUnavailable: return ChatError.unavailable
        case .showLoginNeeded: return ChatError.loginNeeded
        default: return error
        }
    }

    /// Ends the session. Local data goes even when the call fails.
    public func logout() async {
        if let token = token {
            try? await api.logout(token: token)
        }
        await wipe()
        provider = nil
    }

    private func wipe() async {
        secrets.delete(SessionCoordinator.tokenKey)
        storage.removeAll(keeping: StorageName.keptOnLogout)
        onWipe()
    }
}
