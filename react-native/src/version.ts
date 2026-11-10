/** Kept equal to package.json by `npm run check:version` (runs before every pack). */
export const VERSION = '1.0.0';

/** Sent to the native SDK as `wrapper`, so the x-zee-sdk-wrapper header names this package. */
export const WRAPPER = `react-native/${VERSION}`;
