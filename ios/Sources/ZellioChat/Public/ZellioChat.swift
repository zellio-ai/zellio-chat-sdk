#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import UIKit
import ZellioChatCore

/// The ZeeChat SDK. Every call is safe from any thread and returns at once.
/// Calls made before `configure` are ignored and logged when the log level allows.
public enum ZellioChat {
    /// Starts the SDK. Call once at app launch. A second call with the same key only updates the options.
    public static func configure(appKey: String, options: ZellioChatOptions = ZellioChatOptions()) {
        ZellioChatRuntime.shared.configure(appKey: appKey, options: options)
    }

    /// Links chat to your signed-in customer. The provider returns a fresh identity token from your backend.
    /// The SDK calls it again when the token is rejected.
    public static func identify(tokenProvider: @escaping ZellioChatTokenProvider) {
        ZellioChatRuntime.shared.identify(tokenProvider)
    }

    /// Ends the session, removes the push token on the server and deletes the local chat data.
    public static func logout() { ZellioChatRuntime.shared.logout() }

    /// Opens chat on the Home screen. Does nothing while chat is open.
    public static func present() { ZellioChatRuntime.shared.present(entry: .default) }

    /// Opens one conversation. `nil` opens a new one.
    public static func presentConversation(id: String?) { ZellioChatRuntime.shared.present(entry: .conversation(id)) }

    /// Closes chat if it is open.
    public static func dismiss() { ZellioChatRuntime.shared.dismiss() }

    /// The screen or item the customer looks at. Agents see it. Pass `nil` to clear.
    public static func setContext(_ context: ZellioChatContext?) { ZellioChatRuntime.shared.setContext(context) }

    /// The number of unread agent messages, across all conversations.
    public static var unreadCount: Int { ZellioChatRuntime.shared.unreadCount }

    /// An observable object for SwiftUI badges: `@ObservedObject var unread = ZellioChat.unread`.
    public static var unread: ZellioChatUnread { ZellioChatRuntime.shared.unreadState }

    /// Calls back on the main thread now and on every change. Returns a token for `removeUnreadListener`.
    @discardableResult
    public static func addUnreadListener(_ listener: @escaping (Int) -> Void) -> Int {
        ZellioChatRuntime.shared.addUnreadListener(listener)
    }

    public static func removeUnreadListener(_ token: Int) { ZellioChatRuntime.shared.removeUnreadListener(token) }

    /// Events on the main thread. Returns a token for `removeEventListener`.
    @discardableResult
    public static func addEventListener(_ listener: @escaping (ZellioChatEvent) -> Void) -> Int {
        ZellioChatRuntime.shared.addEventListener(listener)
    }

    public static func removeEventListener(_ token: Int) { ZellioChatRuntime.shared.removeEventListener(token) }

    /// A stream of events for Swift concurrency.
    public static var events: AsyncStream<ZellioChatEvent> {
        AsyncStream { continuation in
            let token = ZellioChatRuntime.shared.addEventListener { continuation.yield($0) }
            continuation.onTermination = { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ZellioChatRuntime.shared.removeEventListener(token) } }
            }
        }
    }

    // MARK: Push

    /// Pass the token from `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// `environment` is "sandbox" or "production". Default: sandbox in debug builds, production otherwise.
    public static func setPushToken(_ deviceToken: Data, environment: String? = nil) {
        ZellioChatRuntime.shared.setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined(), environment: environment)
    }

    /// Same, for a token you already turned into a hex string.
    public static func setPushToken(hex: String, environment: String? = nil) {
        ZellioChatRuntime.shared.setPushToken(hex, environment: environment)
    }

    /// True when the payload came from Zellio.
    public static func isZellioPush(_ userInfo: [AnyHashable: Any]) -> Bool { PushPayload.isZellioPush(userInfo) }

    /// Call from `didReceiveRemoteNotification` or `willPresent`. Returns true when the payload is ours.
    @discardableResult
    public static func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool { ZellioChatRuntime.shared.handlePush(userInfo) }

    /// Call from `didReceive response`. Opens the conversation. Returns true when the payload is ours.
    @discardableResult
    public static func handleNotificationTap(_ userInfo: [AnyHashable: Any]) -> Bool {
        ZellioChatRuntime.shared.handleNotificationTap(userInfo)
    }
}

/// The chat as a SwiftUI view, to put in your own navigation or sheet.
public struct ZellioChatView: View {
    @StateObject private var holder = Holder()
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }

    public var body: some View {
        Group {
            if let model = holder.model {
                ChatRootView(model: model, onClose: onClose)
            } else {
                Color.clear
            }
        }
        .onAppear { holder.make() }
    }

    private final class Holder: ObservableObject {
        @Published var model: ChatModel?

        func make() {
            guard model == nil else { return }
            model = ZellioChatRuntime.shared.makeModel(entry: .default)
        }

        // onDisappear also fires on a tab switch or a push, and the controller would not restart on return.
        // The holder goes when the screen is really gone.
        deinit { model?.stop() }
    }
}

/// The chat as a UIKit view controller, to push or present yourself.
public final class ZellioChatViewController: UIViewController {
    /// Called when the customer taps close. Default: dismiss this controller.
    public var onClose: (() -> Void)?

    public override func viewDidLoad() {
        super.viewDidLoad()
        let child = UIHostingController(rootView: ZellioChatView(onClose: { [weak self] in
            guard let self = self else { return }
            if let handler = self.onClose { handler() } else { self.dismiss(animated: true) }
        }))
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
}

/// Objective-C facade. Same calls, plain types.
@objc(ZCZellioChat)
public final class ZCZellioChat: NSObject {
    /// `locale`: "auto", "ar" or "en". `theme`: "auto", "light" or "dark". Nil `baseURL` uses the default.
    @objc public static func configure(appKey: String, baseURL: URL?, locale: String?, theme: String?, primaryColor: UIColor?, fontName: String?, showsInAppBanner: Bool) {
        var options = ZellioChatOptions(baseURL: baseURL, showsInAppBanner: showsInAppBanner)
        switch locale {
        case "ar"?: options.locale = .arabic
        case "en"?: options.locale = .english
        default: options.locale = .auto
        }
        let mode: ZellioChatThemeMode = theme == "light" ? .light : (theme == "dark" ? .dark : .auto)
        options.theme = ZellioChatTheme(mode: mode, primaryColor: primaryColor, fontName: fontName)
        ZellioChat.configure(appKey: appKey, options: options)
    }

    @objc public static func configure(appKey: String) { ZellioChat.configure(appKey: appKey) }

    /// The block gets a completion. Call it with the token, or with nil and an error.
    @objc public static func identify(tokenProvider: @escaping (@escaping (String?, NSError?) -> Void) -> Void) {
        ZellioChat.identify {
            try await withCheckedThrowingContinuation { continuation in
                tokenProvider { token, error in
                    if let token = token {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: "ai.zellio.chat", code: 1))
                    }
                }
            }
        }
    }

    @objc public static func logout() { ZellioChat.logout() }
    @objc public static func present() { ZellioChat.present() }
    @objc public static func presentConversation(id: String?) { ZellioChat.presentConversation(id: id) }
    @objc public static func dismiss() { ZellioChat.dismiss() }

    @objc public static func setContext(screen: String?, itemType: String?, itemId: String?, itemTitle: String?, url: String?) {
        ZellioChat.setContext(ZellioChatContext(screen: screen, itemType: itemType, itemId: itemId, itemTitle: itemTitle, url: url))
    }

    @objc public static func clearContext() { ZellioChat.setContext(nil) }
    @objc public static var unreadCount: Int { ZellioChat.unreadCount }

    @objc @discardableResult
    public static func addUnreadListener(_ listener: @escaping (Int) -> Void) -> Int { ZellioChat.addUnreadListener(listener) }
    @objc public static func removeUnreadListener(_ token: Int) { ZellioChat.removeUnreadListener(token) }

    /// The block gets the event name ("chatOpened", "chatClosed", "messageSent", "messageReceived", "error") and an error code or nil.
    @objc @discardableResult
    public static func addEventListener(_ listener: @escaping (String, String?) -> Void) -> Int {
        ZellioChat.addEventListener { listener($0.name, $0.code) }
    }

    @objc public static func removeEventListener(_ token: Int) { ZellioChat.removeEventListener(token) }

    @objc public static func setPushToken(data: Data) { ZellioChat.setPushToken(data) }
    @objc public static func setPushToken(data: Data, environment: String?) { ZellioChat.setPushToken(data, environment: environment) }
    @objc public static func isZellioPush(_ userInfo: [AnyHashable: Any]) -> Bool { ZellioChat.isZellioPush(userInfo) }
    @objc public static func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool { ZellioChat.handlePush(userInfo) }
    @objc public static func handleNotificationTap(_ userInfo: [AnyHashable: Any]) -> Bool { ZellioChat.handleNotificationTap(userInfo) }
}
#endif
