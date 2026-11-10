import Foundation
import UIKit

/// The only Swift file of this package. It sits between the Objective-C++ module (RNZellioChat.mm) and the
/// ZeeChat iOS SDK, which is compiled into the same pod from ios/vendor. It holds no chat logic.
@objc(ZCRNBridge)
public final class ZCRNBridge: NSObject {
    private static let lock = NSLock()
    private static var unreadToken: Int?
    private static var eventToken: Int?
    private static var onTokenRequest: ((String) -> Void)?
    private static let pending = PendingTokens()

    /// How long native waits for JavaScript to answer a token request.
    private static let tokenTimeout: TimeInterval = 15

    // MARK: Events to JavaScript

    @objc(attachUnread:event:tokenRequest:)
    public static func attach(unread: @escaping (Int) -> Void, event: @escaping (String, String?) -> Void, tokenRequest: @escaping (String) -> Void) {
        detach()
        let unreadToken = ZellioChat.addUnreadListener { count in unread(count) }
        let eventToken = ZellioChat.addEventListener { zellioEvent in event(zellioEvent.name, zellioEvent.code) }
        lock.lock()
        self.unreadToken = unreadToken
        self.eventToken = eventToken
        self.onTokenRequest = tokenRequest
        lock.unlock()
    }

    @objc(detach)
    public static func detach() {
        lock.lock()
        let unreadToken = self.unreadToken
        let eventToken = self.eventToken
        self.unreadToken = nil
        self.eventToken = nil
        self.onTokenRequest = nil
        lock.unlock()
        if let token = unreadToken { ZellioChat.removeUnreadListener(token) }
        if let token = eventToken { ZellioChat.removeEventListener(token) }
        pending.failAll()
    }

    // MARK: Configure and identity

    @objc(configureWithAppKey:options:)
    public static func configure(appKey: String, options: [String: Any]) {
        var result = ZellioChatOptions()
        if let base = options["baseUrl"] as? String, let url = URL(string: base) { result.baseURL = url }
        switch options["locale"] as? String {
        case "ar"?: result.locale = .arabic
        case "en"?: result.locale = .english
        default: result.locale = .auto
        }
        var theme = ZellioChatTheme()
        switch options["themeMode"] as? String {
        case "light"?: theme.mode = .light
        case "dark"?: theme.mode = .dark
        default: theme.mode = .auto
        }
        theme.primaryColor = color(options["primaryColor"])
        theme.customerMessageColor = color(options["customerMessageColor"])
        theme.surfaceColor = color(options["surfaceColor"])
        result.theme = theme
        switch options["logLevel"] as? String {
        case "none"?: result.logLevel = .none
        case "info"?: result.logLevel = .info
        case "debug"?: result.logLevel = .debug
        default: result.logLevel = .error
        }
        if let value = options["showsInAppBanner"] as? Bool { result.showsInAppBanner = value }
        if let value = options["bannerShowsPreview"] as? Bool { result.bannerShowsPreview = value }
        result.wrapper = options["wrapper"] as? String
        ZellioChat.configure(appKey: appKey, options: result)
    }

    @objc(identify)
    public static func identify() {
        ZellioChat.identify { try await requestToken() }
    }

    @objc(resolveTokenWithRequestId:token:errorCode:)
    public static func resolveToken(requestId: String, token: String?, errorCode: String?) {
        if let token = token, !token.isEmpty {
            pending.finish(requestId, .success(token))
        } else {
            pending.finish(requestId, .failure(ZCRNError.rejected(errorCode ?? "no_token")))
        }
    }

    @objc(logout)
    public static func logout() { ZellioChat.logout() }

    // MARK: Presenting and context

    @objc(present)
    public static func present() { ZellioChat.present() }

    @objc(presentConversationWithId:)
    public static func presentConversation(id: String?) { ZellioChat.presentConversation(id: id) }

    @objc(dismiss)
    public static func dismiss() { ZellioChat.dismiss() }

    @objc(setContext:)
    public static func setContext(_ context: [String: Any]?) {
        guard let context = context else {
            ZellioChat.setContext(nil)
            return
        }
        ZellioChat.setContext(ZellioChatContext(
            screen: context["screen"] as? String,
            itemType: context["itemType"] as? String,
            itemId: context["itemId"] as? String,
            itemTitle: context["itemTitle"] as? String,
            url: context["url"] as? String
        ))
    }

    @objc(unreadCount)
    public static func unreadCount() -> Int { ZellioChat.unreadCount }

    // MARK: Push

    @objc(setPushTokenWithHex:environment:)
    public static func setPushToken(hex: String, environment: String?) {
        let env = (environment == "sandbox" || environment == "production") ? environment : nil
        ZellioChat.setPushToken(hex: hex, environment: env)
    }

    @objc(isZellioPushWithJson:)
    public static func isZellioPush(json: String) -> Bool {
        guard let payload = object(json) else { return false }
        return ZellioChat.isZellioPush(payload)
    }

    @objc(handlePushWithJson:)
    public static func handlePush(json: String) -> Bool {
        guard let payload = object(json) else { return false }
        return ZellioChat.handlePush(payload)
    }

    @objc(handleNotificationTapWithJson:)
    public static func handleNotificationTap(json: String) -> Bool {
        guard let payload = object(json) else { return false }
        return ZellioChat.handleNotificationTap(payload)
    }

    // MARK: Helpers

    private static func object(_ json: String) -> [AnyHashable: Any]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }

    /// `#RRGGBB` only. Anything else is ignored and the Studio color stays.
    private static func color(_ value: Any?) -> UIColor? {
        guard var text = value as? String else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let number = UInt32(text, radix: 16) else { return nil }
        return UIColor(red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
                       blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }

    /// The SDK calls this when it needs a session. JavaScript answers through `resolveToken`.
    /// If JavaScript does not answer in 15 seconds, the request fails. The token is never logged.
    private static func requestToken() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            let emit = onTokenRequest
            lock.unlock()
            guard let emit = emit else {
                continuation.resume(throwing: ZCRNError.rejected("no_listener"))
                return
            }
            let requestId = UUID().uuidString
            pending.add(requestId, continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + tokenTimeout) {
                pending.finish(requestId, .failure(ZCRNError.rejected("timeout")))
            }
            emit(requestId)
        }
    }
}

enum ZCRNError: Error {
    /// The code is a short fixed word such as "timeout" or "no_token". Never a token.
    case rejected(String)
}

/// Token requests that wait for JavaScript. Each one finishes once: the first answer or the timeout wins.
private final class PendingTokens {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<String, Error>] = [:]

    func add(_ id: String, _ continuation: CheckedContinuation<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        waiting[id] = continuation
    }

    func finish(_ id: String, _ result: Result<String, Error>) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    func failAll() {
        lock.lock()
        let all = waiting
        waiting.removeAll()
        lock.unlock()
        for (_, continuation) in all { continuation.resume(throwing: ZCRNError.rejected("detached")) }
    }
}
