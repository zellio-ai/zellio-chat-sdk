#!/usr/bin/env node
// package.json and src/version.ts must agree (the wrapper header sends it). Runs before every pack.
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
const ts = readFileSync(resolve(root, 'src', 'version.ts'), 'utf8');
const match = /export const VERSION = '([^']+)'/.exec(ts);
if (!match) {
  console.error('check-version: VERSION not found in src/version.ts');
  process.exit(1);
}
if (match[1] !== pkg.version) {
  console.error(`check-version: src/version.ts says ${match[1]} but package.json says ${pkg.version}`);
  process.exit(1);
}
console.log(`check-version: ${pkg.version}`);
