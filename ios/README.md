# ZeeChat iOS SDK

Native chat for iOS 15+. Swift Package, no dependencies.

- `ZellioChatCore`: all logic (API, session, queue, timeline, stream, consent, theme rules). Foundation only. Builds on Linux.
- `ZellioChat`: SwiftUI and UIKit screens, Keychain, URLSession, push helpers, public API.

## Install

Add the package (path or URL) and the `ZellioChat` product. Add `NSCameraUsageDescription` to your Info.plist.

```swift
ZellioChat.configure(appKey: "zca_...")
ZellioChat.identify { try await myBackend.zellioIdentityToken() }
ZellioChat.present()
```

## Commands

```sh
# Core, any OS with Swift 5.9+ (also works in Docker: swift:6.0)
swift build --target ZellioChatCore
swift test

# Strings (from sdks/design/strings.json)
node scripts/generate-strings.mjs          # write
node scripts/generate-strings.mjs --check  # CI check

# Full build, tests and sample on macOS
scripts/ci-macos.sh

# Sample app (needs xcodegen)
cd Sample && xcodegen generate && open ZellioChatSample.xcodeproj
```

The sample has a demo mode: an in-process fake server that answers with `sdks/contract/v1/fixtures`. No network.

## Verification status (honest)

- `ZellioChatCore` and its tests: built and run in the `swift:6.0` Linux image. The tests read the contract fixtures directly.
- `ZellioChat` (SwiftUI/UIKit), `Sample`, `scripts/ci-macos.sh`: written on Windows. **Not compiled and not run.** They need Xcode. Expect compile errors to fix on the first macOS build. Nothing was checked on a device or simulator: layout, keyboard, VoiceOver, RTL, dark mode, iPad, camera and push are all untested.
- `PrivacyInfo.xcprivacy` is hand-written and not validated by Xcode.
