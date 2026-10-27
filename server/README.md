# Server capability discovery

`GET /v1/capabilities` is a public, unauthenticated deployment feature document,
separate from `/.well-known/oauth-authorization-server`. It returns HTTP 200 with
`Content-Type: application/json; charset=utf-8` and `Cache-Control: no-store`.
No account, cookie, bearer token, or vault token is required.

For a deployment with registration disabled, the version 1 response is:

```json
{
  "version": 1,
  "authentication": {
    "passkeys": true,
    "phone": false,
    "accountRegistration": false
  },
  "oauth": { "dynamicClientRegistration": false },
  "sync": { "encryptedSnapshots": true, "vaultCreation": false },
  "themes": { "catalog": "/assets/themes.json" }
}
```

`accountRegistration`, `dynamicClientRegistration`, and `vaultCreation` all reflect
the current server `:allow_registration` setting (`ALLOW_REGISTRATION=true` outside
tests). Passkey login and encrypted snapshot sync remain supported when registration
is closed; existing sync still requires both account authentication and the vault
token. Phone authentication is not implemented and is always advertised as `false`.
The theme catalog is a fixed path relative to the selected server origin.

This document describes support and policy, not service health or authorization.
It contains no per-user data and accepts no request overrides. Clients may use it
to adapt optional sync setup, but all existing endpoint checks remain authoritative.
OAuth metadata is unchanged, including its registration endpoint even when new
client registration is disabled. Existing native clients need a follow-up to consume
this document and distinguish account, OAuth client, and vault creation from login
and existing sync; capability discovery must not gate offline vault creation or
recovery, or relax OAuth/PKCE or encryption checks.

## Encrypted composer drafts

`GET /v1/vaults/:vault_id/drafts` and `PUT /v1/vaults/:vault_id/drafts` use the
existing `vaults:sync` OAuth scope and `X-Habibi-Vault-Token`. Responses use
`Cache-Control: no-store`. This channel is distinct from immutable snapshots;
capability discovery's `encryptedSnapshots` field does not advertise it.

GET returns 404 before a draft exists, otherwise raw HAB1 bytes with a quoted
SHA-256 `ETag`. PUT requires `Content-Type: application/octet-stream` and either
`If-None-Match: *` for creation or `If-Match: "<digest>"` for replacement. A
successful PUT returns 204 and the resulting ETag. Missing/invalid preconditions
return 428; stale writes return 412. An exact-byte retry of the current blob
succeeds. Clients must merge authenticated plaintext locally before retrying a
stale write; the server cannot inspect or merge versions.

Apply migration `20261028000000_create_vault_drafts` as a separate deployment
step. One row per vault stores at most 1 MiB of client-encrypted ciphertext and
its digest in PostgreSQL, under the existing per-vault transaction lock. This
bounded mutable row does not increment immutable record sequence/byte quotas or
create S3 objects. Include it in database capacity planning and backups. Existing
immutable record endpoints and old-client snapshot formats are unchanged.
