# Habibi Android

Native Material 3 Views/AppCompat host for the shared Rust core. There is no
WebView or Compose dependency. Once builds JNI; this Gradle project merges Android
resources/manifests/AARs and packages the resulting library.

## Build

Use Android SDK 35, Gradle 8.13.0 and Java 21. From the repository root, after Once
has produced an Android `libhabibi_core.so`:

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" \
mise exec gradle@8.13.0 java@temurin-21.0.13+9.0.LTS -- \
  gradle --no-daemon --console=plain -p native/android packageOnce \
  -PonceNativeLibrary=/absolute/path/to/libhabibi_core.so \
  -PonceNativeAbi=arm64-v8a \
  -PnshAndroidAar=/absolute/path/to/nsh.aar \
  -PnshBundleDirectory=/absolute/path/to/native/cards/assets/nsh \
  -PonceOutputApk=/absolute/path/to/HabibiAndroid.apk
```

`onceNativeAbi` accepts `arm64-v8a` or `x86_64`. Staging removes previously staged
ABIs to avoid silently packaging an old library. APK packaging requires an explicit
native library; JVM tests do not. Package/application ID: `fyi.habibi.app`.

`../modules/android.star` exports `habibi_android_application`, consumes one
`android_native_library` provider and the pinned Native Shell `android_library`
through its `nsh` dependency role, and produces `HabibiAndroid.apk` through
`packageOnce`. Once supplies the reviewed card assets and licenses. The JNI entry point is
`Java_fyi_habibi_app_HabibiCore_execute`; Kotlin loads `habibi_core`.

## JVM tests

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" \
mise exec gradle@8.13.0 java@temurin-21.0.13+9.0.LTS -- \
  gradle --no-daemon --console=plain -p native/android \
  testDebugUnitTest testReleaseUnitTest
```

These run real Android views under Robolectric with injected protocol fixtures,
memory storage and inference transport. They cover onboarding, native tabs, Kits
navigation/forms, rotation/process-session restoration, explicit approval, serial
background execution, persistence ordering/failure, cancellation and request caps.
The sync tests inject HTTP and fixed Rust protocol transcripts, not a second
encryption/lineage implementation. They cover strict PKCE callbacks, rotating
refresh response loss, protected credential storage, durable outbox ordering,
scan validation, explicit conflict decisions and native settings. No JVM test
contacts production or the local Phoenix service.
They do not substitute for Android Keystore/JNI/WASM/device verification. Reports
are under `../.once/android-build/reports/tests/`.

Dependency versions, including transitive dependencies for debug and release,
are locked in `gradle.lockfile`. Update intentionally with Gradle's
`dependencies --write-locks` task. AGP and Kotlin plugin versions are pinned in
`build.gradle.kts`.

## Development inference

Only debug builds read these **ephemeral intent extras**:

```sh
adb shell am start -n fyi.habibi.app/.MainActivity \
  --es inference_url http://10.0.2.2:8083/inference \
  --es inference_token "$HABIBI_INFERENCE_TOKEN"
```

The token is never persisted. Only emulator gateway/loopback HTTP destinations are
accepted; redirects are disabled and requests use `Authorization: Bearer …` with
90-second connect/read timeouts. Debug network security configuration permits
cleartext only for those hosts. Release ignores extras and disallows cleartext.
Without a bridge, Conversations explicitly says **Not connected** and disables
Send. It never substitutes fake intelligence.

The Rust core constructs inference requests from the active thread's text context,
not the vault profile/identity/document. Native supplies only the IDs of connected,
unexpired bundled Kits to advertise their tools. Authorized GitHub tool calls add
sanitized profile/public repository results to inference context and the encrypted
conversation archive; credentials and raw HTTP responses never enter either.
Host-owned dialogs approve save/update/remove.
Reviews are bound to a fingerprint of the identity plus encrypted document, and
any intervening change invalidates approval. Stopping disconnects inference
network work, suppresses late GitHub results, denies pending agent review, and
preserves already committed changes.

## Bundled GitHub connection

Profile → Kits → **GitHub** is a reviewed, host-only bundled connector, separate
from user-designed local Kits. The **publisher** bundles the public GitHub OAuth
client ID, with device flow enabled, in `native/core/assets/github-kit.json`,
returned by `bundled_kits` (`clientId`). End users only tap **Connect GitHub** and authenticate;
there is no client-ID or secret entry/state. An empty manifest ID disables Connect
and explains that the publisher has not configured this build. No client secret,
private-repository scope, write scope, redirect callback or arbitrary URL is
accepted. Habibi requests only `read:user`; a returned empty scope is also valid.
Before Connect, the native screen discloses that the agent can read the authorized
profile and up to 10 recently updated public repositories owned by the user, and
send sanitized results to the conversation's inference provider. Credentials stay
private. Inference consent and privacy copy distinguish these authorized results
from credentials, vault keys and saved local Kit entries.

Device authorization opens the system browser only at
`https://github.com/login/device`, without a code or credential in the URL.
Bounded HTTPS requests disable redirects and target only the fixed device-code,
token, `https://api.github.com/user`, and
`https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10`
endpoints. Responses are bounded to 64 KiB except the public repository list,
which has a 256 KiB limit. The device code is memory-only
and expires within GitHub's documented 900 seconds, measured from request start.
A separate scheduled auth worker respects polling intervals and `slow_down`, so
the vault's serial worker never sleeps waiting for browser consent. Cancel
invalidates pending requests and queued success before the durable install gate.
Process death requires starting again.

The host validates the token's bearer type/scope/optional expiry and performs a
real authenticated `GET /user` before storing anything. The connection joins the
existing encrypted vault only after a successful durable save. **Check
connection** repeats the real authenticated request and displays the login only
in local settings, without sharing the check result with inference. Connecting
does not automatically share account data. Only explicit agent calls to
`github_get_profile` and `github_list_repositories` return sanitized profile or
public repository fields to inference and the conversation archive. Both tools
accept only `{}`. Native requests `connection_request` with `id: "github"`, tool
`name` and `arguments`, validates the exact fixed GET descriptor and headers, then
executes it through the fixed native transport. It passes the object/array response
only to the core's `connection_result` operation (`name`, `response`), and forwards
only that operation's `result` through the existing tool-output/archive flow.
Descriptors, headers, raw bodies, token responses and credentials are never
forwarded to inference, Kit guests or transcripts. Stop suppresses late tool
results, including responses already in flight or being sanitized. Refresh tokens
are deliberately never stored or used: sharing rotating refresh credentials
between devices would race.
Expired or revoked connections require reconnecting. Native connection screens
disable saved view state for device codes/accounts and use `FLAG_SECURE`.

Connections travel inside encrypted recovery backups and manual encrypted sync
snapshots. Another device needs the **same vault backup and its separate recovery
key**, then manual sync; Habibi account login does not recover keys. Disconnect
removes only this device's encrypted connection until you sync. Other devices and
old backups may retain usable tokens. For actual revocation, use GitHub Settings
→ Applications → Authorized OAuth Apps (or Authorized GitHub Apps) and revoke the
app.

`GitHubConnectorTest` uses injected HTTP/scheduling and protocol fixtures only,
covering pending/slow-down/error states, request-start deadlines, malformed and
ambiguous responses, cancellation before network/after success, storage failure,
identity validation, automatic account-data isolation, sanitized GitHub tool loops
and encrypted archive restoration, cancellation during tool HTTP/sanitization,
rejection of expanded descriptors/nonempty arguments, publisher-only configuration
UI, fixed browser intents and endpoint-specific transport limits. It never
contacts GitHub. Live device/browser consent and JNI
encryption/sync remain integration checks, not claims made by the fixtures.

The catalog hides bottom navigation before, during and after keyboard use.
The GitHub sheet embeds its reviewed Kit-owned NSH presentation on Android 9+;
Android 8, missing runtimes and page failures use native text. Only public Kit
metadata and theme colors enter the page, with empty granted capabilities and
no authentication or tool bridge. Native disclosure and connection controls
remain available independently. See [Kit-owned presentation pages](../README.md#kit-owned-presentation-pages)
for the package, build and isolation contract.

## Encrypted cloud sync

Profile → **Encrypted sync** offers optional account sign-in in the system
browser (never a WebView), manual **Sync now**, explicit conflict decisions and
disconnect. Production defaults to `https://habibi.fyi`, but no discovery or sync
network request occurs just by opening settings. Account authorization cannot
recover vault keys. Another device needs the existing encrypted recovery backup
and its separate recovery key, imported locally before syncing that vault.

For the existing local Phoenix development server, use its exact advertised
issuer in **both browser and API traffic**, without URL/endpoint rewriting:

```sh
adb -s emulator-5554 reverse tcp:4000 tcp:4000
adb -s emulator-5554 shell am start -n fyi.habibi.app/.MainActivity \
  --es sync_url http://localhost:4000
```

The debug launch extra is removed immediately. Only that exact local origin is
accepted, only in debug; `10.0.2.2` is deliberately not an alias for this issuer.
Reapply the extra on a new application process before local testing. Release
ignores it and permits no cleartext sync origin. There is no insecure-origin
field in settings. Complete the browser's local passkey and consent flow; the
exported `fyi.habibi.android:/oauth/callback` handler accepts credentials only for
a matching, unexpired in-memory state/issuer/redirect/PKCE transaction. Process
death, cancellation and malformed/duplicate callbacks require signing in again.

OAuth access/refresh credentials are origin-scoped in a separate Keystore AES-GCM
record, never the vault document or recovery bundle. Before a refresh consumes
its rotating token, a checked durable write makes the old credentials unusable.
An uncertain exchange or failed replacement write requires reauthorization,
never a refresh replay. All HTTP has bounded bodies/timeouts and redirects
disabled. Disconnect removes local OAuth credentials and attempts grant
revocation, explicitly reporting if revocation could not be confirmed. It never
deletes vault keys, ciphertext, pending uploads or scan progress.

Sync flushes encrypted conversations first and refuses active replies, Kit
reviews and unsaved entry/personalization forms. Editing/navigation pause during
sync application. Every metadata update uses the existing durable install gate;
metadata-only core results retain local state. Pending snapshots persist before
upload and retries reuse their exact UUID/encrypted bytes. Lost acknowledgements
leave the outbox intact. Scanning persists each authenticated contiguous record
before continuing, validates page cursors and stops at practical limits.

Conflicts never use last-writer-wins. Native confirmation lists opaque head IDs
and warns that profile, Kits, entries and conversations may be replaced; export
backups first. The action rescans and demands another confirmation if any head
changed. Applying selected remote state resets ephemeral provider/tool/consent
context and retains the selected conversation if it still exists. Archived tool
results remain inert display data, never replayed approvals.

Sync is intentionally manual: there is no periodic snapshot timer or promised
background delivery. Each changed immutable full-state snapshot counts toward
the server's prototype 100 MiB/10,000-record quota. History completeness and
rollback resistance still require a stronger protocol; sync is not a substitute
for separate recovery backups or an independent security review.

## Native conversations

The inbox opens a separate conversation screen with no bottom tabs. Its composer
stays outside the transcript. Messages, cards, tool-result details, composer drafts
and uninstalled Kit definitions persist in the encrypted vault with stable IDs
and timestamps. Drafts debounce for 500 ms; send, replies, cards, tool results,
review resolution and lifecycle departure checkpoint changes. Failed writes keep
dirty changes retryable without replacing the last durable state. Autosaves defer
during review so they cannot invalidate the approval's document fingerprint.
Cursor positions, viewport, provider protocol history, endpoint/token, consent and
pending work remain ephemeral. Restore rebuilds only user/assistant text context,
never executable tool calls or approvals. Prompt navigation does not send or
replace a draft; Latest resumes following incoming output.

On-device dictation requires Android 12+ and an installed local recognizer/language
model. There is no generic recognizer or cloud fallback. Hold/release or tap/stop
adds editable text without sending. Discard, back, pause and stale permission or
recognition callbacks cannot overwrite the draft.

Native Shell 0.2.0 renders only the bundled reviewed Atlas `result_table` card on
Android 9+. Android 8 and renderer failures use native text with the same guarded
local data action. Rust validates cards and actions; neither the model nor a card
can supply executable bundles or gain network, vault or mutation capabilities.
See [the native contract](../README.md#conversations-and-native-components).

### Private inline Kit entries

Conversations also render `kit_entry` as a native Material input card, separately
from the unchanged Native Shell `result_table` path. The component identifies an
installed Kit, not an arbitrary form schema:

```json
{"type":"kit_entry","version":1,"data":{"title":"Log this set","kitId":"<installed-kit-id>","prefill":[{"key":"exercise","value":"Squat"},{"key":"weight","value":7}]},"actions":[{"id":"save_entry","label":"Save set"}],"fallback":"Enter your set privately."}
```

`prefill` is required and is an array of at most 12 unique `{key,value}` pairs;
use `[]` for none. Values are strings or numbers. All field keys, labels, types,
units and ranges come from the installed Kit definition. Context is editable,
date fields default to the local calendar day, and numeric fields use native
numeric input. Missing Kits or invalid suggestions show an unavailable fallback
without network access. Unsaved card inputs are ephemeral and reset on closing.

Typing never invokes inference or writes an entry. The explicit **Save entry**
action validates locally, flushes the conversation archive, then calls the Rust
non-tool operation `submit_kit_entry` with `conversationId`, `messageId`, `values`
and the existing identity/document. Rust atomically saves the entry and archived
`entryId` receipt; replay returns the same entry, not a duplicate. Android durably
installs the encrypted candidate before showing saved, disabled fields, without
discarding newer composer edits. Chats, Kit reviews, sync and other work fence
submission. Saved values and receipts survive restart but are never tool output
or provider context: `present_component` acknowledges only `{"displayed":true}`.

## Local privacy and recovery

The entire identity/document pair is stored as one AES-256-GCM envelope protected
by Android Keystore, with authenticated record naming and checked synchronous
`commit()`. UI state is published only after persistence succeeds. Read errors
offer retry/recovery, never automatic reset or destructive logout. Cloud and
device-transfer backup are disabled.

Recovery exports save the encrypted backup through Android's native file picker
and show/share the recovery key in a separate step. File import/export streams
run on the serialized worker with an 8 MiB limit, accommodating a full local
document plus pending snapshot without Android's intent/clipboard size ceiling.
An interrupted/rotated picker must be restarted; payloads and keys are never
restored from instance state. Recovery screens/dialogs use `FLAG_SECURE`; secrets are not written to
Android instance-state bundles, autofill, logs, regular preferences or chat.
Import uses a selected encrypted file or native paste fields and explicit replacement confirmation when a
saved vault exists. Retain original backups until recovery succeeds. Recovery
includes encrypted conversations and drafts; legacy backups without an archive
still restore. No conversation plaintext is stored in a separate file or database.
