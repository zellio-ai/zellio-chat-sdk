# ZeeChat Mobile API, contract v1

The API between the native ZeeChat SDKs and `support-api`. Apps stay on phones for
years, so this contract only grows. Do not remove a field, rename a field, or change
its meaning. A breaking change needs a new contract version.

Base path: `/api/v1/zeechat/mobile`. Production host: `https://app.zellio.ai`.

## Rules for both sides

- Server: a success body is `{ "data": ... }`. An error uses the normal support-api
  error body (`fixtures/error.json`) and always has a stable `code` listed below.
  The body is `{ "code", "message", "detail"?, "details"?, "requestId"? }`. Only `code` is stable:
  `message` is text for people and changes. A non-production server also sends `stack`; the SDK ignores it.
  A request body that fails validation is HTTP 422 with `code: "validation_error"`.
- SDK readers ignore unknown JSON fields and unknown enum values. An unknown home
  module, message `from` value or SSE event is skipped, never a crash.
- `workspaceId` never comes from the client. The server reads it from the app record
  that the app key names.
- Every request has `x-zee-app-key: <appKey>` and `x-zee-sdk: <platform>/<sdkVersion>`
  (`ios/1.0.0`, `android/1.0.0`). React Native and Flutter send the native platform
  value and add `x-zee-sdk-wrapper: react-native/1.0.0` or `flutter/1.0.0`.
- After the session exists, every request also has `x-zee-session-token: <token>`.
- Times are ISO 8601 UTC. Cursors are opaque strings.

## Error codes

| HTTP | code | SDK reaction |
|---|---|---|
| 401 | `CHAT_APP_KEY_INVALID` | Stop. Log a developer error. Show the "chat is not available" state. |
| 403 | `CHAT_APP_DISABLED` | Same as above. |
| 403 | `CHAT_ENTITLEMENT_DENIED` | Same as above. |
| 401 | `CHAT_SESSION_INVALID` | Delete the token. Create a session again, then retry once. |
| 401 | `CHAT_SESSION_REQUIRED` | Create a session, then retry once. |
| 401 | `CHAT_IDENTITY_INVALID` | Get a new token from the token provider once. If it fails again, show the login-needed state. |
| 403 | `CHAT_GUESTS_DISABLED` | Show the login-needed state. |
| 404 | `CHAT_CONVERSATION_NOT_FOUND` | Reload the conversation list. |
| 413 | `CHAT_FILE_TOO_LARGE` | Show the file-too-large message. |
| 415 | `CHAT_FILE_TYPE_DENIED` | Show the file-type message. |
| 403 | `CHAT_FILES_DISABLED` | Hide the attach control. |
| 404 | `CHAT_ATTACHMENT_NOT_FOUND` | The file is gone (used, expired, or not this visitor's). Remove it from the composer and let the person attach it again. |
| 422 | `validation_error` | A developer error: the SDK sent a bad body. Log it. Do not retry the same request. |
| 429 | `CHAT_RATE_LIMITED` | Back off. Obey `Retry-After`. Keep queued messages. |
| 426 | `CHAT_SDK_TOO_OLD` | Stop. Log a developer error. Show the "chat is not available" state. |
| 404 | `CHAT_SITE_NOT_FOUND` | Only from `/config`: the chat of this app is gone. Show the "chat is not available" state. |

Staff-only codes (`CHAT_MOBILE_APP_NOT_FOUND` 404, `CHAT_MOBILE_APP_LIMIT` 409, `CHAT_MOBILE_PUSH_INVALID` 422) come
from the dashboard routes. An SDK never receives them.

An unknown `code` is handled by its HTTP status: 401 as a session to make again, 403 as "chat is not available", 429 as
`CHAT_RATE_LIMITED`, 5xx as a retry with backoff. A 401 or 403 with no `code` did not come from Zellio (for example a
proxy): treat it as a failed request and retry later.

## Threads and sessions

- One customer, or one guest, has ONE thread. A thread has at most one open conversation. A customer's thread is the same
  on every phone and for every session of that customer. A guest's thread belongs to its session.
- `POST /session` is open to anyone who knows the app key and an `installId`. It never ends another session and never
  carries a push token over to a different thread. After EVERY new session (create or identify) the SDK registers its push
  token again with `PUT /device`.
- `POST /session/identify` ends the caller's own session, moves the guest chat to the customer and returns a NEW token. Two
  identify calls with the same old token: the second gets `CHAT_SESSION_INVALID`.
- Use ONE app record for both the iOS bundle id and the Android package name. Two app records give two apps with two
  separate threads for the same customer.
- A session of an app that stops allowing guests is refused with `CHAT_GUESTS_DISABLED` on the next request, and the
  event stream is closed. Deleting the app ends every session of that app.
- A customer session can end at any time: 90 days after it was made, even if it is in use, or when the app owner rotates
  the identity secret and stops the old one at once. The next request gets `CHAT_SESSION_INVALID`. The SDK then signs in
  again with its token provider, with no customer action. Neither rule applies to a guest session.
- Limits count an IPv6 caller by its /64. A request with no readable client IP skips the IP limit. Only guest requests
  count against the app-wide limit, so a flood of guests cannot block customers.

### `GET /config`

App key only. Published Studio settings for the app's site, and app settings.
Fixture: `fixtures/config.json`.

`snapshot` is the same `SiteSnapshot` as the website (`packages/zeechat-core/src/contracts.ts`).
The SDK uses it for colors, logo, text, home modules, consent and support hours. It
ignores launcher and website-only fields. It ignores a module's `visibility.paths`.

The SDK saves the last good config and draws it at once on the next open, then reads
this endpoint again. It never starts a session from a saved config.

### `POST /session`

Creates a session. Body:

```json
{ "installId": "uuid made by the SDK at first run", "platform": "ios", "locale": "ar", "identityToken": "optional JWT" }
```

- No `identityToken`: a guest session, if the app allows guests (else `CHAT_GUESTS_DISABLED`). The guest thread key is
  `zmg_` followed by the session id; a customer thread key is `zmu_` followed by a value derived from the app and the
  `sub`. Thread keys are server-side; the SDK never sends or reads them.
- With a valid `identityToken`: a customer session.

Returns 201 with `fixtures/session.json`. Keep `sessionToken` in the iOS Keychain or
in Android Keystore-backed storage. `expiresAt` is 30 days by default, but it is only the value when the session was made:
every send moves it forward and the client is not told. Do not drop a token because of `expiresAt`. Keep it until the
server answers `CHAT_SESSION_INVALID`: a guest who gets a new session gets a new thread and loses the old chat.

### `POST /session/identify`

Session token required. Body: `{ "identityToken": "JWT" }`. Turns a guest session into
a customer session, on this phone only. The guest chat moves to that customer. Returns
the same shape as `POST /session`, with a NEW `sessionToken`; the old one stops working.
If the customer already has an open conversation, the guest's open conversation is resolved first, so the customer
still has one open conversation. The push token stays registered. The SDK still registers it again, as for every new session.

### `POST /session/logout`

Session token required. Empty body. Ends the session and removes this install's push
token. Returns 200 `{ "data": { "loggedOut": true } }`. The SDK deletes all local chat
data at the same time, also if this call fails.

### `GET /conversations`

Session token required. Query: `cursor?`, `limit?` (1 to 50, default 20). Newest first.
Fixture: `fixtures/conversations.json`.

`unreadTotal` counts agent messages newer than the read mark, across all conversations.

`lastMessage.attachmentKind` is `"image"`, `"file"` or null. It is null when `hasAttachment` is false. Use it to show
"Photo" or "File" when `text` is empty.

### `GET /conversations/:conversationId/messages`

Session token required. The conversation must belong to this visitor, or the reply is
`CHAT_CONVERSATION_NOT_FOUND`. Query: `before?`, `after?` (cursors, never both),
`limit?` (1 to 100, default 50). Messages are oldest first in the page. `nextBefore` is
null when no older page exists. `latest` is the cursor to use as `after` to catch up.
Fixture: `fixtures/messages.json`.

### `POST /messages`

Session token required. Returns 202 `{ "data": { "clientMessageId": "...", "accepted": true, "conversationId": "..." } }`.

```json
{
  "text": "Where is my order?",
  "clientMessageId": "uuid",
  "attachmentIds": ["att_1"],
  "context": { "screen": "OrderDetails", "itemType": "order", "itemId": "1042", "itemTitle": "Order 1042", "url": "https://shop.example/orders/1042" }
}
```

`text` is 0 to 4000 characters and may be empty only with an attachment. `clientMessageId`
makes a resend safe: the same id never makes a second message. `attachmentIds` has at most 5 ids. A `context` that breaks
a rule is dropped, not refused, and so is a bad `url` alone: it never costs the customer the message. `context` is optional and
shows to agents. Its strings are at most 200 characters, and `url` must be `https`.
`conversationId` in the reply can be null if the message is still in the inbound queue.

The request has no `conversationId`. A thread has one live conversation: a new message continues the open conversation,
or reopens the latest resolved or closed one, and only creates a new conversation when the thread has none. So
"New conversation" in the SDK opens an empty composer with no conversation yet. It moves to the `conversationId` in the 202
reply after the first send. The SDK never creates a conversation by itself.

### `POST /attachments`

Session token required. `multipart/form-data` with one `file` part. Allowed when the
published snapshot has `behavior.allowAttachments: true`. Images (`image/jpeg`, `image/png`,
`image/webp`, `image/heic`) and `application/pdf`, at most 10 MB. The server checks the real
file bytes, not only the declared type. Returns 201 with `fixtures/attachment.json`. An id
works only for this visitor and only for 24 hours.

Returns 429 `CHAT_RATE_LIMITED` with `Retry-After: 10` when the session, the network address or
the server has too many uploads in flight. Keep the file and retry after the delay. An upload has
120 seconds to arrive; after that the server closes the connection.

### `POST /read`

Session token required. Body: `{ "conversationId": "...", "upTo": "message id" }`. Moves the
read mark forward only. Returns `{ "data": { "unreadTotal": 0 } }`.

### `GET /unread`

Session token required. Returns `{ "data": { "unreadTotal": 2 } }`. The SDK calls it on start
and on return to the foreground.

### `PUT /device`

Session token required. Body:

```json
{ "provider": "apns", "pushToken": "...", "environment": "production", "locale": "ar", "appVersion": "4.2.0" }
```

`provider` is `apns` or `fcm`. `environment` is `sandbox` or `production` and applies to
`apns` only. Returns `{ "data": { "registered": true } }`.

### `DELETE /device`

Session token required. Removes this install's push token. Returns `{ "data": { "registered": false } }`.

### `GET /events`

Session token required. A server-sent event stream. The server sends `: ping` every 20 seconds
and closes the stream after 10 minutes. The SDK reconnects with backoff (1, 2, 4, 8, 16, then
30 seconds, with jitter) and then reads newer messages with `after`, also after any return to the
foreground. The SDK closes the stream when the app goes to the background.

| event | data |
|---|---|
| `ready` | `{ "conversationId": "..." or null }` |
| `message` | One message, same shape as in `fixtures/messages.json`, plus `conversationId` (the conversation the message belongs to) |
| `typing` | `{ "active": true, "agentName": "Mona" or null }` |
| `agent_joined` | `{ "agentName": "Mona" or null, "agentAvatarUrl": "https://..." or null }` |
| `unread` | `{ "unreadTotal": 2 }` |

The stream reaches every phone of the same customer. The server refuses a stream with `CHAT_RATE_LIMITED` and
`Retry-After: 20` when the thread already has 5 open streams, the network address has 100, or the server is full.
Reconnect after the delay.

## Identity token

The brand's server signs a JWT with the app's identity secret. The secret never goes in the app.

- Header: `alg` must be `HS256`. The server refuses any other value, `none` included.
- `aud` (required): the app key.
- `sub` (required): the brand's user id, 1 to 128 characters.
- `iat` (required) and `exp` (required): `exp` is at most 24 hours after `iat`. Clock skew allowed: 60 seconds.
- `name`, `email`, `phone` (optional): saved on the contact only where the field is empty.
  They never decide which contact this is. Only `sub` does.

Each app can have 2 active secrets during a rotation.

The SDK takes an async token provider, not a token. It calls the provider when it needs a new
session.

## Push payload

Keys in the provider's data section (`data` on FCM, top level beside `aps` on APNs). On FCM,
data values are strings, so `zellio` is a JSON string there and an object on APNs. The SDK
helper handles both.

```json
{ "zellio": { "v": 1, "type": "message", "conversationId": "...", "messageId": "..." } }
```

- `zellio` marks the push as ours. The SDK helper `isZellioPush` checks only for it.
- The default alert has no message text: title is the brand name, and the body is "New message"
  in the device's stored locale. With the app setting `pushPreviewEnabled`, the body is the first
  120 characters of the reply.
- The server sends a push only when no event stream of that visitor is open.
- An install gets no push after logout or after the owner stops the old identity secret at once, until the SDK registers
  its token again. A customer install still gets pushes after its session times out, because a tap signs in again. A guest
  install needs a live session.
