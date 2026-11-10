import Foundation

public struct EngineOptions: Sendable {
    public var baseURL: URL
    public var appKey: String
    /// nil follows the device.
    public var localeOption: ChatLocale?
    public var deviceLanguageCode: String?
    public var wrapper: String?
    public var appVersion: String?

    public init(baseURL: URL, appKey: String, localeOption: ChatLocale? = nil, deviceLanguageCode: String? = nil, wrapper: String? = nil, appVersion: String? = nil) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.localeOption = localeOption
        self.deviceLanguageCode = deviceLanguageCode
        self.wrapper = wrapper
        self.appVersion = appVersion
    }
}

public enum HubEvent: Sendable {
    case realtime(RealtimeEvent)
    case reconnected
    case outbox(Outbox.Update)
    /// Logout or a customer switch removed the local data. Caches outside the storage must go too.
    case localDataWiped
}

/// Ties the parts together: config, consent, session, conversations, outbox, stream, push, logout.
/// Every method is safe from any thread. Nothing here blocks the caller.
public final class ChatEngine: @unchecked Sendable {
    public let options: EngineOptions
    public let api: ChatAPI
    public let storage: StorageBackend
    public let secrets: SecretStore
    public let clock: ChatClock
    public let installId: String
    public let queue: OfflineQueue
    public let outbox: Outbox
    public let session: SessionCoordinator
    public let unread = UnreadTracker()
    public let consentStore: ConsentStore
    public let drafts: DraftStore
    private let configCache: ConfigCache

    private struct State {
        var config: ChatConfig?
        var freshConfig = false
        var context: ChatContext?
        var localeOption: ChatLocale?
        var listeners: [Int: @Sendable (HubEvent) -> Void] = [:]
        var nextListener = 0
        var streamConversationId: String?
        var realtime: RealtimeClient?
        var pushToken: PushRegistration?
    }
    private let state = Locked(State())

    public struct PushRegistration: Codable, Equatable, Sendable {
        public var token: String
        public var environment: String?
    }

    public init(options: EngineOptions, transport: HTTPTransport, secrets: SecretStore, storage: StorageBackend, clock: ChatClock = SystemClock(), random: RandomSource = SystemRandom()) {
        let install = InstallId.load(storage)
        let api = ChatAPI(config: ChatAPIConfig(baseURL: options.baseURL, appKey: options.appKey, wrapper: options.wrapper), transport: transport)
        let queue = OfflineQueue(storage: storage, clock: clock)
        let box = Locked<ChatEngine?>(nil)
        let sessionRef = Locked<SessionCoordinator?>(nil)
        let outbox = Outbox(queue: queue, clock: clock, random: random) { item in
            guard let coordinator = sessionRef.snapshot else { throw ChatError.network }
            return try await coordinator.perform { token in
                try await api.sendMessage(text: item.text, clientMessageId: item.clientMessageId, attachmentIds: item.attachmentIds, context: item.context, token: token)
            }
        }
        let session = SessionCoordinator(
            api: api, secrets: secrets, storage: storage, clock: clock, installId: install,
            locale: { box.snapshot?.locale() ?? .en },
            allowed: { try await box.snapshot?.requireSessionAllowed() },
            onWipe: { box.snapshot?.didWipe() },
            onSessionStarted: {
                guard let engine = box.snapshot else { return }
                Task { await engine.registerPushIfPossible() }
            }
        )
        self.options = options
        self.storage = storage
        self.secrets = secrets
        self.clock = clock
        self.installId = install
        self.api = api
        self.queue = queue
        self.outbox = outbox
        self.session = session
        self.consentStore = ConsentStore(storage: storage)
        self.drafts = DraftStore(storage: storage)
        self.configCache = ConfigCache(storage: storage)
        sessionRef.with { $0 = session }
        box.with { $0 = self }
        state.with { s in
            s.localeOption = options.localeOption
            s.config = self.configCache.load()
            s.pushToken = storage.load(PushRegistration.self, StorageName.push)
        }
        let engine = self
        Task { await engine.outbox.setListener { [weak engine] update in engine?.emit(.outbox(update)) } }
    }

    // MARK: Config, locale, consent

    public var cachedConfig: ChatConfig? { state.with { $0.config } }
    public var isConfigFresh: Bool { state.with { $0.freshConfig } }

    /// Reads the config again. On success the new one is saved. Offline keeps the saved one.
    @discardableResult
    public func refreshConfig() async throws -> ChatConfig {
        do {
            let body = try await api.fetchConfigBody()
            let config = try ChatConfig.parse(body)
            if config.sdkTooOld { throw ChatError.unavailable }
            configCache.save(body: body)
            state.with { s in
                s.config = config
                s.freshConfig = true
            }
            return config
        } catch {
            throw ErrorPolicy.map(error)
        }
    }

    public func locale() -> ChatLocale {
        let (config, option) = state.with { ($0.config, $0.localeOption) }
        return LocaleChoice.choose(option: option, policy: config?.snapshot.language, deviceLanguageCode: options.deviceLanguageCode)
    }

    public func setLocaleOption(_ locale: ChatLocale?) { state.with { $0.localeOption = locale } }

    public func consentState() -> ConsentState? {
        guard let config = cachedConfig else { return nil }
        return ConsentGate.state(config: config, store: consentStore)
    }

    public func acceptConsent() {
        guard let config = cachedConfig else { return }
        consentStore.accept(ConsentTerms(behavior: config.snapshot.behavior))
    }

    /// A session is never started from a saved config alone: the config is read fresh first, then consent is checked.
    func requireSessionAllowed() async throws {
        if !isConfigFresh { try await refreshConfig() }
        guard let config = cachedConfig else { throw ChatError.network }
        if config.sdkTooOld { throw ChatError.unavailable }
        if !ConsentGate.allowsSession(config: config, store: consentStore) { throw ChatError.consentRequired }
    }

    func didWipe() {
        unread.set(0)
        state.with { s in
            s.streamConversationId = nil
        }
        emit(.localDataWiped)
    }

    // MARK: Context

    public func setContext(_ context: ChatContext?) { state.with { $0.context = context?.sanitized() } }
    public var context: ChatContext? { state.with { $0.context } }

    // MARK: Identity

    public func identify(_ provider: @escaping IdentityTokenProvider) {
        let engine = self
        Task {
            await engine.session.setProvider(provider)
            // Only when a session exists already. Otherwise the token is used when the session is made.
            try? await engine.session.identifyCurrentSession()
        }
    }

    public func logout() async {
        await stopRealtime()
        await outbox.cancelAll()
        // Tell the server which push token to forget, then end the session. Local data goes in both cases.
        if let token = await session.token { try? await api.deleteDevice(token: token) }
        await session.logout()
        queue.clear()
        state.with { s in
            // The device token stays: the next session on this phone registers it again.
            s.context = nil
        }
        unread.set(0)
    }

    // MARK: Conversations, unread

    public func cachedConversations() -> ConversationsPage? { storage.load(ConversationsPage.self, StorageName.conversations) }

    public func loadConversations(cursor: String? = nil) async throws -> ConversationsPage {
        do {
            let page = try await session.perform { token in try await self.api.conversations(cursor: cursor, token: token) }
            if cursor == nil { storage.save(page, StorageName.conversations) }
            unread.set(page.unreadTotal)
            return page
        } catch {
            throw ErrorPolicy.map(error)
        }
    }

    public func refreshUnread() async {
        guard ConsentGate.allowsSession(config: cachedConfig, store: consentStore), await session.token != nil else { return }
        if let total = try? await session.perform({ token in try await self.api.unread(token: token) }) { unread.set(total) }
    }

    public func markRead(conversationId: String, upTo: String) async {
        if let total = try? await session.perform({ token in try await self.api.markRead(conversationId: conversationId, upTo: upTo, token: token) }) {
            unread.set(total)
        }
    }

    // MARK: Attachments

    public func upload(data: Data, fileName: String, mimeType: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Attachment {
        do {
            return try await session.perform { token in
                try await self.api.uploadAttachment(data: data, fileName: fileName, mimeType: mimeType, token: token, progress: progress)
            }
        } catch {
            throw ErrorPolicy.map(error)
        }
    }

    // MARK: Push

    public func setPushToken(_ token: String, environment: String?) {
        let registration = PushRegistration(token: token, environment: environment)
        state.with { $0.pushToken = registration }
        storage.save(registration, StorageName.push)
        let engine = self
        Task { await engine.registerPushIfPossible() }
    }

    /// Sends the stored token when a session exists. It never creates a session by itself.
    public func registerPushIfPossible() async {
        guard let registration = state.with({ $0.pushToken }), await session.token != nil else { return }
        let locale = self.locale()
        _ = try? await session.perform { token in
            try await self.api.registerDevice(provider: "apns", pushToken: registration.token, environment: registration.environment, locale: locale, appVersion: self.options.appVersion, token: token)
        }
    }

    // MARK: Events hub

    @discardableResult
    public func addListener(_ listener: @escaping @Sendable (HubEvent) -> Void) -> Int {
        state.with { s in
            s.nextListener += 1
            s.listeners[s.nextListener] = listener
            return s.nextListener
        }
    }

    public func removeListener(_ token: Int) { state.with { $0.listeners[token] = nil } }

    func emit(_ event: HubEvent) {
        let listeners: [@Sendable (HubEvent) -> Void] = state.with { s in
            if case .realtime(let inner) = event {
                if case .ready(let id) = inner { s.streamConversationId = id }
            }
            return Array(s.listeners.values)
        }
        if case .realtime(let inner) = event, case .unread(let total) = inner { unread.set(total) }
        for listener in listeners { listener(event) }
    }

    public var streamConversationId: String? { state.with { $0.streamConversationId } }

    // MARK: Realtime and lifecycle

    public func startRealtime() async {
        let existing = state.with { $0.realtime }
        if let existing = existing { await existing.start(); return }
        let client = RealtimeClient(
            api: api, clock: clock,
            tokenSource: { [weak self] in
                guard let self = self else { throw ChatError.cancelled }
                return try await self.session.ensureSession()
            },
            onEvent: { [weak self] event in self?.emit(.realtime(event)) },
            catchUp: { [weak self] in
                guard let self = self else { return }
                await self.refreshUnread()
                self.emit(.reconnected)
            },
            onFailure: { [weak self] error in
                guard let self = self else { return }
                if ErrorPolicy.reaction(for: error) == .recreateSessionThenRetry { await self.session.invalidateToken() }
            }
        )
        state.with { $0.realtime = client }
        await client.start()
    }

    public func stopRealtime() async {
        if let client = state.with({ $0.realtime }) { await client.stop() }
    }

    /// The app went to the background: close the stream.
    public func enteredBackground() async {
        if let client = state.with({ $0.realtime }) { await client.enteredBackground() }
    }

    /// The app came back: read unread, read newer messages, reopen the stream. Also sends the queue.
    public func enteredForeground() async {
        if let client = state.with({ $0.realtime }) { await client.enteredForeground() } else { await refreshUnread() }
        await outbox.kick()
    }

    public func networkReturned() async { await outbox.networkReturned() }

    public func makeThread(conversationId: String?) -> ThreadController {
        ThreadController(engine: self, conversationId: conversationId)
    }
}
