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

An independent static deployment is still possible: publish only `server/priv/static/marketing/`, never the repository root. Set the custom domain to `habibi.fyi` and enable HTTPS. No hosting account or DNS changes are made here.

### Locales

Following Tuist's Gettext convention, English source uses `dgettext("marketing", "English source")`. The generated template is `server/priv/gettext/marketing.pot`; translations belong in `server/priv/gettext/<locale>/LC_MESSAGES/marketing.po`. Eleventy consumes these catalogues at build time rather than introducing runtime translation into Phoenix.

```sh
npm run gettext:extract  # from the repository root
npm run gettext:check    # fails on stale source extraction; also runs during build
```

From `server/`, `mix gettext.extract` invokes the same extractor and `mix assets.deploy` builds the site after `npm ci` has been run at the root. Extraction never merges or rewrites `.po` files. Translation automation or contributors can use standard Gettext/Weblate tooling; no external translation service or credentials are configured. Keep translated values as plain text, not HTML.

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

Record operations require `Authorization: Bearer <sync token>`. No tokens in URLs. Responses have `Cache-Control: no-store`; parameter and SQL-query logging are disabled. The metadata digest is an upload identity check, not a substitute for client GCM authentication. Clients must decrypt/authenticate records before accepting them as history.

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

The image runs as an unprivileged user and contains the OTP release plus generated marketing assets, not Node, npm, Mix, templates, or source credentials. The local release commands only inspect committed history; they reject unborn or dirty worktrees and never create tags, commits, images, or GitHub releases.

`.github/workflows/release.yml` adapts [Tuist's tag-derived release flow](https://github.com/tuist/tuist/blob/650d726f3831d80785b47eaaed311a648aa4408f/.github/workflows/server-production-deployment.yml): pushes to `main`, including merges, or a manual dispatch on `main` ask git-cliff whether a combined server/marketing release is needed. A no-op skips publication; a release runs CI, builds and pushes `ghcr.io/pepicrft/habibi:<version>`, creates the GitHub Release/tag at the exact built SHA, then promotes that digest to `latest`. Publication is serialized across runs. New Git tags use `habibi@x.y.z`; the already-published `server@0.1.0` remains a version baseline. Image references use `:version`, because OCI reserves `@` for content digests. There are no release/version commits back to `main`.

Git-cliff is pinned to Tuist's 2.6.0. Relevant conventional `fix`, `docs`, `perf`, `refactor`, `style` and `test` commits bump patches, `feat` bumps minors, and breaking changes bump majors, including during 0.x. Server, marketing, deployment charts, root build files and release automation define the release boundary; scopes are not restricted to `(server)`. Client-only changes and ordinary `chore`/`ci` commits do not trigger releases. Only reachable stable `habibi@x.y.z` and legacy `server@x.y.z` tags participate, ordered by numeric version; prerelease and unrelated-branch tags do not affect the version. Squash merges need a conventional commit title; ordinary merges retain the conventional commits from their branch. Configuration/tool failures fail visibly rather than becoming a successful no-op.

The initial release requires a committed repository. No image, tag, package-visibility setting or release has been published by adding this workflow. GHCR publication uses the repository's `GITHUB_TOKEN` with `packages: write`, not a personal token. GHCR packages are initially private; making one public is a separate operator action. CI currently publishes `linux/amd64`; the Dockerfile can also build natively on arm64, but there is no multi-architecture manifest yet.

Registry and GitHub publication are not atomic. If a publication step fails, rerun the failed job at the original SHA before starting a newer release. A retry after the GitHub tag was created reuses the existing image digest and leaves release notes untouched. Never force-move a published tag. The workflow does not access Kubernetes: production Flux watches the promoted `latest` digest and performs deployment separately.

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
