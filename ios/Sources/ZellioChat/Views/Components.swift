#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import ZellioChatCore

/// Loads images lazily. Memory cache plus a size-limited disk cache. Only https.
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 40 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, diskPath: "ai.zellio.chat.images")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func cached(_ urlString: String) -> UIImage? { memory.object(forKey: urlString as NSString) }

    /// Logout: customer photos must not stay on the phone.
    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    enum Failure: Error { case notAllowed, expired, failed }

    /// A larger file is never downloaded.
    private static let maxDownloadBytes = 25 * 1024 * 1024
    /// The long edge after decoding, so one photo cannot take hundreds of MB of memory.
    private static let maxPixelEdge = 2048

    /// Throws `.expired` for 403 so the caller can read the message page once more.
    func load(_ urlString: String) async throws -> UIImage {
        if let image = cached(urlString) { return image }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { throw Failure.notAllowed }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 { throw Failure.expired }
                if !(200..<300).contains(http.statusCode) { throw Failure.failed }
            }
            let declared = response.expectedContentLength
            if declared > Int64(Self.maxDownloadBytes) { throw Failure.failed }
            var buffer = [UInt8]()
            if declared > 0 { buffer.reserveCapacity(Int(declared)) }
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > Self.maxDownloadBytes { throw Failure.failed }
            }
            guard let image = ImagePrep.decode(Data(buffer), maxPixelEdge: Self.maxPixelEdge) else { throw Failure.failed }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? buffer.count
            memory.setObject(image, forKey: urlString as NSString, cost: cost)
            return image
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed
        }
    }
}

struct RemoteImage<Placeholder: View>: View {
    let urlString: String?
    let placeholder: Placeholder
    @State private var image: UIImage?

    init(urlString: String?, @ViewBuilder placeholder: () -> Placeholder) {
        self.urlString = urlString
        self.placeholder = placeholder()
        if let urlString = urlString { _image = State(initialValue: ImageLoader.shared.cached(urlString)) }
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: urlString) {
            guard let urlString = urlString, image == nil else { return }
            image = try? await ImageLoader.shared.load(urlString)
        }
    }
}

/// The brand logo, or a monogram of the first letter.
struct LogoView: View {
    @Environment(\.chatTheme) private var theme
    let logoURL: String?
    let size: CGFloat
    let radius: CGFloat
    var onGradient = false

    var body: some View {
        let monogram = String(theme.brandName.first ?? "Z").uppercased()
        RemoteImage(urlString: logoURL) {
            ZStack {
                (onGradient ? Color.white.opacity(0.2) : theme.primary)
                Text(monogram)
                    .font(theme.fontName.map { Font.custom($0, fixedSize: size * 0.45) } ?? Font.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(onGradient ? theme.onPrimary : theme.onPrimary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct AvatarView: View {
    @Environment(\.chatTheme) private var theme
    let name: String?
    let urlString: String?
    let size: CGFloat

    var body: some View {
        let initial = String((name ?? theme.brandName).first ?? "Z").uppercased()
        RemoteImage(urlString: urlString) {
            ZStack {
                theme.avatarTone
                Text(initial)
                    .font(Font.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(theme.avatarInk)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let color: Color
    var background: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text(label))
    }
}

struct ChatCard<Content: View>: View {
    @Environment(\.chatTheme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(Metrics.cardRadius), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CGFloat(Metrics.cardRadius), style: .continuous).stroke(theme.line, lineWidth: 1))
            .shadow(color: theme.cardShadow, radius: 10, x: 0, y: 4)
    }
}

struct DividerLine: View {
    @Environment(\.chatTheme) private var theme
    var body: some View { Rectangle().fill(theme.line).frame(height: 1) }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}

struct AttributionView: View {
    @Environment(\.chatTheme) private var theme
    var body: some View {
        if theme.showAttribution {
            Text(theme.strings.string("common.poweredBy"))
                .chatFont(.caption)
                .foregroundColor(theme.ink2)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
    }
}

/// A thin bar under the top bar.
struct BannerBar: View {
    @Environment(\.chatTheme) private var theme
    let banner: ChatBanner

    var body: some View {
        let colors = palette
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).accessibilityHidden(true)
            Text(text).chatFont(.secondary, size: 13)
            Spacer(minLength: 0)
        }
        .foregroundColor(colors.1)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.0)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch banner {
        case .reconnecting: return "wifi.slash"
        case .outsideHours: return "clock"
        }
    }

    private var text: String {
        switch banner {
        case .reconnecting: return theme.strings.string("banner.reconnecting")
        case .outsideHours(let text): return text
        }
    }

    private var palette: (Color, Color) {
        switch banner {
        case .reconnecting:
            return theme.palette.isDark
                ? (Color(HexColor("#2E1A0E") ?? .black), Color(HexColor("#FDBA74") ?? .white))
                : (Color(HexColor("#FFF3E8") ?? .white), Color(HexColor("#9A3D00") ?? .black))
        case .outsideHours:
            return (theme.bgAlt, theme.ink2)
        }
    }
}

struct PillButton: View {
    @Environment(\.chatTheme) private var theme
    let title: String
    let symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol = symbol { Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).accessibilityHidden(true) }
                Text(title).chatFont(.message, weight: .semibold)
            }
            .foregroundColor(theme.onPrimary)
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .background(Capsule().fill(theme.primary))
            .shadow(color: theme.primary.opacity(0.35), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// A calm placeholder while the first config loads.
struct SkeletonView: View {
    @Environment(\.chatTheme) private var theme
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 12).fill(theme.bgAlt).frame(width: 40, height: 40)
            RoundedRectangle(cornerRadius: 8).fill(theme.bgAlt).frame(width: 220, height: 28)
            RoundedRectangle(cornerRadius: 8).fill(theme.bgAlt).frame(width: 160, height: 16)
            RoundedRectangle(cornerRadius: CGFloat(Metrics.cardRadius)).fill(theme.bgAlt).frame(height: 120)
            RoundedRectangle(cornerRadius: CGFloat(Metrics.cardRadius)).fill(theme.bgAlt).frame(height: 72)
            Spacer()
        }
        .padding(20)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            if !MotionPolicy.reduced { withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { pulse = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(theme.strings.string("state.loading")))
    }
}

/// An icon, one line, and a button. No technical words.
struct MessageStateView: View {
    @Environment(\.chatTheme) private var theme
    let symbol: String
    let text: String
    let buttonTitle: String
    let onClose: () -> Void
    let onButton: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                IconButton(symbol: "xmark", label: theme.strings.string("common.close"), color: theme.ink2, action: onClose)
            }
            .padding(.horizontal, 8)
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(theme.ink2)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.bgAlt))
                    .accessibilityHidden(true)
                Text(text)
                    .chatFont(.screenTitle, weight: .medium)
                    .foregroundColor(theme.ink)
                    .multilineTextAlignment(.center)
                Button(action: onButton) {
                    Text(buttonTitle)
                        .chatFont(.message, size: 15.5, weight: .medium)
                        .foregroundColor(theme.ink)
                        .padding(.horizontal, 26)
                        .frame(minHeight: 48)
                        .overlay(Capsule().stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 44)
            Spacer()
            Spacer().frame(height: 80)
        }
    }
}
#endif
