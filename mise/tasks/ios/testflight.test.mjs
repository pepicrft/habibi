import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import { distribute } from "./testflight.mjs";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const env = {
  ASC_TESTFLIGHT_API_KEY_ID: "TESTKEY",
  ASC_TESTFLIGHT_API_ISSUER_ID: "test-issuer",
  ASC_TESTFLIGHT_API_KEY_P8_BASE64: Buffer.from(privateKey.export({ type: "pkcs8", format: "pem" })).toString("base64"),
};
const release = { version: "0.3.2", build: "47.2", notes: "Fix voice capture and test recovery.\nUse fictional data." };

// Stateful Apple boundary: assertions below concern the resulting release,
// not which helpers or request ordering the implementation chooses.
function apple() {
  let time = 1_800_000_000_000;
  const state = {
    group: {
      id: "01087c85-1ab4-417f-a366-775403e8fce4",
      attributes: { isInternalGroup: false, publicLinkEnabled: false },
      relationships: { app: { data: { id: "6828413839" } } },
    },
    builds: [
      { id: "old-train", app: "6828413839", version: "0.2.0", platform: "IOS", attributes: { version: "47.2", processingState: "VALID" } },
      { id: "other-app", app: "123", version: "0.3.2", platform: "IOS", attributes: { version: "47.2", processingState: "VALID" } },
      { id: "mac-build", app: "6828413839", version: "0.3.2", platform: "MAC_OS", attributes: { version: "47.2", processingState: "VALID" } },
      { id: "older-build", app: "6828413839", version: "0.3.2", platform: "IOS", attributes: { version: "46.1", processingState: "VALID" } },
      { id: "new-build", app: "6828413839", version: "0.3.2", platform: "IOS", attributes: { version: "47.2", processingState: "VALID", usesNonExemptEncryption: false } },
    ],
    visibility: [true],
    processing: ["VALID"],
    localizations: [
      { id: "german", attributes: { locale: "de-DE", whatsNew: "Unverändert" } },
      { id: "english", attributes: { locale: "en-US", whatsNew: "Old notes" } },
    ],
    detail: { id: "beta-detail", attributes: { autoNotifyEnabled: false, internalBuildState: "IN_BETA_TESTING", externalBuildState: "READY_FOR_BETA_SUBMISSION" } },
    groupBuilds: new Set(["old-train"]),
    submissions: new Set(),
    notifications: new Set(),
    conflict: false,
    submissionError: null,
    afterPause: () => {},
  };
  const response = (data, status = 200) => new Response(JSON.stringify({ data }), { status });
  const failure = (code, status) => new Response(JSON.stringify({ errors: [{ code, detail: "Simulated Apple error" }] }), { status });
  const options = {
    env,
    now: () => time,
    timeout: 45 * 60_000,
    pause: async () => { time += 6 * 60_000; state.afterPause(); },
    fetch: async (input, init) => {
      const url = new URL(input);
      assert.equal(url.origin, "https://api.appstoreconnect.apple.com");
      const token = init.headers.Authorization.replace("Bearer ", "").split(".");
      const payload = JSON.parse(Buffer.from(token[1], "base64url"));
      assert.equal(payload.iss, "test-issuer");
      assert.equal(payload.aud, "appstoreconnect-v1");
      assert.ok(payload.iat <= time / 1000 && payload.exp > time / 1000, "JWT must remain valid after processing takes over five minutes");
      assert.ok(verify("sha256", Buffer.from(token.slice(0, 2).join(".")), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(token[2], "base64url")));
      const body = init.body && JSON.parse(init.body);
      const path = url.pathname;
      if (init.method === "GET" && path === `/v1/betaGroups/${state.group.id}`) return response(state.group);
      if (init.method === "GET" && path === "/v1/builds") {
        const visible = state.visibility.length > 1 ? state.visibility.shift() : state.visibility[0];
        if (!visible) return response([]);
        state.builds.at(-1).attributes.processingState = state.processing.length > 1 ? state.processing.shift() : state.processing[0];
        const parameters = url.searchParams;
        return response(state.builds.filter(build =>
          (!parameters.has("filter[app]") || build.app === parameters.get("filter[app]")) &&
          (!parameters.has("filter[preReleaseVersion.version]") || build.version === parameters.get("filter[preReleaseVersion.version]")) &&
          (!parameters.has("filter[preReleaseVersion.platform]") || build.platform === parameters.get("filter[preReleaseVersion.platform]")) &&
          (!parameters.has("filter[version]") || build.attributes.version === parameters.get("filter[version]"))
        ));
      }
      if (init.method === "GET" && path === "/v1/builds/new-build/betaBuildLocalizations") return response(state.localizations);
      if (init.method === "PATCH" && path.startsWith("/v1/betaBuildLocalizations/")) {
        const localization = state.localizations.find(item => item.id === body.data.id);
        Object.assign(localization.attributes, body.data.attributes);
        return response(localization);
      }
      if (init.method === "POST" && path === "/v1/betaBuildLocalizations") {
        assert.equal(body.data.relationships.build.data.id, "new-build");
        const localization = { ...body.data, id: "created-english" };
        state.localizations.push(localization);
        return response(localization, 201);
      }
      if (init.method === "GET" && path === "/v1/builds/new-build/buildBetaDetail") return response(state.detail);
      if (init.method === "PATCH" && path === "/v1/buildBetaDetails/beta-detail") {
        Object.assign(state.detail.attributes, body.data.attributes);
        return response(state.detail);
      }
      if (init.method === "POST" && path === `/v1/betaGroups/${state.group.id}/relationships/builds`) {
        for (const build of body.data) state.groupBuilds.add(build.id);
        return new Response(null, { status: 204 });
      }
      if (init.method === "POST" && path === "/v1/betaAppReviewSubmissions") {
        if (state.submissionError) return failure(state.submissionError, 403);
        if (state.conflict) return failure("ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW", 422);
        const id = body.data.relationships.build.data.id;
        if (state.submissions.has(id)) return failure("DUPLICATE_REVIEW", 409);
        state.submissions.add(id);
        // Apple may accept a write before its reads reflect the new state.
        let polls = 0;
        state.afterPause = () => { if (++polls === 2) state.detail.attributes.externalBuildState = "WAITING_FOR_BETA_REVIEW"; };
        return response({ id, attributes: { betaReviewState: "WAITING_FOR_REVIEW" } }, 201);
      }
      if (init.method === "POST" && path === "/v1/buildBetaNotifications") {
        const id = body.data.relationships.build.data.id;
        if (state.notifications.has(id)) return failure("DUPLICATE_NOTIFICATION", 409);
        state.notifications.add(id);
        let polls = 0;
        state.afterPause = () => { if (++polls === 2) state.detail.attributes.externalBuildState = "IN_BETA_TESTING"; };
        return response({ id }, 201);
      }
      throw new Error(`Unexpected Apple operation: ${init.method} ${path}`);
    },
  };
  return { state, options };
}

test("waits for the exact iOS upload, updates English notes and submits only to the existing private group", async () => {
  const { state, options } = apple();
  state.visibility = [false, true];
  state.processing = ["PROCESSING", "VALID"];
  assert.equal(await distribute(release, options), "WAITING_FOR_BETA_REVIEW");
  assert.equal(state.localizations[0].attributes.whatsNew, "Unverändert");
  assert.equal(state.localizations[1].attributes.whatsNew, release.notes);
  assert.equal(state.detail.attributes.autoNotifyEnabled, true);
  assert.deepEqual([...state.groupBuilds], ["old-train", "new-build"]);
  assert.deepEqual([...state.submissions], ["new-build"]);
  assert.equal(state.group.attributes.publicLinkEnabled, false);
  assert.equal(state.builds[0].attributes.usesNonExemptEncryption, undefined);
});

test("creates missing English notes and starts approved testing; reruns do not submit another review", async () => {
  const { state, options } = apple();
  state.localizations.pop();
  state.detail.attributes.externalBuildState = "BETA_APPROVED";
  assert.equal(await distribute({ ...release, notes: "x".repeat(4100) }, options), "IN_BETA_TESTING");
  assert.equal(state.localizations[1].attributes.whatsNew.length, 4000);
  assert.deepEqual([...state.notifications], ["new-build"]);
  assert.equal(await distribute(release, options), "IN_BETA_TESTING");
  assert.equal(state.submissions.size, 0);
  assert.equal(state.localizations.length, 2);
  assert.equal(state.localizations[1].attributes.whatsNew, release.notes);
});

test("preserves another build's active review and retries after Apple's queue clears", async () => {
  const { state, options } = apple();
  state.conflict = true;
  state.submissions.add("old-train");
  state.afterPause = () => { state.conflict = false; };
  assert.equal(await distribute(release, options), "WAITING_FOR_BETA_REVIEW");
  assert.deepEqual([...state.submissions], ["old-train", "new-build"]);
});

test("fails rather than reporting distribution success for blocked builds or audiences", async t => {
  for (const [name, configure, error] of [
    ["failed processing", s => { s.processing = ["FAILED"]; }, /cannot distribute/],
    ["invalid processing", s => { s.processing = ["INVALID"]; }, /cannot distribute/],
    ["expired", s => { s.builds.at(-1).attributes.expired = true; }, /cannot distribute/],
    ["missing compliance", s => { s.builds.at(-1).attributes.usesNonExemptEncryption = null; }, /Export compliance/],
    ["nonexempt crypto", s => { s.builds.at(-1).attributes.usesNonExemptEncryption = true; }, /Export compliance/],
    ["rejected beta", s => { s.detail.attributes.externalBuildState = "BETA_REJECTED"; }, /requires attention/],
    ["public group", s => { s.group.attributes.publicLinkEnabled = true; }, /refusing to change its audience/],
    ["wrong app", s => { s.group.relationships.app.data.id = "123"; }, /refusing to change its audience/],
    ["processing timeout", s => { s.visibility = [false]; }, /Timed out:.*do not re-upload/],
    ["review queue timeout", s => { s.conflict = true; }, /Timed out:.*do not re-upload/],
    ["insufficient permissions", s => { s.submissionError = "FORBIDDEN_ERROR"; }, /HTTP 403/],
  ]) {
    await t.test(name, async () => {
      const { state, options } = apple();
      configure(state);
      await assert.rejects(distribute(release, options), error);
      assert.equal(state.submissions.size, 0);
      assert.equal(state.notifications.size, 0);
    });
  }
});

test("fails early with setup instructions when management credentials are missing", async () => {
  await assert.rejects(distribute(release, { env: {} }), /App Manager team key in Infisical/);
});
