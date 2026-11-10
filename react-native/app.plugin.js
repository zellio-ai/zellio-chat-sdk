// Expo loads this file for `plugins: ["@zellio/chat-react-native"]`. The TypeScript source is plugin/src;
// `npm run build` (and every `npm pack`) compiles it to plugin/build.
const built = require('./plugin/build');
module.exports = built.default ?? built;
