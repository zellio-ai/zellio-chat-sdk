# ZeeChat Mobile SDKs: shared product spec

All 4 packages follow this file. The server contract is `contract/v1/README.md`. The strings
are in `design/strings.json`. The screens are in the approved design canvas.

## Layout of this folder

```
sdks/
  contract/v1/     API contract and JSON fixtures. Each SDK runs its readers against these.
  design/          strings.json (English + Egyptian Arabic)
  ios/             Swift package: ZellioChatCore (Foundation only), ZellioChat (SwiftUI)
  android/         Gradle project: :zellio-chat (Kotlin, Compose), :sample
  react-native/    Native module over the iOS and Android SDKs, Expo config plugin, sample
  flutter/         Plugin over the iOS and Android SDKs, sample
  docs/            Setup docs (English and Arabic)
```

In the Zellio monorepo, `sdks/` is outside the pnpm workspace. Do not add it to `pnpm-workspace.yaml`. Do not touch the root
lockfile.

## Public API

Same names and same meaning on every platform. Only the language idiom changes.

| Call | Meaning |
|---|---|
| `configure(appKey, options?)` | Call once at app start. Cheap: no network on the calling thread, no UI. `options`: `baseUrl` (default production), `locale` (`ar`, `en` or follow the device), `theme` overrides, `logLevel`. |
| `identify(tokenProvider)` | Marks a logged-in customer. `tokenProvider` is async and returns a JWT from the brand's server. The SDK calls it when it needs a session. |
| `logout()` | Ends the session, deletes all local chat data and removes the push token. |
| `present()` | Shows chat on top of the app, starting on the home screen or the thread that `layout` asks for. |
| `presentConversation(id?)` | Opens one conversation, or a new one if `id` is null. |
| `dismiss()` | Closes chat. |
| `setContext(context?)` | Sets `screen`, `itemType`, `itemId`, `itemTitle`, `url`. Sent with the next messages. Null clears it. |
| `unreadCount` | Observable integer: unread agent messages across all conversations. Plus a listener form for wrappers. |
| `setPushToken(token, environment?)` | Gives the SDK the APNs or FCM token. |
| `isZellioPush(payload)` | True only if the payload has the `zellio` key. |
| `handlePush(payload)` | Refreshes unread state. Returns true if the push was ours. |
| `handleNotificationTap(payload)` | Opens the conversation that the push names. Returns true if the push was ours. |
| `events` | Listener for `chatOpened`, `chatClosed`, `messageSent`, `messageReceived`, `error(code)`. No message text in these events. `code` is one of `unavailable`, `login_needed`, `rate_limited`, `file_too_large`, `file_type_denied`, `files_disabled`, `conversation_not_found`, `consent_required`, `network`, `server`, `decoding`, `cancelled`, `send_failed`, on every platform. Ignore a code you do not know. |

Also provide a host-embedded view for apps that want chat inside their own navigation:
`ZellioChatView` (SwiftUI and a UIKit controller), `ZellioChatScreen` (Compose and an Activity).

The SDK does not take over the app's notification code. The brand's app stays the owner of
`AppDelegate` or `FirebaseMessagingService`, and forwards to the SDK. Only one
`FirebaseMessagingService` can run in an app, so a brand with its own must be able to forward.
Also ship a ready `ZellioMessagingService` for a brand with no other push code.

## Reliability rules

- **An SDK fault must never crash the host app.** No force unwraps. No uncaught exception leaves an
  SDK callback, coroutine or task. Bad data shows an error state. Bad JSON is skipped item by item.
- All public calls are safe from any thread and safe before `configure` (they log and do nothing).
- A public call never blocks the calling thread.
- Session token: iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), Android
  Keystore-backed AES-GCM. Never in logs, never in analytics, never in backups.
- Chat text is never logged at any level.
- Local data: last config, conversation list and the last 200 messages of each conversation, in the
  app's private storage and excluded from backups. Logout deletes all of it.
- A switch of customer (a new `identify` with a different `sub`) follows the logout path first.

## Messages and networking

- Offline queue: a message gets its `clientMessageId` when the customer taps send. It is saved locally
  before the first try. It retries with backoff when the network returns, in order, across app restarts.
  The server dedupes on the id, so a retry is always safe. After 24 hours or a 4xx that is not 401 or 429,
  it shows as failed with "Try again".
- Merge rule: a server message with the same `clientMessageId` replaces the local one, in place, without a
  scroll jump or a flash.
- SSE: as in the contract. On return to the foreground: read `/unread`, read with `after`, reopen the stream.
- Timeouts: connect 10 s, read 30 s, upload 120 s. No SSE read timeout, but treat 45 s with no bytes as dead.
- Images: load lazily, cache in memory and on disk with a size limit. Attachment URLs can expire, so a 403 reloads
  the message page once.
- Links: only open `https` and `mailto`/`tel` with a system prompt. Never render HTML.

## Look and feel

The brand drives color. Zellio is not visible apart from the attribution line.

Tokens from the snapshot's `appearance`:
- `primary` = `primaryColor`, `customer` = `customerMessageColor`, `surfaceLight` = `surfaceColor`.
- Ink on `primary` and `customer`: black or white, whichever has the higher contrast, at least 4.5:1. Port the
  logic from `packages/zeechat-ui/src/color-contrast.ts`.
- `theme`: `auto` follows the system, `light` and `dark` force it. A code override wins.
- `corners: square` sets bubble radius 8 and tail radius 4. `density: compact` makes the message gap 2 pt
  (grouped) and 8 pt (new sender).
- `headerStyle`: `gradient` (160 degrees, primary to primary darkened 18 percent), `solid` or `light`.
- `showAgentAvatar`, `showAttribution`: as named.
- Link color: `primary` if it has at least 4.5:1 on `bg`, else `ink`.
- A photo with or without a caption fills the bubble edge to edge. The bubble clips it.

Neutral colors:

| Token | Light | Dark |
|---|---|---|
| `bg` | `surfaceColor` | `#0F1525` |
| `bgAlt` | ink 4 percent over bg | `#161D30` |
| `ink` | `#111426` | `#F4F6FC` |
| `ink2` | `#50556B` | `#AEB6CC` |
| `line` | `#E7E7EF` | `#222B42` |
| `agentBubble` | `#F1F1F6` | `#1E2740` |
| `ok` | `#16A34A` | `#34D399` |
| `bad` | `#D92D32` | `#F87171` |

If `surfaceColor` is dark in light mode, pick `ink` by contrast.

Type: the platform's system font (SF Pro and SF Arabic, Roboto and Noto Sans Arabic), or the brand's font from
`theme` overrides. Sizes follow Dynamic Type and Android font scale, with no cap on message text.

| Role | Size | Weight |
|---|---|---|
| Home heading | 28 | Bold |
| Screen title | 17 | Semibold |
| Message | 16 | Regular |
| Section title | 15 | Semibold |
| Secondary | 13 | Regular |
| Time, delivery | 12 | Regular |

Arabic line height is 1.45 times the size. English is 1.35. No letter spacing on Arabic.

Spacing grid is 4 pt. Radii: bubble 20, tail 6, card 16, control 12, image 14. Touch targets are at least 44 pt
on iOS and 48 dp on Android.

### Screens

**Home** (when `layout` is `support` or `faq-first`). Header in the header style, running under the status bar:
logo at 40 pt with radius 12 (or a monogram of the first letter), close button at the end, then `screens.heading` and
`screens.description`, then an availability line with a dot. Body scrolls over the header's lower edge by 20 pt, with
cards at radius 16. Modules in snapshot order. Supported: `greeting`, `announcement`, `start-conversation` (primary is a
filled button in `primary`), `external-link`, `contact-links`. Skip all others, and skip modules hidden by `locales`,
`availability` or `customer` visibility. Below the modules: "Recent conversations", at most 3 rows, then "See all". Attribution
at the bottom.

**Conversation list.** Large title on iOS, top bar on Android. A row has an avatar, agent or brand name, last message in 1 line
(a paperclip and "Photo" or "File" if there is no text), relative time, and an unread dot. A floating "New conversation"
button. Empty state: a short line and the same button.

**Thread** (the only screen when `layout` is `chat-only`). Compact bar: back, brand logo at 32 pt, brand or agent name, availability
under the name. The list is newest at the bottom and loads older messages on scroll, with a small spinner at the top. Date separators
are centered ("Today", "Yesterday", then a date). Messages from one sender within 5 minutes form a group with 2 pt gaps. Only
the last of the group has the tail and the avatar. The name shows above the first agent message of a group.

Visitor bubbles sit at the end side in `customer`. Agent bubbles sit at the start side in `agentBubble`. Max bubble width is 78
percent, or 520 pt on iPad. Mixed Arabic and English text uses the natural direction of each paragraph. Long URLs wrap. Links are
underlined and tappable. Long press copies text.

Delivery line under the newest visitor message only: "Sending…", "Sent". A failed message always shows "Not sent" in `bad`, with a
"Try again" button. Queued offline messages show a clock icon.

Attachments: images in a rounded frame, width 240 pt max, keeping the ratio, with a soft placeholder at the real size while they load so
the list does not jump. Tap opens the full viewer with pinch zoom and swipe down to close. Files are a row with an icon, name, size. Upload
shows a ring over the image, and tap cancels.

Typing: a bubble with 3 dots, a slow wave. With reduced motion, the dots are static. New message while scrolled up: a pill "New message" that
scrolls down. The chat stays at the bottom when the keyboard opens. iOS keyboard dismisses interactively by drag.

Composer: a pill field that grows to 6 lines, then scrolls. Attach button (if allowed) at the start side, send button at the end side as a 36 pt
circle in `primary` with a 44 pt touch area. Send is disabled when empty. Send icon mirrors in RTL. Attach opens a system sheet: Camera, Photo library, File. Use
the system photo picker, so no photo permission is needed. Camera asks for permission only when tapped. A denied camera shows a line with a Settings button. Drafts are saved by
conversation.

Banners, in a thin bar under the top bar: reconnecting (after 3 s offline), outside support hours (`screens.offline`, or the strings fallback), login needed, chat not available.

**Consent** (when `behavior.consentRequired`). Before the first session is made, a bottom card shows `consentText` (or the default string), a privacy link, Accept and Not now. Accept is saved per
install, with the text and the privacy link that the customer accepted. A new publish asks again only when one of those changed. Logout forgets it, because another person can use the phone. No session, no history, no stream before Accept.

**Offline first open** with no saved config: a calm skeleton, then the error state with Try again.

**Chat not available**: an icon, one line, a close button. No technical words.

**iPad and Android tablets**: `present()` uses a form sheet on iPad and a centered max width of 640 dp on tablets. Works in split view and all orientations.

**In-app banner**: a new message while chat is closed and the app is open shows a small top banner with the avatar, name and 1 line (or "New message" when preview is off). Swipe up to dismiss, tap to open. A brand can turn it off in `options`. Auto-hide after 4 s.

### Motion and haptics

- Motion is short and calm. A new message slides up 8 pt with a fade, in 180 ms, ease out. Sent bubbles morph in place from the composer position where the platform makes that clean. Reduced motion: fade only.
- Haptics: a light tap on send, a soft tick on a new message while chat is open, a notice on a failed send. Android follows the system haptic setting.
- Sound: only when `soundEnabled` is true and the phone is not silent.

### Accessibility

Every control has a label from `strings.json`. Each message reads as "{sender}, {text}, {time}, {delivery}". A new message is announced politely. Works with VoiceOver and TalkBack, with focus order in reading order in both directions. Contrast is at least 4.5:1 for text. The largest text sizes wrap and never clip.

### RTL

Layout follows the chat locale, not only the device. Icons with direction mirror. Times and numbers use Latin digits in both languages, which matches the web widget. Strings come from `design/strings.json`, and Studio text comes from the snapshot's localized fields, falling back to the other language when one is empty.

## Locale

Chat locale order: `options.locale`, then the snapshot's `language` policy (`single` wins; for `both`, `startIn: browser` means the device language if it is `ar` or `en`, else `defaultLocale`).

## Privacy

- No ad IDs. No device fingerprint. `installId` is a random UUID that resets on reinstall.
- No third-party analytics. No third-party crash SDK.
- iOS: ship `PrivacyInfo.xcprivacy` in the package. Declare: contact info and user content, linked, for app functionality. No tracking. Required-reason APIs as used.
- Android: `docs/` holds a table for the Play Data safety form. No extra permissions in the manifest apart from `INTERNET` and what the push module needs.

## Size and dependencies

- iOS: no third-party packages.
- Android: Kotlin, Compose (the brand's app usually has it), AndroidX core and lifecycle, kotlinx-serialization. Use `HttpURLConnection` or OkHttp only if the choice is justified in the PR. No native `.so` files.
- Size budget: 2 MB added on iOS, 2 MB added on Android excluding Compose.

## Versions

- iOS 15+, Swift 5.9 tools. Android minSdk 24, compileSdk 36, Kotlin 2.x.
- SDK versions are semver. First release is `1.0.0`.
