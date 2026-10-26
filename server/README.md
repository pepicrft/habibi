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
