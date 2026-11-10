import type { CodegenTypes, TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * Codegen spec. Do not import this file from app code: use the typed API in `index.ts`.
 * Options travel as plain objects so the generated native code stays small; `index.ts` types them.
 */
export interface Spec extends TurboModule {
  configure(appKey: string, options: CodegenTypes.UnsafeObject): void;
  /** Registers the token provider on the native side. Native then asks JS through `onTokenRequest`. */
  identify(): void;
  /** Answers one `onTokenRequest`. Exactly one of `token` and `errorCode` is set. */
  resolveToken(requestId: string, token: string | null, errorCode: string | null): void;
  logout(): void;
  present(): void;
  presentConversation(conversationId: string | null): void;
  dismiss(): void;
  setContext(context: CodegenTypes.UnsafeObject | null): void;
  getUnreadCount(): Promise<number>;
  setPushToken(token: string, environment: string | null): void;
  isZellioPush(payloadJson: string): boolean;
  handlePush(payloadJson: string): Promise<boolean>;
  handleNotificationTap(payloadJson: string): Promise<boolean>;

  readonly onUnread: CodegenTypes.EventEmitter<{ count: number }>;
  readonly onEvent: CodegenTypes.EventEmitter<{ name: string; code?: string }>;
  readonly onTokenRequest: CodegenTypes.EventEmitter<{ requestId: string }>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RNZellioChat');
