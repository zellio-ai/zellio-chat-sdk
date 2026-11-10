import NativeZellioChat from './NativeZellioChat';
import type {
  ZellioChatConfig,
  ZellioChatEvent,
  ZellioContext,
  ZellioPushEnvironment,
  ZellioPushPayload,
  ZellioSubscription,
  ZellioTokenProvider,
} from './types';
import { WRAPPER } from './version';

export type * from './types';
export { VERSION } from './version';

/** Native asks for a token at most this long before it gives up. */
export const TOKEN_TIMEOUT_MS = 15_000;

let tokenProvider: ZellioTokenProvider | null = null;
let tokenSubscription: ZellioSubscription | null = null;

function reportMisuse(call: string, error: unknown): void {
  // Only the call name and the error kind. Never the arguments: they can hold a token.
  const kind = error instanceof Error ? error.name : 'unknown';
  console.warn(`[ZellioChat] ${call} failed (${kind})`);
}

function guard(call: string, run: () => void): void {
  try {
    run();
  } catch (error) {
    reportMisuse(call, error);
  }
}

/** Call once at app start. Cheap: no network on the calling thread, no UI. */
export function configure(config: ZellioChatConfig): void {
  guard('configure', () => {
    const { appKey, theme, ...rest } = config;
    NativeZellioChat.configure(
      appKey,
      withoutUndefined({
        ...rest,
        themeMode: theme?.mode,
        primaryColor: theme?.primaryColor,
        customerMessageColor: theme?.customerMessageColor,
        surfaceColor: theme?.surfaceColor,
        wrapper: WRAPPER,
      }),
    );
  });
}

/** The bridge turns `undefined` into null. Native code reads "missing" more simply than "null". */
function withoutUndefined(values: Record<string, string | boolean | undefined>): Record<string, string | boolean> {
  const out: Record<string, string | boolean> = {};
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

async function answerTokenRequest(requestId: string): Promise<void> {
  const provider = tokenProvider;
  if (provider === null) {
    NativeZellioChat.resolveToken(requestId, null, 'no_provider');
    return;
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const token = await Promise.race([
      provider(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('timeout')), TOKEN_TIMEOUT_MS);
      }),
    ]);
    if (typeof token === 'string' && token.length > 0) {
      NativeZellioChat.resolveToken(requestId, token, null);
    } else {
      NativeZellioChat.resolveToken(requestId, null, 'no_token');
    }
  } catch (error) {
    const timedOut = error instanceof Error && error.message === 'timeout';
    NativeZellioChat.resolveToken(requestId, null, timedOut ? 'timeout' : 'provider_error');
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * Marks a signed-in customer. `tokenProvider` returns a JWT from your server. The SDK calls it when it needs a
 * session and again if the server rejects the token. The token is never logged. Calling `identify` again
 * replaces the provider.
 */
export function identify(provider: ZellioTokenProvider): void {
  guard('identify', () => {
    tokenProvider = provider;
    if (tokenSubscription === null) {
      tokenSubscription = NativeZellioChat.onTokenRequest((request) => {
        void answerTokenRequest(request.requestId);
      });
    }
    NativeZellioChat.identify();
  });
}

/** Ends the session, deletes all local chat data and removes the push token from the server. */
export function logout(): void {
  guard('logout', () => {
    tokenProvider = null;
    NativeZellioChat.logout();
  });
}

/** Shows chat on top of the app. */
export function present(): void {
  guard('present', () => NativeZellioChat.present());
}

/** Opens one conversation, or a new one when `conversationId` is omitted. */
export function presentConversation(conversationId?: string | null): void {
  guard('presentConversation', () => NativeZellioChat.presentConversation(conversationId ?? null));
}

/** Closes chat. */
export function dismiss(): void {
  guard('dismiss', () => NativeZellioChat.dismiss());
}

/** Tells agents what the customer looks at. It is sent with the next messages. `null` clears it. */
export function setContext(context: ZellioContext | null): void {
  guard('setContext', () => {
    NativeZellioChat.setContext(context === null ? null : withoutUndefined({ ...context }));
  });
}

/** The number of unread agent messages, across all conversations. Resolves 0 if the SDK is not ready. */
export async function getUnreadCount(): Promise<number> {
  try {
    return await NativeZellioChat.getUnreadCount();
  } catch (error) {
    reportMisuse('getUnreadCount', error);
    return 0;
  }
}

/** Calls back now with the current count and on every change. Call `remove()` to stop. */
export function addUnreadListener(callback: (count: number) => void): ZellioSubscription {
  let active = true;
  const native = NativeZellioChat.onUnread((event) => {
    if (active) callback(event.count);
  });
  void getUnreadCount().then((count) => {
    if (active) callback(count);
  });
  return {
    remove() {
      if (!active) return;
      active = false;
      native.remove();
    },
  };
}

/** Chat events for your own analytics. Call `remove()` to stop. */
export function addEventListener(callback: (event: ZellioChatEvent) => void): ZellioSubscription {
  const native = NativeZellioChat.onEvent((event) => {
    switch (event.name) {
      case 'chatOpened':
      case 'chatClosed':
      case 'messageSent':
      case 'messageReceived':
        callback({ type: event.name });
        break;
      case 'error':
        callback({ type: 'error', code: event.code ?? 'unknown' });
        break;
      default:
        break;
    }
  });
  return {
    remove() {
      native.remove();
    },
  };
}

/** Gives the SDK the push token: the APNs token as a hex string on iOS, the FCM token on Android. */
export function setPushToken(token: string, environment?: ZellioPushEnvironment): void {
  guard('setPushToken', () => NativeZellioChat.setPushToken(token, environment ?? null));
}

function toJson(payload: ZellioPushPayload | null | undefined): string | null {
  if (payload === null || payload === undefined) return null;
  try {
    return JSON.stringify(payload);
  } catch {
    return null;
  }
}

/** True only if the payload has the `zellio` key. */
export function isZellioPush(payload: ZellioPushPayload | null | undefined): boolean {
  const json = toJson(payload);
  if (json === null) return false;
  try {
    return NativeZellioChat.isZellioPush(json);
  } catch (error) {
    reportMisuse('isZellioPush', error);
    return false;
  }
}

/** Refreshes the unread state. Resolves true if the push was ours. */
export async function handlePush(payload: ZellioPushPayload | null | undefined): Promise<boolean> {
  const json = toJson(payload);
  if (json === null) return false;
  try {
    return await NativeZellioChat.handlePush(json);
  } catch (error) {
    reportMisuse('handlePush', error);
    return false;
  }
}

/** Opens the conversation that the push names. Resolves true if the push was ours. */
export async function handleNotificationTap(payload: ZellioPushPayload | null | undefined): Promise<boolean> {
  const json = toJson(payload);
  if (json === null) return false;
  try {
    return await NativeZellioChat.handleNotificationTap(json);
  } catch (error) {
    reportMisuse('handleNotificationTap', error);
    return false;
  }
}
