import { vi } from 'vitest';

type Handler<T> = (value: T) => void;

/** An event emitter shaped like the codegen one: call it with a handler, get a subscription back. */
function makeEmitter<T>() {
  const handlers = new Set<Handler<T>>();
  const emitter = vi.fn((handler: Handler<T>) => {
    handlers.add(handler);
    return { remove: vi.fn(() => handlers.delete(handler)) };
  });
  return {
    emitter,
    emit(value: T) {
      for (const handler of [...handlers]) handler(value);
    },
    count: () => handlers.size,
  };
}

export function makeFakeNative() {
  const unread = makeEmitter<{ count: number }>();
  const event = makeEmitter<{ name: string; code?: string }>();
  const tokenRequest = makeEmitter<{ requestId: string }>();
  const module = {
    configure: vi.fn<(appKey: string, options: Record<string, unknown>) => void>(),
    identify: vi.fn<() => void>(),
    resolveToken: vi.fn<(requestId: string, token: string | null, errorCode: string | null) => void>(),
    logout: vi.fn<() => void>(),
    present: vi.fn<() => void>(),
    presentConversation: vi.fn<(id: string | null) => void>(),
    dismiss: vi.fn<() => void>(),
    setContext: vi.fn<(context: Record<string, unknown> | null) => void>(),
    getUnreadCount: vi.fn<() => Promise<number>>(async () => 0),
    setPushToken: vi.fn<(token: string, environment: string | null) => void>(),
    isZellioPush: vi.fn<(json: string) => boolean>(() => false),
    handlePush: vi.fn<(json: string) => Promise<boolean>>(async () => false),
    handleNotificationTap: vi.fn<(json: string) => Promise<boolean>>(async () => false),
    onUnread: unread.emitter,
    onEvent: event.emitter,
    onTokenRequest: tokenRequest.emitter,
  };
  return { module, unread, event, tokenRequest };
}

export type FakeNative = ReturnType<typeof makeFakeNative>;
