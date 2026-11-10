import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeFakeNative, type FakeNative } from './fakeNative';

let fake: FakeNative;

async function load() {
  vi.resetModules();
  fake = makeFakeNative();
  vi.doMock('../src/NativeZellioChat', () => ({ default: fake.module }));
  return import('../src/index');
}

type Api = Awaited<ReturnType<typeof load>>;
let api: Api;

beforeEach(async () => {
  api = await load();
});

describe('forwarding', () => {
  it('configure sends the key, flat options and the wrapper header value', () => {
    api.configure({
      appKey: 'zk_test',
      baseUrl: 'https://example.test',
      locale: 'ar',
      theme: { mode: 'dark', primaryColor: '#112233' },
      logLevel: 'info',
      showsInAppBanner: false,
      bannerShowsPreview: false,
    });
    expect(fake.module.configure).toHaveBeenCalledTimes(1);
    expect(fake.module.configure).toHaveBeenCalledWith('zk_test', {
      baseUrl: 'https://example.test',
      locale: 'ar',
      logLevel: 'info',
      showsInAppBanner: false,
      bannerShowsPreview: false,
      themeMode: 'dark',
      primaryColor: '#112233',
      wrapper: 'react-native/1.0.0',
    });
  });

  it('configure leaves out options that were not set', () => {
    api.configure({ appKey: 'zk_test' });
    expect(fake.module.configure).toHaveBeenCalledWith('zk_test', { wrapper: 'react-native/1.0.0' });
  });

  it('forwards the simple calls', () => {
    api.present();
    api.presentConversation('c1');
    api.presentConversation();
    api.dismiss();
    api.logout();
    api.setPushToken('abc', 'sandbox');
    api.setPushToken('def');
    expect(fake.module.present).toHaveBeenCalledTimes(1);
    expect(fake.module.presentConversation.mock.calls).toEqual([['c1'], [null]]);
    expect(fake.module.dismiss).toHaveBeenCalledTimes(1);
    expect(fake.module.logout).toHaveBeenCalledTimes(1);
    expect(fake.module.setPushToken.mock.calls).toEqual([
      ['abc', 'sandbox'],
      ['def', null],
    ]);
  });

  it('setContext passes the set fields and null clears', () => {
    api.setContext({ screen: 'Product', itemId: '42', itemTitle: undefined });
    api.setContext(null);
    expect(fake.module.setContext.mock.calls).toEqual([[{ screen: 'Product', itemId: '42' }], [null]]);
  });

  it('getUnreadCount returns the native value and 0 when native fails', async () => {
    fake.module.getUnreadCount.mockResolvedValueOnce(3);
    expect(await api.getUnreadCount()).toBe(3);
    fake.module.getUnreadCount.mockRejectedValueOnce(new Error('boom'));
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    expect(await api.getUnreadCount()).toBe(0);
    warn.mockRestore();
  });

  it('a native throw never reaches the app', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    fake.module.present.mockImplementationOnce(() => {
      throw new Error('native crash');
    });
    expect(() => api.present()).not.toThrow();
    expect(warn).toHaveBeenCalledWith('[ZellioChat] present failed (Error)');
    warn.mockRestore();
  });
});

describe('push', () => {
  it('sends the payload as JSON and returns the native answer', async () => {
    const payload = { zellio: '{"v":1,"type":"message","conversationId":"c9"}', other: 'x' };
    fake.module.isZellioPush.mockReturnValueOnce(true);
    fake.module.handlePush.mockResolvedValueOnce(true);
    fake.module.handleNotificationTap.mockResolvedValueOnce(true);
    expect(api.isZellioPush(payload)).toBe(true);
    expect(await api.handlePush(payload)).toBe(true);
    expect(await api.handleNotificationTap(payload)).toBe(true);
    const json = JSON.stringify(payload);
    expect(fake.module.isZellioPush).toHaveBeenCalledWith(json);
    expect(fake.module.handlePush).toHaveBeenCalledWith(json);
    expect(fake.module.handleNotificationTap).toHaveBeenCalledWith(json);
  });

  it('returns false for null and for payloads that cannot be serialized', async () => {
    const circular: Record<string, unknown> = {};
    circular.self = circular;
    expect(api.isZellioPush(null)).toBe(false);
    expect(api.isZellioPush(circular)).toBe(false);
    expect(await api.handlePush(undefined)).toBe(false);
    expect(await api.handleNotificationTap(circular)).toBe(false);
    expect(fake.module.isZellioPush).not.toHaveBeenCalled();
    expect(fake.module.handlePush).not.toHaveBeenCalled();
  });
});

describe('listeners', () => {
  it('unread listener gets the current value, then changes, and stops after remove', async () => {
    fake.module.getUnreadCount.mockResolvedValueOnce(2);
    const seen: number[] = [];
    const subscription = api.addUnreadListener((count) => seen.push(count));
    await Promise.resolve();
    await Promise.resolve();
    fake.unread.emit({ count: 5 });
    expect(seen).toEqual([2, 5]);
    subscription.remove();
    expect(fake.unread.count()).toBe(0);
    fake.unread.emit({ count: 9 });
    expect(seen).not.toContain(9);
    subscription.remove();
  });

  it('a late current-value answer is dropped after remove', async () => {
    let resolve: (value: number) => void = () => undefined;
    fake.module.getUnreadCount.mockReturnValueOnce(new Promise<number>((r) => (resolve = r)));
    const seen: number[] = [];
    const subscription = api.addUnreadListener((count) => seen.push(count));
    subscription.remove();
    resolve(4);
    await Promise.resolve();
    await Promise.resolve();
    expect(seen).toEqual([]);
  });

  it('maps native events to the typed union and drops unknown names', () => {
    const seen: unknown[] = [];
    const subscription = api.addEventListener((event) => seen.push(event));
    fake.event.emit({ name: 'chatOpened' });
    fake.event.emit({ name: 'messageSent' });
    fake.event.emit({ name: 'error', code: 'network' });
    fake.event.emit({ name: 'error' });
    fake.event.emit({ name: 'somethingNew' });
    expect(seen).toEqual([
      { type: 'chatOpened' },
      { type: 'messageSent' },
      { type: 'error', code: 'network' },
      { type: 'error', code: 'unknown' },
    ]);
    subscription.remove();
    expect(fake.event.count()).toBe(0);
    fake.event.emit({ name: 'chatClosed' });
    expect(seen).toHaveLength(4);
  });
});
