#!/usr/bin/env bash
# CI checks for the zellio_chat Flutter plugin. Runs on Linux (and macOS, Git Bash). Needs flutter and dart on PATH.
#
#   scripts/ci-check.sh
#
# Steps: vendor iOS sources, pub get, format check, analyze, test, version match, publish file check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
cd "$plugin"

step() { printf '\n== %s ==\n' "$1"; }

step "vendor iOS sources"
bash scripts/vendor-ios.sh

step "flutter pub get"
flutter pub get

step "dart format --set-exit-if-changed"
dart format --set-exit-if-changed lib test

step "flutter analyze"
flutter analyze

step "flutter test"
flutter test

step "versions agree (pubspec, Dart constant, podspec, Gradle)"
pub_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' pubspec.yaml | head -n1)"
for check in \
  "lib/src/version.dart:'$pub_version'" \
  "ios/zellio_chat.podspec:s.version          = '$pub_version'" \
  "android/build.gradle.kts:version = \"$pub_version\""; do
  file="${check%%:*}"
  needle="${check#*:}"
  if ! grep -qF "$needle" "$file"; then
    echo "version mismatch: $file does not contain $needle" >&2
    exit 1
  fi
done
echo "all at $pub_version"

step "native files exist (SwiftPM + CocoaPods + Android)"
for f in \
  ios/zellio_chat/Package.swift \
  ios/zellio_chat.podspec \
  ios/zellio_chat/Sources/zellio_chat/ZellioChatPlugin.swift \
  ios/zellio_chat/Sources/zellio_chat/Vendor/PrivacyInfo.xcprivacy \
  android/build.gradle.kts \
  android/src/main/kotlin/ai/zellio/chat/flutter/ZellioChatPlugin.kt; do
  test -f "$f" || { echo "missing: $f" >&2; exit 1; }
done

step "pub publish --dry-run (on a temp copy, with publish_to removed)"
# The real pubspec says `publish_to: none`, which makes pub refuse to even dry-run.
# The copy is NOT a git repo, so pub does not warn about uncommitted files.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar --exclude='./.dart_tool' --exclude='./build' --exclude='./example/build' --exclude='./example/.dart_tool' -cf - . | tar -xf - -C "$tmp"
sed -i.bak '/^publish_to:/d' "$tmp/pubspec.yaml"
rm -f "$tmp/pubspec.yaml.bak"
(cd "$tmp" && flutter pub get >/dev/null)
dry_status=0
dry_out="$(cd "$tmp" && dart pub publish --dry-run 2>&1)" || dry_status=$?
echo "$dry_out"
if [ "$dry_status" -ne 0 ]; then
  echo "pub publish --dry-run failed with exit $dry_status" >&2
  exit "$dry_status"
fi

# The dry run must list the vendored iOS sources (they are git-ignored; .pubignore re-includes them).
step "published file list includes the vendored iOS sources"
if ! grep -q 'Vendor' <<<"$dry_out"; then
  echo "Vendor/ is not in the package" >&2
  exit 1
fi

echo
echo "ci-check: OK"
