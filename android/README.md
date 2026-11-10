# ZeeChat for Android

Native Android SDK for ZeeChat (contract v1, see `../contract/v1/README.md`; product rules in `../SPEC.md`).

| Module | What it is |
|---|---|
| `:zellio-chat` | The SDK (`ai.zellio:zellio-chat`). Kotlin, Compose, no native code. |
| `:zellio-chat-fcm` | Optional. A ready `ZellioMessagingService` and the `ZellioFcm` forwarding helper. |
| `:sample` | A store-like host app with an offline demo (an in-process fake server that serves the contract fixtures). |

## Use it

```kotlin
// Application.onCreate
ZellioChat.configure(this, "APP_KEY", ZellioChatOptions(locale = ZellioLocale.AUTO))

// after login
ZellioChat.identify { myBackend.zeechatToken() }   // returns a JWT; null when logged out
ZellioChat.present()                                // or presentConversation(id)
ZellioChat.logout()
```

Inside your own navigation: `ZellioChatScreen(Modifier.fillMaxSize(), onClose = { ... })`.
Push: call `ZellioFcm.onNewToken` / `onMessageReceived` from your own `FirebaseMessagingService`, or keep the
`ZellioMessagingService` from `:zellio-chat-fcm`. From a tapped notification: `ZellioChat.handleNotificationTap(intent)`.

### Notification icon

The status bar needs a small, single-colour icon. An adaptive launcher icon shows as a white blob. Put this in the
app manifest (inside `<application>`):

```xml
<meta-data android:name="ai.zellio.chat.notification_icon" android:resource="@drawable/ic_stat_notify" />
<meta-data android:name="ai.zellio.chat.notification_color" android:resource="@color/brand" /> <!-- optional -->
```

Without it the SDK uses `com.google.firebase.messaging.default_notification_icon`, then the launcher icon.

## Build and test

Needs JDK 17+ and the Android SDK (platform 36). Gradle 9.6.0 comes from the wrapper.

```
./gradlew :zellio-chat:assembleRelease :zellio-chat-fcm:assembleRelease :sample:assembleDebug test
./gradlew :zellio-chat:testDebugUnitTest     # JVM tests only
./gradlew :zellio-chat:checkSdkSize          # fails over 2 MB or if a .so is inside
./gradlew :zellio-chat:generateStrings       # res/values and res/values-ar from ../design/strings.json
```

`assembleRelease` runs `checkSdkSize` after it. Strings are never edited by hand: change `../design/strings.json`.
Tests read the shared fixtures in `../contract/v1/fixtures` directly.

Run the sample: `adb install sample/build/outputs/apk/debug/sample-debug.apk`. It starts in offline demo mode
(consent, guest session, replies from the fake server). The Developer tab switches to a real server, sets the
language and theme, and calls `present`, `identify`, `logout` and `setContext`.

## Publishing

Maven publishing and signing are configured and never run from here. CI passes `signingInMemoryKey` and the
repository credentials as Gradle properties. Play Data safety answers: `docs/play-data-safety.md`.
