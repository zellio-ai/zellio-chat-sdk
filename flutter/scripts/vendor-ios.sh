#!/usr/bin/env bash
# Copies the native iOS SDK sources (sdks/ios/Sources) into the plugin so that iOS apps get them without a
# new pod on CocoaPods trunk. Output: ios/zellio_chat/Sources/zellio_chat/Vendor (git-ignored, but included
# when you publish: see .pubignore).
#
# Both ZellioChatCore and ZellioChat compile into ONE module (zellio_chat), so the cross-module
# `import ZellioChatCore` lines are removed. Run it before an iOS build. To publish, use scripts/publish.sh (`dart pub publish` runs no scripts).
#
# Usage: scripts/vendor-ios.sh [path/to/ios/Sources]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
src="${1:-$plugin/../ios/Sources}"
dest="$plugin/ios/zellio_chat/Sources/zellio_chat/Vendor"

if [ ! -d "$src/ZellioChat" ] || [ ! -d "$src/ZellioChatCore" ]; then
  echo "vendor-ios: iOS sources not found in $src" >&2
  exit 1
fi
if [ ! -f "$src/ZellioChat/PrivacyInfo.xcprivacy" ]; then
  echo "vendor-ios: PrivacyInfo.xcprivacy missing in $src/ZellioChat" >&2
  exit 1
fi

# The folder is generated output: it is safe to replace it whole.
rm -rf "$dest"
mkdir -p "$dest"

count=0
for module in ZellioChatCore ZellioChat; do
  while IFS= read -r file; do
    rel="${file#"$src/"}"
    mkdir -p "$dest/$(dirname "$rel")"
    sed -e '/^import ZellioChatCore[[:space:]]*$/d' "$file" > "$dest/$rel"
    count=$((count + 1))
  done < <(find "$src/$module" -type f -name '*.swift' | sort)
done
cp "$src/ZellioChat/PrivacyInfo.xcprivacy" "$dest/PrivacyInfo.xcprivacy"
if ! cmp -s "$src/ZellioChat/PrivacyInfo.xcprivacy" "$dest/PrivacyInfo.xcprivacy"; then
  echo "vendor-ios: PrivacyInfo.xcprivacy in the copy differs from the source" >&2
  exit 1
fi

# Checks: no leftover module import, and no file name clash (two modules in one).
if grep -rn --include='*.swift' -E '^[[:space:]]*(@testable )?import ZellioChat(Core)?[[:space:]]*$' "$dest"; then
  echo "vendor-ios: a module import is left in the vendored sources" >&2
  exit 1
fi
dups="$(find "$dest" -name '*.swift' -exec basename {} \; | sort | uniq -d)"
if [ -n "$dups" ]; then
  echo "vendor-ios: duplicate file names (SwiftPM and Xcode need unique names per module): $dups" >&2
  exit 1
fi

echo "vendor-ios: copied $count Swift files and PrivacyInfo.xcprivacy to ${dest#"$plugin/"}"
