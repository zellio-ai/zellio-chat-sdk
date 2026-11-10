#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import ZellioChatCore

struct ThreadRepresentable: UIViewControllerRepresentable {
    let controller: ThreadController
    let theme: ChatTheme
    let services: ThreadServices

    func makeUIViewController(context: Context) -> ThreadViewController {
        ThreadViewController(controller: controller, theme: theme, services: services)
    }

    func updateUIViewController(_ uiViewController: ThreadViewController, context: Context) {
        uiViewController.update(theme: theme, services: services)
    }

    static func dismantleUIViewController(_ uiViewController: ThreadViewController, coordinator: ()) {
        uiViewController.teardown()
    }
}

struct ThreadScreen: View {
    @Environment(\.chatTheme) private var theme
    @ObservedObject var model: ChatModel
    let onClose: () -> Void

    private var title: String {
        if case .thread(let id?) = model.route, let name = model.conversations.first(where: { $0.id == id })?.agentName, !name.isEmpty { return name }
        return theme.brandName
    }

    private var subtitle: String {
        let strings = theme.strings
        if model.config?.online == false { return strings.string("banner.outsideHours") }
        return model.config?.snapshot.behavior.replyExpectation.resolve(theme.locale) ?? strings.string("banner.online")
    }

    private var services: ThreadServices {
        let engine = model.engine
        let config = model.config
        return ThreadServices(
            canAttach: model.allowsAttachments,
            greeting: config?.snapshot.screens.greeting.resolve(theme.locale) ?? theme.strings.string("thread.greeting"),
            soundEnabled: config?.snapshot.appearance.soundEnabled ?? false,
            upload: { data, name, mime, progress in try await engine.upload(data: data, fileName: name, mimeType: mime, progress: progress) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            DividerLine()
            if let banner = model.banner { BannerBar(banner: banner) }
            if let controller = model.activeThread {
                ThreadRepresentable(controller: controller, theme: theme, services: services)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .id(ObjectIdentifier(controller))
            } else {
                Spacer()
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private var bar: some View {
        let strings = theme.strings
        return HStack(spacing: 6) {
            if model.canGoBack && !model.isChatOnly {
                IconButton(symbol: "chevron.backward", label: strings.string("common.back"), color: theme.ink, action: { model.goBack() })
            } else {
                Spacer().frame(width: 8)
            }
            LogoView(logoURL: model.config?.logoUrl, size: 32, radius: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).chatFont(.screenTitle).foregroundColor(theme.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    if model.config?.online != false { StatusDot(color: theme.ok) }
                    Text(subtitle).chatFont(.secondary, size: 12.5).foregroundColor(theme.ink2).lineLimit(1)
                }
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", label: strings.string("common.close"), color: theme.ink2, action: onClose)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.bg)
    }
}

/// The whole chat UI: routes between screens and sets language, direction and theme for everything inside.
struct ChatRootView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    let onClose: () -> Void
    var onStatusBarStyle: ((UIStatusBarStyle) -> Void)?

    /// On Home the status bar sits on the header. Everywhere else it sits on the background.
    private func statusBarStyle(_ theme: ChatTheme) -> UIStatusBarStyle {
        let lightContent: Bool
        if model.route == .home, theme.headerStyle != .light {
            lightContent = Contrast.luminance(theme.palette.onPrimary) > 0.5
        } else {
            lightContent = theme.palette.isDark
        }
        return lightContent ? .lightContent : .darkContent
    }

    var body: some View {
        let theme = model.theme(systemDark: colorScheme == .dark)
        let style = statusBarStyle(theme)
        content(theme)
            .onAppear { onStatusBarStyle?(style) }
            .onChange(of: style) { onStatusBarStyle?($0) }
            .environment(\.chatTheme, theme)
            .environment(\.layoutDirection, theme.layoutDirection)
            .environment(\.locale, ChatFormat.formatter(theme.locale))
            .task { await model.start() }
    }

    @ViewBuilder
    private func content(_ theme: ChatTheme) -> some View {
        ZStack {
            if model.route != .consent {
                theme.bg.ignoresSafeArea()
            }
            switch model.route {
            case .loading:
                SkeletonView()
            case .consent:
                ConsentView(model: model, onDecline: onClose)
            case .home:
                HomeView(model: model, onClose: onClose)
            case .list:
                ConversationListView(model: model, onClose: onClose)
            case .thread:
                ThreadScreen(model: model, onClose: onClose)
            case .unavailable:
                MessageStateView(symbol: "headphones", text: theme.strings.string("state.unavailable"),
                                 buttonTitle: theme.strings.string("attachment.close"), onClose: onClose, onButton: onClose)
            case .loginNeeded:
                MessageStateView(symbol: "person.crop.circle", text: theme.strings.string("state.loginNeeded"),
                                 buttonTitle: theme.strings.string("attachment.close"), onClose: onClose, onButton: onClose)
            case .loadFailed:
                MessageStateView(symbol: "wifi.slash", text: theme.strings.string("state.loadFailed"),
                                 buttonTitle: theme.strings.string("state.retry"), onClose: onClose, onButton: { Task { await model.retry() } })
            }
        }
        .animation(MotionPolicy.reduced ? nil : .easeOut(duration: 0.18), value: model.route)
    }
}
#endif
