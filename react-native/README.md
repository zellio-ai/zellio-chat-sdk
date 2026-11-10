# @zellio/chat-react-native

ZeeChat for React Native. This package is a thin wrapper: the native iOS and Android SDKs draw all screens and
hold all chat logic. JavaScript only configures them, opens them, gives them a token and listens to events.

- Needs the **New Architecture** (Turbo Native Modules). React Native 0.82 and later has no other mode.
  Tested with React Native 0.88.1 and Expo SDK 58. iOS 15.1+, Android minSdk 24.
- English docs here. Arabic docs come later.

## 5-minute setup: bare React Native

```sh
npm install @zellio/chat-react-native
cd ios && pod install && cd ..
```

Add the camera text to `ios/<App>/Info.plist` (the SDK asks for camera access only when a customer taps Camera):

```xml
<key>NSCameraUsageDescription</key>
<string>Allow the app to use the camera so you can send photos in chat.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Allow the app to access your photos so you can send them in chat.</string>
```

Start it once, as early as you can (top of `index.js` or `App.tsx`):

```ts
import * as ZellioChat from '@zellio/chat-react-native';

ZellioChat.configure({ appKey: 'zca_...' });
```

Open it from a button:

```tsx
<Button title="Chat with us" onPress={() => ZellioChat.present()} />
```

That is all. The app key is in Zellio Studio.

## 5-minute setup: Expo

```sh
npx expo install @zellio/chat-react-native
```

`app.json`:

```json
{
  "expo": {
    "plugins": [
      [
        "@zellio/chat-react-native",
        {
          "cameraPermission": "Allow $(PRODUCT_NAME) to use the camera so you can send photos in chat.",
          "photoLibraryPermission": "Allow $(PRODUCT_NAME) to access your photos so you can send them in chat."
        }
      ]
    ]
  }
}
```

Then build a development build: `npx expo prebuild` and `npx expo run:ios` / `npx expo run:android`, or EAS Build.

**This does not work in Expo Go.** Expo Go is one fixed app with a fixed list of native modules. This package adds
native code (a Turbo Native Module and the two native chat SDKs). Native code can only be added when the app is
built, so you need a development build (or a production build). JavaScript changes still reload fast in a
development build.

Plugin options (all optional):

| Option | Default | Meaning |
|---|---|---|
| `cameraPermission` | English text | `NSCameraUsageDescription`. `false` adds nothing. |
| `photoLibraryPermission` | English text | `NSPhotoLibraryUsageDescription`. `false` adds nothing. |
| `enableIosPush` | `false` | Adds the `aps-environment` entitlement and the `remote-notification` background mode. Leave it off if `expo-notifications` already does this. |
| `apsEnvironment` | `development` | Value of `aps-environment` when `enableIosPush` is on. |
| `androidMavenRepository` | none | A Maven URL for `ai.zellio:zellio-chat`, only if it is not on Maven Central for you. |

The plugin never adds push entitlements unless you set `enableIosPush`. It keeps any usage text you already set.

## API

```ts
configure({ appKey, baseUrl?, locale?, theme?, logLevel?, showsInAppBanner?, bannerShowsPreview? }): void
identify(tokenProvider: () => Promise<string | null>): void
logout(): void
present(): void
presentConversation(id?: string | null): void
dismiss(): void
setContext(context: { screen?, itemType?, itemId?, itemTitle?, url? } | null): void
getUnreadCount(): Promise<number>
addUnreadListener(cb: (count: number) => void): { remove(): void }
addEventListener(cb: (event: ZellioChatEvent) => void): { remove(): void }
setPushToken(token: string, environment?: 'sandbox' | 'production'): void
isZellioPush(payload): boolean
handlePush(payload): Promise<boolean>
handleNotificationTap(payload): Promise<boolean>
```

`ZellioChatEvent` is `chatOpened | chatClosed | messageSent | messageReceived | error { code }`. Events never carry
message text. Every call is safe before `configure` and never throws into your app.

`showsInAppBanner` (default true) turns the in-app banner on or off. `bannerShowsPreview` (default true) shows the message text in it; when false it says "New message".

## Identity with a server token

Your server signs a short-lived JWT for the signed-in customer (see the contract in the Zellio docs). The app only
passes a function that fetches it:

```ts
ZellioChat.identify(async () => {
  const response = await fetch('https://api.example.com/zeechat-token', { headers: authHeaders() });
  if (!response.ok) throw new Error('token');
  return (await response.json()).token; // return null for a guest
});
```

How it works: the native SDK calls your function when it needs a session, and again if the server rejects the token.
Native sends an event with a request id, JavaScript runs your function and answers with the token or an error. If
your function does not answer in **15 seconds**, the request fails. The token is never logged, not by JavaScript and
not by native code. On sign-out call `ZellioChat.logout()`: it deletes all local chat data and removes the push token.

## Context

Tell agents what the customer looks at. It is sent with the next messages:

```ts
ZellioChat.setContext({ screen: 'Product', itemType: 'product', itemId: '42', itemTitle: 'Linen shirt', url: 'https://shop.example.com/p/42' });
ZellioChat.setContext(null); // clear
```

`url` must be `https`. Text is cut to 200 characters.

## Push notifications

This package does not take over your notification code. You keep your push library and forward to this package.

**Android (FCM).** Use the FCM library you already use (for example `@react-native-firebase/messaging`). Pass the
token with `setPushToken` and each message with `handlePush`:

```ts
import messaging from '@react-native-firebase/messaging';

messaging().getToken().then((token) => ZellioChat.setPushToken(token));
messaging().onTokenRefresh((token) => ZellioChat.setPushToken(token));

// Foreground and background (data) messages
messaging().onMessage(async (message) => { await ZellioChat.handlePush(message.data); });
messaging().setBackgroundMessageHandler(async (message) => { await ZellioChat.handlePush(message.data); });

// Notification tapped
messaging().onNotificationOpenedApp((message) => { void ZellioChat.handleNotificationTap(message.data); });
messaging().getInitialNotification().then((message) => { if (message) void ZellioChat.handleNotificationTap(message.data); });
```

Do not add a second `FirebaseMessagingService` from this package: Android allows one per app, and FCM goes through
the library you chose. (The native Android SDK has an optional ready service for apps with no other push code. It is
not part of this package.)

**iOS (APNs).** Turn on Push Notifications and Background Modes > Remote notifications for the app target (Expo:
`enableIosPush: true`, or let `expo-notifications` do it). Pass the APNs token as a **hex string**:

```ts
import * as Notifications from 'expo-notifications';

const token = await Notifications.getDevicePushTokenAsync(); // { type: 'ios', data: '<hex>' }
ZellioChat.setPushToken(token.data, __DEV__ ? 'sandbox' : 'production');

Notifications.addNotificationReceivedListener((n) => {
  void ZellioChat.handlePush(n.request.trigger && 'payload' in n.request.trigger ? (n.request.trigger.payload as Record<string, unknown>) : null);
});
Notifications.addNotificationResponseReceivedListener((response) => {
  const trigger = response.notification.request.trigger;
  if (trigger && 'payload' in trigger) void ZellioChat.handleNotificationTap(trigger.payload as Record<string, unknown>);
});
```

`isZellioPush(payload)` is true only when the payload has the `zellio` key, so you can tell our pushes from yours.
`handlePush` and `handleNotificationTap` resolve `true` when the push was ours.

## Build against the local native SDKs (this repository)

The package depends on `ai.zellio:zellio-chat:<version>` from Maven and on the iOS sources copied into the package.
Inside the repository:

- **iOS:** `npm run vendor:ios` copies `../ios/Sources` to `ios/vendor` (git-ignored). `npm pack` does it for you. The
  podspec compiles those sources into the pod, so no extra pod and no CocoaPods trunk push are needed.
- **Android:** publish the SDK to your local Maven repository, then build the sample with it:

  ```sh
  cd ../android && ./gradlew :zellio-chat:publishReleasePublicationToMavenLocal
  ```

  The sample's `android/gradle.properties` has `zellioChatUseMavenLocal=true`, which adds `mavenLocal()` to the sample's
  repositories. Do the same in your own app to test a local SDK. The sample uses stock React Native 0.88 versions of
  Kotlin (2.2.0) and the Android Gradle Plugin, so this also checks that the SDK builds against them. Set
  `zellioChatAndroidVersion` to pin another Maven version.

## Sample

```sh
cd sdks/react-native && npm ci && npm run build
cd sample && npm install && npm run setup   # creates zellio.config.json (git-ignored)
# put your app key in zellio.config.json, then:
npm start
npm run android      # Android
npm run pods && npm run ios   # iOS, macOS only: copies the iOS SDK sources, runs pod install
```

The sample has a store-like screen, an **Open chat** button, an unread badge and product context.

No account? Run `npm run fixture-server` in `sample/`. It answers the API contract with the shared fixtures. Then set
`"baseUrl": "http://10.0.2.2:8787"` (Android emulator) or `"http://localhost:8787"` (iOS simulator) in
`zellio.config.json`. Debug builds allow cleartext HTTP; never ship an http `baseUrl`. The fixture server prints the
`x-zee-sdk-wrapper` header of each request, which shows `react-native/1.0.0`.

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| `TurboModuleRegistry.getEnforcing(...): 'RNZellioChat' could not be found` | The app was not rebuilt after install. Run `pod install` (iOS) and rebuild. In Expo, you are in Expo Go: use a development build. |
| Nothing happens on `present()` | `configure` was not called, or the app key is empty. Set `logLevel: 'debug'` and read Logcat (`ZellioChat`) or the Xcode console. Calls before `configure` are logged and ignored. |
| "Chat not available" screen | The app key or `baseUrl` is wrong, or there is no network. Check them in Zellio Studio. |
| Android: `Could not find ai.zellio:zellio-chat` | The artifact is not on a repository your app uses. Add `mavenCentral()` to `repositories`, or use the Expo option `androidMavenRepository`, or use the local build above. |
| Android build: `kotlin-android` plugin error | RN 0.88 templates set `android.builtInKotlin=false`. Keep that line in `android/gradle.properties`. |
| iOS: duplicate symbol or `No such module 'ZellioChatCore'` | `ios/vendor` is out of date. Run `npm run vendor:ios`, then `pod install`. |
| Token request fails after 15 s | Your `identify` function is slow or never resolves. It must return a string, or `null` for a guest. |
| iOS push never arrives | Use the **hex** APNs token, and `sandbox` for debug builds and `production` for store builds. |
| Unread badge stays 0 | The customer has no session yet (no consent, no `identify`), or the app is in the background. |

## Status (honest)

- The TypeScript API, the identify flow and the Expo config plugin are covered by unit tests.
- The Android module is compiled against the native Android SDK. See the repository notes for what was run.
- The iOS glue (`RNZellioChat.mm`, `ZCRNBridge.swift`) and the podspec were written on Windows and have **never been
  compiled**. Expect small fixes on the first macOS build with `pod install`.
