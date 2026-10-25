import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import yaml from "js-yaml";

const workflow = yaml.load(
  readFileSync(".github/workflows/release.yml", "utf8"),
);
const steps = workflow.jobs.publish.steps;
const packageStep = steps.find(
  (step) => step.name === "Package the versioned Helm chart",
);
const publishStep = steps.find(
  (step) => step.name === "Publish or reuse the versioned Helm chart",
);
const version = "8.7.6";

function temporary(t) {
  const directory = mkdtempSync(join(tmpdir(), "habibi-helm-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function runStep(step, env) {
  return spawnSync("bash", ["-e", "-o", "pipefail", "-c", step.run], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function packageChart(directory) {
  const result = runStep(packageStep, {
    VERSION: version,
    RUNNER_TEMP: directory,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return join(directory, `habibi-${version}.tgz`);
}

test("Helm publication stays gated, shares the release number, and precedes GitHub release and final image promotion", () => {
  assert.equal(
    workflow.jobs.version.steps.at(-1).run,
    "bash mise/tasks/release/check.sh",
  );
  assert.equal(
    workflow.jobs.checks.if,
    "needs.version.outputs.release == 'true'",
  );
  assert.equal(
    workflow.jobs.publish.if,
    "needs.version.outputs.release == 'true'",
  );
  assert.deepEqual(workflow.jobs.publish.needs, ["version", "checks"]);
  assert.equal(workflow.concurrency["cancel-in-progress"], false);
  assert.equal(
    workflow.jobs.publish.env.VERSION,
    "${{ needs.version.outputs.number }}",
  );
  assert.equal(
    workflow.jobs.publish.env.CHART_REGISTRY,
    "ghcr.io/pepicrft/charts",
  );
  const release = steps.find((step) =>
    step.uses?.startsWith("softprops/action-gh-release@"),
  );
  assert.equal(release.with.tag_name, "${{ needs.version.outputs.tag }}");
  assert.ok(
    steps.indexOf(packageStep) < steps.findIndex((step) => step.id === "image"),
  );
  assert.ok(
    steps.findIndex((step) => step.name === "Record the image digest") <
      steps.indexOf(publishStep),
  );
  assert.ok(steps.indexOf(publishStep) < steps.indexOf(release));
  assert.equal(steps.at(-1).name, "Promote the published image to latest");
  assert.equal(
    publishStep.if,
    undefined,
    "retries must also verify the published chart",
  );
  assert.match(
    steps.find((step) => step.id === "existing").run,
    /imagetools inspect "\$IMAGE:\$VERSION"/,
  );
});

test("release packaging defaults both workloads to the matching app image, preserving tag and digest overrides", (t) => {
  const directory = temporary(t);
  const chart = packageChart(directory);
  const metadata = yaml.load(
    execFileSync("helm", ["show", "chart", chart], { encoding: "utf8" }),
  );
  assert.equal(metadata.version, version);
  assert.equal(metadata.appVersion, version);
  const digest = `sha256:${"ab".repeat(32)}`;
  const cases = [
    [[], `ghcr.io/pepicrft/habibi:${version}`],
    [["image.tag=custom"], "ghcr.io/pepicrft/habibi:custom"],
    [
      [`image.digest=${digest}`],
      `ghcr.io/pepicrft/habibi:${version}@${digest}`,
    ],
    [
      [`image.tag=latest,image.digest=${digest}`],
      `ghcr.io/pepicrft/habibi:latest@${digest}`,
    ],
    [
      [
        `image.repository=mirror.example/habibi,image.tag=custom,image.digest=${digest}`,
      ],
      `mirror.example/habibi:custom@${digest}`,
    ],
  ];
  for (const [overrides, expected] of cases) {
    const rendered = execFileSync(
      "helm",
      [
        "template",
        "habibi",
        chart,
        "--set-string",
        "storage.bucketName=test-ciphertext,backup.bucketName=test-backups",
        ...overrides.flatMap((value) => ["--set-string", value]),
      ],
      { encoding: "utf8" },
    );
    const workloads = yaml
      .loadAll(rendered)
      .filter((resource) => ["Deployment", "Job"].includes(resource?.kind));
    assert.equal(workloads.length, 2);
    assert.deepEqual(
      workloads.map(
        (resource) => resource.spec.template.spec.containers[0].image,
      ),
      [expected, expected],
    );
  }
  for (const [setting, required] of [
    ["backup.bucketName=test-backups", "storage.bucketName"],
    ["storage.bucketName=test-ciphertext", "backup.bucketName"],
  ]) {
    const result = spawnSync(
      "helm",
      ["template", "habibi", chart, "--set-string", setting],
      { encoding: "utf8" },
    );
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes(`${required} is required`), result.stderr);
  }
  // The original GitRepository source remains usable without release-time edits.
  const source = yaml.load(
    readFileSync("deploy/helm/habibi/Chart.yaml", "utf8"),
  );
  const rendered = execFileSync(
    "helm",
    [
      "template",
      "habibi",
      "deploy/helm/habibi",
      "-f",
      "deploy/values-production.yaml",
    ],
    { encoding: "utf8" },
  );
  const deployment = yaml
    .loadAll(rendered)
    .find((resource) => resource?.kind === "Deployment");
  assert.equal(
    deployment.spec.template.spec.containers[0].image,
    `ghcr.io/pepicrft/habibi:${source.appVersion}`,
  );
});

test("OCI retry reuses identical content, rejects conflicts and fails closed on registry errors", (t) => {
  const directory = temporary(t);
  const chart = packageChart(directory);
  const bin = join(directory, "bin");
  mkdirSync(bin);
  // Only the registry boundary is faked. Run the workflow's actual shell and real tar/diff.
  writeFileSync(
    join(bin, "helm"),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$HELM_CALLS"
case "$1" in
  pull)
    if [[ -n "$HELM_PULL_ERROR" ]]; then
      printf '%s\\n' "$HELM_PULL_ERROR" >&2
      exit 1
    fi
    cp "$REMOTE_ARCHIVE" "$6/habibi-$VERSION.tgz"
    ;;
  push) ;;
  *) exit 99 ;;
esac
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "curl"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'package-api\\n' >> "$HELM_CALLS"
printf '%s' "$PACKAGE_STATUS"
exit "$PACKAGE_EXIT"
`,
    { mode: 0o755 },
  );

  const repacked = join(directory, "repacked");
  mkdirSync(repacked);
  execFileSync("tar", ["-xzf", chart, "-C", repacked]);
  // Different gzip/tar metadata, identical chart files.
  const identical = join(directory, "identical.tgz");
  execFileSync("tar", ["-czf", identical, "-C", repacked, "habibi"]);
  assert.notDeepEqual(readFileSync(identical), readFileSync(chart));
  writeFileSync(join(repacked, "habibi/values.yaml"), "replicaCount: 99\n");
  const conflicting = join(directory, "conflicting.tgz");
  execFileSync("tar", ["-czf", conflicting, "-C", repacked, "habibi"]);

  const registry = workflow.jobs.publish.env.CHART_REGISTRY;
  const cases = [
    {
      error: `Error: failed to perform "FetchReference" on source: ${registry}/habibi:${version}: not found`,
      status: 0,
      push: true,
    },
    { archive: identical, status: 0, push: false },
    { archive: conflicting, status: 1, push: false },
    {
      error: "Error: unauthorized: authentication required",
      status: 1,
      push: false,
    },
    {
      error: "Error: unexpected status: 503 Service Unavailable",
      status: 1,
      push: false,
    },
    { error: "Error: dial tcp: connection refused", status: 1, push: false },
    { error: "Error: another/chart:8.7.6: not found", status: 1, push: false },
    { error: "Error: 403: denied: denied", api: "404", status: 0, push: true },
    { error: "Error: 403: denied: denied", api: "200", status: 1, push: false },
    { error: "Error: 403: denied: denied", api: "401", status: 1, push: false },
    { error: "Error: 403: denied: denied", api: "403", status: 1, push: false },
    { error: "Error: 403: denied: denied", api: "500", status: 1, push: false },
    {
      error: "Error: 403: denied: denied",
      api: "404",
      apiExit: "7",
      status: 1,
      push: false,
    },
  ];
  for (const scenario of cases) {
    const runner = mkdtempSync(join(directory, "runner-"));
    copyFileSync(chart, join(runner, `habibi-${version}.tgz`));
    const calls = join(runner, "calls");
    const result = runStep(publishStep, {
      VERSION: version,
      CHART_REGISTRY: registry,
      RUNNER_TEMP: runner,
      PATH: `${bin}:${process.env.PATH}`,
      HELM_CALLS: calls,
      HELM_PULL_ERROR: scenario.error ?? "",
      REMOTE_ARCHIVE: scenario.archive ?? "",
      GHCR_TOKEN: "disposable-test-token",
      PACKAGE_STATUS: scenario.api ?? "403",
      PACKAGE_EXIT: scenario.apiExit ?? "0",
    });
    assert.equal(result.status, scenario.status, result.stdout + result.stderr);
    const commands = readFileSync(calls, "utf8").trim().split("\n");
    assert.equal(
      commands.some((command) => command.startsWith("push ")),
      scenario.push,
    );
    if (scenario.push) {
      assert.equal(
        commands.at(-1),
        `push ${runner}/habibi-${version}.tgz oci://${registry}`,
      );
    }
  }
});
