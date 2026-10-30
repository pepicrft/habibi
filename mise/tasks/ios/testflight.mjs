import { sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { setTimeout } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const appId = "6828413839";
const groupId = "01087c85-1ab4-417f-a366-775403e8fce4"; // Existing external group; preserve its enrollment settings.

// Uploads and distribution are separate jobs: retry this without uploading again.
export async function distribute({ version, build, notes }, {
  env = process.env,
  fetch = globalThis.fetch,
  pause = () => setTimeout(30_000),
  now = Date.now,
  timeout = 45 * 60_000,
} = {}) {
  const keyId = env.ASC_TESTFLIGHT_API_KEY_ID;
  const issuer = env.ASC_TESTFLIGHT_API_ISSUER_ID;
  const encodedKey = env.ASC_TESTFLIGHT_API_KEY_P8_BASE64;
  if (!keyId || !issuer || !encodedKey) {
    throw new Error("Configure ASC_TESTFLIGHT_API_KEY_ID, ASC_TESTFLIGHT_API_ISSUER_ID and ASC_TESTFLIGHT_API_KEY_P8_BASE64 with an App Manager team key in Infisical.");
  }
  if (!/^\d+\.\d+\.\d+$/.test(version) || !/^\d+(\.\d+){0,2}$/.test(build) || !notes.trim()) {
    throw new Error("Expected VERSION, BUILD and nonempty TestFlight notes.");
  }
  const key = Buffer.from(encodedKey, "base64");
  const deadline = now() + timeout;
  const encode = value => Buffer.from(JSON.stringify(value)).toString("base64url");

  async function request(method, path, body) {
    // Processing can outlive a JWT. Sign each request, without writing keys to disk.
    const seconds = Math.floor(now() / 1000);
    const input = `${encode({ alg: "ES256", kid: keyId, typ: "JWT" })}.${encode({
      iss: issuer, iat: seconds - 5, exp: seconds + 300, aud: "appstoreconnect-v1",
    })}`;
    const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    const response = await fetch(`https://api.appstoreconnect.apple.com/v1${path}`, {
      method,
      headers: { Authorization: `Bearer ${input}.${signature}`, "Content-Type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(60_000),
    });
    const text = await response.text();
    const result = text ? JSON.parse(text) : {};
    if (!response.ok) {
      const error = new Error(`App Store Connect ${method} ${path}: HTTP ${response.status}. ${
        result.errors?.map(error => `${error.code}: ${error.detail || error.title}`).join("; ") || "Request failed"
      }. Inspect Apple state before retrying a write.`);
      error.codes = result.errors?.map(error => error.code) || [];
      throw error;
    }
    return result;
  }

  async function wait(reason) {
    if (now() >= deadline) {
      throw new Error(`Timed out: ${reason}. Rerun only the TestFlight job after resolving this in App Store Connect; do not re-upload the IPA.`);
    }
    console.log(reason);
    await pause();
  }

  const group = (await request("GET", `/betaGroups/${groupId}?include=app`)).data;
  if (group.relationships.app.data.id !== appId || group.attributes.isInternalGroup) {
    throw new Error("Expected Habibi's existing external TestFlight group; refusing to change its audience.");
  }

  const query = new URLSearchParams({
    "filter[app]": appId,
    "filter[preReleaseVersion.version]": version,
    "filter[preReleaseVersion.platform]": "IOS",
    "filter[version]": build,
    limit: "2",
  });
  let uploaded;
  while (true) {
    const builds = (await request("GET", `/builds?${query}`)).data;
    if (builds.length > 1) throw new Error("Multiple builds matched this version and build number.");
    uploaded = builds[0];
    const state = uploaded?.attributes.processingState;
    if (uploaded?.attributes.expired || state === "FAILED" || state === "INVALID") {
      throw new Error(`Apple cannot distribute Habibi ${version} (${build}): ${state}, expired=${uploaded.attributes.expired}.`);
    }
    if (state === "VALID") break;
    await wait(`Waiting for Apple to process Habibi ${version} (${build}): ${state || "not visible yet"}`);
  }

  const id = uploaded.id;
  // Compliance is declared in the signed IPA, not guessed or overridden here.
  if (uploaded.attributes.usesNonExemptEncryption !== false) {
    throw new Error("Export compliance is unresolved or requires documentation. Resolve it in App Store Connect before rerunning the TestFlight job.");
  }
  const localizations = (await request("GET", `/builds/${id}/betaBuildLocalizations`)).data;
  const english = localizations.find(item => item.attributes.locale === "en-US");
  const whatsNew = notes.slice(0, 4000);
  if (english) {
    await request("PATCH", `/betaBuildLocalizations/${english.id}`, {
      data: { type: "betaBuildLocalizations", id: english.id, attributes: { whatsNew } },
    });
  } else {
    await request("POST", "/betaBuildLocalizations", {
      data: {
        type: "betaBuildLocalizations", attributes: { locale: "en-US", whatsNew },
        relationships: { build: { data: { type: "builds", id } } },
      },
    });
  }
  const detail = (await request("GET", `/builds/${id}/buildBetaDetail`)).data;
  await request("PATCH", `/buildBetaDetails/${detail.id}`, {
    data: { type: "buildBetaDetails", id: detail.id, attributes: { autoNotifyEnabled: true } },
  });
  await request("POST", `/betaGroups/${groupId}/relationships/builds`, { data: [{ type: "builds", id }] });

  let submitted = false;
  let notified = false;
  while (true) {
    const attributes = (await request("GET", `/builds/${id}/buildBetaDetail`)).data.attributes;
    const state = attributes.externalBuildState;
    if (["IN_BETA_TESTING", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"].includes(state)) {
      console.log(`Habibi ${version} (${build}): internal=${attributes.internalBuildState}, external=${state}. Testers will be notified automatically when available.`);
      return state;
    }
    if (state === "READY_FOR_BETA_TESTING" || state === "BETA_APPROVED") {
      if (!notified) {
        await request("POST", "/buildBetaNotifications", {
          data: { type: "buildBetaNotifications", relationships: { build: { data: { type: "builds", id } } } },
        });
        notified = true;
      }
    } else if (state === "READY_FOR_BETA_SUBMISSION") {
      if (!submitted) {
        try {
          await request("POST", "/betaAppReviewSubmissions", {
            data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id } } } },
          });
          submitted = true;
        } catch (error) {
          // Apple allows only one build of a version in review. Preserve that review.
          if (!error.codes?.includes("ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW")) throw error;
        }
      }
    } else if (!["PROCESSING", "IN_EXPORT_COMPLIANCE_REVIEW"].includes(state)) {
      throw new Error(`TestFlight requires attention: ${state}. Resolve this in App Store Connect before rerunning the TestFlight job.`);
    }
    await wait(`Waiting for TestFlight distribution: ${state}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [version, build, notesPath] = process.argv.slice(2);
    const releaseNotes = await readFile(notesPath, "utf8");
    const listing = JSON.parse(await readFile(new URL("../../../native/app-store/locales/en-US.json", import.meta.url), "utf8"));
    await distribute({ version, build, notes: `Habibi ${version} (${build})\n\n${listing.betaDescription}\n\n${releaseNotes}` });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
