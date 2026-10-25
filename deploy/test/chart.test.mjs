import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import yaml from "js-yaml";

test("production routes only Habibi, pins web and migrations together, and keeps durable state and credentials private", () => {
  const digest = `sha256:${"8b".repeat(32)}`;
  const render = (...options) =>
    yaml
      .loadAll(
        execFileSync(
          "helm",
          [
            "template",
            "habibi",
            "deploy/helm/habibi",
            "--namespace",
            "habibi",
            "--values",
            "deploy/values-production.yaml",
            ...options,
          ],
          { encoding: "utf8" },
        ),
      )
      .filter(Boolean);
  const resources = render("--set-string", `image.digest=${digest}`);
  const find = (kind, name) => {
    const resource = resources.find(
      (resource) =>
        resource.kind === kind && (!name || resource.metadata.name === name),
    );
    assert.ok(resource, `${kind}/${name ?? "*"}`);
    return resource;
  };
  const deployment = find("Deployment");
  const web = deployment.spec.template.spec.containers[0];
  const migration = find("Job");
  const migrate = migration.spec.template.spec.containers[0];
  assert.equal(web.image, `ghcr.io/pepicrft/habibi:latest@${digest}`);
  assert.equal(migrate.image, web.image);
  assert.deepEqual(migrate.command, [
    "/app/bin/habibi",
    "eval",
    "Habibi.Release.migrate()",
  ]);
  assert.equal(migration.metadata.annotations?.["helm.sh/hook"], undefined);
  assert.equal(web.readinessProbe.httpGet.path, "/ready");
  assert.equal(web.livenessProbe.httpGet.path, "/health");
  assert.equal(
    web.env.find((env) => env.name === "ALLOW_REGISTRATION").value,
    "false",
  );
  assert.ok(web.env.find((env) => env.name === "DATABASE_CA_CERT"));
  assert.deepEqual(
    web.env.find((env) => env.name === "DATABASE_URL").valueFrom.secretKeyRef,
    { name: "habibi-postgres-app", key: "uri" },
  );
  assert.equal(
    web.env.find((env) => env.name === "S3_ENDPOINT").valueFrom.secretKeyRef
      .key,
    "AWS_ENDPOINT_URL_S3",
  );
  for (const container of [web, migrate]) {
    assert.equal(container.securityContext.readOnlyRootFilesystem, true);
    assert.equal(container.securityContext.runAsNonRoot, true);
    assert.equal(
      container.env.find((env) => env.name === "RELEASE_TMP").value,
      "/tmp",
    );
    assert.ok(
      container.volumeMounts.find(
        (volume) => volume.mountPath === "/database" && volume.readOnly,
      ),
    );
  }
  assert.equal(find("Service", "habibi").spec.type ?? "ClusterIP", "ClusterIP");
  const peers = find("Service", "habibi-peers");
  assert.equal(peers.spec.clusterIP, "None");
  assert.deepEqual(
    peers.spec.ports.map((port) => port.port),
    [4369, 9100],
  );
  const rules = find("NetworkPolicy").spec.ingress;
  assert.deepEqual(
    rules[1].ports.map((port) => port.port),
    [4369, 9100],
  );
  assert.equal(rules[1].from[0].namespaceSelector, undefined);
  assert.equal(
    rules[1].from[0].podSelector.matchLabels["app.kubernetes.io/instance"],
    "habibi",
  );
  const ingress = find("Ingress");
  assert.deepEqual(
    ingress.spec.rules.map((rule) => rule.host),
    ["habibi.fyi"],
  );
  assert.deepEqual(ingress.spec.tls[0].hosts, ["habibi.fyi"]);
  assert.equal(
    ingress.metadata.annotations["external-dns.alpha.kubernetes.io/hostname"],
    "habibi.fyi",
  );
  assert.equal(
    ingress.metadata.annotations[
      "nginx.ingress.kubernetes.io/enable-access-log"
    ],
    "false",
  );
  const ciphertext = find("ObjectBucketClaim", "habibi-ciphertext");
  assert.equal(ciphertext.spec.reclaimPolicy, "Retain");
  assert.equal(ciphertext.spec.lifecycle, undefined);
  assert.equal(
    find("ObjectBucketClaim", "habibi-postgres-backups").spec.reclaimPolicy,
    "Retain",
  );
  assert.equal(find("Cluster").spec.bootstrap.initdb.owner, "habibi");
  const runtimeSecrets = resources.filter(
    (resource) =>
      resource.kind === "ExternalSecret" &&
      resource.spec.refreshPolicy === "CreatedOnce",
  );
  assert.equal(runtimeSecrets.length, 2);
  assert.notEqual(
    runtimeSecrets[0].spec.dataFrom[0].sourceRef.generatorRef.name,
    runtimeSecrets[1].spec.dataFrom[0].sourceRef.generatorRef.name,
  );
  assert.deepEqual(
    web.env
      .filter((env) => env.name.startsWith("SMOLANALYTICS_"))
      .map((env) => [env.name, env.valueFrom.secretKeyRef]),
    ["SMOLANALYTICS_HOST", "SMOLANALYTICS_WRITE_KEY"].map((key) => [
      key,
      { name: "analytics-client", key },
    ]),
  );
  assert.equal(web.envFrom, undefined);

  const isolated = render(
    "--set",
    "analytics.enabled=false,imagePullSecret.enabled=false,ingress.enabled=false,replicaCount=1",
  );
  assert.equal(
    isolated.some((resource) => resource.kind === "Ingress"),
    false,
  );
  const isolatedPod = isolated.find(
    (resource) => resource.kind === "Deployment",
  ).spec.template.spec;
  assert.equal(
    isolatedPod.containers[0].env.some((env) =>
      env.name.startsWith("SMOLANALYTICS_"),
    ),
    false,
  );
  assert.equal(isolatedPod.containers[0].envFrom, undefined);
  assert.equal(isolatedPod.imagePullSecrets, undefined);
});
