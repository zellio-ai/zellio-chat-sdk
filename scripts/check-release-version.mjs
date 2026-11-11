#!/usr/bin/env node
// Every package in this repo ships the same version. This script fails when one version string differs.
//
//   node scripts/check-release-version.mjs          # all files agree with each other
//   node scripts/check-release-version.mjs 1.2.0    # all files say 1.2.0 (the release workflow passes the tag)
//
// Run it from the SDK root (sdks/ in the monorepo, the repo root in zellio-ai/zellio-chat-sdk).
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Each entry: a file and a pattern whose first group is the version in that file. */
const SOURCES = [
  ['ios/Sources/ZellioChatCore/Util.swift', /public static let version = "([^"]+)"/],
  ['android/zellio-chat/build.gradle.kts', /^version = "([^"]+)"/m],
  ['android/zellio-chat-fcm/build.gradle.kts', /^version = "([^"]+)"/m],
  ['react-native/package.json', /^ {2}"version": "([^"]+)"/m],
  ['react-native/src/version.ts', /export const VERSION = '([^']+)'/],
  ['react-native/android/build.gradle', /findProperty\("zellioChatAndroidVersion"\) \?: "([^"]+)"/],
  ['flutter/pubspec.yaml', /^version: (\S+)/m],
  ['flutter/lib/src/version.dart', /zellioChatPluginVersion = '([^']+)'/],
  ['flutter/ios/zellio_chat.podspec', /s\.version\s*=\s*'([^']+)'/],
  ['flutter/android/build.gradle.kts', /^version = "([^"]+)"/m],
  ['flutter/android/build.gradle.kts', /findProperty\("zellioChatAndroidVersion"\) \?: "([^"]+)"/],
];

const SEMVER = /^\d+\.\d+\.\d+$/;
const wanted = process.argv[2];
if (wanted !== undefined && !SEMVER.test(wanted)) {
  console.error(`check-release-version: "${wanted}" is not a plain version like 1.2.0`);
  process.exit(1);
}

const found = SOURCES.map(([file, pattern]) => {
  const match = pattern.exec(readFileSync(resolve(root, file), 'utf8'));
  return { file, version: match ? match[1] : null };
});

const missing = found.filter((f) => f.version === null);
const expected = wanted ?? found[0].version;
const wrong = found.filter((f) => f.version !== null && f.version !== expected);

for (const f of missing) console.error(`check-release-version: no version found in ${f.file}`);
for (const f of wrong) console.error(`check-release-version: ${f.file} says ${f.version}, expected ${expected}`);
if (missing.length > 0 || wrong.length > 0) process.exit(1);
console.log(`check-release-version: ${found.length} version strings say ${expected}`);
