# Releasing the ZeeChat SDKs

All four packages ship together under one version (for example `1.2.0`).

The source of truth is `sdks/` in the Zellio monorepo. The public repo `zellio-ai/zellio-chat-sdk` gets one
snapshot commit per release. A plain version tag on that commit starts
[`.github/workflows/release.yml`](.github/workflows/release.yml), and that workflow publishes the packages.

| Package | Registry | How the workflow signs in |
|---|---|---|
| `ZellioChat` | Swift Package Manager | No job. SPM reads the tag. |
| `ai.zellio:zellio-chat`, `ai.zellio:zellio-chat-fcm` | Maven Central | Portal user token and a GPG key (environment secrets) |
| `@zellio/chat-react-native` | npm | Trusted publishing (OIDC). No token. |
| `zellio_chat` | pub.dev | Automated publishing (OIDC). No token. |

## Release steps

1. In a monorepo PR, set the new version in every file that
   [`scripts/check-release-version.mjs`](scripts/check-release-version.mjs) lists. Then run
   `node sdks/scripts/check-release-version.mjs 1.2.0`. It must pass before you merge.
2. After the merge, from the monorepo root, run `node scripts/sdk-release-snapshot.mjs 1.2.0`.
   - The script clones the public repo and commits `origin/main:sdks` on top. The new tree is the same git
     tree object, so file modes stay exact.
   - It adds the annotated tag `1.2.0`. It does not push.
3. Run the push command that the script prints. **This push is the release.** Get the owner's approval first.
4. Watch the Release run in the public repo's Actions tab. Then check each registry:
   - Maven Central: <https://repo1.maven.org/maven2/ai/zellio/zellio-chat/>
   - npm: `npm view @zellio/chat-react-native version`
   - pub.dev: <https://pub.dev/packages/zellio_chat>

If one job fails, fix the cause and use **Re-run failed jobs**. No registry accepts the same version twice.
So never re-run a job that already published. To change published code, make a new patch version.

## One-time setup (done once per repo, by an owner)

1. **GitHub environment.** In `zellio-ai/zellio-chat-sdk`, go to Settings, then Environments, and add `release`.
   - Under deployment branches and tags, allow only tags that match `[0-9]*.[0-9]*.[0-9]*`.
   - You can also add a required reviewer. Then each release waits for one click.
2. **Environment secrets** in `release`:
   - `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_PASSWORD`: a user token from central.sonatype.com
     (account menu, then View Account, then Generate User Token). The account must own the `ai.zellio`
     namespace.
   - `SIGNING_KEY`: the ASCII-armored private key that signs the artifacts. Its public key is on
     keyserver.ubuntu.com.
   - `SIGNING_KEY_PASSWORD`: the passphrase of that key.
3. **pub.dev.** On <https://pub.dev/packages/zellio_chat/admin>, go to Automated publishing:
   - Enable publishing from GitHub Actions.
   - Repository: `zellio-ai/zellio-chat-sdk`. Tag pattern: `{{version}}`.
   - Require GitHub Actions environment: `release`.
4. **npm.** On npmjs.com, open `@zellio/chat-react-native`, then Settings, then Trusted Publisher, and choose GitHub Actions:
   - Organization `zellio-ai`, repository `zellio-chat-sdk`, workflow `release.yml`, environment `release`.
   - npm says: "A newly created trusted publisher configuration must complete its first successful publish
     within 2 days." So add it on the day of the first automated release, not earlier.
   - After that release works, set publishing access to "Require two-factor authentication and disallow
     tokens".
