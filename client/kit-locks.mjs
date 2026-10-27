// Trusted host API, never installed in the Kit JavaScript sandbox. `request`
// binds a fixed Habibi origin and adds OAuth + vault-capability headers. It must
// not retry provider refreshes. Keep a stable opaque lockId in encrypted state.
export async function acquireKitLock({ vaultId, lockId, request, signal = AbortSignal.timeout(120_000) }) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  if (!uuid.test(vaultId) || !uuid.test(lockId) || typeof request !== "function") {
    throw new Error("Invalid Kit lock configuration");
  }
  const token = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const path = `/v1/vaults/${vaultId}/locks/${lockId}`;

  async function send(method, suffix, body) {
    signal.throwIfAborted();
    let response;
    try {
      response = await request(path + suffix, {
        method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
        cache: "no-store", redirect: "error", signal,
      });
    } catch {
      signal.throwIfAborted();
      // A lost response has an unknown outcome. Do not expose transport errors,
      // which can include request bodies or authorization headers.
      throw new Error("Kit lock request could not be confirmed");
    }
    signal.throwIfAborted();
    try {
      const reader = response.body?.getReader();
      if (!reader) throw new Error();
      const chunks = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > 8192) throw new Error();
          chunks.push(value);
        }
      } finally {
        try { await reader.cancel(); } finally { reader.releaseLock(); }
      }
      signal.throwIfAborted();
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      return { response, value };
    } catch {
      signal.throwIfAborted();
      throw new Error("Invalid Kit lock response");
    }
  }

  function lease(value) {
    if (value?.id !== lockId || !Number.isSafeInteger(value.generation) || value.generation < 1 ||
        !Number.isSafeInteger(value.cursor) || value.cursor < 0 || value.lease_seconds !== 30 ||
        typeof value.expires_at !== "string" || !Number.isFinite(Date.parse(value.expires_at))) {
      throw new Error("Invalid Kit lock lease");
    }
    return value;
  }

  let current;
  while (true) {
    const { response, value } = await send("PUT", "", { token });
    if (response.status === 200) { current = lease(value); break; }
    const retry = response.headers.get("Retry-After");
    if (response.status !== 423 || value?.error !== "locked" || !/^[1-5]$/.test(retry ?? "") ||
        value.retry_after !== Number(retry)) throw new Error("Kit lock acquisition was rejected");
    await wait(Number(retry) * 1000, signal);
  }
  let active = true;
  function requireActive() {
    signal.throwIfAborted();
    if (!active) throw new Error("Kit lock is no longer held");
  }
  // Fencing only protects ciphertext publication. A lease does not guarantee
  // exactly-once provider calls. Reload through cursor before refresh; publish a
  // durable in-progress marker before rotating, and reconnect on unknown outcome.
  return {
    generation: current.generation,
    get cursor() { return current.cursor; },
    get expiresAt() { return current.expires_at; },
    headers() {
      requireActive();
      return { "X-Habibi-Lock-Id": lockId, "X-Habibi-Lock-Token": token,
        "X-Habibi-Lock-Generation": String(current.generation) };
    },
    async renew() {
      requireActive();
      try {
        const { response, value } = await send("POST", "/renew", { token, generation: current.generation });
        if (response.status !== 200 || lease(value).generation !== current.generation) {
          throw new Error("Kit lock renewal was rejected");
        }
        current = value;
      } catch (error) { active = false; throw error; }
    },
    async release() {
      requireActive();
      active = false;
      const { response, value } = await send("DELETE", "", { token, generation: current.generation });
      if (response.status !== 200 || value?.id !== lockId || value.generation !== current.generation || value.released !== true) {
        throw new Error("Kit lock release could not be confirmed");
      }
    },
  };
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    signal.throwIfAborted();
    const timer = setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, ms);
    function abort() { clearTimeout(timer); reject(signal.reason); }
    signal.addEventListener("abort", abort, { once: true });
  });
}
