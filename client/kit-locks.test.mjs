import assert from "node:assert/strict";
import test from "node:test";
import { acquireKitLock } from "./kit-locks.mjs";

const vaultId = "9eab4fe9-b701-4adb-8f17-ceb1de54a14e";
const lockId = "1ac87664-b98d-41e6-a68e-b25933c48c47";
const metadata = (generation, cursor) => ({ id: lockId, generation, cursor,
  lease_seconds: 30, expires_at: "2030-01-01T12:00:30.000000Z" });
const reply = (status, value, headers = {}) => Response.json(value, { status, headers });

test("a competing host waits, acquires the new generation and sees the published cursor", async () => {
  let held, generation = 0, cursor = 7;
  const request = async (path, init) => {
    assert.ok(path.startsWith(`/v1/vaults/${vaultId}/locks/${lockId}`));
    assert.equal(init.redirect, "error");
    const { token, generation: fence } = JSON.parse(init.body);
    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    if (init.method === "DELETE") {
      assert.equal(token, held);
      assert.equal(fence, generation);
      held = undefined;
      // The holder published a new encrypted credential snapshot before unlock.
      cursor = 11;
      return reply(200, { id: lockId, generation, released: true });
    }
    if (init.method === "POST") return reply(200, metadata(generation, cursor));
    if (held && held !== token) return reply(423, { error: "locked", retry_after: 1 }, { "Retry-After": "1" });
    held = token; generation++;
    return reply(200, metadata(generation, cursor));
  };
  const a = await acquireKitLock({ vaultId, lockId, request });
  let acquired = false;
  const pending = acquireKitLock({ vaultId, lockId, request }).then(value => { acquired = true; return value; });
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(acquired, false, "a waiter must not enter while another host owns the lease");
  const oldHeaders = a.headers();
  await a.release();
  assert.throws(() => a.headers(), /no longer held/);
  const b = await pending;
  assert.equal(b.cursor, 11, "waiters must re-read this encrypted version rather than refreshing stale tokens");
  assert.equal(b.generation, 2);
  assert.notEqual(b.headers()["X-Habibi-Lock-Token"], oldHeaders["X-Habibi-Lock-Token"]);
  assert.equal(b.headers()["X-Habibi-Lock-Generation"], "2");
  await b.renew();
  await b.release();
});

test("lost or stale renewal invalidates a local lease instead of allowing fenced writes", async () => {
  for (const outcome of ["stale", "lost", "malformed"]) {
    const request = async (_path, init) => {
      if (init.method === "PUT") return reply(200, metadata(4, 19));
      if (outcome === "lost") throw Error("network error containing private transport data");
      if (outcome === "malformed") return reply(200, metadata(5, 19));
      return reply(409, { error: "stale_lock" });
    };
    const lease = await acquireKitLock({ vaultId, lockId, request });
    await assert.rejects(lease.renew(), error => !error.message.includes("private transport data"));
    assert.throws(() => lease.headers(), /no longer held/);
    await assert.rejects(lease.release(), /no longer held/);
  }
});

test("response stream failures never expose credential-bearing transport diagnostics", async () => {
  for (const operation of ["acquire", "renew", "release"]) {
    for (const failure of ["read", "cancel"]) {
      const request = async (_path, init) => {
        if (init.method === "PUT" && operation !== "acquire") return reply(200, metadata(1, 0));
        return new Response(new ReadableStream({
          start(controller) {
            if (failure === "read") controller.error(new Error("Authorization: Bearer PRIVATE"));
            else controller.enqueue(new Uint8Array(8193));
          },
          cancel() { throw new Error("X-Habibi-Vault-Token: PRIVATE"); },
        }));
      };
      const options = { vaultId, lockId, request };
      const pending = operation === "acquire"
        ? acquireKitLock(options)
        : (await acquireKitLock(options))[operation]();
      await assert.rejects(pending, { message: "Invalid Kit lock response" });
    }
  }
});

test("waiting is cancellable and hostile or malformed lease responses fail closed", async () => {
  const controller = new AbortController();
  let attempts = 0;
  const pending = acquireKitLock({ vaultId, lockId, signal: controller.signal, request: async () => {
    attempts++;
    return reply(423, { error: "locked", retry_after: 5 }, { "Retry-After": "5" });
  } });
  setTimeout(() => controller.abort(), 20);
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(attempts, 1);
  for (const response of [
    reply(423, { error: "locked", retry_after: 1 }, { "Retry-After": "0" }),
    reply(423, { error: "locked", retry_after: 1 }, { "Retry-After": "99" }),
    reply(200, { ...metadata(1, 0), id: vaultId }),
    reply(200, { ...metadata(1, 0), generation: 0 }),
    reply(200, { ...metadata(1, 0), generation: Number.MAX_SAFE_INTEGER + 1 }),
    reply(200, { ...metadata(1, 0), cursor: -1 }),
    new Response("x".repeat(8193), { status: 200 }),
    new Response("not JSON", { status: 200 }),
  ]) {
    await assert.rejects(acquireKitLock({ vaultId, lockId, request: async () => response }));
  }
});
