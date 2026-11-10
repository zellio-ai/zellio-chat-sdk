#!/usr/bin/env node
// Copies the native iOS SDK sources (sdks/ios/Sources) into ios/vendor, so the CocoaPod of this package
// compiles them. No second pod and no CocoaPods trunk push are needed (trunk becomes read-only on 2026-12-02).
//
// The Swift package has two modules (ZellioChatCore and ZellioChat). One pod is one module, so this script
// removes `import ZellioChatCore` and puts both in the pod. It stops if that merge would clash.
//
//   node scripts/vendor-ios.mjs           copy
//   node scripts/vendor-ios.mjs --check   copy to a temp dir, run the clash checks, keep ios/vendor as it is
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourcesDir = resolve(root, '..', 'ios', 'Sources');
const targets = ['ZellioChatCore', 'ZellioChat'];
const checkOnly = process.argv.includes('--check');
const outDir = checkOnly ? mkdtempSync(join(tmpdir(), 'zellio-vendor-')) : join(root, 'ios', 'vendor');

function fail(message) {
  console.error(`vendor-ios: ${message}`);
  process.exit(1);
}

function walk(dir) {
  const files = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) files.push(...walk(full));
    else files.push(full);
  }
  return files;
}

if (!existsSync(sourcesDir)) fail(`${sourcesDir} not found. Run this inside the sdks/ monorepo folder.`);

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, 'swift'), { recursive: true });
mkdirSync(join(outDir, 'resources'), { recursive: true });

const swiftNames = new Map();
const typeNames = new Map();
// Top-level declarations only (no indent). Nested types, such as a private `State`, cannot clash.
const typePattern = /^(?:(?:public|internal|package|open|final|private|fileprivate|indirect)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/gm;
let swiftCount = 0;

for (const target of targets) {
  const targetDir = join(sourcesDir, target);
  if (!existsSync(targetDir)) fail(`${targetDir} not found.`);
  for (const file of walk(targetDir)) {
    const rel = relative(targetDir, file);
    if (file.endsWith('.swift')) {
      const name = basename(file);
      if (swiftNames.has(name)) fail(`two Swift files are called ${name} (${swiftNames.get(name)} and ${target}/${rel}). One pod cannot hold both.`);
      swiftNames.set(name, `${target}/${rel}`);
      const text = readFileSync(file, 'utf8');
      for (const match of text.matchAll(typePattern)) {
        const previous = typeNames.get(match[1]);
        if (previous && previous !== target) fail(`type ${match[1]} is declared in both ${previous} and ${target}. One pod cannot hold both.`);
        typeNames.set(match[1], target);
      }
      const merged = text.replace(/^[ \t]*import ZellioChatCore[ \t]*\r?\n/gm, '');
      const dest = join(outDir, 'swift', target, rel);
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, merged);
      swiftCount += 1;
    } else {
      const dest = join(outDir, 'resources', basename(file));
      cpSync(file, dest);
    }
  }
}

if (swiftCount === 0) fail('no Swift files found.');
if (!existsSync(join(outDir, 'resources', 'PrivacyInfo.xcprivacy'))) fail('PrivacyInfo.xcprivacy is missing from the iOS SDK.');
// The copy must be the file of the iOS SDK, byte for byte.
const privacySource = join(sourcesDir, 'ZellioChat', 'PrivacyInfo.xcprivacy');
if (!existsSync(privacySource) || !readFileSync(privacySource).equals(readFileSync(join(outDir, 'resources', 'PrivacyInfo.xcprivacy')))) {
  fail('PrivacyInfo.xcprivacy in the copy differs from sdks/ios/Sources/ZellioChat/PrivacyInfo.xcprivacy.');
}

console.log(`vendor-ios: ${swiftCount} Swift files and ${readdirSync(join(outDir, 'resources')).length} resource file(s) ${checkOnly ? 'checked' : `copied to ${relative(root, outDir)}`}`);
if (checkOnly) rmSync(outDir, { recursive: true, force: true });
