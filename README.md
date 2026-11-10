# ZeeChat mobile SDKs

Native in-app chat for [Zellio](https://zellio.ai). Your customers chat inside your app, and your team
replies from the Zellio inbox. The screens are fully native (SwiftUI on iOS, Jetpack Compose on Android),
right-to-left ready, in English and Egyptian Arabic, in light and dark mode.

| Platform | Package | Install |
|---|---|---|
| iOS 15+ | `ZellioChat` (Swift Package Manager) | `.package(url: "https://github.com/zellio-ai/zellio-chat-sdk", from: "1.0.0")` |
| Android (minSdk 24) | `ai.zellio:zellio-chat` (Maven Central) | `implementation("ai.zellio:zellio-chat:1.0.0")` |
| React Native 0.82+ | `@zellio/chat-react-native` (npm) | `npm install @zellio/chat-react-native` |
| Flutter 3.27+ | `zellio_chat` (pub.dev) | `flutter pub add zellio_chat` |

Push alerts on Android: add `ai.zellio:zellio-chat-fcm` as well.

## Four calls

```swift
ZellioChat.configure(appKey: "zca_...")                        // once, at app start
ZellioChat.identify { try await myBackend.zellioChatToken() }  // a JWT signed by your server
ZellioChat.present()                                           // open chat
ZellioChat.logout()                                            // when your user logs out
```

The same four calls exist on every platform. Get the app key and the identity secret in the Zellio dashboard:
the Live chat studio, under **Mobile apps**. Never put the identity secret in the app.

## Folders

- [`ios/`](ios/README.md): Swift package (`ZellioChatCore` + `ZellioChat`) and a sample app.
- [`android/`](android/README.md): `zellio-chat`, `zellio-chat-fcm` and a sample app.
- [`react-native/`](react-native/README.md): Turbo Native Module and Expo config plugin over the native SDKs.
- [`flutter/`](flutter/README.md): Flutter plugin over the native SDKs.
- [`contract/v1/`](contract/v1/README.md): the server API contract and JSON fixtures that every SDK is tested against.
- [`SPEC.md`](SPEC.md): shared product rules for all four packages.

## Support

Email support@zellio.ai, or open an issue in this repo.

## License

[Apache-2.0](LICENSE)
