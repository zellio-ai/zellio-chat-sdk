const path = require('node:path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// The sample uses the package one folder up (npm "file:.."). Metro must watch it, and must not load a
// second copy of react or react-native from the package's own node_modules.
const packageRoot = path.resolve(__dirname, '..');
const packageModules = path.join(packageRoot, 'node_modules');
const escapeRegExp = (text) => text.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');

/** @type {import('@react-native/metro-config').MetroConfig} */
const config = {
  watchFolders: [packageRoot],
  resolver: {
    blockList: [new RegExp(`^${escapeRegExp(packageModules)}[\\\\/].*`)],
    // Files of the package one folder up resolve react, react-native and @babel/runtime from the sample.
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
