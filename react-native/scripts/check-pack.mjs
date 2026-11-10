#!/usr/bin/env node
// Checks the file list that `npm pack --dry-run --json` prints.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const report = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const files = report[0].files.map((f) => f.path.split(String.fromCharCode(92)).join('/'));
const failures = [];

const required = [
  'package.json',
  'README.md',
  'app.plugin.js',
  'ZellioChatReactNative.podspec',
  'lib/index.js',
  'lib/index.d.ts',
  'src/NativeZellioChat.ts',
  'plugin/build/index.js',
  'android/build.gradle',
  'android/src/main/AndroidManifest.xml',
  'android/src/main/java/ai/zellio/chat/reactnative/ZellioChatModule.kt',
  'android/src/main/java/ai/zellio/chat/reactnative/ZellioChatPackage.kt',
  'ios/RNZellioChat.h',
  'ios/RNZellioChat.mm',
  'ios/ZCRNBridge.swift',
  'ios/vendor/resources/PrivacyInfo.xcprivacy',
];
for (const path of required) if (!files.includes(path)) failures.push(`missing from the tarball: ${path}`);

for (const target of ['ZellioChatCore', 'ZellioChat']) {
  if (!files.some((f) => f.startsWith(`ios/vendor/swift/${target}/`) && f.endsWith('.swift'))) {
    failures.push(`no vendored Swift files for ${target}`);
  }
}

const forbidden = [/^node_modules\//, /^sample\//, /(^|\/)__tests__\//, /\.tgz$/, /^android\/build\//, /^android\/\.gradle\//, /(^|\/)\.env/, /zellio\.config\.json$/];
for (const pattern of forbidden) {
  for (const f of files.filter((name) => pattern.test(name))) failures.push(`must not ship: ${f}`);
}

// Every vendored Swift file has lost its import of the other module.
function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}
for (const file of walk(join(root, 'ios', 'vendor', 'swift'))) {
  if (/^\s*import ZellioChatCore\s*$/m.test(readFileSync(file, 'utf8'))) failures.push(`still imports ZellioChatCore: ${file}`);
}

if (failures.length > 0) {
  console.error(`check-pack FAILED:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`check-pack: ${files.length} files, all required files present`);
