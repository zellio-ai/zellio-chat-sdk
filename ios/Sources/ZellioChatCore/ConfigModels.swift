import Foundation

public enum ChatLocale: String, Codable, Equatable, Sendable {
    case ar
    case en

    public var isRTL: Bool { self == .ar }
    public var other: ChatLocale { self == .ar ? .en : .ar }
}

public struct LocalizedText: Codable, Equatable, Sendable {
    public var ar: String?
    public var en: String?

    public init(ar: String? = nil, en: String? = nil) {
        self.ar = ar
        self.en = en
    }

    private enum CodingKeys: String, CodingKey { case ar, en }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(ar: container.lenient(String.self, .ar), en: container.lenient(String.self, .en))
    }

    /// The text for a locale. Falls back to the other language when one is empty.
    public func resolve(_ locale: ChatLocale) -> String? {
        let first = locale == .ar ? ar : en
        let second = locale == .ar ? en : ar
        if let first = first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return first }
        if let second = second, !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return second }
        return nil
    }
}

/// Only https, mailto and tel are opened. Never anything else.
public enum LinkPolicy {
    public static func isSafe(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("https://") { return URL(string: lower) != nil && lower.count > 8 }
        if lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") { return lower.count > 7 || lower.hasPrefix("tel:") && lower.count > 4 }
        return false
    }
}

public enum ThemeMode: String, Equatable, Sendable { case auto, light, dark }
public enum Density: String, Equatable, Sendable { case comfortable, compact }
public enum Corners: String, Equatable, Sendable { case rounded, square }
public enum HeaderStyle: String, Equatable, Sendable { case gradient, solid, light }
public enum ChatLayout: String, Equatable, Sendable {
    case chatOnly = "chat-only"
    case support
    case faqFirst = "faq-first"
}

public struct Appearance: Equatable, Sendable {
    public var brandName: String = ""
    public var logoAlt: LocalizedText = LocalizedText()
    public var primaryColor: String = "#7D3BED"
    public var customerMessageColor: String = "#7D3BED"
    public var surfaceColor: String = "#FFFFFF"
    public var theme: ThemeMode = .auto
    public var density: Density = .comfortable
    public var corners: Corners = .rounded
    public var headerStyle: HeaderStyle = .gradient
    public var showAgentAvatar: Bool = true
    public var showAttribution: Bool = true
    public var soundEnabled: Bool = false
    public var unreadBadge: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case brandName, logoAlt, primaryColor, customerMessageColor, surfaceColor, theme, density
        case corners, headerStyle, showAgentAvatar, showAttribution, soundEnabled, unreadBadge
    }

    init(decoding decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        brandName = c.lenient(String.self, .brandName) ?? ""
        logoAlt = c.lenient(LocalizedText.self, .logoAlt) ?? LocalizedText()
        primaryColor = HexColor(c.lenient(String.self, .primaryColor) ?? "")?.hex ?? primaryColor
        customerMessageColor = HexColor(c.lenient(String.self, .customerMessageColor) ?? "")?.hex ?? primaryColor
        surfaceColor = HexColor(c.lenient(String.self, .surfaceColor) ?? "")?.hex ?? surfaceColor
        theme = ThemeMode(rawValue: c.lenient(String.self, .theme) ?? "") ?? .auto
        density = Density(rawValue: c.lenient(String.self, .density) ?? "") ?? .comfortable
        corners = Corners(rawValue: c.lenient(String.self, .corners) ?? "") ?? .rounded
        headerStyle = HeaderStyle(rawValue: c.lenient(String.self, .headerStyle) ?? "") ?? .gradient
        showAgentAvatar = c.lenient(Bool.self, .showAgentAvatar) ?? true
        showAttribution = c.lenient(Bool.self, .showAttribution) ?? true
        soundEnabled = c.lenient(Bool.self, .soundEnabled) ?? false
        unreadBadge = c.lenient(Bool.self, .unreadBadge) ?? true
    }
}

public struct ContactLink: Equatable, Sendable {
    public var label: LocalizedText
    public var href: String
}

public struct ModuleVisibility: Equatable, Sendable {
    public var locales: [ChatLocale]?
    public var availability: String?
    public var customer: String?
    public init(locales: [ChatLocale]? = nil, availability: String? = nil, customer: String? = nil) {
        self.locales = locales
        self.availability = availability
        self.customer = customer
    }
}

public enum HomeModuleKind: String, Equatable, Sendable {
    case greeting
    case announcement
    case startConversation = "start-conversation"
    case externalLink = "external-link"
    case contactLinks = "contact-links"
}

public struct HomeModule: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: HomeModuleKind
    public var label: LocalizedText
    public var description: LocalizedText
    public var primary: Bool
    public var href: String?
    public var links: [ContactLink]
    public var visibility: ModuleVisibility

    public init(id: String, kind: HomeModuleKind, label: LocalizedText = LocalizedText(), description: LocalizedText = LocalizedText(),
                primary: Bool = false, href: String? = nil, links: [ContactLink] = [], visibility: ModuleVisibility = ModuleVisibility()) {
        self.id = id
        self.kind = kind
        self.label = label
        self.description = description
        self.primary = primary
        self.href = href
        self.links = links
        self.visibility = visibility
    }

    /// Hidden by locale, availability or customer visibility.
    public func isVisible(locale: ChatLocale, online: Bool, verified: Bool) -> Bool {
        if let locales = visibility.locales, !locales.contains(locale) { return false }
        if let availability = visibility.availability {
            if availability == "online" && !online { return false }
            if availability == "offline" && online { return false }
        }
        if let customer = visibility.customer {
            if customer == "verified" && !verified { return false }
            if customer == "anonymous" && verified { return false }
        }
        return true
    }
}

private struct RawModule: Decodable {
    var id: String?
    var type: String?
    var label: LocalizedText?
    var description: LocalizedText?
    var primary: Bool?
    var href: String?
    var disabled: Bool?
    var links: [RawLink]?
    var visibility: RawVisibility?

    private enum CodingKeys: String, CodingKey { case id, type, label, description, primary, href, disabled, links, visibility }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        type = c.lenient(String.self, .type)
        label = c.lenient(LocalizedText.self, .label)
        description = c.lenient(LocalizedText.self, .description)
        primary = c.lenient(Bool.self, .primary)
        href = c.lenient(String.self, .href)
        disabled = c.lenient(Bool.self, .disabled)
        links = c.lenient(LossyArray<RawLink>.self, .links)?.items
        visibility = c.lenient(RawVisibility.self, .visibility)
    }

    /// Nil for an unknown type, a disabled module or a module without its required fields.
    func build() -> HomeModule? {
        guard let type = type, let kind = HomeModuleKind(rawValue: type), disabled != true else { return nil }
        let visible = ModuleVisibility(
            locales: visibility?.locales?.compactMap { ChatLocale(rawValue: $0) },
            availability: visibility?.availability,
            customer: visibility?.customer
        )
        var module = HomeModule(
            id: id ?? UUID().uuidString, kind: kind, label: label ?? LocalizedText(),
            description: description ?? LocalizedText(), primary: primary ?? false, visibility: visible
        )
        switch kind {
        case .externalLink:
            guard let href = href, LinkPolicy.isSafe(href) else { return nil }
            module.href = href
        case .contactLinks:
            module.links = (links ?? []).compactMap { link in
                guard let href = link.href, LinkPolicy.isSafe(href) else { return nil }
                return ContactLink(label: link.label ?? LocalizedText(), href: href)
            }
            if module.links.isEmpty { return nil }
        default:
            break
        }
        return module
    }
}

private struct RawLink: Decodable {
    var label: LocalizedText?
    var href: String?
    private enum CodingKeys: String, CodingKey { case label, href }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.lenient(LocalizedText.self, .label)
        href = c.lenient(String.self, .href)
    }
}

private struct RawVisibility: Decodable {
    var locales: [String]?
    var availability: String?
    var customer: String?
    private enum CodingKeys: String, CodingKey { case locales, availability, customer }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locales = c.lenient([String].self, .locales)
        availability = c.lenient(String.self, .availability)
        customer = c.lenient(String.self, .customer)
    }
}

public enum LanguagePolicy: Equatable, Sendable {
    case single(ChatLocale)
    case both(defaultLocale: ChatLocale, startIn: String)
}

public struct ScreenTexts: Equatable, Sendable {
    public var heading = LocalizedText()
    public var greeting = LocalizedText()
    public var description = LocalizedText()
    public var offline = LocalizedText()
    public init() {}
}

public struct Behavior: Equatable, Sendable {
    public var allowAttachments = true
    public var replyExpectation = LocalizedText()
    public var consentRequired = false
    public var consentText = LocalizedText()
    public var privacyUrl: String?
    public init() {}
}

public struct SiteSnapshot: Equatable, Sendable {
    public var siteId: String = ""
    public var versionId: String = ""
    public var layout: ChatLayout = .support
    public var language: LanguagePolicy = .both(defaultLocale: .en, startIn: "browser")
    public var appearance = Appearance()
    public var modules: [HomeModule] = []
    public var screens = ScreenTexts()
    public var behavior = Behavior()
    public init() {}
}

public struct ChatConfig: Equatable, Sendable {
    public var snapshot = SiteSnapshot()
    public var logoUrl: String?
    public var online: Bool = true
    public var allowGuests: Bool = true
    public var minSdkVersion: String?
    public init() {}

    public var versionId: String { snapshot.versionId }

    /// Home modules that this SDK draws, in snapshot order, for this viewer.
    public func homeModules(locale: ChatLocale, verified: Bool) -> [HomeModule] {
        snapshot.modules.filter { $0.isVisible(locale: locale, online: online, verified: verified) }
    }

    public func consentText(locale: ChatLocale) -> String {
        snapshot.behavior.consentText.resolve(locale) ?? ChatStrings(locale: locale).string("consent.default")
    }

    /// True when this SDK version is older than the app's minimum.
    public var sdkTooOld: Bool {
        guard let minimum = minSdkVersion, !minimum.isEmpty else { return false }
        return SemVer.compare(SDKInfo.version, minimum) < 0
    }

    /// Reads the full response body: `{ "data": { ... } }`. Also accepts the inner object alone.
    public static func parse(_ body: Data) throws -> ChatConfig {
        let root = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        guard let object = root as? [String: Any] else { throw ChatAPIError.decoding }
        let inner = (object["data"] as? [String: Any]) ?? object
        let data = try JSONSerialization.data(withJSONObject: inner)
        let raw = try JSONDecoder().decode(RawConfig.self, from: data)
        return raw.build()
    }
}

private struct RawConfig: Decodable {
    var snapshot: RawSnapshot?
    var logoUrl: String?
    var online: Bool?
    var allowGuests: Bool?
    var minSdkVersion: String?

    private enum CodingKeys: String, CodingKey { case snapshot, assets, availability, app }
    private enum AssetKeys: String, CodingKey { case logoUrl }
    private enum AvailabilityKeys: String, CodingKey { case online }
    private enum AppKeys: String, CodingKey { case allowGuests, minSdkVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = c.lenient(RawSnapshot.self, .snapshot)
        if let a = try? c.nestedContainer(keyedBy: AssetKeys.self, forKey: .assets) { logoUrl = a.lenient(String.self, .logoUrl) }
        if let a = try? c.nestedContainer(keyedBy: AvailabilityKeys.self, forKey: .availability) { online = a.lenient(Bool.self, .online) }
        if let a = try? c.nestedContainer(keyedBy: AppKeys.self, forKey: .app) {
            allowGuests = a.lenient(Bool.self, .allowGuests)
            minSdkVersion = a.lenient(String.self, .minSdkVersion)
        }
    }

    func build() -> ChatConfig {
        var config = ChatConfig()
        config.snapshot = snapshot?.build() ?? SiteSnapshot()
        config.logoUrl = logoUrl
        config.online = online ?? true
        config.allowGuests = allowGuests ?? true
        config.minSdkVersion = minSdkVersion
        return config
    }
}

private struct RawSnapshot: Decodable {
    var built = SiteSnapshot()

    private enum CodingKeys: String, CodingKey {
        case siteId, versionId, layout, language, appearance, modules, screens, behavior
    }
    private enum LanguageKeys: String, CodingKey { case mode, locale, defaultLocale, startIn }
    private enum ScreenKeys: String, CodingKey { case heading, greeting, description, offline }
    private enum BehaviorKeys: String, CodingKey {
        case allowAttachments, replyExpectation, consentRequired, consentText, privacyUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        built.siteId = c.lenient(String.self, .siteId) ?? ""
        built.versionId = c.lenient(String.self, .versionId) ?? ""
        built.layout = ChatLayout(rawValue: c.lenient(String.self, .layout) ?? "") ?? .support
        if let l = try? c.nestedContainer(keyedBy: LanguageKeys.self, forKey: .language) {
            let mode = l.lenient(String.self, .mode) ?? "both"
            if mode == "single", let locale = ChatLocale(rawValue: l.lenient(String.self, .locale) ?? "") {
                built.language = .single(locale)
            } else {
                let fallback = ChatLocale(rawValue: l.lenient(String.self, .defaultLocale) ?? "") ?? .en
                built.language = .both(defaultLocale: fallback, startIn: l.lenient(String.self, .startIn) ?? "browser")
            }
        }
        if let a = try? c.superDecoder(forKey: .appearance) { built.appearance = Appearance(decoding: a) }
        built.modules = (c.lenient(LossyArray<RawModule>.self, .modules)?.items ?? []).compactMap { $0.build() }
        if let s = try? c.nestedContainer(keyedBy: ScreenKeys.self, forKey: .screens) {
            built.screens.heading = s.lenient(LocalizedText.self, .heading) ?? LocalizedText()
            built.screens.greeting = s.lenient(LocalizedText.self, .greeting) ?? LocalizedText()
            built.screens.description = s.lenient(LocalizedText.self, .description) ?? LocalizedText()
            built.screens.offline = s.lenient(LocalizedText.self, .offline) ?? LocalizedText()
        }
        if let b = try? c.nestedContainer(keyedBy: BehaviorKeys.self, forKey: .behavior) {
            built.behavior.allowAttachments = b.lenient(Bool.self, .allowAttachments) ?? true
            built.behavior.replyExpectation = b.lenient(LocalizedText.self, .replyExpectation) ?? LocalizedText()
            built.behavior.consentRequired = b.lenient(Bool.self, .consentRequired) ?? false
            built.behavior.consentText = b.lenient(LocalizedText.self, .consentText) ?? LocalizedText()
            let url = b.lenient(String.self, .privacyUrl)
            built.behavior.privacyUrl = (url != nil && LinkPolicy.isSafe(url ?? "")) ? url : nil
        }
    }

    func build() -> SiteSnapshot { built }
}
