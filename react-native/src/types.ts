export type ZellioLocale = 'auto' | 'ar' | 'en';
export type ZellioThemeMode = 'auto' | 'light' | 'dark';
export type ZellioLogLevel = 'none' | 'error' | 'warn' | 'info' | 'debug';

/** Colors are `#RRGGBB`. A color that would make text hard to read is adjusted by the native SDK. */
export interface ZellioTheme {
  mode?: ZellioThemeMode;
  primaryColor?: string;
  customerMessageColor?: string;
  surfaceColor?: string;
}

export interface ZellioChatConfig {
  /** The app key from Zellio Studio. */
  appKey: string;
  /** Default: https://app.zellio.ai */
  baseUrl?: string;
  /** Default: `auto` (the Studio language policy, then the device language). */
  locale?: ZellioLocale;
  theme?: ZellioTheme;
  /** Default: `error` on iOS and `warn` on Android. Chat text and tokens are never logged. */
  logLevel?: ZellioLogLevel;
  /** The small banner for a new message while chat is closed. Default: true. */
  showsInAppBanner?: boolean;
  /** false: the banner says "New message" and never shows the text. Default: true. */
  bannerShowsPreview?: boolean;
}

/** What the customer is looking at. Agents see it. `url` must be https. */
export interface ZellioContext {
  screen?: string;
  itemType?: string;
  itemId?: string;
  itemTitle?: string;
  url?: string;
}

/** Events for your own analytics. They never carry message text. */
export type ZellioChatEvent =
  | { type: 'chatOpened' }
  | { type: 'chatClosed' }
  | { type: 'messageSent' }
  | { type: 'messageReceived' }
  | { type: 'error'; code: string };

/** Returns the identity JWT from your server, or null when nobody is signed in. */
export type ZellioTokenProvider = () => Promise<string | null>;

export interface ZellioSubscription {
  remove(): void;
}

export type ZellioPushEnvironment = 'sandbox' | 'production';

/** The data of a push message, as your push library gives it to you. */
export type ZellioPushPayload = Record<string, unknown>;
