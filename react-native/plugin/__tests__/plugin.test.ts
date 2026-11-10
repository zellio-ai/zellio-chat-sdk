import { compileModsAsync, type ExportedConfig } from 'expo/config-plugins';
import { describe, expect, it } from 'vitest';
import withZellioChat, {
  DEFAULT_CAMERA_TEXT,
  DEFAULT_PHOTO_TEXT,
  applyEntitlements,
  applyInfoPlist,
  applyMavenRepository,
  type ZellioChatPluginProps,
} from '../src/index';

async function runIos(props: ZellioChatPluginProps | undefined) {
  const base: ExportedConfig = { name: 'Shop', slug: 'shop', ios: { bundleIdentifier: 'com.example.shop' } };
  const configured = props === undefined ? withZellioChat(base) : withZellioChat(base, props);
  const result = await compileModsAsync(configured, { projectRoot: process.cwd(), platforms: ['ios'], introspect: true });
  return result.ios as { infoPlist?: Record<string, unknown>; entitlements?: Record<string, unknown> };
}

describe('Info.plist', () => {
  it('adds English defaults for camera and photos', () => {
    const out = applyInfoPlist({}, {});
    expect(out.NSCameraUsageDescription).toBe(DEFAULT_CAMERA_TEXT);
    expect(out.NSPhotoLibraryUsageDescription).toBe(DEFAULT_PHOTO_TEXT);
  });

  it('uses the texts from the options', () => {
    const out = applyInfoPlist({}, { cameraPermission: 'Camera please', photoLibraryPermission: 'Photos please' });
    expect(out.NSCameraUsageDescription).toBe('Camera please');
    expect(out.NSPhotoLibraryUsageDescription).toBe('Photos please');
  });

  it('keeps a text the app already set', () => {
    const out = applyInfoPlist({ NSCameraUsageDescription: 'Mine' }, { cameraPermission: 'Other' });
    expect(out.NSCameraUsageDescription).toBe('Mine');
  });

  it('adds nothing for a permission set to false', () => {
    const out = applyInfoPlist({}, { cameraPermission: false, photoLibraryPermission: false });
    expect(out).toEqual({});
  });

  it('does not touch background modes unless push is on', () => {
    expect(applyInfoPlist({ UIBackgroundModes: ['audio'] }, {}).UIBackgroundModes).toEqual(['audio']);
    expect(applyInfoPlist({}, {}).UIBackgroundModes).toBeUndefined();
  });

  it('adds remote-notification once when push is on', () => {
    const once = applyInfoPlist({ UIBackgroundModes: ['audio'] }, { enableIosPush: true });
    expect(once.UIBackgroundModes).toEqual(['audio', 'remote-notification']);
    expect(applyInfoPlist(once, { enableIosPush: true }).UIBackgroundModes).toEqual(['audio', 'remote-notification']);
  });
});

describe('entitlements', () => {
  it('adds no push entitlement by default', () => {
    expect(applyEntitlements({}, {})).toEqual({});
  });

  it('adds aps-environment when asked, development by default', () => {
    expect(applyEntitlements({}, { enableIosPush: true })).toEqual({ 'aps-environment': 'development' });
    expect(applyEntitlements({}, { enableIosPush: true, apsEnvironment: 'production' })).toEqual({
      'aps-environment': 'production',
    });
  });

  it('keeps an entitlement that is already there', () => {
    const existing = { 'aps-environment': 'production' };
    expect(applyEntitlements(existing, { enableIosPush: true, apsEnvironment: 'development' })).toEqual(existing);
  });
});

describe('Maven repository', () => {
  const gradle = ['buildscript { }', 'allprojects {', '    repositories {', '        google()', '    }', '}'].join('\n');

  it('inserts the repository once', () => {
    const once = applyMavenRepository(gradle, 'https://maven.example.test/repo');
    expect(once).toContain("maven { url 'https://maven.example.test/repo' }");
    expect(applyMavenRepository(once, 'https://maven.example.test/repo')).toBe(once);
    expect(once.match(/maven \{/g)).toHaveLength(1);
  });

  it('escapes quotes in the URL', () => {
    expect(applyMavenRepository(gradle, "https://x.test/a'b")).toContain("https://x.test/a\\'b");
  });

  it('fails loudly when the file has no allprojects block', () => {
    expect(() => applyMavenRepository('buildscript { }', 'https://x.test')).toThrow(/allprojects/);
  });
});

describe('the plugin on an iOS project', () => {
  it('writes the usage texts and no push entitlement with no options', async () => {
    const ios = await runIos(undefined);
    expect(ios.infoPlist?.NSCameraUsageDescription).toBe(DEFAULT_CAMERA_TEXT);
    expect(ios.infoPlist?.NSPhotoLibraryUsageDescription).toBe(DEFAULT_PHOTO_TEXT);
    expect(ios.infoPlist?.UIBackgroundModes).toBeUndefined();
    expect(ios.entitlements?.['aps-environment']).toBeUndefined();
  });

  it('writes the push entitlement and background mode only when asked', async () => {
    const ios = await runIos({ enableIosPush: true, apsEnvironment: 'production' });
    expect(ios.entitlements?.['aps-environment']).toBe('production');
    expect(ios.infoPlist?.UIBackgroundModes).toEqual(['remote-notification']);
  });

  it('running it twice gives the same result (run-once)', async () => {
    const base: ExportedConfig = { name: 'Shop', slug: 'shop', ios: { bundleIdentifier: 'com.example.shop' } };
    const twice = withZellioChat(withZellioChat(base, { enableIosPush: true }), { enableIosPush: true });
    const result = await compileModsAsync(twice, { projectRoot: process.cwd(), platforms: ['ios'], introspect: true });
    const ios = result.ios as { infoPlist?: Record<string, unknown> };
    expect(ios.infoPlist?.UIBackgroundModes).toEqual(['remote-notification']);
  });
});
