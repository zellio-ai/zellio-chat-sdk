#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import SwiftUI
import ZellioChatCore

/// Sample data for the Xcode previews. The text matches the contract fixtures.
enum PreviewData {
    static let configJSON = """
    {"data":{"protocol":"studio-v1","snapshot":{"schemaVersion":1,"siteId":"ws_1~site_1","versionId":"ver_1","layout":"support",
    "language":{"mode":"both","defaultLocale":"en","startIn":"browser"},
    "appearance":{"brandName":"Nile Store","logoFileId":"file_1","logoAlt":{"en":"Nile Store","ar":"متجر النيل"},"primaryColor":"#7D3BED","customerMessageColor":"#7D3BED","surfaceColor":"#FFFFFF","theme":"auto","density":"comfortable","corners":"rounded","position":"right","desktopOffset":20,"mobileOffset":16,"launcherSize":56,"launcherLabel":{},"showAgentAvatar":true,"soundEnabled":false,"unreadBadge":true,"showAttribution":true,"launcherIcon":"bubbles","launcherShape":"circle","headerStyle":"gradient","mirrorInRtl":true,"welcomeBubble":{"enabled":false,"text":{},"delaySeconds":5}},
    "modules":[{"id":"m1","type":"start-conversation","label":{"en":"Talk to our team","ar":"كلّم فريقنا"},"visibility":{},"primary":true},
    {"id":"m2","type":"announcement","label":{"en":"Eid delivery","ar":"توصيل العيد"},"description":{"en":"Orders placed today arrive on Sunday.","ar":"الطلبات النهاردة توصل يوم الحد."},"visibility":{}},
    {"id":"m3","type":"external-link","label":{"en":"Track my order","ar":"تتبّع طلبي"},"href":"https://shop.example/track","visibility":{}}],
    "screens":{"heading":{"en":"How can we help?","ar":"إزاي نقدر نساعدك؟"},"greeting":{"en":"Hi! Tell us what you need help with.","ar":"أهلاً! قولّنا محتاج إيه."},"description":{"en":"We usually reply in a few minutes.","ar":"غالباً بنرد في دقايق."},"offline":{"en":"We are away.","ar":"إحنا مش متاحين دلوقتي."}},
    "behavior":{"allowAttachments":true,"inheritHours":true,"replyExpectation":{"en":"Usually within minutes","ar":"غالباً في دقايق"},"consentRequired":true,"consentText":{"en":"We store your messages and share them with our support team.","ar":"هنحفظ رسايلك ونشاركها مع فريق الدعم."},"privacyUrl":"https://shop.example/privacy"}},
    "assets":{"logoUrl":null},"availability":{"online":true},"app":{"allowGuests":true,"minSdkVersion":null}}}
    """

    static let conversationsJSON = """
    {"data":{"conversations":[
    {"id":"conv_2","status":"open","lastMessageAt":"2026-11-03T10:00:00.000Z","lastMessage":{"from":"agent","text":"Your order is on the way.","hasAttachment":false},"agentName":"Mona","agentAvatarUrl":null,"unread":1},
    {"id":"conv_1","status":"resolved","lastMessageAt":"2026-10-20T08:30:00.000Z","lastMessage":{"from":"visitor","text":"","hasAttachment":true},"agentName":null,"agentAvatarUrl":null,"unread":0}],
    "nextCursor":null,"unreadTotal":1}}
    """

    static var config: ChatConfig? { try? ChatConfig.parse(Data(configJSON.utf8)) }

    static var conversations: [ConversationSummary] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(conversationsJSON.utf8))) as? [String: Any],
              let inner = root["data"],
              let data = try? JSONSerialization.data(withJSONObject: inner),
              let page = try? JSONDecoder().decode(ConversationsPage.self, from: data) else { return [] }
        return page.conversations
    }

    static func model(_ route: ChatRoute, locale: ChatLocale, banner: ChatBanner? = nil) -> ChatModel {
        ChatModel.preview(config: config, conversations: conversations, route: route, locale: locale, banner: banner)
    }
}

private struct ScreenPreview: View {
    let route: ChatRoute
    let locale: ChatLocale
    let dark: Bool

    var body: some View {
        ChatRootView(model: PreviewData.model(route, locale: locale), onClose: {})
            .preferredColorScheme(dark ? .dark : .light)
    }
}

struct ChatScreens_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach(Array([ChatRoute.home, .list, .thread(nil), .consent, .loadFailed].enumerated()), id: \.offset) { _, route in
                ScreenPreview(route: route, locale: .en, dark: false).previewDisplayName("\(String(describing: route)) light")
                ScreenPreview(route: route, locale: .en, dark: true).previewDisplayName("\(String(describing: route)) dark")
                ScreenPreview(route: route, locale: .ar, dark: false).previewDisplayName("\(String(describing: route)) arabic")
            }
        }
    }
}
#endif
