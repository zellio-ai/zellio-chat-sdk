import Foundation

/// A #RRGGBB color. Parsing never fails the caller: use the failable init and fall back.
public struct HexColor: Equatable, Sendable {
    public let r: Int
    public let g: Int
    public let b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = min(255, max(0, r))
        self.g = min(255, max(0, g))
        self.b = min(255, max(0, b))
    }

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(r: (number >> 16) & 255, g: (number >> 8) & 255, b: number & 255)
    }

    public var hex: String {
        func two(_ v: Int) -> String {
            let s = String(v, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + two(r) + two(g) + two(b)
    }

    public static let black = HexColor(r: 0, g: 0, b: 0)
    public static let white = HexColor(r: 255, g: 255, b: 255)
}

/// Ports packages/zeechat-ui/src/color-contrast.ts.
public enum Contrast {
    /// WCAG relative luminance.
    public static func luminance(_ color: HexColor) -> Double {
        func channel(_ value: Int) -> Double {
            let c = Double(value) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return channel(color.r) * 0.2126 + channel(color.g) * 0.7152 + channel(color.b) * 0.0722
    }

    public static func ratio(_ a: HexColor, _ b: HexColor) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Black or white, whichever has the higher contrast on the background.
    public static func readable(on background: HexColor) -> (foreground: HexColor, ratio: Double) {
        let black = ratio(background, .black)
        let white = ratio(background, .white)
        return black >= white ? (.black, black) : (.white, white)
    }

    private static let lightBrand = 0.4

    /// A brand color for surfaces that carry text. Mid-tone brands get darker until white text passes 4.5:1.
    public static func brandSurface(_ color: HexColor) -> (background: HexColor, foreground: HexColor) {
        if ratio(color, .white) >= 4.5 { return (color, .white) }
        if luminance(color) > lightBrand { return (color, .black) }
        let (h, s, l) = toHSL(color)
        var next = l
        while next >= 0 {
            let shade = fromHSL(h, s, next)
            if ratio(shade, .white) >= 4.5 { return (shade, .white) }
            next -= 0.01
        }
        return (.black, .white)
    }

    public static func toHSL(_ color: HexColor) -> (Double, Double, Double) {
        let r = Double(color.r) / 255, g = Double(color.g) / 255, b = Double(color.b) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let light = (maxV + minV) / 2
        if maxV == minV { return (0, 0, light) }
        let delta = maxV - minV
        let saturation = light > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)
        let hue: Double
        if maxV == r { hue = (g - b) / delta + (g < b ? 6 : 0) } else if maxV == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
        return (hue / 6, saturation, light)
    }

    public static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> HexColor {
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Int {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let value: Double
            if t < 1.0 / 6 { value = p + (q - p) * 6 * t } else if t < 0.5 { value = q } else if t < 2.0 / 3 { value = p + (q - p) * (2.0 / 3 - t) * 6 } else { value = p }
            return Int((value * 255).rounded())
        }
        return HexColor(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3))
    }

    /// Lightness scaled down by a percent. Used for the header gradient end (18 percent).
    public static func darken(_ color: HexColor, percent: Double) -> HexColor {
        let (h, s, l) = toHSL(color)
        return fromHSL(h, s, max(0, l * (1 - percent / 100)))
    }

    /// `top` over `bottom` at an alpha from 0 to 1.
    public static func blend(_ top: HexColor, over bottom: HexColor, alpha: Double) -> HexColor {
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) * alpha + Double(b) * (1 - alpha)).rounded()) }
        return HexColor(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b))
    }
}

/// All colors for one screen, resolved from the snapshot and the dark flag. Hex strings.
public struct ChatPalette: Equatable, Sendable {
    public var isDark: Bool
    public var primary: HexColor
    public var onPrimary: HexColor
    public var headerEnd: HexColor
    public var customer: HexColor
    public var onCustomer: HexColor
    public var bg: HexColor
    public var bgAlt: HexColor
    public var ink: HexColor
    public var ink2: HexColor
    public var line: HexColor
    public var agentBubble: HexColor
    public var ok: HexColor
    public var bad: HexColor
    public var link: HexColor
    public var avatarTone: HexColor
    public var avatarInk: HexColor
    public var disabledSend: HexColor

    /// Resolves the palette. `systemDark` is the device setting; the snapshot theme and `override` can force it.
    public static func resolve(appearance: Appearance, systemDark: Bool, override: ThemeMode? = nil) -> ChatPalette {
        let mode = override ?? appearance.theme
        let dark = mode == .dark || (mode == .auto && systemDark)
        let primary = HexColor(appearance.primaryColor) ?? HexColor(r: 125, g: 59, b: 237)
        let customer = HexColor(appearance.customerMessageColor) ?? primary
        let surface = HexColor(appearance.surfaceColor) ?? .white

        let bg: HexColor = dark ? HexColor("#0F1525") ?? .black : surface
        // A dark surface in light mode needs light ink: pick by contrast.
        let ink: HexColor
        let ink2: HexColor
        if dark {
            ink = HexColor("#F4F6FC") ?? .white
            ink2 = HexColor("#AEB6CC") ?? .white
        } else if Contrast.readable(on: bg).foreground == .white {
            ink = HexColor("#F4F6FC") ?? .white
            ink2 = HexColor("#AEB6CC") ?? .white
        } else {
            ink = HexColor("#111426") ?? .black
            ink2 = HexColor("#50556B") ?? .black
        }
        let inkIsLight = Contrast.luminance(ink) > 0.5
        let bgAlt: HexColor = dark ? HexColor("#161D30") ?? bg : Contrast.blend(ink, over: bg, alpha: 0.04)
        let agent: HexColor = dark ? HexColor("#1E2740") ?? bg : (inkIsLight ? Contrast.blend(.white, over: bg, alpha: 0.12) : HexColor("#F1F1F6") ?? bg)
        let line: HexColor = dark ? HexColor("#222B42") ?? ink2 : (inkIsLight ? Contrast.blend(.white, over: bg, alpha: 0.16) : HexColor("#E7E7EF") ?? ink2)

        // Link: primary if it has 4.5:1 on bg, else ink.
        let link = Contrast.ratio(primary, bg) >= 4.5 ? primary : ink

        return ChatPalette(
            isDark: dark,
            primary: primary,
            onPrimary: Contrast.readable(on: primary).foreground,
            headerEnd: Contrast.darken(primary, percent: 18),
            customer: customer,
            onCustomer: Contrast.readable(on: customer).foreground,
            bg: bg,
            bgAlt: bgAlt,
            ink: ink,
            ink2: ink2,
            line: line,
            agentBubble: agent,
            ok: HexColor(dark ? "#34D399" : "#16A34A") ?? .black,
            bad: HexColor(dark ? "#F87171" : "#D92D32") ?? .black,
            link: link,
            avatarTone: HexColor(dark ? "#2B3556" : "#D9D3F5") ?? .white,
            avatarInk: HexColor(dark ? "#E7E9F6" : "#3B2A86") ?? .black,
            disabledSend: HexColor(dark ? "#2B3556" : "#E3E3EB") ?? .white
        )
    }
}

/// Sizes from the spec and the approved canvas. Points.
public enum Metrics {
    public static let bubbleRadius: Double = 20
    public static let tailRadius: Double = 6
    public static let squareBubbleRadius: Double = 8
    public static let squareTailRadius: Double = 4
    public static let cardRadius: Double = 16
    public static let controlRadius: Double = 12
    public static let imageRadius: Double = 14
    public static let maxBubbleFraction: Double = 0.78
    public static let maxBubbleWidthPad: Double = 520
    public static let maxImageWidth: Double = 240
    public static let minTouch: Double = 44
    public static let composerSend: Double = 36
    public static let groupGap: Double = 2
    public static let groupGapCompact: Double = 2
    public static let newSenderGap: Double = 12
    public static let newSenderGapCompact: Double = 8
    public static let groupWindowSeconds: Double = 300
    public static let homeOverlap: Double = 20

    public static func bubbleRadius(_ corners: Corners) -> Double { corners == .square ? squareBubbleRadius : bubbleRadius }
    public static func tailRadius(_ corners: Corners) -> Double { corners == .square ? squareTailRadius : tailRadius }
    public static func senderGap(_ density: Density) -> Double { density == .compact ? newSenderGapCompact : newSenderGap }

    /// 1.45 for Arabic, 1.35 for English.
    public static func lineHeightMultiple(_ locale: ChatLocale) -> Double { locale == .ar ? 1.45 : 1.35 }
}

/// Type roles: size and weight. Weight uses the CSS numbers (400, 600, 700).
public enum TypeRole: Sendable {
    case homeHeading, screenTitle, message, sectionTitle, secondary, caption

    public var size: Double {
        switch self {
        case .homeHeading: return 28
        case .screenTitle: return 17
        case .message: return 16
        case .sectionTitle: return 15
        case .secondary: return 13
        case .caption: return 12
        }
    }

    public var weight: Int {
        switch self {
        case .homeHeading: return 700
        case .screenTitle, .sectionTitle: return 600
        case .message, .secondary, .caption: return 400
        }
    }
}
