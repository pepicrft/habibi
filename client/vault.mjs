// Reference format for native clients, not a production device-key store.
// All cryptography uses the platform Web Crypto implementation.
const text = new TextEncoder();
const utf8 = new TextDecoder("utf-8", { fatal: true });
const magic = text.encode("HAB1");
const maxBytes = 1024 * 1024;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function createVault() {
  return {
    id: crypto.randomUUID(),
    key: randomKey(),
    token: encode(randomKey()),
  };
}

export async function encryptRecord(key, vaultId, recordId, plaintext) {
  return seal(key, recordContext(vaultId, recordId), plaintext);
}

export async function decryptRecord(key, vaultId, recordId, envelope) {
  return open(key, recordContext(vaultId, recordId), envelope);
}

// Keep the exported bundle and its random recovery key in separate safe places.
// Neither the recovery key nor the unwrapped vault belongs on Habibi's server.
export async function createRecovery(vault) {
  validateVault(vault);
  const recoveryKey = randomKey();
  const contents = text.encode(JSON.stringify({
    id: vault.id,
    key: encode(vault.key),
    token: vault.token,
  }));
  const encrypted = await seal(recoveryKey, recoveryContext(vault.id), contents);

  return {
    bundle: { version: 1, vaultId: vault.id, envelope: encode(encrypted) },
    recoveryKey: encode(recoveryKey),
  };
}

export async function recoverVault(bundle, recoveryKey) {
  if (bundle?.version !== 1) throw new Error("Unsupported recovery bundle");
  const plaintext = await open(decodeKey(recoveryKey), recoveryContext(bundle.vaultId), decode(bundle.envelope));
  const saved = JSON.parse(utf8.decode(plaintext));
  const vault = { id: saved.id, key: decodeKey(saved.key), token: saved.token };
  validateVault(vault);
  if (vault.id !== bundle.vaultId) throw new Error("Recovery vault mismatch");
  return vault;
}

async function seal(key, context, plaintext) {
  if (!(plaintext instanceof Uint8Array) || plaintext.length > maxBytes - 64) {
    throw new Error("Record must contain at most 1 MiB minus 64 bytes");
  }

  const salt = randomKey();
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const header = join(magic, salt, nonce);
  const derived = await derive(key, salt, context);
  const encrypted = await crypto.subtle.encrypt({
    name: "AES-GCM", iv: nonce, additionalData: join(header, context), tagLength: 128,
  }, derived, plaintext);

  return join(header, new Uint8Array(encrypted));
}

async function open(key, context, envelope) {
  if (!(envelope instanceof Uint8Array) || envelope.length < 64 || envelope.length > maxBytes ||
      !magic.every((byte, index) => envelope[index] === byte)) {
    throw new Error("Invalid encrypted record");
  }

  const derived = await derive(key, envelope.slice(4, 36), context);
  const plaintext = await crypto.subtle.decrypt({
    name: "AES-GCM", iv: envelope.slice(36, 48),
    additionalData: join(envelope.slice(0, 48), context), tagLength: 128,
  }, derived, envelope.slice(48));

  return new Uint8Array(plaintext);
}

async function derive(key, salt, context) {
  if (!(key instanceof Uint8Array) || key.length !== 32) throw new Error("Expected a 256-bit key");
  const base = await crypto.subtle.importKey("raw", key, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt, info: context },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

function recordContext(vaultId, recordId) {
  validateId(vaultId);
  validateId(recordId);
  return text.encode(`habibi/record/v1\0${vaultId}\0${recordId}`);
}

function recoveryContext(vaultId) {
  validateId(vaultId);
  return text.encode(`habibi/recovery/v1\0${vaultId}`);
}

function validateVault(vault) {
  validateId(vault.id);
  if (!(vault.key instanceof Uint8Array) || vault.key.length !== 32) throw new Error("Invalid vault key");
  decodeKey(vault.token);
}

function validateId(id) {
  if (typeof id !== "string" || !uuidPattern.test(id)) throw new Error("Expected a lowercase UUID");
}

function randomKey() {
  return crypto.getRandomValues(new Uint8Array(32));
}

function join(...parts) {
  const result = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function encode(bytes) {
  const chunks = [];
  for (let offset = 0; offset < bytes.length; offset += 32768) {
    chunks.push(String.fromCharCode(...bytes.subarray(offset, offset + 32768)));
  }
  return btoa(chunks.join("")).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decode(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("Invalid base64url");
  return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), char => char.charCodeAt(0));
}

function decodeKey(value) {
  const bytes = decode(value);
  if (bytes.length !== 32 || encode(bytes) !== value) throw new Error("Expected a 256-bit base64url key");
  return bytes;
}
