## 1.0.0

- First version. A thin Flutter wrapper over the native ZeeChat iOS and Android SDKs.
- API: `configure`, `identify`, `logout`, `present`, `presentConversation`, `dismiss`, `setContext`,
  `unreadCount`, `unreadStream`, `events`, `setPushToken`, `isZellioPush`, `handlePush`, `handleNotificationTap`.
- iOS: Swift Package Manager and CocoaPods. The native sources are vendored by `scripts/vendor-ios.sh`.
- Android: depends on `ai.zellio:zellio-chat`.
