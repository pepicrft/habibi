# Habibi

An open-source personal AI companion, in the making. The static home is designed for **https://habibi.fyi**.

The app logo is [`assets/logo.png`](assets/logo.png), a 1024×1024 PNG for GitHub and other integrations.

This repository contains an Eleventy website, an Elixir/Phoenix ciphertext-sync prototype, a Web Crypto reference client, and development native iOS/Android apps. **There is no released mobile app. The sync protocol and native vault are experimental and have not been independently audited. Do not entrust them with real personal data yet.**

## Native apps

[`native/`](native/README.md) uses SwiftUI on iOS, Material 3 Views on Android, shared Rust logic and Once builds, following Atlas/Glossia. Onboarding generates a random content key locally, saves personalization in an encrypted vault, and opens native Home, Conversations and Profile tabs. Profile → Kits supports model-authored JavaScript, native review, typed entry forms and local summaries through QuickJS Wasm in wasmi's no-JIT interpreter. Keychain/Keystore protect local secrets; no WebView is involved.

Native conversations, cards and drafts persist in that encrypted vault and its recovery backups. Restart restores text context without replaying tools, pending approvals or provider consent. Failed saves retain the previous encrypted record and retryable edits; no plaintext conversation database is created.

Unsent native composer drafts also sync automatically between connected devices
that have recovered the same vault. Offline conflicts keep both encrypted versions
under **Other draft versions**; choosing a version never sends it. Full-vault sync
still uses explicit snapshot conflict choices. See [automatic drafts](native/README.md#automatic-composer-drafts)
for setup, timing and limits.

Kits can present native input cards directly inside a conversation, such as asking for exercise repetitions. Fields come from the installed Kit schema. An explicit Save seals the entry and card receipt together; retries do not duplicate it, and saved cards restore after restart. Editing or saving does not call inference or disclose the entered values to the model. Unsaved inline inputs remain ephemeral. Read-only result tables still use the reviewed bundled Atlas Native Shell renderer.

Simulator/debug launch flags connect to a loopback host inference bridge using authenticated Amp, Claude or Pi. The host CLI returns tool requests as data; the app validates, executes and approves them. Messages and requested definitions reach the selected provider, but tools never send saved entries or keys. Profile → Encrypted sync connects native apps through system-browser OAuth/PKCE and immutable encrypted snapshots, with explicit conflict choices. Account sign-in does not recover encryption keys. See the [build, inference and privacy instructions](native/README.md). Production inference, public sharing and migrations are not connected. The browser workbench below remains a separate reference client with different local key storage.

Profile → Kits also includes a bundled **GitHub connection Kit**. Its publisher supplies the public OAuth client ID in the Kit manifest; users only connect and authenticate through GitHub’s device flow. Once connected, the agent can read the GitHub profile and recent public repositories through reviewed tools. Requested results reach the conversation’s inference provider, but credentials never do. Sessions stay in the encrypted vault and travel through the same recovery/manual-sync path to another device holding that vault’s key. Expiring tokens require reconnection; disconnect is not provider revocation. See [publisher configuration and cross-device limitations](native/README.md#bundled-connection-kits). Slack and Google Calendar are not connected yet.

## Habibi Kits: personal tools, made from a prompt

Kits are named, described personal trackers: for example, a calorie journal or workout log. The **local browser reference workbench** supports conversation → draft → test → review → install → log entries, with management under **Profile → Kits**. It is not a native app, marketplace, or production sandbox.

```sh
npm ci
npm run kits:dev
# Open http://127.0.0.1:8081 on the machine running this command.
```

For real inference using an already authenticated local Claude Code CLI:

```sh
KITS_PORT=8082 npm run kits:dev -- --local-claude
# Open http://127.0.0.1:8082. Approve the Claude Code disclosure in the workbench.
```

This development-only bridge uses the CLI's existing authentication and default model (tested with Claude Code 2.1.310), so no API key is entered in the page. **The CLI is local; inference is still cloud-hosted by Anthropic.** It returns structured Kit tool requests; the browser executes them through the same validation, Wasm and approval boundaries. Native CLI tools, MCP, skills, hooks, browser integration and session persistence are disabled. It never receives vault keys or saved entries. The opt-in `/inference` route binds to loopback, requires same-origin JSON POSTs, caps requests, runs one CLI process at a time, and kills it on cancellation or timeout. It is not part of Phoenix, a deployment feature, or a substitute for native simulator integration. Without the flag there is no inference endpoint.

Create a local vault with a long, unique passphrase. Describe a Kit, open **OpenAI connection**, supply your own API key, and approve sending the prompt and current draft. Generation calls OpenAI directly using its Responses API with Structured Outputs (`gpt-5-mini` by default; configurable). It never automatically includes saved entries, other Kits, or vault credentials. **Anything you type into the prompt or draft is disclosed to the provider.** `store:false` is not a promise of zero provider retention. The API key stays in page memory and is cleared on Lock/reload. Provider access and charges are yours; live generation requires a compatible model/key. Without a key, the explicitly labeled calorie/workout examples work offline after loading the workbench.

The conversation has seven local tools: `list_kits`, `read_kit`, `write_kit`, `evaluate_kit`, `save_kit`, `update_kit`, and `remove_kit`. `write_kit` stages a draft; `evaluate_kit` runs real Wasm JavaScript against schema-validated **synthetic** values supplied in that call. Saving, updating, or deleting pauses for an explicit host-owned review that the model cannot approve. Updates preserve entries and cannot change fields; removal explicitly deletes the Kit's entries. A Kit changed during review requires a new approval. The tool loop is bounded to eight provider requests per message and conversations stay only in page memory. Approved changes remain saved if a later request fails or is stopped. **Conversation messages, requested Kit names/descriptions/definitions, and synthetic test outputs go to the model. Saved entries do not.** Do not paste private journal data into chat unless you intend to disclose it. Tools do not bypass a locked vault.

Review and edit the name, description, and JavaScript before installation. The empty-data check only checks runtime/schema compatibility, not arithmetic correctness or health advice. The host renders the declared form and validates/saves entries. Export/import shares a JSON Kit definition (including code), **not its saved entries**; imports always open as drafts. Names, descriptions, source, or prompts can still contain information you put there, so review exports before sharing. The development server binds to loopback only, serves an explicit asset allowlist, and has no vault/data endpoint. Restart it after editing source.

### The Kit contract is data and a read-only calculation

A definition is `{apiVersion:1,name,description,fields,source}`. Fields declare a unique `key`, `label`, `type` (`text`, `number`, or `date`), `unit`, and nullable `min`/`max`; all fields are required. No arbitrary HTML, CSS, SQL, imports, or host API names are accepted. JavaScript declares this synchronous entry point:

```js
function summarize(inputJson) {
  const { entries, today } = JSON.parse(inputJson);
  // entries: [{id, createdAt, values: {...this Kit's declared fields}}]
  // today: local calendar date, YYYY-MM-DD
  return JSON.stringify({ metrics: [
    { label: "Entries", value: String(entries.length), unit: "entries" }
  ] });
}
```

The host gives the guest a JSON string containing **only that installed Kit's entries** and the local day, then accepts bounded text metrics, never executable presentation or write commands. Daily trackers use their explicit date field, not the UTC creation timestamp. The conversation harness runs in the trusted client, not on the server or inside the guest; it can evaluate synthetic values but cannot retrieve saved entries. Guest code gets neither the harness tools nor storage writes. Encryption does not make sending decrypted results to a model private.

The runtime uses QuickJS compiled to WebAssembly (`quickjs-emscripten-core` and the single-file browser-sync variant, both pinned at 0.32.0). Each call gets a fresh worker, Wasm instance, runtime and context. No network, DOM, filesystem, module loader, host functions, timers, or pending-job execution are installed. Limits: 24 KiB source, 256 KiB JSON input, 16 KiB JSON output, eight metrics, 8 MiB guest allocation, 256 KiB guest stack, a 100 ms guest initialization/execution deadline, and a separate 2 s worker watchdog covering cold engine startup and the whole invocation. Exceeding a summary budget does not delete entries. These controls limit exposure; they are not an independent security audit or proof against engine/browser vulnerabilities. The loaded host application remains trusted.

### Storage and schema changes stay on the client

Kits, code, and entries are one encrypted IndexedDB snapshot using the existing identity-bound `HAB1` AES-GCM/HKDF envelope. A 32-byte key is derived locally with PBKDF2-SHA256, a random 32-byte salt, and 600,000 iterations. Passphrases need at least 12 characters; a weak passphrase still permits offline guessing. No account, sync, or backend service receives this snapshot or key. Metadata exposes a random vault/record identity, salt, storage version and revision, and ciphertext size. Each installation gets a separate namespace, even when installing the same definition twice.

Writes are copy-on-write and compare their revision inside an IndexedDB transaction. Failed writes leave the old state intact; stale tabs must lock/unlock before saving. This reference supports up to 12 Kits, 250 entries per Kit, and a total encrypted snapshot of 1 MiB. Lock drops decrypted working state and clears its key buffer; JavaScript cannot guarantee physical memory erasure. Download encrypted backups and keep the passphrase separately: there is **no password reset or recovery without it**, and clearing browser storage without a backup loses the data. Restore authenticates/decrypts first and requires an empty workbench. Backups do not provide rollback protection.

Schema/API and storage versions are explicit. Unknown versions fail closed. **Code/name/description updates require approval; installed field schemas cannot change and no migrations run.** A schema upgrade would need a new package version, local migration preview over a copy, schema validation, explicit approval, atomic encrypted commit, and recovery from the pre-migration backup. Ciphertext sync would also need fresh immutable server record IDs and conflict handling; the current local rewrite protocol must not be plugged directly into the existing immutable sync API. Public catalogues, update signing and migration execution remain future work. No App Store naming or policy approval is implied by “Kits.”

## Run the website

```sh
npm ci
npm run dev
```

Marketing source lives in `server/marketing/`. Eleventy listens on port 8080 and `npm run build` produces `server/priv/static/marketing/`. The homepage uses a small, first-party script for early-access signup and referrals; the story, changelog and privacy content are readable without it. There are no analytics or external font requests. Fonts and licenses are bundled locally. The static development server previews the design only; signup requires Phoenix.

The Docker build renders the site before assembling the Elixir release. Phoenix serves the generated pages, assets, robots and sitemap alongside the API; Node and Eleventy are not present in the runtime image. HTML is publicly cacheable, while sync API responses retain `Cache-Control: no-store`. Unknown API paths return JSON, not the marketing 404 page.

### Early access and referrals

The homepage invites people into the first early-access circle without invented counts, deadlines or guaranteed admission. `POST /waitlist/join` sends a one-use, 24-hour confirmation link. The email and rank remain private; a public referral code cannot sign someone in. Confirmation opens a 15-minute HttpOnly browser session with a personal share link, live rank on return to the tab, confirmed-referral count, and email deletion. Request a fresh email link to return after the session expires; priority and referral code stay the same. Confirmation secrets use URL fragments, are removed from browser history immediately, and are stored only as SHA-256 digests on the server. Public HTML stays cacheable; the waitlist API uses `no-store` and CSRF protection. It uses the existing PostgreSQL rate limit (60 requests/minute per socket peer and route, shared across replicas) plus a one-minute per-email resend cooldown and a honeypot. Functional session cookies are not analytics.

Priority is confirmed-referral count descending, then confirmation time ascending, with a stable ID tie-breaker. Unconfirmed, self and duplicate case-insensitive email signups add no credit. A signup's first referral is fixed; resubmitting an existing email cannot transfer it. Deleting a membership removes its email, tokens and any credit it gave its inviter; its friends keep their own places. Email aliases and distinct mailboxes cannot reliably be identified as the same person: this is basic abuse protection, not a Sybil-proof system. Review suspicious referrals before admitting a cohort. No access grants or admission emails are sent automatically, and waitlist membership does not enable app account registration.

Before enabling this in production:

- Apply migration `20261027000000_create_waitlist` through the normal migration job. No shared database is migrated by local development.
- Configure `WAITLIST_EMAIL_API_KEY` with a Resend sending key and `WAITLIST_EMAIL_FROM` with a verified sender, for example `Habibi <invitations@habibi.fyi>`. Store the key in the deployment's secret manager, never Git. Set Helm `waitlistEmailSecret` to a pre-created Kubernetes Secret containing these two environment variables. External deployments can instead include them in `external.existingSecret`. Mail configuration is independent of `ALLOW_REGISTRATION`, which can remain false.
- Set `PHX_HOST` to the public HTTPS domain so email and referral links use the canonical origin. Allow outbound HTTPS to Resend. Resend receives the email address and confirmation message; these are not encrypted app data. Provider acceptance does not guarantee inbox delivery. Missing mail configuration or a delivery failure returns 503, never a successful signup.
- Review email retention and provider policies before collecting real addresses. Confirmed and unconfirmed emails persist until deleted; there is no automatic retention worker. Confirmation tokens are pruned on later signup requests. The operator can inspect the invitation order using `Habibi.Repo.all(Habibi.Waitlist.ranked())` in a private release console; do not publish this list or export it into logs.

For local testing only, set `WAITLIST_EMAIL_DIR` to a private temporary directory when starting Phoenix. It writes JSON emails there instead of contacting Resend; follow the link in the file to exercise confirmation. This mailbox is ignored in production and must not be served as static content. Keep it outside the repository and delete it after testing. Confirmation emails currently use English; page and interaction copy use the marketing Gettext catalogue. A standalone static deployment cannot collect signups without a same-origin Phoenix service for `/waitlist/*`.

The server exposes marketing pages, OAuth/passkey routes, health checks and client APIs only. It has no dashboard, Kit workbench or inference relay. Run server-connected end-to-end checks against local Phoenix with disposable PostgreSQL and S3 storage, not against the separate browser workbench or production.

`/changelog/` lists verified published server/website releases using a checked-in, translatable snapshot in `server/marketing/site/changelog.njk`. Its source comment documents updating the snapshot from GitHub's published release dates and git-cliff notes, then regenerating the marketing catalogue. Local changes and planned mobile features are not listed as released. The page does not fetch GitHub during builds or browsing and is not automatically updated by publication.

An independent static deployment is still possible: publish only `server/priv/static/marketing/`, never the repository root. Set the custom domain to `habibi.fyi` and enable HTTPS. No hosting account or DNS changes are made here.

### Shared UI theme

**`server/priv/theme.json` owns the design tokens**, independently of OAuth credentials and vault keys. It follows the [Theme UI theme specification](https://theme-ui.com/theme-spec): semantic colors, fonts, type/spacing scales, radii, and shared styles/variants. The marketing and sign-in pages use Theme UI's actual framework-agnostic `@theme-ui/css` resolver at build time. Both load the generated `/assets/theme.css`, including local font faces and the primary-button variant; their own CSS keeps page layout and illustration geometry. No React or styling JavaScript ships in marketing pages.

Change the server theme, then run `npm run build` (or use the theme-aware development watcher). The build also exposes the same object at `/assets/theme.json`. `client/theme.mjs` re-exports the server source for bundling and offline startup; a future React UI can pass it directly to `ThemeUIProvider`. Native apps consume `/assets/themes.json`, generated from these tokens and `server/priv/theme-variants.json`: Forest, Clay and Lavender with Theme UI `colors.modes.dark`. They bundle the same catalog for offline startup, cache validated public responses and keep theme/mode selections in the encrypted user profile, recovery and sync. Native typography respects platform accessibility settings. Run `mise run prepare:themes` in `native/` after changing tokens. Clients do not download or execute remote presentation code. Build tests change tokens and verify that CSS, metadata, public JSON and the client export agree.

The favicon and SVG share card are also rendered from server tokens, in `site/favicon.njk` and `site/social.njk`. `site/assets/social.png` is a checked-in 1200×630 raster export of the generated `/assets/social.svg`; refresh that export when changing its copy or theme.

The build also emits `/assets/nsh-theme.json`, mapping the same semantic colors, fonts, spacing and radius into [NSH's theme format](https://nsh.dev/). NSH is not React and does not consume `ThemeUIProvider` or `sx`. This public adapter exports the base light palette; native hosts independently adapt the selected catalog palette for their bundled, reviewed table renderer. Native controls and text continue to use platform fonts and accessibility settings.

Habibi's mascot is **Heartling**, an asymmetric clay heart with tiny feet. Its generated artwork was converted to neutral grayscale, cleaned of stray alpha, and aligned on a shared baseline. The transparent poster, eight-frame atlas and platform-neutral frame map live in `server/marketing/site/assets/mascot/` and ship under `/assets/mascot/`. Four expressions (idle, curious, sleepy, attentive) accompany a four-frame, 800ms ambient walk. The smaller poster loads by default; expression or walking states load the atlas.

The mascot's body follows the active theme's **`colors.primary`**, not a fixed terracotta image or a separate palette. The web renderer hard-light blends the neutral texture over that color, then masks the result with the texture's alpha, preserving the clay shading and dark eyes. Updating `--theme-ui-colors-primary` recolors it immediately. Use `<span class="heartling" aria-hidden="true"></span>` after loading `heartling.css`; add `data-state="curious"`, `sleepy`, `attentive`, or `walk` as needed. Motion is opt-in and stops with `prefers-reduced-motion`. Describe actual work or errors in separate localized text, never with the mascot alone.

Native apps bundle a six-expression atlas in `native/resources/heartling/`: row-major, 384×384 pixels, with idle, curious, delighted, sleepy, attentive and blink frames. They resolve its `tintToken` against the **selected** Theme UI palette, hard-light blend the cropped texture over that color and apply the cropped alpha as a mask. Colors update without rebuilding the artwork. Heartling greets on tap, blinks at rest and accompanies actual work; motion stops for reduced-motion settings and inactive views, following Atlas Pip's bundled-artwork/native-animation pattern. Welcome, home and empty conversations use the mascot; status text remains independent of animation.

The [Shadowfax website, iOS screenshots and changelog](https://www.krispuckett.com/shadowfax) inform the design: warm paper, readable ink, restrained sans-serif type, quiet separators, and contextual cards. The homepage's original conversation study uses native HTML disclosure to reveal a fictional source note, not a running agent or released mobile app. No reference artwork or media is distributed. Native glass, sheets, widgets and accessibility should use platform components rather than copying web effects; the development apps use native sheets/navigation, but widgets remain unimplemented.

The intended native conversation model is an answer plus small, interactive objects: choices, editable lists, reminders, source-backed previews and contextual follow-up suggestions. Keep suggested, approved, saved and completed states distinct, with explicit progress, stop and undo actions. A compact card may expand into a focused surface without losing its place in the thread; any doorway transition should use original Habibi artwork, support reduced motion and have an ordinary accessible open action. Optional ambient animation must not masquerade as real agent progress.

Ongoing tasks (the reference's “quests”) should retain an inspectable goal, permission scope, activity and stop/approval controls. Sustained background work belongs on the user's paired runner rather than assuming an iOS app can run indefinitely or moving readable conversations onto Habibi's sync server. Lock Screen and Live Activity presentation should hide sensitive content by default; push payloads must not become a plaintext side channel. Voice capture needs explicit recording feedback and a deliberate on-device or user-approved transcription destination.

Native conversation cards accept bounded data and named actions, never downloaded bundles, vault keys, OAuth credentials or arbitrary tool/network access. The reviewed NSH table renderer ships with the app and receives explicit `{}` capabilities; Kit-entry cards use trusted native controls and a separate private submission operation. Any future downloadable JavaScript/TSX needs a separate capability and distribution design. Generation belongs on the device or a user-controlled paired runner, not the blind sync service. Lock Screen capture, Live Activities/Dynamic Island, widgets and background execution still require native targets and platform permission handling and are not implemented. Dynamic downloaded code also needs review against Apple's current App Store rules (including 2.5.2 and 4.7); sandboxing alone does not establish eligibility.

### Locales

Following Tuist's Gettext convention, English source uses `dgettext("marketing", "English source")`. The generated template is `server/priv/gettext/marketing.pot`; translations belong in `server/priv/gettext/<locale>/LC_MESSAGES/marketing.po`. Eleventy consumes these catalogues at build time rather than introducing runtime translation into Phoenix.

```sh
npm run gettext:extract  # from the repository root
npm run gettext:check    # fails on stale source extraction; also runs during build
```

Authentication uses standard Elixir Gettext independently: `HabibiWeb.AuthGettext`, domain `auth`, with `server/priv/auth_gettext/auth.pot` and translations in `server/priv/auth_gettext/<locale>/LC_MESSAGES/auth.po`. From `server/`, run `mix gettext.extract` to update it and `mix gettext.extract --check-up-to-date` to check it. CI runs both marketing and authentication extraction checks; a content change without updated catalogues fails. Browser passkey messages use server-translated text rather than hardcoded JavaScript copy. Auth selects an installed catalogue using `Accept-Language` and sets `Content-Language`, `lang` and `dir`; marketing language selection remains URL-based.

`mix assets.deploy` builds the site after `npm ci` has been run at the root. Marketing extraction never merges or rewrites `.po` files. Translation automation or contributors can use standard Gettext/Weblate tooling; no external translation service or credentials are configured. Keep translated values as plain text, not HTML. Docker copies auth catalogues before Elixir compilation because Gettext compiles them into the release.

English is served at `/`; an additional catalogue such as `es` generates `/es/` and `/es/404.html`, localized navigation/metadata, `lang`/`dir`, alternate-language links and sitemap entries. Missing or fuzzy translations fall back to English, and translated HTML is escaped. Only English ships initially: empty catalogues for languages without translations are not created. Builds clean obsolete output, so removing a catalogue removes its pages. Browser-language redirects and locale cookies are intentionally absent: URLs alone choose the language and public pages remain cacheable.

## Encryption decision: client-owned encrypted vaults

We borrow Signal's client-held key boundary, not a complete messenger protocol. Durable personal memory needs recoverable encrypted objects rather than discarded message-ratchet keys.

```text
Authorized device
  ├─ readable local memory, search, tools, and agent loop
  ├─ selected context ──────────────> chosen inference provider
  └─ authenticated encrypted bytes -> Elixir sync -> private object storage
                                               └-> Postgres metadata
```

- Each vault has a random **256-bit content key** generated on a client. Neither the key nor provider credentials are sent to Habibi.
- Records use **AES-256-GCM**, a random per-record 256-bit HKDF salt, and a random 96-bit nonce. **HKDF-SHA-256** derives the record key. Vault and record IDs are bound to the key derivation and authenticated data, preventing ciphertext from being moved between identities undetected. Titles, filenames, summaries, embeddings, and tool results belong **inside** encrypted payloads, not sync metadata.
- A separate random **256-bit sync token** authorizes storage access. Only its SHA-256 digest is persisted. This token cannot decrypt content; it is not the vault key.
- A separate random **256-bit recovery key** encrypts an exported recovery bundle containing the vault ID, content key, and sync token. Keep the bundle and recovery key separately. **Both are required** to recover without an authorized device. The operator cannot reset encryption. Native apps expose manual recovery export/import; no automatic backup service is connected.
- Inference and tools execute from the authorized device, or eventually a paired user-controlled runner. A chosen remote model provider **does receive the selected readable prompts**. Connecting a provider does not make that provider blind. No inference relay or provider credential storage is implemented on this server.
- Keyword and semantic indexes must stay local, protected by device storage; indexes are not implemented yet. Native apps protect vault secrets with Keychain/Keystore; the JavaScript reference keeps them in process memory and is **not** a mobile key-storage implementation.

### Exact record format

All lengths below are bytes. `client/vault.mjs` is the executable reference; its tests also decrypt using Node's independent HKDF/AES APIs.

```text
"HAB1" (4) | random salt (32) | random nonce (12) | ciphertext | GCM tag (16)
```

The total maximum is **1 MiB**, leaving 1 MiB minus 64 bytes for plaintext. Inputs are raw bytes, not JSON/base64-expanded ciphertext. UUIDs use lowercase canonical text. For ordinary records, UTF-8 context is `habibi/record/v1\0{vault UUID}\0{record UUID}`; `\0` denotes a zero byte. The context is HKDF `info`; the first 48 header bytes concatenated with the context are GCM additional authenticated data. Recovery uses domain-separated context `habibi/recovery/v1\0{vault UUID}` with the same envelope format. Recovery bundle version is 1, and its envelope and keys use unpadded base64url.

An encrypted record is immutable. **Retry the exact prepared envelope with the same record ID**, not a fresh encryption of the same plaintext: randomized re-encryption produces different bytes and correctly conflicts. Multiple events may be batched inside one encrypted record to reduce storage requests and metadata rows.

### What this does not protect

The operator still sees vault/record IDs, encrypted sizes, timestamps, access patterns, and network metadata. Framing checks cannot prove that a malicious client encrypted its input. Endpoint compromise, malicious client updates, provider retention, and deliberate tool disclosures are separate risks.

This vault format has **no messenger-style forward secrecy**: compromise of the content key exposes retained records for that key. Authentication detects changed bytes and identity substitution; it does **not** prove that a malicious server returned complete, fresh history. Sync sequence numbers are server metadata, not signed rollback proofs. Device pairing, independent device credentials, revocation with new key epochs, signed history consistency, content deletion/compaction, and a review of native key storage remain necessary before a real mobile release. A removed device cannot be made to forget previously decrypted data.

## Why Elixir and object storage

The API uses Phoenix/Bandit, Ecto/Postgres, DNSCluster, and Phoenix.PubSub. No vault is owned by a process or local disk. Any replica can authenticate, append, list, or download using the same Postgres and private S3-compatible bucket. One larger BEAM node is the initial vertical scaling path; more identical replicas behind a load balancer are the horizontal path. No sticky sessions are required.

**Clustering is not the database.** DNSCluster discovers named nodes; PubSub is available for future wakeups, not durable data or ordering. PostgreSQL transactions serialize writes **within one vault**, allocating a committed-prefix sync cursor across replicas. Independent vaults do not share that row lock. The prototype holds this lock while a bounded object upload completes: simple and correct for small records, but hot-vault throughput and storage latency must be measured before optimizing.

Immutable encrypted records live in commodity object storage, not Postgres, Redis, or replicated BEAM memory. Their Postgres metadata consists of vault credentials' hashes, byte counters, record IDs, sequence numbers, digests, sizes, and creation timestamps. Lists are indexed and paginated in batches of 100. Defaults cap each vault at **100 MiB / 10,000 records**, with a 1 MiB per-record request limit; byte quotas are enforced under the same database lock. Object storage can grow independently; Postgres remains a capacity/planning boundary, not magically limitless because the API is clustered. At larger scale, partition metadata by vault and retain one write authority per vault.

Automatic composer drafts use one separate, replaceable **client-encrypted blob,
at most 1 MiB per vault**, in PostgreSQL's `vault_drafts` table. Keeping the blob
and its digest in the same row permits atomic conditional writes without creating
an immutable record on every typing pause. This storage is separate from the
immutable-record byte/sequence quotas. The server never receives plaintext,
version clocks or content keys. Database backups now include this bounded
ciphertext as well as metadata; capacity planning must account for it.

Storage cost includes requests and egress, not just bytes. Batch small events, avoid listing entire histories, choose a bucket in the API's region, and plan encrypted snapshot/compaction and deletion before lifting prototype quotas. Content-addressed keys make retries reuse an object. A failed database commit after a successful S3 upload can leave an unreferenced object; production needs a grace-period reconciliation job against committed metadata. Never apply a blanket age-based bucket expiry to live encrypted history. No reconciliation/deletion worker is shipped yet.

## Run the sync prototype

Use the pinned toolchain in `mise.toml` (`mise install`). Provision **disposable local PostgreSQL** and a private S3-compatible bucket; MinIO works for development. The example credentials below are only for your own disposable local services, not shared infrastructure.

From `server/`:

```sh
export DATABASE_URL=ecto://habibi@127.0.0.1:5432/habibi_dev
export S3_ENDPOINT=http://127.0.0.1:9000
export S3_BUCKET=habibi
export AWS_REGION=us-east-1
export AWS_ACCESS_KEY_ID=your-local-access-key
export AWS_SECRET_ACCESS_KEY=your-local-secret-key
export ALLOW_REGISTRATION=true

mise exec -- mix deps.get
mise exec -- mix assets.deploy
mise exec -- mix ecto.setup
PHX_SERVER=true mise exec -- mix run --no-halt
```

Create the bucket using your storage service's tooling first. Omit `S3_ENDPOINT` to use the normal regional AWS S3 endpoint. The API defaults to loopback port 4000 outside production. Run the disposable round-trip example from the repository root:

```sh
node --test client/vault.test.mjs
# Complete the local browser OAuth flow below, then set its access token securely.
node client/demo.mjs
```

The demo creates a disposable vault, encrypts locally, uploads/retries, lists/downloads, decrypts locally, restores an encrypted recovery bundle, and checks unauthorized access. It deliberately never prints keys or tokens and does not persist a recovery kit.

The API is small:

| Method | Route | Contract |
| --- | --- | --- |
| POST | `/v1/vaults` | JSON `{ "id": "<client UUID>", "token": "<random 32-byte base64url>" }`; no content keys |
| PUT | `/v1/vaults/:id/records/:record_id` | Raw envelope, `Content-Type: application/octet-stream`; 201 new, 200 identical retry, 409 replacement |
| GET | `/v1/vaults/:id/records?after=0` | Up to 100 metadata entries plus the next cursor |
| GET | `/v1/vaults/:id/records/:record_id` | Raw encrypted bytes |
| GET | `/health` | Process liveness, not a storage-readiness check |
| GET | `/ready` | Database connectivity and initial sync schema; 503 until migrations complete |

Every vault API operation requires `Authorization: Bearer <OAuth access token>`. Record operations additionally require `X-Habibi-Vault-Token: <sync token>`. This replaces the prototype's capability-only Authorization header. Neither credential decrypts content. There is deliberately no account-to-vault ownership mapping: another authenticated account still needs the separate vault capability. No bearer tokens in URLs. Responses have `Cache-Control: no-store`; parameter and SQL-query logging are disabled. The metadata digest is an upload identity check, not a substitute for client GCM authentication. Clients must decrypt/authenticate records before accepting them as history. The local demo reads its OAuth token from `HABIBI_ACCESS_TOKEN`; never commit it or put it on a command line.

### Server-backed Kit locks

Trusted Kit hosts can coordinate across devices using **PostgreSQL leases**,
shared by every server replica. Locks require both the OAuth access token and
`X-Habibi-Vault-Token`. Keep one stable random lock UUID per shared resource in
encrypted state; do not send provider names or credentials as lock identifiers.
Each acquisition uses a fresh random 32-byte base64url owner token; the server
stores only its hash. Lock ownership tokens are not provider refresh tokens.

| Method | Vault-relative route | JSON body |
| --- | --- | --- |
| PUT | `/locks/:id` | `{ "token": "<owner token>" }` |
| POST | `/locks/:id/renew` | `{ "token": "<owner token>", "generation": 1 }` |
| DELETE | `/locks/:id` | `{ "token": "<owner token>", "generation": 1 }` |

Acquire/renew return `{id,generation,expires_at,lease_seconds:30,cursor}`.
Contention returns **423** with `Retry-After: 1..5`; clients wait, then acquire
and sync through the returned cursor before reading credentials. Renew before
expiry during long operations. Expiry uses the database clock. Renew/release
require the current owner and generation, preventing an old client from
releasing its successor's lock. Acquire retries with the same active owner are
idempotent but do not extend expiry. Each vault supports 32 distinct lock IDs,
including released generation tombstones; reuse stable IDs.

[`acquireKitLock`](client/kit-locks.mjs) is the reference **trusted-host** API.
Supply `{vaultId,lockId,request,signal}`, where `request(path,init)` binds a fixed
Habibi origin and adds both authorization headers. It waits on contention
(cancellable, two-minute default), then returns `cursor`, `generation`,
`expiresAt`, `renew()`, `release()` and `headers()`. It does not auto-renew or
auto-release; release only after the replacement ciphertext is durably uploaded.
Attach its three `X-Habibi-Lock-*` headers to the record PUT to reject stale
publication inside the same database transaction. An identical immutable record
retry still succeeds after expiry because it publishes nothing new. Unfenced
record APIs retain their existing behavior. This API is not exposed to guest
JavaScript or model tools.

**A lease alone does not make token rotation crash-safe.** A paused old client
can still contact a third party, and a lost refresh response can lose its new
token. A refresh implementation must publish an encrypted in-progress marker
before the provider call, re-read state after waiting, fence the replacement
upload, and require recovery/reconnection on an ambiguous outcome. Generic
locking does not provide provider-side exactly-once execution. The native
GitHub Kit currently requires reconnection on expiry; automatic refresh and
its durable recovery protocol are not wired yet. The server never receives or
refreshes provider credentials. The additive lock migration must be applied
before deploying the new server; no shared database was migrated here.

## Native app authentication

The server implements a deliberately narrow OAuth profile using Boruta 2.3.8: **public native clients, authorization code with mandatory S256 PKCE, rotating refresh tokens, and revocation**. Browser identity uses discoverable passkeys verified by Wax, with required user verification and explicit CSRF-protected consent. Accounts are random pseudonymous IDs, not email addresses. Authentication does not recover or release vault encryption keys. This is OAuth, not OpenID Connect; no ID tokens, password grants, implicit flow, userinfo or third-party provider login are exposed.

1. Discover `/.well-known/oauth-authorization-server` at the configured canonical origin. In production, set `PHX_HOST=habibi.fyi`; HTTPS and Secure cookies are mandatory. Passkeys are bound to this relying-party domain.
2. POST JSON to `/oauth/register`, for example:

   ```json
   {"client_name":"Habibi for iPhone","application_type":"native","redirect_uris":["fyi.habibi.ios:/oauth/callback"],"token_endpoint_auth_method":"none","grant_types":["authorization_code","refresh_token"],"response_types":["code"],"scope":"vaults:sync"}
   ```

   No client secret is returned. This profile accepts exact app-claimed HTTPS callbacks and reverse-domain, single-slash private schemes. Wildcards, credentials, fragments and query strings are rejected. Desktop HTTP loopback redirects and client metadata/key-fetch extensions are not supported. Registration does not prove that a client is an official Habibi app; the consent page displays its unverified name and callback. App/universal-link association files must be configured by the eventual native app.
3. Generate a fresh high-entropy verifier and state on the device. Open `/oauth/authorize` in **ASWebAuthenticationSession on iOS or a system-browser/custom-tab flow on Android**, never an embedded WebView. Send `response_type=code`, `client_id`, the exact `redirect_uri`, `scope=vaults:sync`, state (16–256 bytes), `code_challenge=BASE64URL(SHA256(verifier))`, and `code_challenge_method=S256`. The verifier is 43–128 RFC7636 unreserved characters. The browser signs in or creates a passkey account, then asks for consent.
4. Validate the callback's `state` and `iss` on the device. Exchange its single-use, 60-second code at `/oauth/token` using an `application/x-www-form-urlencoded` POST with `grant_type=authorization_code`, `client_id`, `code`, the original `redirect_uri`, and `code_verifier`. Access tokens last 15 minutes. `GET /v1/me` returns only the pseudonymous `sub`.
5. Refresh with a form POST containing `grant_type=refresh_token`, `client_id`, and `refresh_token`. Persist the returned replacement atomically in Keychain/Keystore-backed storage and **serialize refreshes**. Reuse of a spent refresh token or correctly bound authorization code invalidates its entire grant, including descendants. Concurrent duplicate exchanges are not idempotent: one may succeed, but the replay invalidates that success. Grants have an absolute 30-day lifetime; sign in again afterward.
6. Disconnect with a form POST to `/oauth/revoke` containing `client_id`, `token`, and optionally `token_type_hint`. Either an access or refresh token revokes its whole grant. Unknown or wrong-client tokens return the same success response. Browser logout only drops the browser session; it does not disconnect native grants or rotate vault credentials.

Authorization codes and access/refresh credentials are stored as SHA-256 digests. PostgreSQL grant-row locks serialize exchange, replay handling and revocation across replicas; authorization reads bypass application caches. Keep grant/token ancestry until its replay-retention policy is designed; do not run Boruta's stock inactive-token cleanup. Passkey public keys, pseudonymous account IDs, client registrations and authentication metadata are necessarily visible to the server; private passkey keys and vault content keys remain on devices. This does not hide network/access metadata.

`ALLOW_REGISTRATION=true` enables both account creation and dynamic client registration locally; production remains closed by default. Authentication endpoints have a shared PostgreSQL 60-request/minute limit per socket peer and route. Untrusted forwarded headers cannot bypass it; behind an ingress, users may conservatively share that limit. This is not a complete abuse-prevention system.

Native development clients implement this OAuth flow separately from local-vault onboarding. Extra-passkey enrollment, account recovery, account deletion and token cleanup remain unimplemented. Losing the only passkey loses that account; **vault recovery still requires the separately held recovery key and exported encrypted bundle**. This implementation remains experimental and needs a security review before sensitive use.

For API tests, use a **separate disposable database**:

```sh
export DATABASE_URL=ecto://habibi@127.0.0.1:5432/habibi_test
MIX_ENV=test mise exec -- mix ecto.setup
MIX_ENV=test mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
```

Tests use real PostgreSQL transactions and process-local object storage; `client/demo.mjs` additionally exercises the real configured S3 adapter. Neither is an independent cryptographic audit or load test.

## Deployment boundary

The **site is deployable independently now**. The sync backend remains a development prototype, not a public service. Registration is disabled unless `ALLOW_REGISTRATION=true`; do not enable it publicly before authenticated onboarding, durable abuse/rate controls, operational deletion/reconciliation, and security review exist.

For a native release, run `npm ci && npm run build` at the root, then `MIX_ENV=prod mise exec -- mix release` in `server/`. In production configure `DATABASE_URL`, S3 credentials/bucket/region, `SECRET_KEY_BASE`, `PHX_SERVER=true`, and a shared secret `RELEASE_COOKIE`. Run migrations once as a separate release step, never on every replica boot. Put HTTPS at the ingress; keep PostgreSQL, the bucket, and Erlang distribution private. Use bucket-scoped credentials, encrypted database backups, a bounded total database connection budget across replicas, and redact authorization headers in infrastructure logs.

For DNS clustering set `DNS_CLUSTER_QUERY` to a private headless service resolving only this deployment's replicas, and `POD_IP` to each replica's address. The release names nodes `habibi@<POD_IP>`. Restrict EPMD/distribution ports to trusted peers; use secure private transport or distribution TLS. Never reuse a cookie across unrelated environments or expose distribution publicly. `BIND_IP`, `PORT`, and `POOL_SIZE` configure listening and per-replica database connections. Clustering does not remove the need for Postgres and object-storage redundancy or backups.

### Container releases

Build locally without publishing, from the root:

```sh
docker build -f server/Dockerfile --target runner -t habibi:local .
mise run release:check
mise run release:notes
mise run release:test
```

The image runs as an unprivileged user and contains the OTP release plus generated marketing and authentication assets, not Node, npm, Mix, or source credentials. The local release commands only inspect committed history; they reject unborn or dirty worktrees and never create tags, commits, images, or GitHub releases.

`.github/workflows/release.yml` adapts [Tuist's tag-derived release flow](https://github.com/tuist/tuist/blob/650d726f3831d80785b47eaaed311a648aa4408f/.github/workflows/server-production-deployment.yml): pushes to `main`, including merges, or a manual dispatch on `main` ask git-cliff whether a combined server/marketing release is needed. A no-op skips publication; a release runs CI, builds and pushes `ghcr.io/pepicrft/habibi:<version>`, publishes the matching OCI Helm chart, creates the GitHub Release/tag at the exact built SHA, then promotes that digest to `latest`. Publication is serialized across runs. New Git tags use `habibi@x.y.z`; the already-published `server@0.1.0` remains a version baseline. Image references use `:version`, because OCI reserves `@` for content digests. There are no release/version commits back to `main`.

Git-cliff is pinned to Tuist's 2.6.0. Relevant conventional `fix`, `docs`, `perf`, `refactor`, `style` and `test` commits bump patches, `feat` bumps minors, and breaking changes bump majors, including during 0.x. Server, marketing, deployment charts, root build files and release automation define the release boundary; scopes are not restricted to `(server)`. Client-only changes and ordinary `chore`/`ci` commits do not trigger releases. Only reachable stable `habibi@x.y.z` and legacy `server@x.y.z` tags participate, ordered by numeric version; prerelease and unrelated-branch tags do not affect the version. Squash merges need a conventional commit title; ordinary merges retain the conventional commits from their branch. Configuration/tool failures fail visibly rather than becoming a successful no-op.

The initial release requires a committed repository. No image, tag, package-visibility setting or release has been published by adding this workflow. GHCR publication uses the repository's `GITHUB_TOKEN` with `packages: write`, not a personal token. GHCR packages are initially private; making one public is a separate operator action. CI currently publishes `linux/amd64`; the Dockerfile can also build natively on arm64, but there is no multi-architecture manifest yet.

Registry and GitHub publication are not atomic. If a publication step fails, rerun the failed job at the original SHA before starting a newer release. A retry after the GitHub tag was created reuses the existing image digest and leaves release notes untouched. Never force-move a published tag. The workflow does not access Kubernetes: production Flux watches the promoted `latest` digest and performs deployment separately.

### Install with Helm

The release workflow publishes `oci://ghcr.io/pepicrft/charts/habibi` with chart `version` and `appVersion` set to the git-cliff release number. Installing chart X selects application image X for both web and migration workloads. Explicit `image.repository`, `image.tag` and `image.digest` overrides remain supported. Retries compare extracted chart contents, reuse identical publications and reject conflicts. No chart has been published by these local changes yet.

For self-hosting without the production cluster's custom operators, copy `deploy/values-external.yaml` to your own values file. This mode renders only ordinary Kubernetes resources. Provision PostgreSQL and a private S3-compatible bucket separately, then create the referenced Secrets in the target namespace. The chart does not create, migrate or delete your external infrastructure; its migration Job does apply Habibi's database migrations when installed or upgraded.

- `external.existingSecret` contains `DATABASE_URL`, a persistent random `SECRET_KEY_BASE` (at least 64 bytes), a separate random `RELEASE_COOKIE`, `S3_BUCKET`, `AWS_REGION`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Include `S3_ENDPOINT` for non-AWS storage; omit it for regional AWS S3. Use bucket-scoped credentials and your secret-management tooling, not Git or command-line literals.
- `external.databaseCASecret` contains `ca.crt`, mounted read-only in both workloads for verified PostgreSQL TLS. The example enables it. Emptying this setting disables certificate-based TLS configuration and is only appropriate for disposable local setups.
- Set `host` to your HTTPS origin. The example exposes a ClusterIP service only; configure `ingress.enabled`, the nginx ingress controller/certificate issuer, and `networkPolicy.ingressNamespace` for your cluster before browser authentication. The ingress policy expects nginx controller labels. Keep Erlang distribution private.
- Anonymous installation requires **both** the chart and application image packages to be public. Their GHCR visibility settings are separate operator actions. For a private chart, use `helm registry login ghcr.io`; for a private image, enable `imagePullSecret` and set `imagePullSecret.existingSecret` to a pre-created registry Secret. The external example assumes public images.

After a release has published both artifacts:

```sh
VERSION=<published-version>
helm upgrade --install habibi oci://ghcr.io/pepicrft/charts/habibi \
  --version "$VERSION" \
  --namespace habibi --create-namespace \
  --values habibi-values.yaml \
  --wait --wait-for-jobs
```

Back up the external database, bucket and runtime Secrets; the operator cannot restore vault content keys. Registration remains disabled by default. Existing Flux deployments retain the operator-managed mode (`platform.enabled=true`) described below, including their explicit image digest pins.

### Pepicrft cluster deployment

`deploy/helm/habibi` and `deploy/values-production.yaml` define the production application. The companion declarations in `pepicrft/indie` register the chart source, Flux image automation, `habibi` namespace, and `habibi.fyi` in the platform's allowed domains. The ingress requests a certificate from the existing issuer and lets ExternalDNS manage the apex record. No manual address or second load balancer is required. The current cluster uses amd64 nodes, matching the release image.

Flux polls only the release-promoted `latest` tag, records its immutable digest in `indie`, and upgrades the Helm release. Chart configuration follows application `main`; image promotion follows successful stable releases. The initial release stays suspended until the first real digest is recorded, then requires one Git change to unsuspend it. See the [infrastructure bootstrap runbook](https://github.com/pepicrft/indie/blob/main/infra/docs/habibi.md). No cluster, package, certificate, bucket, or DNS mutation occurs merely by preparing these files.

The chart runs two non-root replicas with read-only filesystems and private Erlang peer traffic. PostgreSQL verifies its server certificate using the cluster's certificate authority. A separate, revision-scoped migration Job runs `Habibi.Release.migrate()`; web replicas never migrate on boot. Readiness waits for database connectivity and the initial schema. Future schema changes must remain compatible with the previous image during rolling upgrades; automatic application rollback does not undo migrations.

Metadata initially uses one PostgreSQL instance on a 10 GiB volume, with daily backups and seven-day database-backup retention. This is a low-cost starting point, not a highly available database. Ciphertext uses a separate retained Hetzner bucket with no automatic content expiry. The existing object-storage controller distributes a project-wide credential, not bucket-isolated credentials; this is an operational isolation limitation, not access to vault decryption keys. Registration stays disabled until the sync service is ready for real users.

Application runtime secrets are generated once by the cluster's existing External Secrets controller; Git stores no secret values. Registry pulls use the existing shared read credential, which must cover the Habibi package. The namespace receives the standard analytics host/write-key wiring, but this does not add browser scripts or event collection. Habibi's no-analytics behavior remains unchanged; instrumentation requires a separate privacy decision.

```sh
mise exec -- helm lint deploy/helm/habibi --values deploy/values-production.yaml
mise exec -- npm run test:deploy
```

## Architecture references

- **Atlas:** its [native workspace](https://github.com/tuist/tuist/blob/78afe3211abf60c843bf479b04b941061efc86d7/atlas-native/AGENTS.md) separates Swift/Kotlin presentation from shared Rust protocol/session state and uses a scoped Once build graph. Habibi's native prototype follows that build/presentation split, while keeping the server and website independent. Atlas's [server run loop](https://github.com/tuist/tuist/blob/78afe3211abf60c843bf479b04b941061efc86d7/atlas/lib/atlas/orbit/runs.ex#L380-L435) reads conversations and executes inference; copying that data placement would violate Habibi's operator-blind boundary.
- **Signal:** the [Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/) and [linked-device history transfer](https://signal.org/blog/a-synchronized-start-for-linked-devices/) distinguish live session keys from recoverable history archives. Habibi borrows endpoint key custody, not Signal's protocol or its forward-secrecy guarantees.
- **Search:** inspected [Signal Android search](https://github.com/signalapp/Signal-Android/blob/16f138410a4ab940864a2791ae281dd1b2318611/app/src/main/java/org/thoughtcrime/securesms/database/SearchTable.kt#L28-L145) uses a local SQLite FTS5 index inside its SQLCipher-encrypted database. Telegram's [Cloud Chats are not E2EE](https://telegram.org/faq#secret-chats); its [iOS client](https://github.com/TelegramMessenger/Telegram-iOS/blob/fb0e62ba8a147f0821da6aa63c09da7d79a10111/submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift#L308-L648) searches Secret Chats locally but uses remote APIs for cloud/global queries. Habibi's planned keyword and semantic retrieval stay local; no search index is implemented yet.
- **Provider access:** Native onboarding offers an experimental **Connect with ChatGPT** device-code flow using the public Codex client also used by Pi's legacy provider, with direct device-to-OpenAI inference and device-local credentials. See [native setup and limitations](native/README.md#connect-chatgpt). Pi now prefers [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) with dynamic app-specific registration; native callback support and approval for Habibi's use of the legacy client remain unverified. Ordinary API billing is not assumed to be included in a ChatGPT subscription. Opt-in host CLI development bridges remain separate.

## License

MIT. See [LICENSE](LICENSE). Bundled fonts retain their own SIL Open Font Licenses.
