import { test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv, hkdfSync } from "node:crypto";
import { createVault, encryptRecord, decryptRecord, createRecovery, recoverVault } from "./vault.mjs";

const message = new TextEncoder().encode("Remember: الأحد at 17:30, not Friday. 🔐");

test("record format interoperates with Node's independent HKDF and AES-GCM APIs", async () => {
  const vault = createVault();
  const id = crypto.randomUUID();
  const encrypted = await encryptRecord(vault.key, vault.id, id, message);
  const context = Buffer.from(`habibi/record/v1\0${vault.id}\0${id}`);
  const key = hkdfSync("sha256", vault.key, encrypted.slice(4, 36), context, 32);
  const decipher = createDecipheriv("aes-256-gcm", key, encrypted.slice(36, 48));
  decipher.setAAD(Buffer.concat([encrypted.slice(0, 48), context]));
  decipher.setAuthTag(encrypted.slice(-16));
  const plaintext = Buffer.concat([decipher.update(encrypted.slice(48, -16)), decipher.final()]);
  assert.deepEqual(plaintext, Buffer.from(message));
  assert.equal(Buffer.from(encrypted).includes(Buffer.from(message)), false);
});

test("tampering, wrong keys and moving a record between identities fail authentication", async () => {
  const vault = createVault();
  const id = crypto.randomUUID();
  const encrypted = await encryptRecord(vault.key, vault.id, id, message);
  for (const offset of [0, 4, 35, 36, 47, 48, encrypted.length - 1]) {
    const corrupted = encrypted.slice();
    corrupted[offset] ^= 1;
    await assert.rejects(decryptRecord(vault.key, vault.id, id, corrupted));
  }
  await assert.rejects(decryptRecord(createVault().key, vault.id, id, encrypted));
  await assert.rejects(decryptRecord(vault.key, crypto.randomUUID(), id, encrypted));
  await assert.rejects(decryptRecord(vault.key, vault.id, crypto.randomUUID(), encrypted));
  await assert.rejects(decryptRecord(vault.key, vault.id, id, encrypted.slice(0, 63)));
});

test("records are randomized and enforce the exact binary size boundary", async () => {
  const vault = createVault();
  const id = crypto.randomUUID();
  const first = await encryptRecord(vault.key, vault.id, id, message);
  const second = await encryptRecord(vault.key, vault.id, id, message);
  assert.notDeepEqual(first, second);
  for (const bytes of [new Uint8Array(), message, new Uint8Array(1024 * 1024 - 64).fill(173)]) {
    const encrypted = await encryptRecord(vault.key, vault.id, id, bytes);
    assert.equal(encrypted.length, bytes.length + 64);
    assert.deepEqual(await decryptRecord(vault.key, vault.id, id, encrypted), bytes);
  }
  await assert.rejects(encryptRecord(vault.key, vault.id, id, new Uint8Array(1024 * 1024 - 63)));
});

test("a separate recovery key restores secrets without putting them in the exported bundle", async () => {
  const vault = createVault();
  const { bundle, recoveryKey } = await createRecovery(vault);
  assert.notEqual(recoveryKey, vault.token);
  assert.equal(JSON.stringify(bundle).includes(vault.token), false);
  assert.deepEqual(await recoverVault(JSON.parse(JSON.stringify(bundle)), recoveryKey), vault);
  await assert.rejects(recoverVault(bundle, createVault().token));
  await assert.rejects(recoverVault({ ...bundle, vaultId: crypto.randomUUID() }, recoveryKey));
  await assert.rejects(recoverVault({ ...bundle, version: 2 }, recoveryKey));
});
