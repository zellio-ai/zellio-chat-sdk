# zellio_chat

ZeeChat for Flutter. A thin wrapper over the native Zellio chat SDKs for iOS and Android.
The native SDKs draw every screen and hold all chat logic. The Dart code only forwards calls and events.

- Product rules: `../SPEC.md`. Server contract: `../contract/v1/README.md`.
- Needs Flutter 3.27+, iOS 15+, Android minSdk 24.
- License: Apache-2.0. Source: https://github.com/zellio-ai/zellio-chat-sdk.

## Set up in 5 minutes

1. Add the package (path or, later, pub.dev):

   ```yaml
   dependencies:
     zellio_chat:
       path: ../path/to/sdks/flutter
   ```

2. **iOS only, until the package is published:** copy the native iOS sources into the plugin.
   The published package already contains them.

   ```sh
   sdks/flutter/scripts/vendor-ios.sh
   ```

3. **Android only, until the native SDK is on Maven:** the plugin needs `ai.zellio:zellio-chat`.
   To use the checkout in `sdks/android`, see "Build against the local Android SDK" below.

4. Add `NSCameraUsageDescription` to `ios/Runner/Info.plist` (the customer can take a photo in chat).

5. Start the SDK and open chat:

   ```dart
   import 'package:zellio_chat/zellio_chat.dart';

   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await ZellioChat.configure('zca_YOUR_APP_KEY');
     runApp(const MyApp());
   }

   // anywhere:
   ZellioChat.present();
   ```

## API

| Call | Meaning |
|---|---|
| `ZellioChat.configure(appKey, {baseUrl, locale, theme, logLevel, showsInAppBanner, bannerShowsPreview})` | Call once at app start. |
| `ZellioChat.identify(Future<String?> Function() tokenProvider)` | Marks a signed-in customer. |
| `ZellioChat.logout()` | Ends the session, deletes local chat data, removes the push token. |
| `ZellioChat.present()` / `presentConversation([id])` / `dismiss()` | Show, open one conversation (or a new one), close. |
| `ZellioChat.setContext(ZellioContext?)` | What the customer looks at. `null` clears it. |
| `await ZellioChat.unreadCount` and `ZellioChat.unreadStream` | Unread number, now and on every change. |
| `ZellioChat.events` | `ChatOpened`, `ChatClosed`, `MessageSent`, `MessageReceived`, `ChatError(code)`. No message text. |
| `setPushToken(token, {environment})`, `isZellioPush(payload)`, `handlePush(payload)`, `handleNotificationTap(payload)` | Push. See below. |

No call throws. A call before `configure` is ignored by the native SDK.

## Identity: log in your customer with a server token

Your server signs a short-lived JWT for the signed-in customer (see the contract). The SDK asks your Dart code for it
when it needs a session, and again if the server rejects it:

```dart
await ZellioChat.identify(() async {
  final response = await myBackend.post('/zellio/identity-token'); // your own call
  return response.token;          // return null when nobody is signed in
});

// on sign out
await ZellioChat.logout();
```

- The provider has **15 seconds**. A provider that is slower, or throws, counts as a failure; the chat then shows the
  login-needed state. Only the error type name reaches the native side, never the error text.
- The token is never logged by the plugin or the native SDKs.
- A new `identify` for a different customer runs `logout` first (the native SDK does it).

## Push with firebase_messaging

The app keeps its own notification code. Forward Zellio pushes to the plugin.

```dart
// After login and on refresh. Android: the FCM token. iOS: the APNs token (hex), not the FCM token.
final fcm = FirebaseMessaging.instance;
final token = Platform.isIOS ? await fcm.getAPNSToken() : await fcm.getToken();
if (token != null) await ZellioChat.setPushToken(token /* , environment: 'sandbox' */);
fcm.onTokenRefresh.listen((t) {
  if (!Platform.isIOS) ZellioChat.setPushToken(t);
});

// Foreground message
FirebaseMessaging.onMessage.listen((m) => ZellioChat.handlePush(m.data));

// Notification tapped while the app was in the background
FirebaseMessaging.onMessageOpenedApp.listen((m) => ZellioChat.handleNotificationTap(m.data));

// Notification tapped while the app was closed
final first = await fcm.getInitialMessage();
if (first != null) await ZellioChat.handleNotificationTap(first.data);
```

- `isZellioPush(payload)` is true only if the payload has the `zellio` key. Use it to keep other pushes for your own code.
- Android: when a system-tray notification starts your activity, the plugin reads the intent and opens the conversation
  by itself. Call `handleNotificationTap` for notifications you show yourself.
- Android needs the `firebase_messaging` setup of your app (`google-services.json`). The plugin does not add a
  `FirebaseMessagingService`: yours stays in charge.
- iOS: enable Push Notifications and Background Modes > Remote notifications in Xcode. On a simulator there is no APNs token.
- A tapped iOS notification must reach Dart through `firebase_messaging` (it swizzles `UNUserNotificationCenter` by default).

## Context

```dart
ZellioChat.setContext(const ZellioContext(
  screen: 'product_detail',
  itemType: 'product',
  itemId: '42',
  itemTitle: 'Canvas sneakers',
  url: 'https://shop.example.com/p/42', // https only
));
ZellioChat.setContext(null); // clear
```

## Theme and language

```dart
ZellioChat.configure(
  'zca_...',
  locale: ZellioLocale.arabic,                       // auto | arabic | english
  theme: const ZellioTheme(mode: ZellioThemeMode.dark, primaryColor: Color(0xFF1A73E8)),
);
```

## Build against the local Android SDK (inside this repo)

The native SDK is not on Maven yet. Put it into your local Maven repository, then build the example:

```sh
sdks/flutter/scripts/publish-android-local.sh      # runs :zellio-chat:publishReleasePublicationToMavenLocal in sdks/android
cd sdks/flutter/example && flutter run --dart-define=ZELLIO_APP_KEY=zca_...
```

`example/android/gradle.properties` has `zellioChatUseMavenLocal=true`, which adds `mavenLocal()`. Add the same
property and the same `mavenLocal()` lines to your own app while you test. Remove them when the SDK is on Maven.
A Gradle composite build (`includeBuild`) does not work: Flutter's template uses AGP 9.0.1 and `sdks/android` uses
its own AGP, and Gradle does not allow two AGP versions in one build.

## Develop

```sh
scripts/ci-check.sh   # vendor iOS, pub get, format, analyze, test, publish dry-run check
```

On a machine without Flutter, run it in Docker (Linux image `ghcr.io/cirruslabs/flutter:stable`).

### What is verified

- Dart side: formatted, analyzed, unit tested (Linux, Docker).
- Android side: see the receipt of the PR for what was compiled.
- iOS side: **not compiled.** The Swift plugin, `Package.swift` and the podspec were written on Windows. The first
  compile happens on a Mac. Expect small fixes. The vendored SDK sources compile into one module (`zellio_chat`),
  so both SwiftPM and CocoaPods work without a new pod on trunk (CocoaPods trunk becomes read-only on 2026-12-02).

## Troubleshooting

| Problem | What to check |
|---|---|
| `present()` does nothing | Did you `await ZellioChat.configure(...)` with a real app key? Set `logLevel: ZellioLogLevel.debug` and read Logcat (`ZellioChat`) or the Xcode console. |
| Chat shows "login needed" | Your token provider returned `null`, threw, or took over 15 s. Check the JWT claims against the contract. |
| iOS: `No such module` / missing symbols | Run `scripts/vendor-ios.sh` (the vendored sources are not in git). Then `flutter clean` and rebuild. |
| iOS: build uses CocoaPods but you want SwiftPM (or the reverse) | `flutter config --enable-swift-package-manager` / `--no-enable-swift-package-manager`. Both are supported. |
| Android: `Could not find ai.zellio:zellio-chat` | The native SDK is not on your Maven repositories yet. Use the local wiring (see above). |
| Android: Kotlin metadata is too new | Raise the Kotlin version of your app (the native SDK uses Kotlin 2.4). |
| No unread badge | `unreadStream` sends a value after `configure` and `identify`. An anonymous customer has no unread state. |
| Push opens nothing | Is the payload from Zellio (`isZellioPush`)? On iOS pass the **APNs** token, not the FCM token. |
