import SwiftUI
import UIKit
import UserNotifications
import ZellioChat

@main
struct ZellioSampleApp: App {
    @UIApplicationDelegateAdaptor(SampleAppDelegate.self) private var delegate
    @StateObject private var settings = SampleSettings()

    var body: some Scene {
        WindowGroup {
            StoreHomeView()
                .environmentObject(settings)
                .onAppear {
                    settings.apply()
                    switch UserDefaults.standard.string(forKey: "autoOpen") {
                    case "home": ZellioChat.present()
                    case "thread": ZellioChat.presentConversation(id: "conv_2")
                    default: break
                    }
                    if UserDefaults.standard.bool(forKey: "demoFocus") {
                        Task { @MainActor in
                            // The chat can take a few seconds to open on a slow simulator.
                            for _ in 0..<8 {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if focusFirstTextView() { break }
                            }
                        }
                    }
                }
        }
    }
}

/// Only for the screenshot script. The chat keeps its text view private, so this looks for it.
@MainActor
private func focusFirstTextView() -> Bool {
    func search(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap(search).first
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    return windows.lazy.compactMap(search).first?.becomeFirstResponder() ?? false
}

final class SampleAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ZellioChat.setPushToken(deviceToken)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        ZellioChat.handlePush(userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if ZellioChat.handlePush(notification.request.content.userInfo) {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        ZellioChat.handleNotificationTap(response.notification.request.content.userInfo)
        completionHandler()
    }
}
