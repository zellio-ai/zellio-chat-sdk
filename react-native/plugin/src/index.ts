import {
  createRunOncePlugin,
  withEntitlementsPlist,
  withInfoPlist,
  withProjectBuildGradle,
  type ConfigPlugin,
} from 'expo/config-plugins';

export interface ZellioChatPluginProps {
  /** Text for NSCameraUsageDescription. `false` adds nothing. */
  cameraPermission?: string | false;
  /** Text for NSPhotoLibraryUsageDescription. `false` adds nothing. */
  photoLibraryPermission?: string | false;
  /**
   * Adds the `aps-environment` entitlement and the `remote-notification` background mode.
   * Default: false. Leave it off if another plugin (for example expo-notifications) already adds them.
   */
  enableIosPush?: boolean;
  /** Value of `aps-environment` when `enableIosPush` is true. Default: `development`. */
  apsEnvironment?: 'development' | 'production';
  /**
   * A Maven repository URL for `ai.zellio:zellio-chat`. Only needed while the SDK is not on Maven Central
   * (for example a private or local mirror). Default: none.
   */
  androidMavenRepository?: string;
}

export const DEFAULT_CAMERA_TEXT = 'Allow $(PRODUCT_NAME) to use the camera so you can send photos in chat.';
export const DEFAULT_PHOTO_TEXT = 'Allow $(PRODUCT_NAME) to access your photos so you can send them in chat.';

type PlistObject = Record<string, unknown>;

/** Adds the usage texts. A key that the app already sets is never replaced. */
export function applyInfoPlist(plist: PlistObject, props: ZellioChatPluginProps): PlistObject {
  const out: PlistObject = { ...plist };
  if (props.cameraPermission !== false && out.NSCameraUsageDescription === undefined) {
    out.NSCameraUsageDescription = props.cameraPermission ?? DEFAULT_CAMERA_TEXT;
  }
  if (props.photoLibraryPermission !== false && out.NSPhotoLibraryUsageDescription === undefined) {
    out.NSPhotoLibraryUsageDescription = props.photoLibraryPermission ?? DEFAULT_PHOTO_TEXT;
  }
  if (props.enableIosPush === true) {
    const modes = Array.isArray(out.UIBackgroundModes) ? [...(out.UIBackgroundModes as unknown[])] : [];
    if (!modes.includes('remote-notification')) modes.push('remote-notification');
    out.UIBackgroundModes = modes;
  }
  return out;
}

/** Push entitlement. Only when asked. */
export function applyEntitlements(entitlements: PlistObject, props: ZellioChatPluginProps): PlistObject {
  if (props.enableIosPush !== true) return entitlements;
  if (entitlements['aps-environment'] !== undefined) return entitlements;
  return { ...entitlements, 'aps-environment': props.apsEnvironment ?? 'development' };
}

const MARKER = '// @zellio/chat-react-native';

/** Adds a Maven repository to `allprojects.repositories`. Safe to run twice. */
export function applyMavenRepository(gradle: string, url: string): string {
  if (gradle.includes(MARKER)) return gradle;
  const pattern = /allprojects\s*\{\s*repositories\s*\{/;
  if (!pattern.test(gradle)) {
    throw new Error(
      '@zellio/chat-react-native: could not find allprojects { repositories { in android/build.gradle. ' +
        `Add maven { url '${url}' } by hand.`,
    );
  }
  const safe = url.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  return gradle.replace(pattern, (match) => `${match}\n        maven { url '${safe}' } ${MARKER}`);
}

const withZellioChat: ConfigPlugin<ZellioChatPluginProps | void> = (config, props) => {
  const options: ZellioChatPluginProps = props ?? {};
  config = withInfoPlist(config, (mod) => {
    mod.modResults = applyInfoPlist(mod.modResults, options) as typeof mod.modResults;
    return mod;
  });
  if (options.enableIosPush === true) {
    config = withEntitlementsPlist(config, (mod) => {
      mod.modResults = applyEntitlements(mod.modResults, options) as typeof mod.modResults;
      return mod;
    });
  }
  if (options.androidMavenRepository) {
    const url = options.androidMavenRepository;
    config = withProjectBuildGradle(config, (mod) => {
      if (mod.modResults.language !== 'groovy') {
        throw new Error('@zellio/chat-react-native: androidMavenRepository needs a Groovy android/build.gradle.');
      }
      mod.modResults.contents = applyMavenRepository(mod.modResults.contents, url);
      return mod;
    });
  }
  return config;
};

const pkg = require('../../package.json') as { name: string; version: string };

export default createRunOncePlugin(withZellioChat, pkg.name, pkg.version);
