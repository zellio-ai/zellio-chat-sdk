## 1.0.1

- No API change. Release built by the automated release workflow.
- The repo keeps the executable bit on `gradlew` and the shell scripts again.

## 1.0.0

- First version. A thin Flutter wrapper over the native ZeeChat iOS and Android SDKs.
- API: `configure`, `identify`, `logout`, `present`, `presentConversation`, `dismiss`, `setContext`,
  `unreadCount`, `unreadStream`, `events`, `setPushToken`, `isZellioPush`, `handlePush`, `handleNotificationTap`.
- iOS: Swift Package Manager and CocoaPods. The native sources are vendored by `scripts/vendor-ios.sh`.
- Android: depends on `ai.zellio:zellio-chat`.
