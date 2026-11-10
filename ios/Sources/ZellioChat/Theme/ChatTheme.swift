#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import ZellioChatCore

extension Color {
    init(_ hex: HexColor) {
        self.init(.sRGB, red: Double(hex.r) / 255, green: Double(hex.g) / 255, blue: Double(hex.b) / 255, opacity: 1)
    }
}

extension UIColor {
    convenience init(hex: HexColor, alpha: CGFloat = 1) {
        self.init(red: CGFloat(hex.r) / 255, green: CGFloat(hex.g) / 255, blue: CGFloat(hex.b) / 255, alpha: alpha)
    }

    /// #RRGGBB in sRGB. Nil only when the color cannot be read as RGB.
    var hexColor: HexColor? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return HexColor(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }
}

/// Everything a view needs to draw: palette, language, fonts, corner and density choices.
struct ChatTheme {
    var palette: ChatPalette
    var locale: ChatLocale
    var fontName: String?
    var corners: Corners
    var density: Density
    var headerStyle: HeaderStyle
    var showAgentAvatar: Bool
    var showAttribution: Bool
    var brandName: String

    var strings: ChatStrings { ChatStrings(locale: locale) }
    var isRTL: Bool { locale.isRTL }
    var layoutDirection: LayoutDirection { locale.isRTL ? .rightToLeft : .leftToRight }

    var bg: Color { Color(palette.bg) }
    var bgAlt: Color { Color(palette.bgAlt) }
    var ink: Color { Color(palette.ink) }
    var ink2: Color { Color(palette.ink2) }
    var line: Color { Color(palette.line) }
    var primary: Color { Color(palette.primary) }
    var onPrimary: Color { Color(palette.onPrimary) }
    var customer: Color { Color(palette.customer) }
    var onCustomer: Color { Color(palette.onCustomer) }
    var agentBubble: Color { Color(palette.agentBubble) }
    var ok: Color { Color(palette.ok) }
    var bad: Color { Color(palette.bad) }
    var link: Color { Color(palette.link) }
    var avatarTone: Color { Color(palette.avatarTone) }
    var avatarInk: Color { Color(palette.avatarInk) }
    var disabledSend: Color { Color(palette.disabledSend) }
    var cardShadow: Color { palette.isDark ? Color.black.opacity(0.4) : Color(HexColor(r: 17, g: 20, b: 38)).opacity(0.10) }
    /// Cards on the dark theme use the alt background, like the canvas.
    var card: Color { palette.isDark ? bgAlt : bg }

    static func make(config: ChatConfig?, locale: ChatLocale, systemDark: Bool, overrides: ZellioChatTheme) -> ChatTheme {
        var appearance = config?.snapshot.appearance ?? Appearance()
        if let primary = overrides.primaryColor?.hexColor {
            appearance.primaryColor = primary.hex
            if overrides.customerMessageColor == nil { appearance.customerMessageColor = primary.hex }
        }
        if let customer = overrides.customerMessageColor?.hexColor { appearance.customerMessageColor = customer.hex }
        if let surface = overrides.surfaceColor?.hexColor { appearance.surfaceColor = surface.hex }
        let palette = ChatPalette.resolve(appearance: appearance, systemDark: systemDark, override: overrides.coreMode)
        return ChatTheme(palette: palette, locale: locale, fontName: overrides.fontName, corners: appearance.corners, density: appearance.density,
                         headerStyle: appearance.headerStyle, showAgentAvatar: appearance.showAgentAvatar, showAttribution: appearance.showAttribution,
                         brandName: appearance.brandName)
    }

    static let fallback = ChatTheme.make(config: nil, locale: .en, systemDark: false, overrides: ZellioChatTheme())

    // UIKit helpers for the thread list.

    func uiColor(_ hex: HexColor) -> UIColor { UIColor(hex: hex) }

    func uiFont(_ role: TypeRole, size: CGFloat? = nil, weight: UIFont.Weight? = nil) -> UIFont {
        let points = size ?? CGFloat(role.size)
        let weightValue = weight ?? ChatTheme.uiWeight(role.weight)
        let base: UIFont
        if let name = fontName, let custom = UIFont(name: name, size: points) {
            base = custom
        } else {
            base = UIFont.systemFont(ofSize: points, weight: weightValue)
        }
        return UIFontMetrics(forTextStyle: ChatTheme.uiTextStyle(role)).scaledFont(for: base)
    }

    static func uiWeight(_ css: Int) -> UIFont.Weight {
        switch css {
        case 700: return .bold
        case 600: return .semibold
        case 500: return .medium
        default: return .regular
        }
    }

    static func uiTextStyle(_ role: TypeRole) -> UIFont.TextStyle {
        switch role {
        case .homeHeading: return .largeTitle
        case .screenTitle: return .headline
        case .message: return .body
        case .sectionTitle: return .subheadline
        case .secondary: return .footnote
        case .caption: return .caption1
        }
    }

    static func swiftUIStyle(_ role: TypeRole) -> Font.TextStyle {
        switch role {
        case .homeHeading: return .largeTitle
        case .screenTitle: return .headline
        case .message: return .body
        case .sectionTitle: return .subheadline
        case .secondary: return .footnote
        case .caption: return .caption
        }
    }

    static func swiftUIWeight(_ css: Int) -> Font.Weight {
        switch css {
        case 700: return .bold
        case 600: return .semibold
        case 500: return .medium
        default: return .regular
        }
    }
}

private struct ChatThemeKey: EnvironmentKey {
    static let defaultValue = ChatTheme.fallback
}

extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}

/// Text that follows Dynamic Type with no cap, uses the brand font when set, and has the spec line height.
struct ChatFontModifier: ViewModifier {
    @Environment(\.chatTheme) private var theme
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let role: TypeRole

    init(role: TypeRole, size: CGFloat?, weight: Font.Weight?) {
        self.role = role
        let points = size ?? CGFloat(role.size)
        _size = ScaledMetric(wrappedValue: points, relativeTo: ChatTheme.swiftUIStyle(role))
        self.weight = weight ?? ChatTheme.swiftUIWeight(role.weight)
    }

    func body(content: Content) -> some View {
        content
            .font(font)
            .lineSpacing(max(0, size * (CGFloat(Metrics.lineHeightMultiple(theme.locale)) - 1.2)))
    }

    private var font: Font {
        if let name = theme.fontName { return Font.custom(name, fixedSize: size) }
        return Font.system(size: size, weight: weight)
    }
}

extension View {
    func chatFont(_ role: TypeRole, size: CGFloat? = nil, weight: Font.Weight? = nil) -> some View {
        modifier(ChatFontModifier(role: role, size: size, weight: weight))
    }

    /// Keeps a touch target at 44 pt or more.
    func chatTouchTarget() -> some View {
        frame(minWidth: CGFloat(Metrics.minTouch), minHeight: CGFloat(Metrics.minTouch))
    }
}

/// Reduced motion: fade only, no slide.
struct MotionPolicy {
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
}
#endif
