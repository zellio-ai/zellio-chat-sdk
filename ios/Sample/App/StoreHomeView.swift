import SwiftUI
import UIKit
import UserNotifications
import ZellioChat
import ZellioChatCore

/// What the host app stores: where the server is, which app key, and a test identity token.
final class SampleSettings: ObservableObject {
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var appKey: String { didSet { UserDefaults.standard.set(appKey, forKey: "appKey") } }
    @Published var identityToken: String { didSet { UserDefaults.standard.set(identityToken, forKey: "identityToken") } }
    @Published var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode") } }
    @Published var arabic: Bool { didSet { UserDefaults.standard.set(arabic, forKey: "arabic") } }
    @Published var darkMode: Bool { didSet { UserDefaults.standard.set(darkMode, forKey: "darkMode") } }
    @Published var identified = false

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: "baseURL") ?? "https://app.zellio.ai"
        appKey = defaults.string(forKey: "appKey") ?? ""
        identityToken = defaults.string(forKey: "identityToken") ?? ""
        demoMode = defaults.object(forKey: "demoMode") as? Bool ?? true
        arabic = defaults.bool(forKey: "arabic")
        darkMode = defaults.bool(forKey: "darkMode")
    }

    func apply() {
        var options = ZellioChatOptions(baseURL: demoMode ? nil : URL(string: baseURL))
        options.locale = arabic ? .arabic : .auto
        options.theme = ZellioChatTheme(mode: darkMode ? .dark : .auto)
        options.logLevel = .debug
        if demoMode { options.transport = DemoTransport() }
        ZellioChat.configure(appKey: demoMode ? "demo-app-key" : appKey, options: options)
    }

    func identify() {
        let token = identityToken
        // Your app asks its own backend for a fresh token here. The sample reuses the one typed in.
        ZellioChat.identify { token }
        identified = true
    }

    func logout() {
        ZellioChat.logout()
        identified = false
    }
}

/// A made-up store screen, so you can see the chat on top of a real-looking app.
struct StoreHomeView: View {
    @EnvironmentObject private var settings: SampleSettings
    @ObservedObject private var unread = ZellioChat.unread
    @State private var showConfig = false

    private let products = [("Linen shirt", "EGP 890"), ("Canvas tote", "EGP 450"), ("Leather wallet", "EGP 1,200"), ("Sunglasses", "EGP 780")]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(products, id: \.0) { product in
                        HStack {
                            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.2)).frame(width: 72, height: 72)
                            VStack(alignment: .leading) {
                                Text(product.0).font(.headline)
                                Text(product.1).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Ask") {
                                ZellioChat.setContext(ZellioChatContext(screen: "product", itemType: "product", itemId: product.0, itemTitle: product.0))
                                ZellioChat.present()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Divider()
                    actions
                }
                .padding(20)
            }
            .navigationTitle("Nile Store")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showConfig = true } label: { Image(systemName: "gearshape") }
                }
            }
            .overlay(alignment: .bottomTrailing) { chatButton }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showConfig) { ConfigView().environmentObject(settings) }
    }

    private var chatButton: some View {
        Button { ZellioChat.present() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 22)).foregroundColor(.white)
                    .frame(width: 56, height: 56).background(Circle().fill(Color.purple))
                if unread.count > 0 {
                    Text("\(unread.count)").font(.caption2.bold()).foregroundColor(.white)
                        .padding(5).background(Circle().fill(Color.red)).offset(x: 4, y: -4)
                }
            }
        }
        .padding(20)
        .accessibilityLabel("Chat with us")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SDK calls").font(.headline)
            Button("present()") { ZellioChat.present() }
            Button("presentConversation(id: \"conv_2\")") { ZellioChat.presentConversation(id: "conv_2") }
            Button("identify") { settings.identify() }.disabled(settings.identityToken.isEmpty)
            Button("logout") { settings.logout() }
            Button("setContext (checkout)") {
                ZellioChat.setContext(ZellioChatContext(screen: "checkout", url: "https://shop.example/checkout"))
            }
            Button("Ask for push permission") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                }
            }
            Text(settings.identified ? "Identified" : "Guest").font(.footnote).foregroundColor(.secondary)
        }
        .buttonStyle(.bordered)
    }
}

struct ConfigView: View {
    @EnvironmentObject private var settings: SampleSettings
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Mode")) {
                    Toggle("Demo mode (fake server, no network)", isOn: $settings.demoMode)
                    Toggle("Arabic", isOn: $settings.arabic)
                    Toggle("Dark", isOn: $settings.darkMode)
                }
                Section(header: Text("Server")) {
                    TextField("Base URL", text: $settings.baseURL).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                    TextField("App key", text: $settings.appKey).autocapitalization(.none).disableAutocorrection(true)
                    TextField("Test identity token", text: $settings.identityToken).autocapitalization(.none).disableAutocorrection(true)
                }
                .disabled(settings.demoMode)
                Section(footer: Text("Changing the server or the app key needs an app restart.")) {
                    Button("Apply language and theme") { settings.apply() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentation.wrappedValue.dismiss() } } }
        }
    }
}
