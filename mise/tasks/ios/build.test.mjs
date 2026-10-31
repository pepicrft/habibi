import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import yaml from "js-yaml";

const root = new URL("../../../", import.meta.url);
const workflow = yaml.load(readFileSync(new URL(".github/workflows/ios-release.yml", root), "utf8"));
const { version, upload, testflight } = workflow.jobs;

test("upload attempts allocate UTC builds even when version selection is reused", t => {
  const directory = mkdtempSync(join(tmpdir(), "habibi-build-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const step = upload.steps.find(step => step.id === "build");
  assert.ok(step, "Build selection must run in the upload job, not the reusable version job");
  assert.equal(version.outputs.build, "${{ steps.version.outputs.build-number }}", "Keep the historical output interface for distribution-only retries");
  assert.equal(upload.env.BUILD, undefined, "Do not inherit a stale version-job build");
  assert.equal(upload.outputs.build, "${{ steps.build.outputs.build-number }}");
  assert.deepEqual(workflow.concurrency, { group: "habibi-ios-release", "cancel-in-progress": false });

  for (const build of ["20261031235959", "20261101000002"]) {
    const envPath = join(directory, `${build}.env`);
    const outputPath = join(directory, `${build}.output`);
    execFileSync("bash", ["-euo", "pipefail", "-c", `
      date() {
        [[ "$*" == '-u +%Y%m%d%H%M%S' ]]
        printf '%s\\n' "$FIXTURE_BUILD"
      }
      ${step.run}
    `], { env: { ...process.env, TZ: "Pacific/Honolulu", FIXTURE_BUILD: build,
      GITHUB_ENV: envPath, GITHUB_OUTPUT: outputPath, GITHUB_RUN_NUMBER: "37", GITHUB_RUN_ATTEMPT: "2" } });
    assert.equal(readFileSync(envPath, "utf8"), `BUILD=${build}\n`);
    assert.equal(readFileSync(outputPath, "utf8"), `build-number=${build}\n`);

    // Run the real packaging/receipt commands with only their external writes stubbed.
    const packageStep = upload.steps.find(step => step.name === "Sign and package");
    const receiptStep = upload.steps.find(step => step.name === "Record the uploaded release");
    const result = execFileSync("bash", ["-euo", "pipefail", "-c", `
      source "$GITHUB_ENV"
      bash() { [[ "$*" == "mise/tasks/ios/bundle.sh $VERSION $BUILD $RUNNER_TEMP/Habibi.ipa" ]]; }
      gh() { [[ "$*" == "release create $TAG --target $GITHUB_SHA --title Habibi iOS $VERSION --notes-file $RUNNER_TEMP/ios-release-notes.md --latest=false" ]]; }
      ${packageStep.run}
      ${receiptStep.run}
      cat "$RUNNER_TEMP/ios-release-notes.md"
    `], { encoding: "utf8", env: { ...process.env, GITHUB_ENV: envPath, RUNNER_TEMP: directory,
      VERSION: "0.3.2", TAG: "ios@0.3.2", GITHUB_SHA: "fixture-sha" } });
    assert.ok(result.includes(`App Store Connect upload: Habibi 0.3.2 (${build}).`));
  }
});

test("distribution-only reruns preserve the uploaded build, including historical dotted numbers", () => {
  assert.equal(testflight.env.BUILD, "${{ needs.upload.outputs.build || needs.version.outputs.build }}");
  const step = testflight.steps.find(step => step.name === "Wait for processing and distribute the private beta");
  for (const build of ["20261031235959", "37.2", "1.0.9"]) {
    execFileSync("bash", ["-euo", "pipefail", "-c", `
      node() { [[ "$*" == "mise/tasks/ios/testflight.mjs 0.3.2 $EXPECTED_BUILD /tmp/ios-release-notes.md" ]]; }
      ${step.run}
    `], { env: { ...process.env, VERSION: "0.3.2", BUILD: build, EXPECTED_BUILD: build,
      RUNNER_TEMP: "/tmp", GITHUB_RUN_ATTEMPT: "9" } });
  }
});

test("new packages require timestamp builds before accessing signing credentials", () => {
  for (const build of ["20261031235959", "37.2", "1.0.9", "2026103123595", "202610312359590"]) {
    const result = spawnSync("bash", [new URL("mise/tasks/ios/bundle.sh", root).pathname, "0.3.2", build], {
      encoding: "utf8", env: { ...process.env, IOS_DISTRIBUTION_P12_BASE64: "" },
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, build === "20261031235959" ? /Missing signing identity/ : /UTC build timestamp/);
  }
});
