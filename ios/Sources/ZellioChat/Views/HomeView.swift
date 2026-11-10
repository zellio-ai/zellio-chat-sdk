#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import ZellioChatCore

struct HomeView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: ChatModel
    let onClose: () -> Void

    private var snapshot: SiteSnapshot { model.config?.snapshot ?? SiteSnapshot() }
    private var locale: ChatLocale { theme.locale }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner { BannerBar(banner: banner) }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups.indices, id: \.self) { index in
                        moduleGroup(groups[index])
                    }
                    recent
                    AttributionView()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.top, -CGFloat(Metrics.homeOverlap))
        }
        .background(theme.bg.ignoresSafeArea())
    }

    // MARK: Header

    private var headerForeground: Color { theme.headerStyle == .light ? theme.ink : theme.onPrimary }

    @ViewBuilder
    private var headerBackground: some View {
        switch theme.headerStyle {
        case .gradient:
            // 160 degrees: mostly downward, a little toward the end side.
            LinearGradient(colors: [theme.primary, Color(theme.palette.headerEnd)], startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
        case .solid:
            theme.primary
        case .light:
            theme.bgAlt
        }
    }

    private var header: some View {
        let strings = theme.strings
        let heading = snapshot.screens.heading.resolve(locale) ?? strings.string("home.fallbackHeading")
        let description = snapshot.screens.description.resolve(locale)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                LogoView(logoURL: model.config?.logoUrl, size: 40, radius: 12, onGradient: theme.headerStyle != .light)
                Spacer()
                IconButton(symbol: "xmark", label: strings.string("common.close"), color: headerForeground,
                           background: theme.headerStyle == .light ? theme.bg : Color.white.opacity(0.14), action: onClose)
            }
            Text(heading)
                .chatFont(.homeHeading)
                .foregroundColor(headerForeground)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            if let description = description {
                Text(description)
                    .chatFont(.sectionTitle, size: 15)
                    .foregroundColor(headerForeground.opacity(0.92))
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                StatusDot(color: Color(HexColor("#4ADE80") ?? .white), size: 8)
                Text(availabilityText).chatFont(.secondary, size: 13, weight: .medium).foregroundColor(headerForeground)
            }
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
        // The iPad sheet has no status bar above the header.
        .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 18 : 4)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackground.ignoresSafeArea(edges: .top))
    }

    private var availabilityText: String {
        let strings = theme.strings
        if model.config?.online == false { return strings.string("banner.outsideHours") }
        return snapshot.behavior.replyExpectation.resolve(locale) ?? strings.string("banner.online")
    }

    // MARK: Modules

    private var groups: [[HomeModule]] {
        let modules = model.config?.homeModules(locale: locale, verified: model.isIdentified) ?? []
        var result: [[HomeModule]] = []
        for module in modules {
            let isLink = module.kind == .externalLink || module.kind == .contactLinks
            if isLink, let last = result.last?.last, last.kind == .startConversation || last.kind == .externalLink || last.kind == .contactLinks {
                result[result.count - 1].append(module)
            } else {
                result.append([module])
            }
        }
        return result
    }

    @ViewBuilder
    private func moduleGroup(_ modules: [HomeModule]) -> some View {
        ChatCard {
            ForEach(modules.indices, id: \.self) { index in
                let module = modules[index]
                if index > 0, module.kind != .externalLink, module.kind != .contactLinks { DividerLine() }
                moduleView(module, isFirst: index == 0)
            }
        }
    }

    @ViewBuilder
    private func moduleView(_ module: HomeModule, isFirst: Bool) -> some View {
        switch module.kind {
        case .startConversation:
            startButton(module)
        case .greeting, .announcement:
            textCard(module)
        case .externalLink:
            if let href = module.href { linkRow(title: module.label.resolve(locale) ?? "", href: href, symbol: "bag") }
        case .contactLinks:
            ForEach(module.links.indices, id: \.self) { index in
                let link = module.links[index]
                linkRow(title: link.label.resolve(locale) ?? link.href, href: link.href, symbol: symbol(forContact: link.href))
            }
        }
    }

    private func symbol(forContact href: String) -> String {
        if href.lowercased().hasPrefix("tel:") { return "phone" }
        if href.lowercased().hasPrefix("mailto:") { return "envelope" }
        return "link"
    }

    private func startButton(_ module: HomeModule) -> some View {
        let title = module.label.resolve(locale) ?? theme.strings.string("home.talkToTeam")
        return VStack(spacing: 0) {
            Button(action: { model.open(.thread(nil)) }) {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left").font(.system(size: 18, weight: .semibold)).accessibilityHidden(true)
                    Text(title).chatFont(.message, weight: .semibold)
                }
                .foregroundColor(module.primary ? theme.onPrimary : theme.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(module.primary ? theme.primary : theme.bgAlt)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(14)
        }
    }

    private func textCard(_ module: HomeModule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = module.label.resolve(locale) {
                Text(title).chatFont(.sectionTitle, weight: .semibold).foregroundColor(theme.ink)
            }
            if let body = module.description.resolve(locale) {
                Text(body).chatFont(.secondary, size: 14).foregroundColor(theme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private func linkRow(title: String, href: String, symbol: String) -> some View {
        Button(action: { open(href) }) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(theme.ink2)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.bgAlt))
                    .accessibilityHidden(true)
                Text(title).chatFont(.message, size: 15.5, weight: .medium).foregroundColor(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .regular)).foregroundColor(theme.ink2).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Only https, mailto and tel. The system asks before it leaves the app.
    private func open(_ href: String) {
        guard LinkPolicy.isSafe(href), let url = URL(string: href) else { return }
        openURL(url)
    }

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        let rows = Array(model.conversations.prefix(3))
        if !rows.isEmpty {
            HStack {
                Text(theme.strings.string("home.recent")).chatFont(.sectionTitle, weight: .semibold).foregroundColor(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: { model.open(.list) }) {
                    Text(theme.strings.string("home.seeAll")).chatFont(.secondary, size: 14, weight: .medium).foregroundColor(theme.link)
                        .chatTouchTarget()
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
            ChatCard {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { DividerLine() }
                    ConversationRow(summary: rows[index], compact: true) { model.open(.thread(rows[index].id)) }
                }
            }
        }
    }
}

/// One conversation: avatar, name, last message in one line, time, unread dot.
struct ConversationRow: View {
    @Environment(\.chatTheme) private var theme
    let summary: ConversationSummary
    let compact: Bool
    let action: () -> Void

    private var name: String { summary.agentName ?? theme.brandName }

    private var preview: (symbol: String?, text: String) {
        let strings = theme.strings
        if let last = summary.lastMessage {
            if !last.text.isEmpty { return (nil, last.text) }
            if last.hasAttachment {
                return last.attachmentKind == "image"
                    ? ("photo", strings.string("attachment.photo"))
                    : ("paperclip", strings.string("attachment.file"))
            }
        }
        return (nil, "")
    }

    private var timeText: String {
        guard let date = summary.lastDate else { return "" }
        return ChatFormat.listTime(date, now: Date(), locale: theme.locale)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 12 : 13) {
                AvatarView(name: name, urlString: summary.agentAvatarUrl, size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).chatFont(.message, size: compact ? 15 : 16, weight: .semibold).foregroundColor(theme.ink).lineLimit(1)
                    HStack(spacing: 5) {
                        if let symbol = preview.symbol { Image(systemName: symbol).font(.system(size: 13)).accessibilityHidden(true) }
                        Text(preview.text).chatFont(.secondary, size: compact ? 13.5 : 14, weight: summary.unread > 0 ? .medium : .regular).lineLimit(1)
                    }
                    .foregroundColor(summary.unread > 0 ? theme.ink : theme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(timeText).chatFont(.caption, size: 12.5).foregroundColor(theme.ink2)
                    if summary.unread > 0 {
                        Circle().fill(theme.primary).frame(width: 10, height: 10)
                    } else {
                        Spacer().frame(height: 10)
                    }
                }
            }
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.vertical, compact ? 12 : 10)
            .frame(minHeight: compact ? 60 : 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [name, preview.text, timeText]
        if summary.unread > 0 { parts.append(theme.strings.string("a11y.unread")) }
        return parts.filter { !$0.isEmpty }.joined(separator: theme.isRTL ? "، " : ", ")
    }
}

struct ConversationListView: View {
    @Environment(\.chatTheme) private var theme
    @ObservedObject var model: ChatModel
    let onClose: () -> Void

    var body: some View {
        let strings = theme.strings
        VStack(spacing: 0) {
            HStack {
                if model.canGoBack {
                    IconButton(symbol: "chevron.backward", label: strings.string("common.back"), color: theme.ink, action: { model.goBack() })
                }
                Spacer()
                IconButton(symbol: "xmark", label: strings.string("common.close"), color: theme.ink2, action: onClose)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            Text(strings.string("list.title"))
                .chatFont(.homeHeading, size: 30)
                .foregroundColor(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if let banner = model.banner { BannerBar(banner: banner) }
            DividerLine()
            if model.conversations.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Text(strings.string("list.empty")).chatFont(.message).foregroundColor(theme.ink2).multilineTextAlignment(.center)
                    PillButton(title: strings.string("list.new"), symbol: "plus", action: { model.openNewConversation() })
                }
                .padding(.horizontal, 32)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.conversations) { summary in
                            ConversationRow(summary: summary, compact: false) { model.open(.thread(summary.id)) }
                            DividerLine()
                        }
                    }
                }
                HStack { Spacer(); PillButton(title: strings.string("list.new"), symbol: "plus", action: { model.openNewConversation() }); Spacer() }
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }
}

struct ConsentView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: ChatModel
    let onDecline: () -> Void

    var body: some View {
        let strings = theme.strings
        let text = model.config?.consentText(locale: theme.locale) ?? strings.string("consent.default")
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { }
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(theme.line).frame(width: 38, height: 5).frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    LogoView(logoURL: model.config?.logoUrl, size: 44, radius: 13)
                    Text(theme.brandName).chatFont(.screenTitle, size: 19, weight: .bold).foregroundColor(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(text).chatFont(.message).foregroundColor(theme.ink).fixedSize(horizontal: false, vertical: true)
                if let privacy = model.config?.snapshot.behavior.privacyUrl, let url = URL(string: privacy) {
                    Button(action: { openURL(url) }) {
                        Text(strings.string("consent.privacy")).chatFont(.secondary, size: 14.5, weight: .medium).foregroundColor(theme.link)
                            .chatTouchTarget()
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Button(action: { Task { await model.acceptConsent() } }) {
                    Text(strings.string("consent.accept")).chatFont(.message, weight: .semibold).foregroundColor(theme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.primary))
                }
                .buttonStyle(PlainButtonStyle())
                Button(action: onDecline) {
                    Text(strings.string("consent.decline")).chatFont(.message, weight: .medium).foregroundColor(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .background(
                theme.bg
                    .clipShape(RoundedCorners(radius: 24, corners: [.topLeft, .topRight]))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

/// A shape with chosen rounded corners.
struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
#endif
