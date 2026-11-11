#!/usr/bin/env bash
# Builds and tests the iOS SDK on macOS. Needs Xcode 15+, xcodegen, and an iOS Simulator runtime.
# Usage: sdks/ios/scripts/ci-macos.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DERIVED="$ROOT/.build/derived"
DEST="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 15}"

echo "== Check generated strings"
node scripts/generate-strings.mjs --check

echo "== Resolve packages"
swift package resolve

echo "== Core tests (macOS host)"
swift test

echo "== Build ZellioChat for iOS Simulator"
xcodebuild build -scheme ZellioChat -destination "$DEST" -derivedDataPath "$DERIVED" -skipPackagePluginValidation

echo "== Core tests on iOS Simulator"
xcodebuild test -scheme ZellioChat-Package -destination "$DEST" -derivedDataPath "$DERIVED"

echo "== Build the sample app"
(cd Sample && xcodegen generate)
xcodebuild build -project Sample/ZellioChatSample.xcodeproj -scheme ZellioChatSample -configuration Release \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED"

echo "== Binary size"
APP="$(find "$DERIVED/Build/Products" -name 'ZellioChatSample.app' -maxdepth 3 | head -n 1)"
if [ -n "$APP" ]; then
  BIN="$APP/ZellioChatSample"
  echo "app binary: $(stat -f%z "$BIN") bytes"
  du -sh "$APP"
fi
LIB="$(find "$DERIVED/Build/Products" -name 'ZellioChat.o' -o -name 'libZellioChat.a' 2>/dev/null | head -n 1)"
[ -n "$LIB" ] && echo "SDK object: $(stat -f%z "$LIB") bytes"
echo "done"
