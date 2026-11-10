#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import UIKit
import ZellioChatCore

/// The process-wide state behind the `ZellioChat` calls. Every public call goes through here.
/// All entry points are safe from any thread, never block the caller, and do nothing before `configure`.
final class ZellioChatRuntime: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = ZellioChatRuntime()

    private let queue = DispatchQueue(label: "ai.zellio.chat.runtime")
    private let lock = NSLock()
    private var engine: ChatEngine?
    private var options = ZellioChatOptions()
    private var appKey = ""
    private var eventListeners: [Int: (ZellioChatEvent) -> Void] = [:]
    private var unreadListeners: [Int: (Int) -> Void] = [:]
    private var nextToken = 0
    private let network = NetworkMonitor()
    private var observersAdded = false
    private var pendingTapConversation: String??
    let unreadState = ZellioChatUnread()

    // Main thread only.
    private var model: ChatModel?
    private weak var hosting: ChatHostingController?
    private var banner: InAppBannerController?

    private override init() { super.init() }

    private var currentEngine: ChatEngine? { lock.lock(); defer { lock.unlock() }; return engine }
    private var currentOptions: ZellioChatOptions { lock.lock(); defer { lock.unlock() }; return options }

    // MARK: Configure

    func configure(appKey: String, options newOptions: ZellioChatOptions) {
        queue.async { [self] in
            SDKLog.level = newOptions.logLevel
            if currentEngine != nil && self.appKey == appKey {
                lock.lock(); options = newOptions; lock.unlock()
                currentEngine?.setLocaleOption(newOptions.locale.core)
                return
            }
            guard !appKey.isEmpty else { SDKLog.log(.error, "configure: the app key is empty"); return }
            let base = newOptions.baseURL ?? URL(string: SDKInfo.defaultBaseURL) ?? URL(fileURLWithPath: "/")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let engine = ChatEngine(
                options: EngineOptions(baseURL: base, appKey: appKey, localeOption: newOptions.locale.core,
                                       deviceLanguageCode: Locale.preferredLanguages.first, wrapper: newOptions.wrapper, appVersion: version),
                transport: newOptions.transport ?? URLSessionTransport(), secrets: KeychainSecretStore(), storage: AppleStorage.make(appKey: appKey)
            )
            lock.lock()
            self.engine = engine
            self.appKey = appKey
            self.options = newOptions
            lock.unlock()

            _ = engine.unread.add { [weak self] count in
                DispatchQueue.main.async {
                    self?.unreadState.count = count
                    self?.notifyUnread(count)
                }
            }
            // Engine and network callbacks come from other threads. The main queue keeps their order.
            _ = engine.addListener { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }
            network.onChange = { [weak self] online in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = self, let engine = self.currentEngine else { return }
                        self.model?.networkChanged(online: online)
                        if online { Task { await engine.networkReturned() } }
                    }
                }
            }
            network.start()
            DispatchQueue.main.async { self.addLifecycleObservers() }
            Task { @MainActor in
                await engine.refreshUnread()
                await self.startStreamIfPossible()
                if let pending = self.takePendingTap() { DispatchQueue.main.async { self.presentChat(entry: .conversation(pending)) } }
            }
        }
    }

    private func takePendingTap() -> String?? {
        lock.lock(); defer { lock.unlock() }
        let value = pendingTapConversation
        pendingTapConversation = nil
        return value
    }

    // MARK: Lifecycle

    private func addLifecycleObservers() {
        guard !observersAdded else { return }
        observersAdded = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func didBecomeActive() {
        guard let engine = currentEngine else { return }
        Task {
            await engine.enteredForeground()
            await self.startStreamIfPossible()
        }
    }

    @objc private func didEnterBackground() {
        guard let engine = currentEngine else { return }
        Task { await engine.enteredBackground() }
    }

    /// The stream runs while the app is open and a session exists, so a new message can show the banner.
    /// Never before consent: no session, no stream.
    private func startStreamIfPossible() async {
        guard let engine = currentEngine, await engine.session.token != nil,
              ConsentGate.allowsSession(config: engine.cachedConfig, store: engine.consentStore) else { return }
        await engine.startRealtime()
    }

    // MARK: Identity and context

    func identify(_ provider: @escaping ZellioChatTokenProvider) {
        queue.async { [self] in
            guard let engine = currentEngine else { SDKLog.log(.error, "identify called before configure"); return }
            engine.identify(provider)
        }
    }

    func logout() {
        queue.async { [self] in
            guard let engine = currentEngine else { SDKLog.log(.error, "logout called before configure"); return }
            Task {
                await engine.logout()
                DispatchQueue.main.async { self.dismissChat(emit: true) }
            }
        }
    }

    func setContext(_ context: ZellioChatContext?) {
        queue.async { [self] in
            guard let engine = currentEngine else { return }
            engine.setContext(context?.core)
        }
    }

    // MARK: Push

    func setPushToken(_ token: String, environment: String?) {
        queue.async { [self] in
            guard let engine = currentEngine else { SDKLog.log(.error, "setPushToken called before configure"); return }
            engine.setPushToken(token, environment: environment ?? ZellioChatRuntime.defaultPushEnvironment)
        }
    }

    static var defaultPushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func handlePush(_ payload: [AnyHashable: Any]) -> Bool {
        guard PushPayload.isZellioPush(payload) else { return false }
        queue.async { [self] in
            guard let engine = currentEngine else { return }
            Task {
                await engine.refreshUnread()
                DispatchQueue.main.async { self.model?.catchUpActiveThread() }
            }
        }
        return true
    }

    func handleNotificationTap(_ payload: [AnyHashable: Any]) -> Bool {
        guard PushPayload.isZellioPush(payload) else { return false }
        let conversationId = PushPayload.parse(payload)?.conversationId
        queue.async { [self] in
            if currentEngine == nil {
                // The app is still starting. Open the conversation as soon as configure is done.
                lock.lock(); pendingTapConversation = .some(conversationId); lock.unlock()
                return
            }
            DispatchQueue.main.async { self.presentChat(entry: .conversation(conversationId)) }
        }
        return true
    }

    // MARK: Events

    @discardableResult
    func addEventListener(_ listener: @escaping (ZellioChatEvent) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextToken += 1
        eventListeners[nextToken] = listener
        return nextToken
    }

    func removeEventListener(_ token: Int) { lock.lock(); eventListeners[token] = nil; lock.unlock() }

    @discardableResult
    func addUnreadListener(_ listener: @escaping (Int) -> Void) -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        unreadListeners[token] = listener
        lock.unlock()
        let current = unreadState.count
        DispatchQueue.main.async { listener(current) }
        return token
    }

    func removeUnreadListener(_ token: Int) { lock.lock(); unreadListeners[token] = nil; lock.unlock() }

    func emit(_ event: ZellioChatEvent) {
        lock.lock()
        let listeners = Array(eventListeners.values)
        lock.unlock()
        DispatchQueue.main.async { for listener in listeners { listener(event) } }
    }

    private func notifyUnread(_ count: Int) {
        lock.lock()
        let listeners = Array(unreadListeners.values)
        lock.unlock()
        for listener in listeners { listener(count) }
    }

    var unreadCount: Int { currentEngine?.unread.count ?? 0 }

    private func handle(_ event: HubEvent) {
        switch event {
        case .outbox(let update):
            switch update {
            case .sent: emit(.messageSent)
            case .failed: emit(.error(code: "send_failed"))
            case .changed: break
            }
        case .realtime(let realtime):
            if case .message(let message, _) = realtime, message.from == .agent {
                emit(.messageReceived)
                DispatchQueue.main.async { self.showBanner(for: message) }
            }
        case .localDataWiped:
            ImageLoader.shared.clear()
        case .reconnected:
            break
        }
    }

    // MARK: Presenting (main thread)

    func present(entry: ChatEntry) {
        // `configure` runs on `queue`. Going through the queue first puts the present after a configure that came before it.
        queue.async { [self] in
            DispatchQueue.main.async { self.presentChat(entry: entry) }
        }
    }

    func dismiss() {
        DispatchQueue.main.async { self.dismissChat(emit: true) }
    }

    /// A model for the embedded view. Nil before `configure`.
    func makeModel(entry: ChatEntry) -> ChatModel? {
        guard let engine = currentEngine else { return nil }
        let model = ChatModel(engine: engine, entry: entry, theme: currentOptions.theme)
        model.emit = { [weak self] event in self?.emit(event) }
        return model
    }

    private func presentChat(entry: ChatEntry, canRetry: Bool = true) {
        guard hosting == nil else {
            if case .conversation = entry { model?.openFromOutside(entry) }
            return
        }
        // A cold start from a push tap has no window yet. The presenter must be on screen.
        guard let presenter = ChatPresenter.topViewController(), presenter.viewIfLoaded?.window != nil else {
            retryPresent(entry: entry, canRetry: canRetry, reason: "no visible view controller to present from")
            return
        }
        guard let model = makeModel(entry: entry) else { SDKLog.log(.error, "present called before configure"); return }
        banner?.hide(animated: false)
        self.model = model
        let root = ChatRootView(model: model, onClose: { [weak self] in self?.dismissChat(emit: true) },
                                onStatusBarStyle: { [weak self] style in self?.hosting?.statusBarStyle = style })
        let controller = ChatHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        switch currentOptions.theme.mode {
        case .light: controller.overrideUserInterfaceStyle = .light
        case .dark: controller.overrideUserInterfaceStyle = .dark
        case .auto: break
        }
        if presenter.traitCollection.userInterfaceIdiom == .pad {
            // iPad: a form sheet. It works in split view and in every orientation.
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 640, height: 720)
        } else {
            controller.modalPresentationStyle = .overFullScreen
            // Over full screen, the host app keeps the status bar unless the chat asks for it.
            controller.modalPresentationCapturesStatusBarAppearance = true
        }
        controller.presentationController?.delegate = self
        hosting = controller
        presenter.present(controller, animated: true)
        guard controller.presentingViewController != nil else {
            // UIKit refused (an alert on top, or another transition). Clean up and do not report an opened chat.
            controller.presentationController?.delegate = nil
            hosting = nil
            model.stop()
            self.model = nil
            retryPresent(entry: entry, canRetry: canRetry, reason: "the presenter refused the chat")
            return
        }
        emit(.chatOpened)
    }

    private func retryPresent(entry: ChatEntry, canRetry: Bool, reason: String) {
        guard canRetry else { SDKLog.log(.error, "present failed: \(reason)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.presentChat(entry: entry, canRetry: false) }
    }

    private func dismissChat(emit shouldEmit: Bool) {
        guard let hosting = hosting else { return }
        self.hosting = nil
        model?.stop()
        model = nil
        hosting.dismiss(animated: true)
        if shouldEmit { emit(.chatClosed) }
        queue.async { [self] in
            Task { await self.startStreamIfPossible() }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // The customer swiped the form sheet down.
        hosting = nil
        model?.stop()
        model = nil
        emit(.chatClosed)
    }

    // MARK: In-app banner

    private func showBanner(for message: ChatMessage) {
        guard hosting == nil, currentOptions.showsInAppBanner, UIApplication.shared.applicationState == .active, let engine = currentEngine else { return }
        let controller = banner ?? InAppBannerController()
        banner = controller
        let window = ChatPresenter.keyWindow()
        let dark = (window?.traitCollection.userInterfaceStyle ?? .light) == .dark
        let theme = ChatTheme.make(config: engine.cachedConfig, locale: engine.locale(), systemDark: dark, overrides: currentOptions.theme)
        let strings = theme.strings
        var line = message.text.split(separator: "\n").first.map(String.init) ?? ""
        if line.isEmpty { line = message.attachments.isEmpty ? strings.string("thread.newMessage") : strings.string("attachment.photo") }
        if !currentOptions.bannerShowsPreview { line = strings.string("thread.newMessage") }
        let name = message.agentName ?? theme.brandName
        controller.show(name: name, brand: theme.brandName, text: line, avatarURL: message.agentAvatarUrl, theme: theme, in: window) { [weak self] in
            self?.presentChat(entry: .default)
        }
    }
}

final class ChatHostingController: UIHostingController<ChatRootView> {
    var statusBarStyle: UIStatusBarStyle = .default {
        didSet { if statusBarStyle != oldValue { setNeedsStatusBarAppearanceUpdate() } }
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }
}

enum ChatPresenter {
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let candidates = (active.isEmpty ? scenes : active).flatMap { $0.windows }
        return candidates.first { $0.isKeyWindow } ?? candidates.first
    }

    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

extension ChatModel {
    /// Opens a conversation while the chat is already on screen (a push tap).
    func openFromOutside(_ entry: ChatEntry) {
        if case .conversation(let id) = entry {
            DispatchQueue.main.async { self.open(.thread(id)) }
        }
    }

    func catchUpActiveThread() {
        guard let thread = activeThread else { return }
        Task { await thread.catchUp() }
    }
}
#endif
