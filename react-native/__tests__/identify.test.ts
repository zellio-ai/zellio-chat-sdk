import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
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
  vi.useFakeTimers();
  api = await load();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('identify token flow', () => {
  it('registers once with native and listens once', () => {
    api.identify(async () => 'a');
    api.identify(async () => 'b');
    expect(fake.module.identify).toHaveBeenCalledTimes(2);
    expect(fake.module.onTokenRequest).toHaveBeenCalledTimes(1);
  });

  it('answers a request with the token from the provider', async () => {
    const provider = vi.fn(async () => 'jwt-value');
    api.identify(provider);
    fake.tokenRequest.emit({ requestId: 'r1' });
    await vi.advanceTimersByTimeAsync(0);
    expect(provider).toHaveBeenCalledTimes(1);
    expect(fake.module.resolveToken).toHaveBeenCalledWith('r1', 'jwt-value', null);
  });

  it('answers each request id separately', async () => {
    let n = 0;
    api.identify(async () => `t${++n}`);
    fake.tokenRequest.emit({ requestId: 'a' });
    fake.tokenRequest.emit({ requestId: 'b' });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.module.resolveToken.mock.calls).toEqual([
      ['a', 't1', null],
      ['b', 't2', null],
    ]);
  });

  it('a null or empty token answers no_token (customer is signed out)', async () => {
    const answers = [null, ''];
    api.identify(async () => answers.shift() ?? null);
    fake.tokenRequest.emit({ requestId: 'r1' });
    fake.tokenRequest.emit({ requestId: 'r2' });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.module.resolveToken.mock.calls).toEqual([
      ['r1', null, 'no_token'],
      ['r2', null, 'no_token'],
    ]);
  });

  it('a rejected provider answers provider_error and never forwards the error text', async () => {
    api.identify(async () => {
      throw new Error('secret-jwt-in-message');
    });
    fake.tokenRequest.emit({ requestId: 'r1' });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.module.resolveToken).toHaveBeenCalledWith('r1', null, 'provider_error');
    expect(JSON.stringify(fake.module.resolveToken.mock.calls)).not.toContain('secret-jwt');
  });

  it('a provider that throws before it returns a promise is handled too', async () => {
    api.identify(() => {
      throw new Error('sync');
    });
    fake.tokenRequest.emit({ requestId: 'r1' });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.module.resolveToken).toHaveBeenCalledWith('r1', null, 'provider_error');
  });

  it('times out after 15 seconds with a failure', async () => {
    api.identify(() => new Promise<string | null>(() => undefined));
    fake.tokenRequest.emit({ requestId: 'slow' });
    await vi.advanceTimersByTimeAsync(api.TOKEN_TIMEOUT_MS - 1);
    expect(fake.module.resolveToken).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(fake.module.resolveToken).toHaveBeenCalledTimes(1);
    expect(fake.module.resolveToken).toHaveBeenCalledWith('slow', null, 'timeout');
  });

  it('the timeout is 15000 ms', () => {
    expect(api.TOKEN_TIMEOUT_MS).toBe(15_000);
  });

  it('a fast token clears the timer and nothing fires later', async () => {
    api.identify(async () => 'ok');
    fake.tokenRequest.emit({ requestId: 'r1' });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(fake.module.resolveToken).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('after logout a late request is refused, not answered with the old provider', async () => {
    const provider = vi.fn(async () => 'old');
    api.identify(provider);
    api.logout();
    fake.tokenRequest.emit({ requestId: 'late' });
    await vi.advanceTimersByTimeAsync(0);
    expect(provider).not.toHaveBeenCalled();
    expect(fake.module.resolveToken).toHaveBeenCalledWith('late', null, 'no_provider');
  });

  it('never logs the token', async () => {
    const spies = [
      vi.spyOn(console, 'log').mockImplementation(() => undefined),
      vi.spyOn(console, 'warn').mockImplementation(() => undefined),
      vi.spyOn(console, 'error').mockImplementation(() => undefined),
      vi.spyOn(console, 'info').mockImplementation(() => undefined),
      vi.spyOn(console, 'debug').mockImplementation(() => undefined),
    ];
    api.identify(async () => 'super-secret-token');
    fake.tokenRequest.emit({ requestId: 'r1' });
    await vi.advanceTimersByTimeAsync(0);
    for (const spy of spies) {
      expect(spy).not.toHaveBeenCalled();
      spy.mockRestore();
    }
  });
});
