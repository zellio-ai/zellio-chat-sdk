#!/usr/bin/env bash
# Publishes the zellio_chat plugin. `dart pub publish` runs no scripts, and the vendored iOS sources
# (ios/zellio_chat/Sources/zellio_chat/Vendor) are git-ignored, so a stale or missing copy would ship.
# This script makes a fresh copy first, checks it, then calls `dart pub publish` with your arguments.
#
#   scripts/publish.sh --dry-run
#   scripts/publish.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
cd "$plugin"

bash scripts/vendor-ios.sh

vendor="ios/zellio_chat/Sources/zellio_chat/Vendor"
if ! cmp -s "../ios/Sources/ZellioChat/PrivacyInfo.xcprivacy" "$vendor/PrivacyInfo.xcprivacy"; then
  echo "publish: PrivacyInfo.xcprivacy in Vendor differs from sdks/ios/Sources/ZellioChat" >&2
  exit 1
fi
if ! find "$vendor" -name '*.swift' | grep -q .; then
  echo "publish: no vendored Swift files" >&2
  exit 1
fi

dart pub publish "$@"
