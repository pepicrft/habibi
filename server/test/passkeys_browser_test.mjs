import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../priv/static/auth/passkeys.js", import.meta.url), "utf8");
const messages = {
  prompt: "TEST prompt <script>&",
  unsupported: 'TEST unsupported "browser"',
  cancelled: "TEST cancelled",
  failure: "TEST generic failure",
};

function browser({ supported = true, credentialError, httpError, networkError, nullCredential = false } = {}) {
  const handlers = new Map();
  const requests = [];
  const credentials = [];
  let reloads = 0;
  const status = { textContent: "", dataset: messages };
  Object.defineProperty(status, "innerHTML", { set() { assert.fail("Messages must use textContent"); } });
  const buttons = ["login", "register"].map((kind) => ({
    dataset: { passkey: kind },
    disabled: false,
    addEventListener(event, handler) {
      assert.equal(event, "click");
      handlers.set(kind, handler);
    },
  }));

  const credential = async (kind, options) => {
    assert.equal(status.textContent, messages.prompt);
    assert.ok(buttons.every((button) => button.disabled));
    credentials.push({ kind, options });
    if (credentialError !== undefined) throw credentialError;
    if (nullCredential) return null;
    return {
      rawId: new Uint8Array([1, 2, 3]).buffer,
      response: {
        clientDataJSON: new Uint8Array([4, 5]).buffer,
        authenticatorData: new Uint8Array([6]).buffer,
        signature: new Uint8Array([7]).buffer,
        userHandle: null,
      },
    };
  };

  vm.runInNewContext(source, {
    document: {
      querySelector: (selector) => selector === "#status" ? status : { content: "test-csrf" },
      querySelectorAll: () => buttons,
    },
    window: { PublicKeyCredential: supported, location: { reload() { reloads += 1; } } },
    navigator: { credentials: {
      create: (options) => credential("register", options),
      get: (options) => credential("login", options),
    } },
    async fetch(path, options) {
      const step = path.endsWith("/options") ? "options" : "finish";
      requests.push({ path, options });
      if (step === networkError) throw new Error("RAW private network details <script>");
      return {
        ok: step !== httpError,
        async json() {
          assert.notEqual(step, httpError, "Error response bodies must not be displayed");
          return step === "options"
            ? { challenge: "AQID", user: JSON.parse(options.body).kind === "register" ? { id: "BAU" } : undefined }
            : { status: "authenticated" };
        },
      };
    },
    atob,
    btoa,
  });

  return { status, buttons, requests, credentials, click: (kind = "login") => handlers.get(kind)(), reloads: () => reloads };
}

test("unsupported browsers use the server message and re-enable both buttons", async () => {
  const page = browser({ supported: false });
  await page.click();
  assert.equal(page.status.textContent, messages.unsupported);
  assert.equal(page.requests.length, 0);
  assert.ok(page.buttons.every((button) => !button.disabled));
});

for (const kind of ["login", "register"]) {
  test(`${kind} cancellation uses only the server cancellation message`, async () => {
    const page = browser({ credentialError: { name: "NotAllowedError", message: "RAW browser error" } });
    await page.click(kind);
    assert.equal(page.status.textContent, messages.cancelled);
    assert.equal(page.reloads(), 0);
    assert.ok(page.buttons.every((button) => !button.disabled));
  });

  test(`${kind} completes the passkey flow without hardcoded UI messages`, async () => {
    const page = browser();
    await page.click(kind);
    assert.equal(page.status.textContent, messages.prompt);
    assert.equal(page.reloads(), 1);
    assert.equal(page.credentials[0].kind, kind);
    assert.deepEqual(Array.from(page.credentials[0].options.publicKey.challenge), [1, 2, 3]);
    if (kind === "register") assert.deepEqual(Array.from(page.credentials[0].options.publicKey.user.id), [4, 5]);
    assert.deepEqual(page.requests.map(({ path }) => path), ["/auth/passkeys/options", "/auth/passkeys/finish"]);
    for (const { options } of page.requests) {
      assert.equal(options.headers["x-csrf-token"], "test-csrf");
      assert.equal(options.method, "POST");
    }
    assert.equal(JSON.parse(page.requests[1].options.body).id, "AQID");
  });
}

for (const options of [
  { credentialError: new Error("RAW private browser details <script>alert(1)</script>") },
  { credentialError: { name: "NotSupportedError", message: "RAW browser details" } },
  { credentialError: null },
  { nullCredential: true },
  { httpError: "options" },
  { httpError: "finish" },
  { networkError: "options" },
  { networkError: "finish" },
]) {
  test(`failures use the server generic message: ${JSON.stringify(options)}`, async () => {
    const page = browser(options);
    await page.click();
    assert.equal(page.status.textContent, messages.failure);
    assert.equal(page.reloads(), 0);
    assert.ok(page.buttons.every((button) => !button.disabled));
  });
}
