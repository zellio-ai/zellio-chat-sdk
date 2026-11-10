import Flutter
import UIKit

// The native iOS SDK sources are copied next to this file (Vendor/) by scripts/vendor-ios.sh and compile into
// this same module, so `ZellioChat`, `ZellioChatOptions` and the other SDK types are used without an import.

/// A thin bridge between Dart and the native ZeeChat SDK. It holds no chat logic and draws nothing.
/// Method and event names match `lib/src/zellio_chat.dart`.
public final class ZellioChatPlugin: NSObject, FlutterPlugin {
    private let methods: FlutterMethodChannel
    private let eventsHandler = ZellioEventsHandler()
    private let unreadHandler = ZellioUnreadHandler()
    private let tokenBridge: ZellioTokenBridge

    private init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "ai.zellio.chat/methods", binaryMessenger: messenger)
        tokenBridge = ZellioTokenBridge(channel: methods)
        super.init()
        FlutterEventChannel(name: "ai.zellio.chat/events", binaryMessenger: messenger).setStreamHandler(eventsHandler)
        FlutterEventChannel(name: "ai.zellio.chat/unread", binaryMessenger: messenger).setStreamHandler(unreadHandler)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ZellioChatPlugin(messenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: instance.methods)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "configure":
            configure(args)
            result(nil)
        case "identify":
            let bridge = tokenBridge
            ZellioChat.identify { try await bridge.fetch() }
            result(nil)
        case "logout":
            ZellioChat.logout()
            result(nil)
        case "present":
            ZellioChat.present()
            result(nil)
        case "presentConversation":
            ZellioChat.presentConversation(id: args?["conversationId"] as? String)
            result(nil)
        case "dismiss":
            ZellioChat.dismiss()
            result(nil)
        case "setContext":
            if let args = args {
                ZellioChat.setContext(ZellioChatContext(
                    screen: args["screen"] as? String,
                    itemType: args["itemType"] as? String,
                    itemId: args["itemId"] as? String,
                    itemTitle: args["itemTitle"] as? String,
                    url: args["url"] as? String))
            } else {
                ZellioChat.setContext(nil)
            }
            result(nil)
        case "unreadCount":
            result(ZellioChat.unreadCount)
        case "setPushToken":
            if let token = args?["token"] as? String, !token.isEmpty {
                ZellioChat.setPushToken(hex: token, environment: args?["environment"] as? String)
            }
            result(nil)
        case "isZellioPush":
            result(ZellioChat.isZellioPush(args ?? [:]))
        case "handlePush":
            result(ZellioChat.handlePush(args ?? [:]))
        case "handleNotificationTap":
            result(ZellioChat.handleNotificationTap(args ?? [:]))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func configure(_ args: [String: Any]?) {
        guard let args = args, let appKey = args["appKey"] as? String, !appKey.isEmpty else { return }
        var options = ZellioChatOptions()
        if let base = args["baseUrl"] as? String, !base.isEmpty, let url = URL(string: base) {
            options.baseURL = url
        }
        switch args["locale"] as? String {
        case "ar": options.locale = .arabic
        case "en": options.locale = .english
        default: options.locale = .auto
        }
        let theme = args["theme"] as? [String: Any]
        let mode: ZellioChatThemeMode
        switch theme?["mode"] as? String {
        case "light": mode = .light
        case "dark": mode = .dark
        default: mode = .auto
        }
        options.theme = ZellioChatTheme(
            mode: mode,
            primaryColor: ZellioChatPlugin.color(theme?["primaryColor"] as? String),
            customerMessageColor: ZellioChatPlugin.color(theme?["customerMessageColor"] as? String),
            surfaceColor: ZellioChatPlugin.color(theme?["surfaceColor"] as? String))
        switch args["logLevel"] as? String {
        case "none": options.logLevel = .none
        case "info": options.logLevel = .info
        case "debug": options.logLevel = .debug
        default: options.logLevel = .error  // "error" and "warn": the iOS SDK has no warn level
        }
        options.showsInAppBanner = (args["showsInAppBanner"] as? Bool) ?? true
        options.bannerShowsPreview = (args["bannerShowsPreview"] as? Bool) ?? true
        options.wrapper = args["wrapper"] as? String
        ZellioChat.configure(appKey: appKey, options: options)
    }

    /// `#RRGGBB` to a color. Anything else gives nil, so the Studio color stays.
    private static func color(_ hex: String?) -> UIColor? {
        guard var text = hex, text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

/// Asks Dart for the identity token. Dart times out after 15 s; this guard answers after 20 s if Dart never does.
private final class ZellioTokenBridge: @unchecked Sendable {
    private let channel: FlutterMethodChannel

    init(channel: FlutterMethodChannel) { self.channel = channel }

    private struct TokenError: Error { let reason: String }

    /// Makes sure a continuation is resumed once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, Error>

        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { continuation.resume(with: result) }
        }
    }

    func fetch() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                once.finish(.failure(TokenError(reason: "timeout")))
            }
            DispatchQueue.main.async { [channel] in
                channel.invokeMethod("identifyToken", arguments: nil) { value in
                    if let token = value as? String, !token.isEmpty {
                        once.finish(.success(token))
                    } else {
                        // Nil means logged out. An error or "not implemented" is a failure. Either way: no token.
                        once.finish(.failure(TokenError(reason: "no_token")))
                    }
                }
            }
        }
    }
}

private final class ZellioEventsHandler: NSObject, FlutterStreamHandler {
    private var token: Int?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if let old = token { ZellioChat.removeEventListener(old) }
        token = ZellioChat.addEventListener { event in
            var map: [String: Any] = ["type": event.name]
            if let code = event.code { map["code"] = code }
            events(map)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let old = token { ZellioChat.removeEventListener(old) }
        token = nil
        return nil
    }
}

private final class ZellioUnreadHandler: NSObject, FlutterStreamHandler {
    private var token: Int?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if let old = token { ZellioChat.removeUnreadListener(old) }
        token = ZellioChat.addUnreadListener { count in events(count) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let old = token { ZellioChat.removeUnreadListener(old) }
        token = nil
        return nil
    }
}
