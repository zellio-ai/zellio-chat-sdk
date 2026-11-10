#!/usr/bin/env bash
# CI check for @zellio/chat-react-native. Runs on Linux. From sdks/react-native:  bash scripts/ci-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== npm ci"
npm ci --no-audit --no-fund

echo "== version agrees in package.json and src/version.ts"
node scripts/check-version.mjs

echo "== iOS sources can be merged into one pod (no clashing file or type names)"
node scripts/vendor-ios.mjs --check

echo "== tsc (library, tests, plugin)"
npx tsc --noEmit -p tsconfig.json
npx tsc --noEmit -p plugin/tsconfig.json

if ls eslint.config.* .eslintrc* >/dev/null 2>&1; then
  echo "== eslint"
  npx eslint src plugin/src __tests__ plugin/__tests__
else
  echo "== eslint: no config in this package, skipped"
fi

echo "== specs (API forwarding, identify flow, listeners, config plugin)"
npx vitest run

echo "== prepack steps (version check, vendor iOS, build), then npm pack --dry-run"
npm run --silent prepack
PACK_JSON="$(mktemp)"
npm pack --dry-run --json --ignore-scripts >"$PACK_JSON"
node scripts/check-pack.mjs "$PACK_JSON"
rm -f "$PACK_JSON"
echo "== all checks passed"
