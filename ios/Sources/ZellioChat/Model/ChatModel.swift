#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import ZellioChatCore

enum ChatRoute: Equatable {
    case loading
    case consent
    case home
    case list
    case thread(String?)
    case unavailable
    case loginNeeded
    case loadFailed
}

enum ChatBanner: Equatable {
    case reconnecting
    case outsideHours(String)
}

/// What the screen asked for when it was presented.
enum ChatEntry: Equatable {
    case `default`
    case conversation(String?)
}

/// The state behind the SwiftUI screens. Thin: all rules live in ZellioChatCore.
final class ChatModel: ObservableObject {
    @Published private(set) var route: ChatRoute = .loading
    @Published private(set) var config: ChatConfig?
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var locale: ChatLocale = .en
    @Published private(set) var banner: ChatBanner?
    @Published private(set) var isIdentified = false
    @Published var themeOverrides: ZellioChatTheme

    let engine: ChatEngine
    private let entry: ChatEntry
    private var history: [ChatRoute] = []
    private var offlineTimer: Task<Void, Never>?
    private var isOffline = false
    private var started = false
    private(set) var activeThread: ThreadController?

    var onClose: () -> Void = {}
    var emit: (ZellioChatEvent) -> Void = { _ in }

    init(engine: ChatEngine, entry: ChatEntry, theme: ZellioChatTheme) {
        self.engine = engine
        self.entry = entry
        self.themeOverrides = theme
        self.locale = engine.locale()
        self.config = engine.cachedConfig
        if let saved = engine.cachedConversations() { self.conversations = saved.conversations }
        self.route = ChatModel.initialRoute(config: engine.cachedConfig, entry: entry)
        if case .thread(let id) = route { activeThread = engine.makeThread(conversationId: id) }
    }

    /// A model for SwiftUI previews and tests. It never touches the network.
    static func preview(config: ChatConfig?, conversations: [ConversationSummary] = [], route: ChatRoute, locale: ChatLocale, banner: ChatBanner? = nil) -> ChatModel {
        let transport = PreviewTransport()
        let engine = ChatEngine(options: EngineOptions(baseURL: URL(string: "https://preview.invalid") ?? URL(fileURLWithPath: "/"), appKey: "preview", localeOption: locale),
                                transport: transport, secrets: MemorySecretStore(), storage: MemoryStorage())
        let model = ChatModel(engine: engine, entry: .default, theme: ZellioChatTheme())
        model.config = config
        model.conversations = conversations
        model.route = route
        model.locale = locale
        model.banner = banner
        model.started = true
        return model
    }

    private static func initialRoute(config: ChatConfig?, entry: ChatEntry) -> ChatRoute {
        guard let config = config else { return .loading }
        if case .conversation(let id) = entry { return .thread(id) }
        return config.snapshot.layout == .chatOnly ? .thread(nil) : .home
    }

    var theme: ChatTheme {
        ChatTheme.make(config: config, locale: locale, systemDark: false, overrides: themeOverrides)
    }

    func theme(systemDark: Bool) -> ChatTheme {
        ChatTheme.make(config: config, locale: locale, systemDark: systemDark, overrides: themeOverrides)
    }

    var isChatOnly: Bool { config?.snapshot.layout == .chatOnly }
    var canGoBack: Bool { !history.isEmpty }
    var allowsAttachments: Bool { config?.snapshot.behavior.allowAttachments ?? true }

    // MARK: Loading

    @MainActor
    func start() async {
        guard !started else { return }
        started = true
        await loadConfigAndContinue()
    }

    @MainActor
    func retry() async {
        route = config == nil ? .loading : route
        await loadConfigAndContinue()
    }

    @MainActor
    private func loadConfigAndContinue() async {
        do {
            let fresh = try await engine.refreshConfig()
            config = fresh
            locale = engine.locale()
        } catch let error as ChatError {
            if error == .unavailable { route = .unavailable; emit(.error(code: error.eventCode)); return }
            if config == nil { route = .loadFailed; emit(.error(code: error.eventCode)); return }
        } catch {
            if config == nil { route = .loadFailed; return }
        }
        guard let config = config else { route = .loadFailed; return }
        if ConsentGate.state(config: config, store: engine.consentStore) == .required {
            route = .consent
            return
        }
        await proceedAfterConsent()
    }

    @MainActor
    func acceptConsent() async {
        engine.acceptConsent()
        await proceedAfterConsent()
    }

    @MainActor
    private func proceedAfterConsent() async {
        guard let config = config else { return }
        locale = engine.locale()
        let target = ChatModel.initialRoute(config: config, entry: entry)
        if case .thread(let id) = target {
            if activeThread == nil { activeThread = engine.makeThread(conversationId: id) }
            route = target
            await engine.startRealtime()
            await refreshIdentity()
            updateBanner()
            return
        }
        route = target
        await reloadConversations()
        await engine.startRealtime()
        await refreshIdentity()
        updateBanner()
    }

    @MainActor
    private func refreshIdentity() async {
        let identified = await engine.session.isIdentified
        if identified != isIdentified { isIdentified = identified }
    }

    @MainActor
    func reloadConversations() async {
        do {
            let page = try await engine.loadConversations()
            conversations = page.conversations
            await refreshIdentity()
        } catch let error as ChatError {
            handle(error)
        } catch {
            // Keep the saved list.
        }
    }

    @MainActor
    private func handle(_ error: ChatError) {
        switch error {
        case .unavailable:
            route = .unavailable
        case .loginNeeded:
            route = .loginNeeded
        default:
            break
        }
        emit(.error(code: error.eventCode))
    }

    // MARK: Navigation

    @MainActor
    func open(_ next: ChatRoute) {
        if next == route { return }
        history.append(route)
        if case .thread(let id) = next {
            activeThread = engine.makeThread(conversationId: id)
        }
        route = next
    }

    @MainActor
    func goBack() {
        guard let previous = history.popLast() else { return }
        // The thread that was on screen may be another one now (a push tap opened it). Make the earlier one again.
        if case .thread(let id) = previous { activeThread = engine.makeThread(conversationId: id) }
        route = previous
        Task { await reloadConversations() }
    }

    @MainActor
    func openNewConversation() {
        // The server decides which conversation a message goes to. A new thread starts empty.
        open(.thread(nil))
    }

    // MARK: Network banner

    func networkChanged(online: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isOffline = !online
            self.offlineTimer?.cancel()
            if online {
                self.updateBanner()
            } else {
                // "Reconnecting" shows after 3 seconds offline.
                self.offlineTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run { self?.updateBanner() }
                }
            }
        }
    }

    @MainActor
    private func updateBanner() {
        if isOffline {
            banner = .reconnecting
        } else if let config = config, !config.online {
            banner = .outsideHours(config.snapshot.screens.offline.resolve(locale) ?? ChatStrings(locale: locale).string("banner.offline"))
        } else {
            banner = nil
        }
    }

    @MainActor
    func refreshBanner() { updateBanner() }

    func stop() {
        offlineTimer?.cancel()
        if let thread = activeThread { Task { await thread.stop() } }
    }
}

/// Never reaches a network. For previews.
final class PreviewTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw ChatAPIError.network }
    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse { throw ChatAPIError.network }
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatAPIError.network) }
    }
}
#endif
