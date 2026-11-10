#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import UIKit
import ZellioChatCore

public enum ZellioChatLogLevel: Int, Sendable {
    case none = 0
    case error = 1
    case info = 2
    case debug = 3
}

public enum ZellioChatLocale: Sendable {
    /// Follow the device, then the Studio language policy.
    case auto
    case arabic
    case english

    var core: ChatLocale? {
        switch self {
        case .auto: return nil
        case .arabic: return .ar
        case .english: return .en
        }
    }
}

public enum ZellioChatThemeMode: Sendable {
    case auto
    case light
    case dark
}

/// Overrides for the look. A value set here wins over Studio.
public struct ZellioChatTheme {
    public var mode: ZellioChatThemeMode
    public var primaryColor: UIColor?
    public var customerMessageColor: UIColor?
    public var surfaceColor: UIColor?
    /// The PostScript name of a font that the app has registered. Sizes still follow Dynamic Type.
    public var fontName: String?

    public init(mode: ZellioChatThemeMode = .auto, primaryColor: UIColor? = nil, customerMessageColor: UIColor? = nil,
                surfaceColor: UIColor? = nil, fontName: String? = nil) {
        self.mode = mode
        self.primaryColor = primaryColor
        self.customerMessageColor = customerMessageColor
        self.surfaceColor = surfaceColor
        self.fontName = fontName
    }

    var coreMode: ThemeMode? {
        switch mode {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public struct ZellioChatOptions {
    /// Default: https://app.zellio.ai
    public var baseURL: URL?
    public var locale: ZellioChatLocale
    public var theme: ZellioChatTheme
    public var logLevel: ZellioChatLogLevel
    /// The small banner for a new message while chat is closed and the app is open.
    public var showsInAppBanner: Bool
    /// false: the banner says "New message" and never shows the text.
    public var bannerShowsPreview: Bool
    /// Set by the React Native and Flutter wrappers: "react-native/1.0.0".
    public var wrapper: String?
    /// For demos and tests only: replaces the network. Leave nil in a real app.
    public var transport: HTTPTransport?

    public init(baseURL: URL? = nil, locale: ZellioChatLocale = .auto, theme: ZellioChatTheme = ZellioChatTheme(),
                logLevel: ZellioChatLogLevel = .error, showsInAppBanner: Bool = true, bannerShowsPreview: Bool = true, wrapper: String? = nil, transport: HTTPTransport? = nil) {
        self.baseURL = baseURL
        self.locale = locale
        self.theme = theme
        self.logLevel = logLevel
        self.showsInAppBanner = showsInAppBanner
        self.bannerShowsPreview = bannerShowsPreview
        self.transport = transport
        self.wrapper = wrapper
    }
}

/// The page or item the customer looks at. Sent with the next messages. Agents see it.
public struct ZellioChatContext: Equatable, Sendable {
    public var screen: String?
    public var itemType: String?
    public var itemId: String?
    public var itemTitle: String?
    /// Must be https. Other values are dropped.
    public var url: String?

    public init(screen: String? = nil, itemType: String? = nil, itemId: String? = nil, itemTitle: String? = nil, url: String? = nil) {
        self.screen = screen
        self.itemType = itemType
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.url = url
    }

    var core: ChatContext { ChatContext(screen: screen, itemType: itemType, itemId: itemId, itemTitle: itemTitle, url: url) }
}

/// Events for the brand's own analytics. They never carry message text.
public enum ZellioChatEvent: Equatable, Sendable {
    case chatOpened
    case chatClosed
    case messageSent
    case messageReceived
    case error(code: String)

    public var name: String {
        switch self {
        case .chatOpened: return "chatOpened"
        case .chatClosed: return "chatClosed"
        case .messageSent: return "messageSent"
        case .messageReceived: return "messageReceived"
        case .error: return "error"
        }
    }

    public var code: String? {
        if case .error(let code) = self { return code }
        return nil
    }
}

/// Async source of the brand's identity JWT. Called when the SDK needs a session.
public typealias ZellioChatTokenProvider = @Sendable () async throws -> String

/// The unread number, for SwiftUI and UIKit.
public final class ZellioChatUnread: ObservableObject {
    @Published public internal(set) var count: Int = 0
    init() {}
}
#endif
