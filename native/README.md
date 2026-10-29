# Native Habibi

SwiftUI on iOS, Material 3 Views/AppCompat on Android, and a shared Rust core,
built with Once. There is no WebView, generated Xcode project, or native QuickJS
library. Onboarding creates a **local encrypted vault**, not a server account.
Use fictional data: this is an unaudited development prototype.

## Build and test

Run `npm ci` at the repository root. From this directory:

```sh
mise install
mise exec -- rustup component add rustfmt clippy
mise exec -- rustup target add aarch64-apple-ios-sim aarch64-apple-ios aarch64-linux-android
mise run check
mise run build:ios
mise run build:ios-device
mise run test:ios
mise run test:ios-ui
```

Apple builds require macOS and Xcode. Simulator output is
`.once/out/HabibiIOS/Habibi.app`; the device target compiles ARM64 but does not
configure distribution signing itself or install on a physical device. The iOS
release workflow below signs a separate copy. Tests use a dedicated simulator
when `ONCE_APPLE_SIMULATOR_UDID` is set. Use a disposable
simulator: Once's UI-test runner reinstalls the app and removes its local files.

`mise run test:ios-ui` creates or reuses **Habibi UI Tests**, an iPhone 17 Pro
running iOS 26.5, unless `ONCE_APPLE_SIMULATOR_UDID` is set. Install that runtime
in Xcode before running the task. iOS 26.3's simulator cannot load the system
alternate-icon alert handler; the first icon change returns an I/O error and
later changes report a busy resource. Apple's alternate-icon sample reproduces
the failure, while the complete Habibi UI suite passes on 26.5 without skipped
assertions. A bare `once test HabibiIOSUITests` still uses Once's first booted
or available simulator unless you supply the environment variable.

For Android, install SDK 35, build-tools 35.0.0 and NDK 27.3.13750724. Set
`ANDROID_HOME` to your SDK and `ANDROID_NDK_HOME` to that NDK directory, then:

```sh
mise run build:android
mise run test:android
adb install -r .once/out/HabibiAndroid/HabibiAndroid.apk
```

The current Once target builds ARM64. Gradle packages the JNI library, real
Android resources and locked Android dependencies. See [android/README.md](android/README.md)
for its packaging contract and standalone JVM tests. Both apps use `fyi.habibi.app`.

## iOS App Store Connect releases

`.github/workflows/ios-release.yml` runs on relevant changes to `main` or manual
dispatch on `main`. Bash automation lives in `mise/tasks/ios/`. It shares the
root git-cliff 2.6.0 conventional-commit policy, but uses independent reachable
stable `ios@x.y.z` tags, starting at `0.1.0`. Native/shared-theme fixes bump patches,
features bump minors, and breaking changes bump majors, including during `0.x`.
Ordinary maintenance and server-only changes do not release iOS. The build number
is `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT`, so a retried upload gets a new number.
Keep the workflow's run-counter history when changing its name or location.
Local bootstrap builds use `1.0.N`, below CI's first `1.1`, to avoid collisions
before the workflow is enabled.

Personal Infisical EU organization `pepicrft`, project `habibi`, environment
`prod`, root folder stores:

| Secret | Value |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 certificate and private key, exported as password-protected PKCS#12 |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that PKCS#12 export |
| `IOS_APP_STORE_PROFILE_BASE64` | Base64 App Store Connect provisioning profile for `fyi.habibi.app` |
| `ASC_API_KEY_ID` | App Store Connect **team** API key ID |
| `ASC_API_ISSUER_ID` | That team's API issuer UUID |
| `ASC_API_KEY_P8_BASE64` | Base64 private `.p8` API key |

All six secrets are configured for the App Store Connect app `Habibi Bot`
(`fyi.habibi.app`). For a new setup, create the app record, then generate
a team API key under Users and Access → Integrations → App Store Connect API.
Give it the Developer role for build uploads and store its three values above;
do not put its private key in Git or chat. This is not the separate APNs key.
Signing certificate/profile expiration is 29 October 2027; renew both secrets
before then. Preserve the matching private key when renewing the certificate.

The CI machine identity has read-only access to this dedicated project and
15-minute tokens. OIDC is bound to the immutable GitHub repository/owner IDs,
the exact release workflow, and `refs/heads/main`; pull requests cannot use it.
No persistent Infisical token or Apple ID password is needed in GitHub.
CI builds the device app before fetching credentials, so dependency installers
and build scripts never inherit the signing or App Store Connect private keys.

The bundle script checks profile type, app ID, expiry and certificate matching;
stamps a copy of the built device bundle's version and SDK metadata;
embeds the profile, scoped entitlements and Swift support; and verifies the
distribution signature. Its temporary Keychain and private files are deleted
on exit, without changing the default Keychain. The cached app and source plist
remain unchanged. App extensions require separate profiles and are rejected.

The upload script validates with Apple before uploading. Only a successful upload
creates the exact-SHA GitHub release/tag. It does not submit for App Review,
release publicly, or automatically invite TestFlight testers. Upload acceptance
does not guarantee Apple's later processing or beta review. No IPA is published
as a public GitHub artifact. Complete App Store Connect's encryption/export
compliance questions for the Rust-based encrypted vault rather than claiming
the app uses only operating-system encryption. Do not blindly retry an upload
with an unknown outcome; inspect App Store Connect first.

Run `mise exec -- bash mise/tasks/release/test.sh` from the repository root to
exercise real disposable Git histories for both server and iOS releases.

## Translation sources

`app-store/locales/en-US.json` contains the English App Store listing and
screenshot headlines. Copy it to an App Store locale such as `es-ES.json` or
`de-DE.json`, keeping field names and screenshot IDs unchanged. Apple limits
names/subtitles to 30 characters, promotional text to 170, descriptions to
4,000 and keywords to 100 UTF-8 bytes. Listing translations do not change the
languages supported inside the app.

From the repository root, run `mise run ios:localize` with Xcode 26.6 or later
to refresh `ios/Localizable.xcstrings`. Apple's extractor recognizes static
SwiftUI strings and `String(localized:)`; its synchronizer preserves existing
translations. Open the catalog in Xcode to add languages. The command also
checks that the catalog compiles before replacing it.

This is an initial source extraction, not complete localization support.
Interpolations whose types cannot be inferred are reported and skipped.
Dynamic strings, ordinary Swift/Rust model messages, Android copy and system
permission descriptions still need localization work. Once 0.68.2 does not
compile string catalogs as resources; packaging compiled `.lproj` resources is
also required before shipping translated native UI. The uploaded 0.1.0 build
remains English-only.

## Habibi Plus subscriptions

**Profile → Habibi Plus** offers monthly and yearly subscriptions for hosted
encrypted snapshot uploads and automatic composer-draft handoff. Local
conversations, supported local AI, Kits, skins, encryption and recovery
exports/imports remain free. AI-provider subscriptions and usage are separate.
Signing in is free and does not recover a vault key. After expiration, hosted
writes pause with HTTP 402; local data, pending snapshots, existing downloads,
and lease renewal/release remain available. Cancellation never deletes data.

Checkout uses StoreKit 2 or Google Play Billing. Both show the store's localized
recurring price, handle pending payments, offer restore and link to subscription
management. There are no hardcoded prices, trials, discounts or lifetime grants.
The native client verifies the signed-in account before checkout, binds the
purchase to it, and submits the store proof to the authenticated server before
finishing/acknowledging it. Use the same Habibi passkey account on both platforms;
manage payment in the original store. Apple and Google accounts are not Habibi
accounts, and changing Habibi accounts does not transfer a subscription.

The server uses RevenueCat REST v1 as its purchase verifier. It sends a
pseudonymous Habibi account UUID, platform, product ID and store receipt/token,
never vault content, encryption keys, AI-provider credentials or waitlist email.
RevenueCat and the stores process billing metadata under their own policies.
No receipt is stored in Habibi's database. `GET /v1/subscription` and
`POST /v1/subscription/receipt` require OAuth. Every hosted write checks current
verified access; client-supplied customer IDs or entitlement flags cannot grant
it. Renewals, cancellation, grace periods and refunds come from RevenueCat's
subscriber response. Missing configuration or a provider failure returns 503
and leaves local data untouched. There is no entitlement cache or webhook
receiver: RevenueCat availability and request limits affect hosted writes.

### External billing setup required before launch

This repository does **not** create store products, configure a RevenueCat
project, set prices or enable live payments. Before distribution:

1. Create `habibi_plus_monthly` and `habibi_plus_yearly` in App Store Connect
   in the same subscription group, with one-month and one-year renewal periods.
   Disable Family Sharing: access is for one Habibi account.
2. Create those same subscription IDs in Google Play, each with one ordinary
   auto-renewing base plan, respectively `P1M` and `P1Y`. Do not add prepaid or
   trial offers expecting this checkout to display them. Publish through a Play
   test track to test billing; a sideloaded APK cannot prove checkout works.
3. Connect both store apps in one RevenueCat project, attach all four products
   to entitlement **`plus`**, configure store credentials and Apple server
   notifications/Google real-time developer notifications for renewals/refunds.
   Set RevenueCat restore behavior to **Keep with original App User ID**. This
   is required to prevent a receipt being moved to another Habibi account.
4. Supply `REVENUECAT_SECRET_KEY` (server-side REST v1 read key),
   `REVENUECAT_APPLE_KEY` and `REVENUECAT_GOOGLE_KEY` (respective public app keys)
   using your server's secret manager. No billing keys belong in native source.
   Allow outbound HTTPS to `api.revenuecat.com`. Billing availability requires
   all three keys. No new database migration is needed for subscriptions.
5. Use a separate nonproduction server with `BILLING_ALLOW_SANDBOX=true` for
   store sandbox testing. Production rejects sandbox entitlements even if that
   variable is set. Test success, pending/canceled payment, renewal, grace,
   refund, expiry, restore after interruption and cross-platform sign-in. Also
   test that a different Habibi account cannot claim an existing receipt.
6. Publish billing privacy/retention disclosures and store subscription terms,
   set the approved localized prices and tax details, and complete store review.
   Apple sandbox review needs the nonproduction verification path. Store
   approval and live transactions have not been verified by local tests.

## App icons

Profile → Appearance offers Forest (the default/GitHub logo), Midnight and
Blossom. Icon choice belongs to the operating system on each device, not the
encrypted profile or sync. iOS uses UIKit alternate icons; Android switches
launcher aliases without disabling the activity that handles OAuth callbacks.

The opaque Forest master is [`../assets/logo.png`](../assets/logo.png);
the other masters are `resources/app-icons/{midnight,blossom}.png`. After editing
one, run `python3 resources/prepare_app_icon.py` (Pillow and NumPy) and retain the
generated Android layers and iOS primary/preview/alternate PNGs. Android artwork fits
the central 66dp adaptive-icon safe zone and includes Android 13+ monochrome
layers. Neither platform bakes rounded corners into the master.

## Skins

**Profile → Skins** opens Habibi's local wardrobe. Coach, Socratic Tutor and
Gentle Planner are bundled starting points. **Try on** opens a separate saved
conversation with an editable example; it neither installs the skin nor sends
a message. **Add to wardrobe** opens an explicit, editable review. **Wear** starts
a new conversation. The skin control above the composer switches future
replies in that conversation or returns to **Just Habibi**. New ordinary
conversations have no skin, and selection is disabled during an active turn.

Skins are portable JSON definitions with `apiVersion:1`, `name`, `description`,
`author`, `instructions` and `examplePrompt`. Make one in the native editor, or
import a file (32 KiB maximum) and review it before adding. Exports contain only
the definition, never conversations, entries or credentials. Any personal text
you put in the definition is still exported; author names are self-declared,
not verified. A wardrobe holds up to 24 skins. Editing/removing a skin
does not rewrite existing conversations: each keeps its selected definition.
The wardrobe and those copies are encrypted in the vault, recovery and sync.
Stored JSON keys and core operation names retain `costume`/`costumes` for
compatibility with existing vaults, conversations and exported definitions.

Only the selected name and instructions join the model request, alongside the
conversation's normal context and tool results. The example is sent only if you
send it as a message. Other skins and author metadata are not sent. Skins
change conversational guidance, not tools, data access, approval requirements or
professional qualifications. The native host still enforces those boundaries;
prompt text is not a security boundary. There is no executable skin code,
public catalogue, automatic update, model-generated creation flow or skin
artwork in this first version.

## Connect ChatGPT

Onboarding offers **Connect with ChatGPT**, with **Skip for now** for local-only
use. Existing users can connect or disconnect in **Profile → AI provider**.
Copy the displayed device code, open OpenAI's sign-in page, approve there, and
return to Habibi. Device-code login may need enabling in ChatGPT security
settings or workspace permissions. Connecting does not send a prompt or create
a Habibi sync account; the first conversation still asks for disclosure consent.

This experimental integration follows Pi's **legacy `openai-codex` provider** at
[`b3a29f1`](https://github.com/earendil-works/pi/blob/b3a29f1111114fac696e2cfcd65acdb382a6ed5e/packages/ai/src/auth/oauth/openai-codex.ts):
public client ID `app_EMoamEEZ73f0CkXaXp7hrann`, OpenAI device authorization and
PKCE code exchange, and direct HTTPS SSE inference at
`https://chatgpt.com/backend-api/codex/responses`. Profile → AI provider sets the
default model, initially `gpt-6.1-sol`. The iOS conversation title menu and Android
toolbar options override it for that conversation; **Use default** resumes following
the Profile choice. New conversations inherit the default. Both preferences are
encrypted with the vault and included in recovery and sync. A running turn keeps
one model through tool calls and approvals. The shared Rust catalog follows Pi's
legacy provider, not account-specific entitlements; all use medium reasoning.
Onboarding does not ask for a model. Plan eligibility and model availability
apply; no ordinary OpenAI API billing or unrestricted ChatGPT access is implied.
Partial or failed streams cannot execute tools or become successful replies.
Habibi's existing local tool validation and mutation approval remain in force.

Credentials live only in a device-only Keychain item on iOS or a separate
Keystore-encrypted record on Android, **not** in vault snapshots, recovery
backups, model prompts or Habibi's server. Each device connects separately and
serializes its own refreshes. A durable marker precedes refresh; an ambiguous
rotation or failed replacement write requires reconnection instead of replaying
the old refresh token. Disconnect deletes local credentials without deleting the
vault or revoking other ChatGPT sessions. Manage usage in ChatGPT settings.

Pi now prefers the newer [Sign in with ChatGPT OSS registration flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
which issues an app-specific client ID and uses the public Responses API. Its
documented return path is HTTP loopback, not a native app link. Neither Pi's
public legacy client ID nor mocked tests establish OpenAI approval for Habibi,
production mobile support, account-specific model access, or App Store policy
compliance. Validate a real account and obtain the appropriate provider approval
before distributing this experimental connection.

## Apple on-device inference

On iOS 26+, **Profile → AI provider → Default model** and the conversation title
menu include **Apple · On device**. It uses Foundation Models' on-device
`SystemLanguageModel`, without an account, API key or cloud disclosure prompt.
Apple Intelligence must be supported, enabled and have its model ready. The UI
shows the actual availability reason and retains saved preferences if unavailable.
An Apple preference synced to Android is preserved but cannot run there; choose
a ChatGPT override explicitly. Nothing silently falls back to a cloud provider.

The smaller model is best for short conversations, not complex Kit code generation.
Each step selects an operation before receiving that operation's argument schema,
instead of placing every schema in its 4K-token context window. Arguments still
pass through Rust validation and native mutation approval. Context overflow,
refusal, cancellation and generation failures produce no executable partial output.
Requests contain only the same bounded conversation and tool context as other
providers. Connected service tools still contact their service when requested;
encrypted sync and recovery retain the transcript as before. Switching from
on-device inference to cloud inference requires disclosure approval again.

## Use host inference in the simulator

From the repository root, start one opt-in development bridge with an already
authenticated host CLI:

```sh
node native/resources/inference.mjs amp
# Alternatively: node native/resources/inference.mjs claude
# Alternatively: node native/resources/inference.mjs pi
```

Amp uses its configured account/provider routing; `HABIBI_AMP_MODE` selects the
mode (default `gpt61s`). Claude and Pi use their configured default provider/model.
Host tools are disabled: a completion returns a Kit operation as JSON, and the
native app executes it under its normal validation and approval checks. Amp
verifies an empty enabled-tool list at startup; Pi disables tools, MCP,
extensions, skills, context files and sessions; Claude uses safe mode with no
tools, MCP, hooks, skills or saved session. These are CLI controls, not an OS
sandbox. Do not use the bridge as an untrusted public service.

The installed Codex CLI (0.164.0) does not offer a supported global zero-tools,
zero-host-context mode. It is deliberately **not** an adapter. Read-only sandbox
or disabling shell alone would not provide that boundary.

The bridge binds only to `127.0.0.1:8083`, accepts one bounded request at a time,
requires a random bearer token, rejects browser-origin requests, and kills an
inference process on cancellation or a 90-second timeout. Its token is written
with owner-only permissions to `.amp/in/native-inference-token`, never logged.
Keep that directory excluded from Git. The bridge has no vault or storage API.

Boot your dedicated iOS simulator and launch the built app from the root:

```sh
xcrun simctl install "$SIMULATOR_UDID" native/.once/out/HabibiIOS/Habibi.app
xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" fyi.habibi.app \
  --inference-url http://127.0.0.1:8083/inference \
  --inference-token "$(cat .amp/in/native-inference-token)"
```

These arguments work **only in DEBUG simulator builds**. The device target ignores
them. For the standard Android emulator, launch the debug APK with:

```sh
adb shell am start -n fyi.habibi.app/.MainActivity \
  --es inference_url http://10.0.2.2:8083/inference \
  --es inference_token "$(cat .amp/in/native-inference-token)"
```

Android immediately removes the extras from the activity intent. Release builds
ignore them and disallow cleartext networking. Neither platform persists the
bridge token. Without the flags, a connected ChatGPT account or an available
selected Apple model, Conversations is explicitly disconnected rather than using
mock responses. Both platforms ask for cloud disclosure consent. An explicitly
selected Apple model takes precedence over cloud and development inference;
otherwise a connected ChatGPT account takes precedence over a development bridge.
Provider failures never silently fall back to another provider.

**A local CLI is not local inference.** The harness/provider receives messages,
requested Kit metadata/definitions, synthetic test results and authorized GitHub
tool results. Its terms, retention and charges apply. App tools never send the
Habibi profile, saved local Kit entries, real local summaries, credentials or keys.
Anything typed into chat or embedded in a definition is still disclosed. Do not
put recovery secrets in a prompt or recording.

## Kit and storage boundary

The Rust core owns the contract documented in the root README:
`{apiVersion:1,name,description,fields,source}`. The host renders declared forms,
validates entries and persists them. Guest JavaScript only implements synchronous
`summarize(inputJson)` returning a primitive JSON string of bounded text metrics.
`createdAt` is UTC RFC3339; `today` is the host's local calendar date. Daily
trackers should use an explicit date field.

The native runtime runs the pinned QuickJS Wasm engine in **wasmi's interpreter**,
without JIT or executable-memory entitlements. Every call has a fresh instance,
runtime and context. It exposes no WASI, filesystem, networking, host functions,
module loader or pending jobs. Only immutable compiled module state is cached.
Limits: 24 KiB source, 256 KiB input, 16 KiB output, 8 MiB QuickJS allocation,
256 KiB QuickJS stack, 32 MiB Wasm memory and 25 million interpreter fuel units.
Fuel bounds work, not wall-clock time. Runtime/schema errors never delete entries.
New entries are rejected before persistence if they would exceed the input budget.

`core/assets/quickjs.wasm` is extracted from the npm-pinned 0.32.0 single-file
variant, with its upstream license. Reproduce and verify it after `npm ci`:

```sh
node native/resources/prepare_quickjs.mjs
```

The trusted conversation loop exposes seven Kit tools: list/read/write/evaluate/
save/update/remove, plus native-only `present_component` and `react_to_message` operations.
Connecting a bundled service Kit adds its reviewed service tools to that loop.
Evaluation receives **synthetic data**, not saved entries.
Save/update/remove require host-owned approval, tied to the current encrypted
document revision. Updates cannot change fields. The loop stops after eight
provider requests per user message. Approved changes survive cancellation and
restart; transcript persistence cannot approve or replay a Kit operation.

## Bundled connection Kits

Profile → Kits includes **GitHub**, the first reviewed connection Kit on iOS and
Android. **The Kit publisher owns OAuth configuration; users only tap Connect
and authenticate.** The reviewed manifest at `core/assets/github-kit.json`
bundles the public `clientId`, requested permissions and agent tool schemas.
The publisher registers a GitHub **OAuth app**, enables **device flow** and sets
that ID before distributing a build. The checked-in ID is empty until supplied;
unconfigured builds disable Connect, never ask end users to configure OAuth.
No client secret belongs in the app or Habibi server. The device flow does not
use a callback, even if GitHub requires one when registering the app.

The app requests only `read:user`, shows a short-lived code and opens
`https://github.com/login/device` in the system browser. It honors polling
intervals/backoff, checks the authenticated account before saving, and drops
cancelled or expired transactions. Once connected, the agent gains two tools:

- `github_get_profile`: the connected account's profile.
- `github_list_repositories`: up to ten recently updated public repositories
  owned by that account, not private repositories or repository contents.

The native host reads credentials from the encrypted vault and performs only
the reviewed fixed-endpoint GETs. Rust projects bounded result fields before
they reach inference and the encrypted conversation archive. **Requested tool
results are shared with the conversation's inference provider; credentials are
never shared.** Connecting does not automatically send the profile or other
GitHub data. **Check connection** remains a local-only diagnostic. Disconnect
or expiry removes the tools from subsequent inference requests, and actual
execution independently rejects missing/expired connections. Guest JavaScript
has no network or connection access. Slack and Google Calendar are not
implemented yet.

The resulting session is saved in the same client-encrypted vault as your Kits,
profile and conversations, so recovery exports and manual encrypted sync include
it. Recover **the same vault** on the second device using its encrypted backup
and separate recovery key, then use Profile → Encrypted sync on both devices.
Signing into a Habibi account alone does not transfer the vault key. Offline
conflicts use the existing explicit full-snapshot choice, including connections;
there is no silent account/session merge or automatic full-vault sync. Older
native clients reject snapshots containing connections instead of stripping
credentials: update both devices before syncing.

Expiring access tokens require reconnection. Refresh tokens are deliberately
not persisted or used: two offline clients cannot safely rotate a shared refresh
token without coordinating ownership. Provider revocation is also detected by
the next API request. Disconnect removes the local session and propagates on
sync, but **does not revoke GitHub access** or erase tokens from older snapshots,
backups or offline devices. Revoke the app in GitHub Settings → Applications to
invalidate those copies. The existing vault has no forward secrecy, and this
prototype remains unaudited; use a disposable account while dogfooding.

### Kit-owned presentation pages

The GitHub detail sheet embeds the Kit's own NSH `kits/github/App.tsx` page.
The host retains the native sheet, icon, permission/disclosure text and all
Connect, check, disconnect and recovery controls. The catalog hides bottom
navigation for its entire lifetime; its iOS search uses the conversation
composer's glass surface and accessibility fallbacks.

The iOS catalog uses grouped lists and system scope controls, switching to a
menu at accessibility text sizes. Android uses tonal search, Material filter
chips and a resizable modal sheet with an accessible drag handle and a 640 dp
maximum width. Kit pages receive platform typography tokens; authentication
and disclosure controls remain native.

The manifest's `presentation` declares version 1, a compiled entry, SHA-256 and
native text fallback. The host-only `kit_page` operation accepts `{id}` without
a vault document, resolves only reviewed bundled entries and verifies their
digest. It is not an agent tool. Repository downloads, installation and package
signature/trust policies are not implemented.

The `habibi.kit-page` bridge sends only `{kit:{id,name,description},colors,typography}`.
It accepts only a finite height from 1 to 6000 logical points (zero is ignored
during initial layout), not authentication, tool, navigation or install actions.
Each page has empty granted capabilities, denied network/filesystem/process/
clipboard/status-bar capabilities, disposable storage, 16 MB memory, 512 nodes,
a 1-second load budget and a 250 ms call budget. A missing runtime, error or
3-second readiness timeout shows native text without disabling host controls.
Android 8 uses the native fallback. These limits are not a security audit.

After editing the page, rebuild with the pinned NSH 0.2.0 CLI and review both
source and generated artifacts:

```sh
NSH_BIN=/path/to/nsh kits/build.sh
python3 kits/verify.py
```

The verifier checks source/configuration/bundle hashes and the manifest; Once
runs it for both native builds. Re-recording hashes is a developer build step,
not permission to load arbitrary or remote code.

## Conversations and native components

The Conversations tab is an inbox. Opening or creating a conversation pushes a
separate native view and hides the tab bar, including when the keyboard closes.
Messages, rich cards, tool-result details, composer drafts and uninstalled Kit
definitions are saved inside the existing encrypted vault and recovery backup.
Drafts autosave after a short typing pause; leaving the view and conversation
checkpoints also flush changes. Failed writes keep the previous encrypted record
and the unsaved in-memory changes for retry. Nothing is silently truncated when
the vault reaches its size limit. Wait for saving to finish before force-quitting.

Relaunch restores stable conversation/message IDs and dates. Provider protocol
history, endpoints, tokens, consent, approval continuations and pending work are
never archived. Continuing a restored conversation requires fresh consent and
rebuilds context from that thread's user/assistant text, including card fallbacks,
not executable tool calls or tool results. Archive saves defer while a Kit review
owns the document revision. Older backups without conversations still open.
The pinned composer, prompt index and jump-to-latest follow Atlas's native
conversation design; incoming output does not pull a reader away from history.

Habibi can acknowledge a user message with a reaction instead of another text
bubble. `react_to_message` takes `{message_id,emoji}`, using a stable user-message
ID from the active conversation and one of 👍 ❤️ 😂 🎉 😮 😢. A successful reaction
ends the turn without another inference request; another reaction replaces the
previous one on that message. Reactions never approve or execute Kit operations.
Both native apps show an accessible badge and include it in encrypted saves,
recovery and manual sync. Only the active conversation's user-message text, IDs
and existing Habibi reactions are supplied as reaction targets; drafts and other
conversations are excluded. Restore rebuilds text context and supplies saved
reactions separately, without replaying their original tool calls. Old backups
without reactions still open; upgrade both clients before syncing reacted messages
because older clients reject the added archive field.

Dictation uses Apple Speech's required on-device recognition on iOS and Android's
on-device recognizer on Android 12+. There is no generic/cloud recognizer fallback,
audio upload or automatic message submission. Tap to start/stop, or hold and
release; review the resulting editable text before Send. Discard, leaving the
screen and app interruption invalidate pending capture callbacks. Unavailable
recognizers or language models leave typing available. iOS Simulator deliberately
keeps dictation unavailable: its host RemoteIO service can abort the app while
opening a microphone. Test actual transcription on a physical iPhone.

`present_component` accepts `{component}` with one of two reviewed contracts.
The display-only Atlas table is:

```json
{
  "type": "result_table",
  "version": 1,
  "data": {
    "title": "Synthetic workout",
    "columns": ["Exercise", "Repetitions"],
    "rows": [["Squat", "7"], ["Press", "11"]]
  },
  "actions": [{"id": "show_source", "label": "View data"}],
  "fallback": "Squat: 7 repetitions. Press: 11 repetitions."
}
```

Rust rejects unknown fields/types/versions/actions and enforces 32 KiB serialized
data, 8 columns, 20 rows, 120 cells and exact row widths. The app acknowledges
display with `{"displayed":true}`; it does not route the request to Kit mutation
tools. A table's only action, `show_source`, reveals the original message's
already-held data locally after revalidation. It cannot fetch, execute or approve
anything.

An installed Kit can also offer an inline native entry card:

```json
{
  "type": "kit_entry",
  "version": 1,
  "data": {
    "title": "How many reps?",
    "kitId": "<installed Kit UUID>",
    "prefill": [{"key": "exercise", "value": "Squat"}]
  },
  "actions": [{"id": "save_entry", "label": "Save set"}],
  "fallback": "Log a set in your workout Kit."
}
```

The host derives typed inputs, labels, units and ranges from the installed Kit,
never model-supplied UI code or field definitions. Prefill is an array of at most
12 unique declared keys with schema-valid string/number values; use `[]` for no
suggestions. Display still acknowledges immediately with `{"displayed":true}`.
Editing and explicit Save happen locally afterward: values and receipts are not
added to provider history and submission does not trigger inference.

The non-model `submit_kit_entry` bridge resolves the archived conversation and
message IDs, validates complete values, and atomically seals the entry and its
message receipt in one encrypted document. The app publishes only after durable
storage succeeds. Retrying the same card never duplicates or overwrites its
entry. Saved cards restore their values and disabled state after restart;
unsaved inline inputs remain ephemeral. Removed Kits or incompatible suggestions
show an unavailable fallback. Cards never grant the model access to saved entries
or vault keys, and cannot install or approve Kits.

Once bundles the checksum-pinned Native Shell 0.2.0 SDK and the byte-identical
reviewed Atlas table renderer; entry cards use trusted SwiftUI/Android controls.
No model/server-supplied JS, TSX, bundle URLs or
capabilities are accepted. Each renderer gets explicit `{}` capabilities,
disposable storage, 16 MB memory, 512 nodes and a 250 ms call budget. Renderer
errors/timeouts use native text and the same guarded action; Android 8 uses this
fallback without loading NSH. These runtime limits are not a substitute for a
security audit. Verify the source/bundle manifest with `python3 cards/verify.py`.
Changes to the renderer require `cards/build.sh` and review of the regenerated
artifact. Atlas's MIT and Native Shell's Apache notices ship in both apps.

Habibi's Phoenix server remains marketing pages, OAuth routes and client APIs.
It does not run component renderers or receive decryption keys. Local-stack E2E
uses the local Phoenix service; the explicit developer inference bridge is a
separate loopback-only process, not a new server dashboard or production relay.
ChatGPT inference connects directly from the native device; no production relay
or production mobile-provider approval has been configured.

## Encrypted sync

Profile → Encrypted sync connects to the server through system-browser OAuth
with S256 PKCE. Account credentials are origin-scoped and protected separately
from vault secrets. Sign-in does not recover a vault: another device needs the
encrypted recovery backup and its separate recovery key first.

Manual sync uploads immutable encrypted snapshots and downloads authenticated
history. The client durably saves an upload before sending it and retries the
exact ciphertext after interruption. Concurrent edits require an explicit choice
of local or remote state; there is no automatic full-vault field-level merge. Disconnect
removes account credentials but retains the local vault and sync progress.
The server sees opaque IDs, sizes, digests, sequence numbers and access metadata,
not conversations, entries, preferences or content keys. This does not detect
a malicious server withholding the newest history or prove rollback resistance.

For local development, pass `--sync-url http://localhost:4000` to the DEBUG iOS
simulator. On Android, run `adb reverse tcp:4000 tcp:4000` and pass
`--es sync_url http://localhost:4000` to the debug activity. The origin must match
OAuth discovery exactly; do not rewrite its issuer to an emulator alias. Native
sync remains an unaudited prototype, and production rollout is not configured.

### Automatic composer drafts

Recover **the same vault** on both devices using its encrypted backup and separate
recovery key, then sign in through Profile → Encrypted sync on each device.
Signing in alone cannot transfer encryption keys. Both native apps automatically
exchange unsent conversation text after a 1.5-second typing pause and poll every
5 seconds while active. They make a best-effort final attempt on departure;
background suspension, force-quitting or offline devices can delay delivery.
Keep the first device open until its draft status confirms encrypted sync before
switching devices. Disconnect stops automatic network sync, not local saving.

Drafts are encrypted on-device with the existing vault content key and the HAB1
format, under the separate context `habibi/drafts/v1\0{vault UUID}`. Only draft
text, conversation IDs/dates and causal version clocks are inside this channel.
An unknown conversation arrives as an empty transcript with its draft. Messages,
Kit definitions/entries, provider context, credentials, consent and approvals are
not synchronized automatically. Full snapshots and recovery backups still include
the draft metadata along with the rest of the vault.

Causal edits replace their earlier version. Concurrent device edits retain both
versions instead of choosing by timestamp or arrival order. **Other draft versions**
lets you switch without sending or discarding the other branch, including when
you continue editing the selected version. Sending or clearing a branch leaves
an encrypted empty marker so stale retries cannot resurrect its previous text;
other conflict branches remain available. A restored backup and an explicitly
selected alternative start a fresh local editing identity to avoid reusing old
revision counters. There is no automatic text merge or conflict deletion UI.

Local persistence succeeds before any merged draft is uploaded. The server
compares ciphertext digests using conditional HTTP writes; on a conflict, the
client downloads, decrypts, merges and retries. Invalid ciphertext, failed writes
or size limits leave saved versions intact; sync pauses rather than truncating.
Bounds are 128 tracked conversations (including cleared markers), 16 concurrent
versions per conversation, 32 editing identities per version, 64 KiB UTF-8 per
version and a 1 MiB encrypted draft blob. The existing 1 MiB local-vault limit
can be reached first, since draft text and version metadata also live there.

Deploy the `20261028000000_create_vault_drafts` server migration before using
automatic drafts. Its one bounded ciphertext row per vault is in PostgreSQL,
not the immutable snapshot bucket. No server decryption is introduced. Upgrade
both clients before exchanging new backups or full snapshots: older clients
reject the new draft/clock fields rather than silently stripping them. Server
freshness and rollback resistance are still not proven, and the prototype is
not independently audited.

## Server-owned appearance and Heartling

The server generates `/assets/themes.json` from its Theme UI tokens and palette
descriptors. Run `mise run prepare:themes` to refresh the native bundled fallback.
Both apps use bounded public catalog requests without OAuth or vault credentials,
retain cached themes offline and keep unknown saved theme IDs unchanged.
Profile → Appearance saves the theme ID and system/light/dark preference inside
the encrypted profile, including recovery and sync. Platform typography continues
to respect accessibility settings.

`resources/heartling/` contains the neutral transparent sprite atlas and frame map.
Native compositing tints it with the current palette's primary color. Like Atlas
Pip, it uses bundled artwork and native motion, not downloaded executable UI.
Heartling appears in welcome, home, empty conversations and actual activity;
tapping greets without sending messages. Reduce Motion stops idle/working motion,
and inactive or departed views stop animation. Status text remains independent.

Rust generates a random 256-bit content key and a separate sync token. Profile,
Kit definitions, entries and conversations form one HAB1 AES-GCM/HKDF encrypted document. iOS
keeps identity secrets in device-only Keychain and atomically writes a protected
encrypted file; Android protects the identity/document record with Keystore
AES-GCM and checks durable writes before publishing state. The size limits are
12 Kits, 250 entries per Kit and a 1 MiB encrypted document. Unknown versions fail
closed. Recovery needs both the exported encrypted backup and a separate recovery
key. Backups are not rollback proofs, and Habibi cannot reset encryption.

Public distribution, production provider approval, signed updates and schema
migration execution are **not connected**. A future migration
must run locally over a copy, validate its result, show a preview, obtain approval
and atomically replace encrypted state with a recoverable backup. Neither guest
code nor a server migration should receive the vault key. No App Store naming or
downloaded-code policy approval is implied by the name “Kits.”
