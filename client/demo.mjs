import assert from "node:assert/strict";
import { createVault, encryptRecord, decryptRecord, createRecovery, recoverVault } from "./vault.mjs";

// Disposable local smoke test. Never use real personal data in this example.
const origin = new URL(process.env.SYNC_URL || "http://127.0.0.1:4000");
if (!["127.0.0.1", "localhost", "[::1]"].includes(origin.hostname)) {
  throw new Error("This disposable demo only connects to a loopback server");
}

const vault = createVault();
const id = crypto.randomUUID();
const plaintext = new TextEncoder().encode("A private test note: water the balcony plants on Tuesday.");
const envelope = await encryptRecord(vault.key, vault.id, id, plaintext);
const headers = { authorization: `Bearer ${vault.token}` };
const path = `/v1/vaults/${vault.id}/records`;

const created = await fetch(new URL("/v1/vaults", origin), {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ id: vault.id, token: vault.token }),
});
assert.equal(created.status, 201);

const upload = () => fetch(new URL(`${path}/${id}`, origin), {
  method: "PUT", headers: { ...headers, "content-type": "application/octet-stream" }, body: envelope,
});
assert.equal((await upload()).status, 201);
assert.equal((await upload()).status, 200, "retry must not append or overwrite");

const listing = await fetch(new URL(path, origin), { headers }).then(response => response.json());
assert.equal(listing.records.length, 1);
assert.equal(listing.cursor, 1);
assert.equal(listing.records[0].id, id);

const download = await fetch(new URL(`${path}/${id}`, origin), { headers });
assert.equal(download.status, 200);
const downloaded = new Uint8Array(await download.arrayBuffer());
assert.deepEqual(downloaded, envelope);
assert.deepEqual(await decryptRecord(vault.key, vault.id, id, downloaded), plaintext);
const { bundle, recoveryKey } = await createRecovery(vault);
assert.deepEqual(await recoverVault(bundle, recoveryKey), vault);

const denied = await fetch(new URL(path, origin), {
  headers: { authorization: `Bearer ${createVault().token}` },
});
assert.equal(denied.status, 401);
console.log("Passed: create → encrypt → S3 sync → idempotent retry → list → download → decrypt → recover; wrong-token access denied.");
