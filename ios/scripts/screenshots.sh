#!/usr/bin/env bash
# Opens the sample on simulators with the demo server and takes screenshots of the real screens.
# It fails if the app is not alive after a screen opened. Run it after ci-macos.sh, which builds the app.
# Usage: sdks/ios/scripts/screenshots.sh <output folder>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?output folder}"
BUNDLE=ai.zellio.sample.chat
APP="$(find "$ROOT/.build/derived/Build/Products" -maxdepth 2 -name 'ZellioChatSample.app' | head -n 1)"
PHONE="${IOS_DESTINATION:?IOS_DESTINATION}"
PHONE="${PHONE##*name=}"
mkdir -p "$OUT"

shot() {
  local device="$1" file="$2"
  shift 2
  xcrun simctl terminate "$device" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$device" "$BUNDLE" "$@" >/dev/null
  sleep 6
  # Read the list first: grep -q closes a pipe early, and pipefail would read that as a dead app.
  local running
  running="$(xcrun simctl spawn "$device" launchctl list)"
  if ! grep -q "$BUNDLE" <<<"$running"; then
    echo "::error::The sample is not running after: $file"
    cp ~/Library/Logs/DiagnosticReports/ZellioChatSample* "$OUT/" 2>/dev/null || true
    exit 1
  fi
  xcrun simctl io "$device" screenshot "$OUT/$file.png" >/dev/null
}

prepare() {
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl uninstall "$1" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$1" "$APP"
}

prepare "$PHONE"
shot "$PHONE" phone-consent-en -autoOpen home
shot "$PHONE" phone-consent-ar -autoOpen home -arabic YES
for theme in light dark; do
  dark=NO; [ "$theme" = dark ] && dark=YES
  for lang in en ar; do
    ar=NO; [ "$lang" = ar ] && ar=YES
    shot "$PHONE" "phone-home-$lang-$theme" -autoOpen home -demoNoConsent YES -arabic "$ar" -darkMode "$dark"
    shot "$PHONE" "phone-thread-$lang-$theme" -autoOpen thread -demoNoConsent YES -arabic "$ar" -darkMode "$dark"
  done
done
shot "$PHONE" phone-thread-en-keyboard -autoOpen thread -demoNoConsent YES -demoFocus YES

IPAD="$(xcrun simctl list devices available | grep -E '^ +iPad ' | head -n 1 | sed -E 's/^ +(iPad.*[^ ]) +\([0-9A-F-]{36}\).*/\1/')"
if [ -z "$IPAD" ]; then
  echo "::warning::No iPad simulator on this runner. iPad screenshots skipped."
else
  prepare "$IPAD"
  shot "$IPAD" ipad-thread-en -autoOpen thread -demoNoConsent YES
  shot "$IPAD" ipad-thread-ar -autoOpen thread -demoNoConsent YES -arabic YES
  shot "$IPAD" ipad-thread-en-dark -autoOpen thread -demoNoConsent YES -darkMode YES
  shot "$IPAD" ipad-thread-en-keyboard -autoOpen thread -demoNoConsent YES -demoFocus YES
  shot "$IPAD" ipad-thread-ar-keyboard -autoOpen thread -demoNoConsent YES -demoFocus YES -arabic YES
  shot "$IPAD" ipad-home-en -autoOpen home -demoNoConsent YES
fi
echo "screenshots: $(find "$OUT" -name '*.png' | wc -l)"
