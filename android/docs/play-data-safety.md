# Play Data safety: ZeeChat Android SDK

What the SDK collects when a brand ships it. The brand fills the form for the whole app; this is the SDK's part.

| Data type | Collected | Shared | Linked to the user | Why | Optional |
|---|---|---|---|---|---|
| Messages (text the customer types) | Yes | No (only with the brand's support team, as a service provider) | Yes | App functionality | No |
| Photos and files the customer attaches | Yes | No | Yes | App functionality | Yes |
| Name, email, phone (only if the brand puts them in the identity token) | Yes | No | Yes | App functionality | Yes |
| User ID (`sub` of the identity token) | Yes | No | Yes | App functionality | Yes |
| Device or other IDs: random `installId` (resets on reinstall), push token | Yes | No | Yes | App functionality (session, push) | Push token: yes |
| App version, SDK version, chat language | Yes | No | No | App functionality | No |

Not collected: advertising ID, location, contacts, device fingerprint, crash logs sent to a third party, analytics.

Security: data is encrypted in transit (HTTPS only; cleartext is refused by the manifest defaults). The session token is
encrypted with an AES-256-GCM key in the Android Keystore. Chat data is kept in the app's private `noBackupFilesDir`, is
excluded from backups and device transfer (`zc_backup_rules.xml`, `zc_data_extraction_rules.xml`), and is deleted on
`ZellioChat.logout()`. The customer can ask the brand to delete server data.

Permissions in the SDK manifest: `INTERNET` only. `:zellio-chat-fcm` adds `POST_NOTIFICATIONS`. The camera button uses
the system camera app through an intent; if the host app declares `CAMERA`, the SDK asks for it when the customer taps
the camera button, and never otherwise.
