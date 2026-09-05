#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  DEFAULT_CONFIG_PATH,
  UTILITY_CATALOG,
  PLAYWRIGHT_VERSION,
  WolfiConfigError,
  canonicalJson,
  loadWolfiConfig,
  parseWolfiConfig,
  validateWolfiConfig,
  verifyWolfiLock,
  wolfiConfigSemanticSha256,
  companionLockPath,
  wolfiImageReference
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
    platform: config.image.platform,
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
  assert.equal(validConfig.schemaVersion, 2);
  assert.equal(validConfig.image.platform, "linux/amd64");
  assert.equal(validConfig.utilities.helm, "4");
  assert.equal(validConfig.utilities.oras, "1");
  assert.equal(validConfig.utilities.mongosh, "2");
  assert.equal(validConfig.utilities.mongodbDatabaseTools, "100");
  assert.ok(validConfig.build.rust.components.includes("rust-analyzer"));
  assert.equal(validConfig.vscode.extensions.length, 15);
});

test("CI and development profiles select the same tools with isolated outputs", () => {
  const ci = loadWolfiConfig(path.join(path.dirname(DEFAULT_CONFIG_PATH), "wolfi-ci.yaml"));
  assert.deepEqual(ci.build, validConfig.build);
  assert.deepEqual(ci.utilities, validConfig.utilities);
  assert.deepEqual(ci.kaniko, {version: "1.28.4"});
  assert.equal(ci.devcontainer, false);
  for (const key of ["user", "docker", "vscode"]) assert.equal(key in ci, false);
  assert.notEqual(ci.artifacts.root, validConfig.artifacts.root);
  assert.notEqual(ci.image.reference, validConfig.image.reference);
});

test("minimal profiles need no identity, editor, Docker, or toolchain", () => {
  const config = clone(validConfig);
  for (const key of ["user", "docker", "vscode", "build", "utilities", "kaniko", "playwright", "devcontainer"]) delete config[key];
  const normalized = validateWolfiConfig(config);
  assert.deepEqual(normalized.build, {});
  assert.equal(normalized.devcontainer, false);
  assert.equal("user" in normalized, false);
  assert.equal("docker" in normalized, false);
  assert.equal("vscode" in normalized, false);
});

test("VS Code alone has stable quality and no extension archive selection", () => {
  const config = clone(validConfig);
  config.vscode = { version: "1.136.1" };
  assert.deepEqual(validateWolfiConfig(config).vscode, { version: "1.136.1", quality: "stable", extensions: [] });
});

test("Dev Container metadata requires an explicit non-root remote user", () => {
  const config = clone(validConfig);
  delete config.user;
  delete config.docker;
  expectConfigError(() => validateWolfiConfig(config), /devcontainer.*requires a configured non-root user/);
});

test("Docker clients are independent of socket integration", () => {
  const config = clone(validConfig);
  delete config.user;
  config.devcontainer = false;
  config.docker = { cli: "latest" };
  assert.deepEqual(validateWolfiConfig(config).docker, { cli: "latest", socket: false });
  config.docker = { compose: "latest" };
  assert.deepEqual(validateWolfiConfig(config).docker, { compose: "latest", socket: false });
  config.docker = { buildx: "latest" };
  expectConfigError(() => validateWolfiConfig(config), /buildx.*requires docker.cli/);
});

test("socket integration validates CLI, remote identity, and devcontainer startup", () => {
  for (const missing of ["cli", "user", "devcontainer"]) {
    const config = clone(validConfig);
    if (missing === "cli") delete config.docker.cli;
    if (missing === "user") delete config.user;
    if (missing === "devcontainer") config.devcontainer = false;
    expectConfigError(() => validateWolfiConfig(config), /requires/);
  }
  const config = clone(validConfig);
  config.docker.socket = "false";
  expectConfigError(() => validateWolfiConfig(config), /must be a boolean/);
});

test("rejects null optional mappings and ambiguous legacy schema", () => {
  for (const key of ["user", "docker", "vscode", "build", "utilities", "kaniko", "playwright", "devcontainer"]) {
    const config = clone(validConfig);
    config[key] = null;
    expectConfigError(() => validateWolfiConfig(config), /must be a mapping|must be a boolean/);
  }
  const config = clone(validConfig);
  config.schemaVersion = 1;
  expectConfigError(() => validateWolfiConfig(config), /migrate legacy/);
});

test("offline Rust analyzer extensions require the locked language server component", () => {
  const config = clone(validConfig);
  config.build.rust.components = ["rust-src"];
  expectConfigError(() => validateWolfiConfig(config), /rust-analyzer.*offline activation/);
});

test("Rust selectors must match the installer's dated nightly contract", () => {
  for (const selector of ["stable", "beta", "nightly", "latest", "1.99.0", "nightly-2026-9-4", "nightly-2026-09-04-x86_64-unknown-linux-gnu"]) {
    const config = clone(validConfig);
    config.build.rust.toolchain = selector;
    expectConfigError(() => validateWolfiConfig(config), /build\.rust\.toolchain: must be a dated nightly/);
  }
  const config = clone(validConfig);
  config.build.rust.toolchain = "nightly-2026-09-04";
  assert.equal(validateWolfiConfig(config).build.rust.toolchain, "nightly-2026-09-04");
});

test("Rust may select no optional components without an analyzer VSIX", () => {
  const config = clone(validConfig);
  delete config.vscode;
  config.build.rust.components = [];
  assert.deepEqual(validateWolfiConfig(config).build.rust.components, []);
  config.vscode = { version: "1.136.1", extensions: ["rust-lang.rust-analyzer"] };
  expectConfigError(() => validateWolfiConfig(config), /rust-analyzer.*offline activation/);
});

test("VS Code commit overrides are outside the schema", () => {
  const config = clone(validConfig);
  config.vscode.commit = "a".repeat(40);
  expectConfigError(() => validateWolfiConfig(config), /vscode: unknown field: commit/);
});

test("rejects duplicate YAML mapping keys", () => {
  const source = validSource.replace("schemaVersion: 2", "schemaVersion: 2\nschemaVersion: 2");
  expectConfigError(() => parseWolfiConfig(source), /unique|Map keys must be unique/i);
});

test("rejects YAML aliases", () => {
  const source = validSource
    .replace("schemaVersion: 2", "schemaVersion: &schema 2")
    .replace("uid: 1000", "uid: *schema");
  expectConfigError(() => parseWolfiConfig(source), /aliases are not allowed/i);
});

test("rejects YAML merge keys", () => {
  const source = validSource.replace("user:\n", "user:\n  <<: {}\n");
  expectConfigError(() => parseWolfiConfig(source), /merge keys are not allowed/i);
});

test("rejects explicit and custom YAML tags", () => {
  const source = validSource.replace("schemaVersion: 2", "schemaVersion: !integer 2");
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
  config.image.reference = "${REGISTRY}/example:1";
  expectConfigError(() => validateWolfiConfig(config), /interpolation strings are not allowed/);
});

test("rejects invalid image references and registry ports", () => {
  const config = clone(validConfig);
  config.image.reference = "devcontainers/Wolfi-Dev:1";
  expectConfigError(() => validateWolfiConfig(config), /invalid OCI path component/);
  config.image.reference = "registry.example.com:70000/team/image:1";
  expectConfigError(() => validateWolfiConfig(config), /invalid registry host or port/);
  config.image.reference = "devcontainers/wolfi-dev";
  expectConfigError(() => validateWolfiConfig(config), /explicit tag/);
});

test("accepts namespaced registry references with a valid port", () => {
  const config = clone(validConfig);
  config.image.reference = "localhost:5000/defense/team/image:2026.09";
  assert.equal(validateWolfiConfig(config).image.reference, config.image.reference);
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
  delete config.utilities.helm;
  delete config.utilities.oras;
  const normalized = validateWolfiConfig(config);
  assert.equal("helm" in normalized.utilities, false);
  assert.equal("oras" in normalized.utilities, false);
  assert.equal(normalized.utilities.mongosh, "2");
});

test("native build tools can be selected without Clang", () => {
  const config = clone(validConfig);
  config.build.native = {};
  assert.deepEqual(validateWolfiConfig(config).build.native, {});
});

test("requires Maven and npm runtimes when those tools are enabled", () => {
  const withoutJava = clone(validConfig);
  delete withoutJava.build.java;
  expectConfigError(() => validateWolfiConfig(withoutJava), /maven.*requires build\.java/);

  const withoutNode = clone(validConfig);
  delete withoutNode.build.node;
  expectConfigError(() => validateWolfiConfig(withoutNode), /npm.*requires build\.node/);
});

test("accepts only supported frozen Rust components", () => {
  const config = clone(validConfig);
  config.build.rust.components[0] = "rust-docs";
  expectConfigError(() => validateWolfiConfig(config), /unsupported component: rust-docs/);
});

test("rejects artifact paths that can escape the artifact root", () => {
  for (const artifactPath of ["/tmp/wolfi", "artifacts/../secret", "artifacts\\wolfi", "artifacts", "tmp/cache"] ) {
    const config = clone(validConfig);
    config.artifacts.root = artifactPath;
    expectConfigError(() => validateWolfiConfig(config), /relative POSIX path|path components|dedicated directory/);
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

test("has one configured image and derives its companion lock path", () => {
  assert.deepEqual(wolfiImageReference(validConfig), {
    reference: "devcontainers/wolfi-dev:0.1.0", platform: "linux/amd64"
  });
  assert.equal(companionLockPath("config/wolfi-ci.yaml"), "config/wolfi-ci.lock.json");
  assert.equal(companionLockPath("profile.yml"), "profile.lock.json");
  assert.equal(companionLockPath("profile"), "profile.lock.json");
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

test("base-resolution intermediates require explicit incomplete-lock verification", () => {
  const lock = createWolfiLock(validConfig, {
    generatedAt: "2026-09-04T00:00:00.000Z",
    baseImage: baseResolution(),
    runtime: { dockerClient: "test", dockerBuildx: "test" }
  });
  assert.equal(lock.source.semanticSha256, wolfiConfigSemanticSha256(validConfig));
  assert.match(lock.source.fileSha256, /^[a-f0-9]{64}$/);
  assert.equal(lock.resolved.baseImage.digest, AMD64_DIGEST);
  assert.equal(verifyWolfiLock(validConfig, lock, { requireArtifacts: false }), true);
  expectConfigError(() => verifyWolfiLock(validConfig, lock), /must contain the artifact mapping/);
});

test("legacy toolchain entries receive migration guidance", () => {
  expectConfigError(() => validateWolfiConfig({...validConfig, toolchain: {}}), /migrate.*build.*utilities/);
});

test("every reviewed utility works independently and unsafe umbrella packages are rejected", () => {
  for (const key of Object.keys(UTILITY_CATALOG)) {
    const config = clone(validConfig);
    config.utilities = {[key]: UTILITY_CATALOG[key].exampleSelector};
    assert.deepEqual(validateWolfiConfig(config).utilities, config.utilities);
  }
  for (const key of ["openssh", "openssh-server", "alpine-sdk", "curl-minimal"]) {
    expectConfigError(() => validateWolfiConfig({...validConfig, utilities: {[key]: "latest"}}), /unknown field/);
  }
});

test("Playwright supports a maintained default, an exact version, and complete omission", () => {
  assert.deepEqual(validateWolfiConfig({...validConfig, playwright: true}).playwright, {version: PLAYWRIGHT_VERSION});
  assert.deepEqual(validateWolfiConfig({...validConfig, playwright: {version: "1.63.0"}}).playwright, {version: "1.63.0"});
  assert.equal("playwright" in validateWolfiConfig({...validConfig, playwright: false}), false);
  for (const playwright of [null, {}, "true", {version: "latest"}, {version: "1.63"}, {version: "1.63.0", firefox: true}]) {
    expectConfigError(() => validateWolfiConfig({...validConfig, playwright}), /playwright/);
  }
  for (const build of [{}, {node: "24"}]) {
    expectConfigError(() => validateWolfiConfig({...validConfig, vscode: {version: "1.136.1"}, build, playwright: true}), /requires build.node and build.npm/);
  }
});

test("Kaniko is independent of Docker and requires an exact version", () => {
  const config = { ...validConfig, kaniko: {version: "1.28.4"}};
  delete config.docker;
  assert.deepEqual(validateWolfiConfig(config).kaniko, {version: "1.28.4"});
  for (const kaniko of [true, null, {}, {version: "latest"}, {version: "1.28"}]) {
    expectConfigError(() => validateWolfiConfig({...validConfig, kaniko}), /kaniko/);
  }
});

test("complete default locks retain all selected artifact records", () => {
  for (const configName of ["wolfi-ci.yaml", "wolfi-dev.yaml"]) {
    const configPath = path.join(path.dirname(DEFAULT_CONFIG_PATH), configName);
    const config = loadWolfiConfig(configPath);
    const lock = JSON.parse(fs.readFileSync(companionLockPath(configPath), "utf8"));
    assert.equal(verifyWolfiLock(config, lock), true);
  }
});

test("final APK package sets accept single-repository compatibility metadata", () => {
  const lock = JSON.parse(fs.readFileSync(companionLockPath(DEFAULT_CONFIG_PATH), "utf8"));
  const final = lock.resolved.apk.packageSets.final;
  assert.deepEqual(final.repositorySubdirs, ["repositories/extra", "repositories/main"]);
  final.repositorySubdirs = ["repositories/main"];
  final.repositorySubdir = "repositories/main";
  assert.equal(verifyWolfiLock(validConfig, lock), true);
});

test("frozen locks reject absent, null, empty, and non-object selected vendor records", () => {
  const complete = JSON.parse(fs.readFileSync(companionLockPath(DEFAULT_CONFIG_PATH), "utf8"));
  for (const name of ["vscode", "extensions", "kubectl", "rust"]) {
    for (const replacement of [undefined, null, {}, [], false]) {
      const lock = clone(complete);
      if (replacement === undefined) delete lock.resolved[name];
      else lock.resolved[name] = replacement;
      expectConfigError(() => verifyWolfiLock(validConfig, lock), new RegExp(`lock\\.resolved\\.${name}: must contain`));
    }
  }
});

test("frozen Kaniko records must match the selected version and architecture", () => {
  const configPath = path.join(path.dirname(DEFAULT_CONFIG_PATH), "wolfi-ci.yaml");
  const config = loadWolfiConfig(configPath);
  const complete = JSON.parse(fs.readFileSync(companionLockPath(configPath), "utf8"));
  for (const patch of [{version: "1.28.3"}, {platform: "linux/arm64"}]) {
    const lock = clone(complete);
    Object.assign(lock.resolved.kaniko, patch);
    expectConfigError(() => verifyWolfiLock(config, lock), /version\/platform differs/);
  }
});

test("frozen locks require one complete final APK package set", () => {
  const complete = JSON.parse(fs.readFileSync(companionLockPath(DEFAULT_CONFIG_PATH), "utf8"));
  for (const mutate of [
    (lock) => { delete lock.resolved.apk; },
    (lock) => { lock.resolved.apk = null; },
    (lock) => { delete lock.resolved.apk.packageSets; },
    (lock) => { delete lock.resolved.apk.packageSets.final; },
    (lock) => { lock.resolved.apk.packageSets.legacy = {}; },
    (lock) => { lock.resolved.apk.packageSets.final = null; },
    (lock) => { lock.resolved.apk.packageSets.final.artifactDirectory = ""; }
  ]) {
    const lock = clone(complete);
    mutate(lock);
    expectConfigError(() => verifyWolfiLock(validConfig, lock), /lock\.resolved\.apk/);
  }
  for (const field of ["closure", "modules", "packages", "repositorySubdirs", "roots"]) {
    for (const replacement of [undefined, null, [], {}]) {
      const lock = clone(complete);
      if (replacement === undefined) delete lock.resolved.apk.packageSets.final[field];
      else lock.resolved.apk.packageSets.final[field] = replacement;
      expectConfigError(() => verifyWolfiLock(validConfig, lock), /lock\.resolved\.apk\.packageSets\.final/);
    }
  }
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

test("lock verification rejects a different output image and disabled vendor artifacts", () => {
  const lock = createWolfiLock(validConfig, { baseImage: baseResolution() });
  lock.image.reference = "devcontainers/wolfi-ci:0.1.0";
  expectConfigError(() => verifyWolfiLock(validConfig, lock), /image coordinates/);

  const config = clone(validConfig);
  delete config.vscode;
  const withoutEditor = createWolfiLock(config, { baseImage: baseResolution(config) });
  withoutEditor.resolved.vscode = { commit: "stale" };
  expectConfigError(() => verifyWolfiLock(config, withoutEditor), /artifact disabled/);
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
