#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  DEFAULT_CONFIG_PATH,
  WolfiConfigError,
  canonicalJson,
  loadWolfiConfig,
  parseWolfiConfig,
  validateWolfiConfig,
  verifyWolfiLock,
  wolfiConfigSemanticSha256,
  wolfiImageReferences
} from "./config.mjs";
import {
  createWolfiLock,
  loadResolutionFragment,
  mergeResolutionStages,
  selectPlatformManifest
} from "./update-lock.mjs";

const validSource = fs.readFileSync(DEFAULT_CONFIG_PATH, "utf8");
const validConfig = loadWolfiConfig();
const AMD64_DIGEST = `sha256:${"a".repeat(64)}`;
const ARM64_DIGEST = `sha256:${"b".repeat(64)}`;
const INDEX_DIGEST = `sha256:${"c".repeat(64)}`;

function clone(value) {
  return structuredClone(value);
}

function baseResolution(config = validConfig) {
  return {
    requested: config.wolfi.baseImage,
    repository: "cgr.dev/chainguard/wolfi-base",
    platform: config.images.platform,
    digest: AMD64_DIGEST,
    pinnedReference: `cgr.dev/chainguard/wolfi-base@${AMD64_DIGEST}`,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    indexDigest: INDEX_DIGEST
  };
}

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

function expectConfigError(fn, pattern) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof WolfiConfigError, `expected WolfiConfigError, got ${error}`);
    assert.match(error.message, pattern);
    return true;
  });
}

test("loads the repository Wolfi configuration", () => {
  assert.equal(validConfig.schemaVersion, 1);
  assert.equal(validConfig.images.platform, "linux/amd64");
  assert.equal(validConfig.toolchain.helm, "4");
  assert.equal(validConfig.toolchain.oras, "1");
  assert.equal(validConfig.toolchain.mongosh, "2");
  assert.equal(validConfig.toolchain.mongodbDatabaseTools, "100");
  assert.equal(validConfig.vscode.extensions.length, 15);
});

test("rejects duplicate YAML mapping keys", () => {
  const source = validSource.replace("schemaVersion: 1", "schemaVersion: 1\nschemaVersion: 1");
  expectConfigError(() => parseWolfiConfig(source), /unique|Map keys must be unique/i);
});

test("rejects YAML aliases", () => {
  const source = validSource
    .replace("schemaVersion: 1", "schemaVersion: &schema 1")
    .replace("uid: 1000", "uid: *schema");
  expectConfigError(() => parseWolfiConfig(source), /aliases are not allowed/i);
});

test("rejects YAML merge keys", () => {
  const source = validSource.replace("user:\n", "user:\n  <<: {}\n");
  expectConfigError(() => parseWolfiConfig(source), /merge keys are not allowed/i);
});

test("rejects explicit and custom YAML tags", () => {
  const source = validSource.replace("schemaVersion: 1", "schemaVersion: !integer 1");
  expectConfigError(() => parseWolfiConfig(source), /tag/i);
});

test("rejects unknown fields", () => {
  const config = clone(validConfig);
  config.vscode.downloadEverything = true;
  expectConfigError(() => validateWolfiConfig(config), /vscode: unknown field: downloadEverything/);
});

test("rejects missing required fields", () => {
  const config = clone(validConfig);
  delete config.user.gid;
  expectConfigError(() => validateWolfiConfig(config), /user: missing required field: gid/);
});

test("rejects interpolation in any validated string", () => {
  const config = clone(validConfig);
  config.images.prefix = "${REGISTRY}";
  expectConfigError(() => validateWolfiConfig(config), /interpolation strings are not allowed/);
});

test("rejects invalid image names and prefixes", () => {
  const config = clone(validConfig);
  config.images.names.dod = "Wolfi-Base";
  expectConfigError(() => validateWolfiConfig(config), /lowercase OCI repository component/);

  config.images.names.dod = "wolfi-base-dod";
  config.images.prefix = "registry.example.com:70000/team";
  expectConfigError(() => validateWolfiConfig(config), /invalid registry host or port/);
});

test("accepts a namespaced registry prefix with a valid port", () => {
  const config = clone(validConfig);
  config.images.prefix = "localhost:5000/defense/team";
  assert.equal(validateWolfiConfig(config).images.prefix, config.images.prefix);
});

test("requires an explicitly tagged base image", () => {
  const config = clone(validConfig);
  config.wolfi.baseImage = "cgr.dev/chainguard/wolfi-base";
  expectConfigError(() => validateWolfiConfig(config), /explicit tag/);
});

test("rejects root, zero, fractional, and oversized identities", () => {
  for (const [field, value] of [
    ["name", "root"],
    ["uid", 0],
    ["gid", 1000.5],
    ["uid", 2147483648]
  ]) {
    const config = clone(validConfig);
    config.user[field] = value;
    expectConfigError(() => validateWolfiConfig(config), /non-root POSIX user name|integer between/);
  }
});

test("accepts distinct large enterprise UID and GID values", () => {
  const config = clone(validConfig);
  config.user.uid = 1234567;
  config.user.gid = 7654321;
  const normalized = validateWolfiConfig(config);
  assert.equal(normalized.user.uid, 1234567);
  assert.equal(normalized.user.gid, 7654321);
});

test("rejects duplicate extension identifiers case-insensitively", () => {
  const config = clone(validConfig);
  config.vscode.extensions.push("sonarsource.sonarlint-vscode");
  expectConfigError(() => validateWolfiConfig(config), /duplicates an earlier entry/);
});

test("rejects malformed extension identifiers", () => {
  const config = clone(validConfig);
  config.vscode.extensions[0] = "not-an-extension";
  expectConfigError(() => validateWolfiConfig(config), /publisher\.extension/);
});

test("requires HTTPS repositories without embedded credentials", () => {
  for (const repository of [
    "http://apk.example.test/wolfi",
    "https://user:password@apk.example.test/wolfi",
    "https://apk.example.test/wolfi?stream=edge",
    "https://apk.example.test/wolfi/../other"
  ]) {
    const config = clone(validConfig);
    config.wolfi.repositories.main = repository;
    expectConfigError(
      () => validateWolfiConfig(config),
      /HTTPS|credentials, a query, or a fragment|canonical URL form/
    );
  }
});

test("treats optional tool keys as enable switches", () => {
  const config = clone(validConfig);
  delete config.toolchain.helm;
  delete config.toolchain.oras;
  const normalized = validateWolfiConfig(config);
  assert.equal("helm" in normalized.toolchain, false);
  assert.equal("oras" in normalized.toolchain, false);
  assert.equal(normalized.toolchain.mongosh, "2");
});

test("requires Maven and npm runtimes when those tools are enabled", () => {
  const withoutJava = clone(validConfig);
  delete withoutJava.toolchain.java;
  expectConfigError(() => validateWolfiConfig(withoutJava), /maven.*requires toolchain\.java/);

  const withoutNode = clone(validConfig);
  delete withoutNode.toolchain.node;
  expectConfigError(() => validateWolfiConfig(withoutNode), /npm.*requires toolchain\.node/);
});

test("rejects artifact paths that can escape the artifact root", () => {
  for (const artifactPath of ["/tmp/wolfi", "artifacts/../secret", "artifacts\\wolfi"] ) {
    const config = clone(validConfig);
    config.artifacts.root = artifactPath;
    expectConfigError(() => validateWolfiConfig(config), /relative POSIX path|path components/);
  }
});

test("semantic hashing ignores YAML formatting and comments", () => {
  const commented = parseWolfiConfig(`# build parameters\n${validSource}\n`);
  assert.equal(wolfiConfigSemanticSha256(commented), wolfiConfigSemanticSha256(validConfig));
  assert.equal(canonicalJson(commented), canonicalJson(validConfig));
});

test("canonical JSON is independent of mapping insertion order", () => {
  assert.equal(canonicalJson({ z: 1, a: { y: 2, b: 3 } }), canonicalJson({ a: { b: 3, y: 2 }, z: 1 }));
});

test("derives all three tagged image references", () => {
  const images = wolfiImageReferences(validConfig);
  assert.equal(images.dod.reference, "devcontainers/wolfi-base-dod:0.1.0");
  assert.equal(images.vscode.platform, "linux/amd64");
  assert.equal(images.toolchain.repository, "devcontainers/wolfi-base-toolchain");
});

test("selects the exact platform manifest and preserves the index digest", () => {
  const selected = selectPlatformManifest({
    digest: INDEX_DIGEST,
    manifests: [
      {
        digest: AMD64_DIGEST,
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        platform: { os: "linux", architecture: "amd64" }
      },
      {
        digest: ARM64_DIGEST,
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        platform: { os: "linux", architecture: "arm64" }
      }
    ]
  }, "linux/amd64");
  assert.deepEqual(selected, {
    digest: AMD64_DIGEST,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    indexDigest: INDEX_DIGEST
  });
});

test("fails when a requested platform manifest is absent or ambiguous", () => {
  expectConfigError(() => selectPlatformManifest({ digest: INDEX_DIGEST, manifests: [] }, "linux/amd64"), /0 unambiguous manifests/);
  const duplicate = {
    digest: INDEX_DIGEST,
    manifests: [0, 1].map(() => ({
      digest: AMD64_DIGEST,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      platform: { os: "linux", architecture: "amd64" }
    }))
  };
  expectConfigError(() => selectPlatformManifest(duplicate, "linux/amd64"), /2 unambiguous manifests/);
});

test("merges disjoint resolver outputs and rejects collisions", () => {
  const stages = [
    { name: "apk", version: "1", resolved: { apk: { packages: [] } } },
    { name: "vscode", version: "1", resolved: { vscode: { commit: "abc" } } }
  ];
  const merged = mergeResolutionStages(stages);
  assert.deepEqual(Object.keys(merged.resolved), ["apk", "vscode"]);
  assert.deepEqual(merged.metadata.map(({ name }) => name), ["apk", "vscode"]);
  expectConfigError(
    () => mergeResolutionStages([...stages, { name: "other", version: "1", resolved: { apk: {} } }]),
    /both define resolved\.apk/
  );
});

test("loads only versioned, non-empty resolution fragments", () => {
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "wolfi-config-test-"));
  const validPath = path.join(tempDirectory, "valid.json");
  const invalidPath = path.join(tempDirectory, "invalid.json");
  try {
    fs.writeFileSync(validPath, JSON.stringify({
      schemaVersion: 1,
      name: "apk-resolver",
      version: "1",
      configSemanticSha256: wolfiConfigSemanticSha256(validConfig),
      resolved: { apk: { repositories: {} } }
    }));
    fs.writeFileSync(invalidPath, JSON.stringify({
      schemaVersion: 1,
      name: "apk-resolver",
      version: "1",
      configSemanticSha256: wolfiConfigSemanticSha256(validConfig),
      resolved: {},
      checksum: "made-up"
    }));
    const fragment = loadResolutionFragment(validPath, wolfiConfigSemanticSha256(validConfig));
    assert.equal(fragment.name, "apk-resolver");
    assert.match(fragment.sourceSha256, /^[a-f0-9]{64}$/);
    expectConfigError(() => loadResolutionFragment(invalidPath), /unknown fields: checksum/);
    expectConfigError(() => loadResolutionFragment(validPath, "0".repeat(64)), /different YAML configuration/);
  } finally {
    fs.rmSync(tempDirectory, { recursive: true, force: true });
  }
});

test("creates and verifies a lock containing normalized config and real resolution fields", () => {
  const lock = createWolfiLock(validConfig, {
    generatedAt: "2026-09-04T00:00:00.000Z",
    baseImage: baseResolution(),
    runtime: { dockerClient: "test", dockerBuildx: "test" }
  });
  assert.equal(lock.source.semanticSha256, wolfiConfigSemanticSha256(validConfig));
  assert.match(lock.source.fileSha256, /^[a-f0-9]{64}$/);
  assert.equal(lock.resolved.baseImage.digest, AMD64_DIGEST);
  assert.equal(verifyWolfiLock(validConfig, lock), true);
});

test("lock verification detects YAML drift", () => {
  const lock = createWolfiLock(validConfig, {
    generatedAt: "2026-09-04T00:00:00.000Z",
    baseImage: baseResolution()
  });
  const changed = clone(validConfig);
  changed.user.uid = 2000;
  expectConfigError(() => verifyWolfiLock(changed, lock), /does not match the YAML/);
});

test("lock verification rejects malformed and mismatched base-image pins", () => {
  const lock = createWolfiLock(validConfig, {
    generatedAt: "2026-09-04T00:00:00.000Z",
    baseImage: baseResolution()
  });
  lock.resolved.baseImage.pinnedReference = `cgr.dev/chainguard/wolfi-base@${ARM64_DIGEST}`;
  expectConfigError(() => verifyWolfiLock(validConfig, lock), /must combine repository and resolved platform digest/);
});

test("lock verification rejects malformed timestamps and resolver metadata", () => {
  const lock = createWolfiLock(validConfig, {
    generatedAt: "2026-09-04T00:00:00.000Z",
    baseImage: baseResolution()
  });
  lock.generatedAt = "today";
  expectConfigError(() => verifyWolfiLock(validConfig, lock), /ISO 8601 UTC timestamp/);

  lock.generatedAt = "2026-09-04T00:00:00.000Z";
  lock.resolver.stages.push({ name: "oci-base-image", version: "2" });
  expectConfigError(() => verifyWolfiLock(validConfig, lock), /duplicates resolver stage/);
});

console.log("Wolfi configuration and lockfile tests passed.");
