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
configure distribution signing or install on a physical device. Tests use a
dedicated simulator when `ONCE_APPLE_SIMULATOR_UDID` is set. Use a disposable
simulator: Once's UI-test runner reinstalls the app and removes its local files.

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
bridge token. Without the flags, Conversations is explicitly disconnected rather
than using mock responses. Both platforms ask for cloud disclosure consent.

**A local CLI is not local inference.** The harness/provider receives messages,
requested Kit metadata/definitions and synthetic test results. Its terms,
retention and charges apply. App tools never send profile, saved entries, real
summaries or keys. Anything typed into chat or embedded in a definition is still
disclosed. Do not put recovery secrets in a prompt or recording.

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
save/update/remove, plus the native-only `present_component` display operation.
Evaluation receives **synthetic data**, not saved entries.
Save/update/remove require host-owned approval, tied to the current encrypted
document revision. Updates cannot change fields. The loop stops after eight
provider requests per user message. Approved changes survive cancellation and
restart; transcript persistence cannot approve or replay a Kit operation.

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
Production inference remains unconnected.

## Encrypted sync

Profile → Encrypted sync connects to the server through system-browser OAuth
with S256 PKCE. Account credentials are origin-scoped and protected separately
from vault secrets. Sign-in does not recover a vault: another device needs the
encrypted recovery backup and its separate recovery key first.

Sync now uploads immutable encrypted snapshots and downloads authenticated
history. The client durably saves an upload before sending it and retries the
exact ciphertext after interruption. Concurrent edits require an explicit choice
of local or remote state; there is no automatic field-level merge. Disconnect
removes account credentials but retains the local vault and sync progress.
The server sees opaque IDs, sizes, digests, sequence numbers and access metadata,
not conversations, entries, preferences or content keys. This does not detect
a malicious server withholding the newest history or prove rollback resistance.

For local development, pass `--sync-url http://localhost:4000` to the DEBUG iOS
simulator. On Android, run `adb reverse tcp:4000 tcp:4000` and pass
`--es sync_url http://localhost:4000` to the debug activity. The origin must match
OAuth discovery exactly; do not rewrite its issuer to an emulator alias. Native
sync remains an unaudited prototype, and production rollout is not configured.

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

Production inference, public distribution, signed updates and schema migration
execution are **not connected**. A future migration
must run locally over a copy, validate its result, show a preview, obtain approval
and atomically replace encrypted state with a recoverable backup. Neither guest
code nor a server migration should receive the vault key. No App Store naming or
downloaded-code policy approval is implied by the name “Kits.”
