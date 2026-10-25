# Habibi

An open-source personal AI companion, in the making. The static home is designed for **https://habibi.fyi**.

This repository contains an Eleventy website, an Elixir/Phoenix ciphertext-sync prototype, and an executable Web Crypto reference client. **There is no released mobile app. The sync protocol is experimental and has not been independently audited. Do not entrust it with real personal data yet.**

## Run the website

```sh
npm ci
npm run dev
```

Marketing source lives in `server/marketing/`. Eleventy listens on port 8080 and `npm run build` produces `server/priv/static/marketing/`. The pages contain no runtime JavaScript, analytics, or external font requests. Fonts and licenses are bundled locally.

The Docker build renders the site before assembling the Elixir release. Phoenix serves the generated pages, assets, robots and sitemap alongside the API; Node and Eleventy are not present in the runtime image. HTML is publicly cacheable, while sync API responses retain `Cache-Control: no-store`. Unknown API paths return JSON, not the marketing 404 page.

`/changelog/` lists verified published server/website releases using a checked-in, translatable snapshot in `server/marketing/site/changelog.njk`. Its source comment documents updating the snapshot from GitHub's published release dates and git-cliff notes, then regenerating the marketing catalogue. Local changes and planned mobile features are not listed as released. The page does not fetch GitHub during builds or browsing and is not automatically updated by publication.

An independent static deployment is still possible: publish only `server/priv/static/marketing/`, never the repository root. Set the custom domain to `habibi.fyi` and enable HTTPS. No hosting account or DNS changes are made here.

### Shared UI theme

**`server/priv/theme.json` owns the design tokens**, independently of OAuth credentials and vault keys. It follows the [Theme UI theme specification](https://theme-ui.com/theme-spec): semantic colors, fonts, type/spacing scales, radii, and shared styles/variants. The marketing and sign-in pages use Theme UI's actual framework-agnostic `@theme-ui/css` resolver at build time. Both load the generated `/assets/theme.css`, including local font faces and the primary-button variant; their own CSS keeps page layout and illustration geometry. No React or styling JavaScript ships in marketing pages.

Change the server theme, then run `npm run build` (or use the theme-aware development watcher). The build also exposes the same object at `/assets/theme.json`. `client/theme.mjs` re-exports the server source for bundling and offline startup; a future React UI can pass it directly to `ThemeUIProvider`. There is no mobile UI yet, and native views will need a platform adapter for CSS font/length values and native materials. Clients do not automatically download or execute remote presentation code. Build tests change tokens and verify that CSS, metadata, public JSON and the client export agree.

The favicon and SVG share card are also rendered from server tokens, in `site/favicon.njk` and `site/social.njk`. `site/assets/social.png` is a checked-in 1200×630 raster export of the generated `/assets/social.svg`; refresh that export when changing its copy or theme.

The build also emits `/assets/nsh-theme.json`, mapping the same semantic colors, fonts, spacing and radius into [NSH's theme format](https://nsh.dev/). NSH is not React and does not consume `ThemeUIProvider` or `sx`. This is a generated theme adapter, not an installed or verified native runtime; native font availability and platform materials still need testing in the eventual app. Only the light palette ships today.

Habibi's mascot is **Heartling**, an asymmetric clay heart with tiny feet. Its generated artwork was converted to neutral grayscale, cleaned of stray alpha, and aligned on a shared baseline. The transparent poster, eight-frame atlas and platform-neutral frame map live in `server/marketing/site/assets/mascot/` and ship under `/assets/mascot/`. Four expressions (idle, curious, sleepy, attentive) accompany a four-frame, 800ms ambient walk. The smaller poster loads by default; expression or walking states load the atlas.

The mascot's body follows the active theme's **`colors.primary`**, not a fixed terracotta image or a separate palette. The web renderer hard-light blends the neutral texture over that color, then masks the result with the texture's alpha, preserving the clay shading and dark eyes. Updating `--theme-ui-colors-primary` recolors it immediately. Use `<span class="heartling" aria-hidden="true"></span>` after loading `heartling.css`; add `data-state="curious"`, `sleepy`, `attentive`, or `walk` as needed. Motion is opt-in and stops with `prefers-reduced-motion`. Describe actual work or errors in separate localized text, never with the mascot alone.

For the future native host, bundle the same PNGs and `heartling.json`: frames are row-major, 384×384 pixels; resolve its `tintToken` against the **selected** Theme UI palette (or NSH `primary`), hard-light blend the cropped texture over the resolved color, and apply the cropped alpha as a mask. Re-resolve on theme changes rather than baking a tint into cached frames. Native materials, compositing, animation and theme selection are not implemented or verified yet; this is a reusable asset contract and a working web renderer, not a mobile feature claim.

The [Shadowfax website, iOS screenshots and changelog](https://www.krispuckett.com/shadowfax) inform the design: warm paper, readable ink, restrained sans-serif type, quiet separators, and contextual cards. The homepage's original conversation study uses native HTML disclosure to reveal a fictional source note, not a running agent or released mobile app. No reference artwork or media is distributed. Native glass, sheets, widgets and accessibility should use platform components rather than copying web effects; those mobile features remain unimplemented.

The intended native conversation model is an answer plus small, interactive objects: choices, editable lists, reminders, source-backed previews and contextual follow-up suggestions. Keep suggested, approved, saved and completed states distinct, with explicit progress, stop and undo actions. A compact card may expand into a focused surface without losing its place in the thread; any doorway transition should use original Habibi artwork, support reduced motion and have an ordinary accessible open action. Optional ambient animation must not masquerade as real agent progress.

Ongoing tasks (the reference's “quests”) should retain an inspectable goal, permission scope, activity and stop/approval controls. Sustained background work belongs on the user's paired runner rather than assuming an iOS app can run indefinitely or moving readable conversations onto Habibi's sync server. Lock Screen and Live Activity presentation should hide sensitive content by default; push payloads must not become a plaintext side channel. Voice capture needs explicit recording feedback and a deliberate on-device or user-approved transcription destination.

For a future NSH host, Rust components ship compiled with the app; downloadable components use sandboxed JavaScript/TSX. Generated components must receive only the content and named actions needed for that answer, never vault keys, OAuth credentials or arbitrary tool/network access. Explicitly deny unneeded capabilities: NSH's omitted capability declaration is not a deny-all default, and registered native components need host-side checks. Generation belongs on the device or a user-controlled paired runner, not the blind sync service. Lock Screen capture, Live Activities/Dynamic Island, widgets and background execution require native targets and platform permission handling. Dynamic downloaded code also needs review against Apple's current App Store rules (including 2.5.2 and 4.7); sandboxing alone does not establish eligibility. None of these native features is implemented here yet.

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
- A separate random **256-bit recovery key** encrypts an exported recovery bundle containing the vault ID, content key, and sync token. Keep the bundle and recovery key separately. **Both are required** to recover without an authorized device. The operator cannot reset encryption. This prototype exports the bundle; it does not automatically back it up or implement a recovery UI.
- Inference and tools execute from the authorized device, or eventually a paired user-controlled runner. A chosen remote model provider **does receive the selected readable prompts**. Connecting a provider does not make that provider blind. No inference relay or provider credential storage is implemented on this server.
- Keyword and semantic indexes stay local, protected by device storage. Native apps must wrap vault keys using platform secure storage; the JavaScript reference keeps them in process memory and is **not** a mobile key-storage implementation.

### Exact record format

All lengths below are bytes. `client/vault.mjs` is the executable reference; its tests also decrypt using Node's independent HKDF/AES APIs.

```text
"HAB1" (4) | random salt (32) | random nonce (12) | ciphertext | GCM tag (16)
```

The total maximum is **1 MiB**, leaving 1 MiB minus 64 bytes for plaintext. Inputs are raw bytes, not JSON/base64-expanded ciphertext. UUIDs use lowercase canonical text. For ordinary records, UTF-8 context is `habibi/record/v1\0{vault UUID}\0{record UUID}`; `\0` denotes a zero byte. The context is HKDF `info`; the first 48 header bytes concatenated with the context are GCM additional authenticated data. Recovery uses domain-separated context `habibi/recovery/v1\0{vault UUID}` with the same envelope format. Recovery bundle version is 1, and its envelope and keys use unpadded base64url.

An encrypted record is immutable. **Retry the exact prepared envelope with the same record ID**, not a fresh encryption of the same plaintext: randomized re-encryption produces different bytes and correctly conflicts. Multiple events may be batched inside one encrypted record to reduce storage requests and metadata rows.

### What this does not protect

The operator still sees vault/record IDs, encrypted sizes, timestamps, access patterns, and network metadata. Framing checks cannot prove that a malicious client encrypted its input. Endpoint compromise, malicious client updates, provider retention, and deliberate tool disclosures are separate risks.

This vault format has **no messenger-style forward secrecy**: compromise of the content key exposes retained records for that key. Authentication detects changed bytes and identity substitution; it does **not** prove that a malicious server returned complete, fresh history. Sync sequence numbers are server metadata, not signed rollback proofs. Device pairing, independent device credentials, revocation with new key epochs, signed history consistency, content deletion/compaction, and native key storage must be designed and reviewed before a real mobile release. A removed device cannot be made to forget previously decrypted data.

## Why Elixir and object storage

The API uses Phoenix/Bandit, Ecto/Postgres, DNSCluster, and Phoenix.PubSub. No vault is owned by a process or local disk. Any replica can authenticate, append, list, or download using the same Postgres and private S3-compatible bucket. One larger BEAM node is the initial vertical scaling path; more identical replicas behind a load balancer are the horizontal path. No sticky sessions are required.

**Clustering is not the database.** DNSCluster discovers named nodes; PubSub is available for future wakeups, not durable data or ordering. PostgreSQL transactions serialize writes **within one vault**, allocating a committed-prefix sync cursor across replicas. Independent vaults do not share that row lock. The prototype holds this lock while a bounded object upload completes: simple and correct for small records, but hot-vault throughput and storage latency must be measured before optimizing.

Encrypted bytes live in commodity object storage, not Postgres, Redis, or replicated BEAM memory. Postgres stores only vault credentials' hashes, byte counters, record IDs, sequence numbers, digests, sizes, and creation timestamps. Lists are indexed and paginated in batches of 100. Defaults cap each vault at **100 MiB / 10,000 records**, with a 1 MiB per-record request limit; byte quotas are enforced under the same database lock. Object storage can grow independently; Postgres remains a capacity/planning boundary, not magically limitless because the API is clustered. At larger scale, partition metadata by vault and retain one write authority per vault.

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

No native client, extra-passkey enrollment, account recovery, account deletion, or token-cleanup job is shipped yet. Losing the only passkey loses that account; **vault recovery still requires the separately held recovery key and exported encrypted bundle**. This implementation remains experimental and needs a security review before sensitive use.

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

- **Atlas:** its [native workspace](https://github.com/tuist/tuist/blob/78afe3211abf60c843bf479b04b941061efc86d7/atlas-native/AGENTS.md) separates Swift/Kotlin presentation from shared Rust protocol/session state and uses a scoped Once build graph. Habibi currently adopts pinned toolchains and independent site/server builds, not that native stack yet. Atlas's [server run loop](https://github.com/tuist/tuist/blob/78afe3211abf60c843bf479b04b941061efc86d7/atlas/lib/atlas/orbit/runs.ex#L380-L435) reads conversations and executes inference; copying that data placement would violate Habibi's operator-blind boundary.
- **Signal:** the [Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/) and [linked-device history transfer](https://signal.org/blog/a-synchronized-start-for-linked-devices/) distinguish live session keys from recoverable history archives. Habibi borrows endpoint key custody, not Signal's protocol or its forward-secrecy guarantees.
- **Search:** inspected [Signal Android search](https://github.com/signalapp/Signal-Android/blob/16f138410a4ab940864a2791ae281dd1b2318611/app/src/main/java/org/thoughtcrime/securesms/database/SearchTable.kt#L28-L145) uses a local SQLite FTS5 index inside its SQLCipher-encrypted database. Telegram's [Cloud Chats are not E2EE](https://telegram.org/faq#secret-chats); its [iOS client](https://github.com/TelegramMessenger/Telegram-iOS/blob/fb0e62ba8a147f0821da6aa63c09da7d79a10111/submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift#L308-L648) searches Secret Chats locally but uses remote APIs for cloud/global queries. Habibi's planned keyword and semantic retrieval stay local; no search index is implemented yet.
- **Provider access:** [Sign in with ChatGPT](https://developers.openai.com/siwc/llms-full.txt) documents a conditional open-source/local-app plan-usage route. Native callback support, eligibility, and granted inference scopes still need validation. This repository does not implement provider sign-in or inference and does not assume that ordinary API billing is included in a ChatGPT subscription.

## License

MIT. See [LICENSE](LICENSE). Bundled fonts retain their own SIL Open Font Licenses.
