#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parse as parseYaml } from "yaml";
import {
  DEFAULT_CONFIG_PATH,
  PLAYWRIGHT_VERSION,
  UTILITY_CATALOG,
  WolfiConfigError,
  canonicalJson,
  companionLockPath,
  loadWolfiConfig,
  parseWolfiConfig,
  validateWolfiConfig,
  verifyWolfiLock,
  wolfiConfigSemanticSha256,
  wolfiImageReference
} from "../../src/config/config.mjs";
import {
  ImageSettingsError,
  imageReference,
  loadImageSettings,
  parseImageSettings,
  profilePaths,
  settingsFileSha256
} from "../../src/config/settings.mjs";
import {
  createWolfiLock,
  loadResolutionFragment,
  mergeResolutionStages,
  selectPlatformManifest
} from "../../src/config/lock.mjs";

const CONFIG_DIR = path.dirname(DEFAULT_CONFIG_PATH);
const settings = loadImageSettings();
const validSource = fs.readFileSync(DEFAULT_CONFIG_PATH, "utf8");
const validRaw = parseYaml(validSource);
const validConfig = loadWolfiConfig();
const AMD64_DIGEST = `sha256:${"a".repeat(64)}`;
const ARM64_DIGEST = `sha256:${"b".repeat(64)}`;
const INDEX_DIGEST = `sha256:${"c".repeat(64)}`;

const clone = structuredClone;
function test(name, fn) {
  try { fn(); console.log(`ok - ${name}`); }
  catch (error) { console.error(`not ok - ${name}`); throw error; }
}
function expectConfigError(fn, pattern) {
  assert.throws(fn, error => {
    assert.ok(error instanceof WolfiConfigError, `expected WolfiConfigError, got ${error}`);
    assert.match(error.message, pattern);
    return true;
  });
}
function expectSettingsError(source, pattern) {
  assert.throws(() => parseImageSettings(source), error => {
    assert.ok(error instanceof ImageSettingsError);
    assert.match(error.message, pattern);
    return true;
  });
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

// Naming is data, never a sourced environment.
test("strict image settings derive every public coordinate", () => {
  assert.deepEqual(settings.profiles, ["dev", "build", "kaniko"]);
  assert.equal(imageReference(settings, "dev"), "local/toolbox-dev:0.2.0");
  assert.deepEqual(profilePaths(settings, "kaniko"), {
    config: path.join(path.resolve(CONFIG_DIR, ".."), "config/kaniko.yaml"),
    lock: path.join(path.resolve(CONFIG_DIR, ".."), "config/kaniko.lock.json"),
    artifacts: "artifacts/kaniko",
    image: "local/toolbox-kaniko:0.2.0"
  });
  assert.match(settingsFileSha256(), /^[a-f0-9]{64}$/);
});

test("settings reject commands, interpolation, duplicates, unknowns, and missing keys", () => {
  const good = fs.readFileSync(path.join(CONFIG_DIR, "images.env"), "utf8");
  for (const [source, pattern] of [
    [good + "RUN=touch /tmp/pwned\n", /unknown key/],
    [good.replace("IMAGE_PREFIX=local", "IMAGE_PREFIX=$(id)"), /shell syntax/],
    [good.replace("IMAGE_FAMILY=toolbox", "IMAGE_FAMILY=${FAMILY}"), /shell syntax/],
    [good + "IMAGE_VERSION=2\n", /duplicates/],
    [good.replace(/^IMAGE_VERSION=.*\n/m, ""), /missing required key/],
    [good.replace("IMAGE_PROFILES=dev,build,kaniko", "IMAGE_PROFILES=dev,dev"), /duplicate profile/],
  ]) expectSettingsError(source, pattern);
});

test("three profiles are structurally parallel where software is shared", () => {
  const profiles = Object.fromEntries(settings.profiles.map(name => [name, loadWolfiConfig(path.join(CONFIG_DIR, `${name}.yaml`))]));
  for (const [name, config] of Object.entries(profiles)) {
    assert.equal(config.schemaVersion, 3);
    assert.equal(config.profile, name);
    assert.equal(config.image.reference, `local/toolbox-${name}:0.2.0`);
    assert.equal(config.artifacts.root, `artifacts/${name}`);
    assert.deepEqual(config.build, profiles.dev.build);
    assert.deepEqual(config.playwright, profiles.dev.playwright);
    assert.deepEqual(config.utilities, profiles.dev.utilities);
    assert.deepEqual(Object.keys(config.utilities).sort(), Object.keys(UTILITY_CATALOG).sort());
    assert.equal("clamav" in config.utilities, false);
  }
  assert.equal(profiles.dev.devcontainer, true);
  assert.equal(profiles.dev.docker.socket, true);
  assert.ok(profiles.dev.vscode);
  assert.equal(profiles.build.devcontainer, false);
  assert.deepEqual(profiles.build.docker, {cli: "latest", buildx: "latest", compose: "latest", socket: false});
  assert.ok(profiles.kaniko.kaniko);
  for (const field of ["user", "docker", "vscode"]) assert.equal(field in profiles.kaniko, false);
});

test("profile role boundaries reject accidental capability crossover", () => {
  const dev = clone(validRaw);
  delete dev.vscode;
  expectConfigError(() => validateWolfiConfig(dev), /dev requires user, devcontainer, and vscode/);
  const build = parseYaml(fs.readFileSync(path.join(CONFIG_DIR, "build.yaml"), "utf8"));
  build.vscode = {version: "1.136.1"};
  expectConfigError(() => validateWolfiConfig(build), /build must be a root CI image/);
  const kaniko = parseYaml(fs.readFileSync(path.join(CONFIG_DIR, "kaniko.yaml"), "utf8"));
  kaniko.docker = {cli: "latest"};
  expectConfigError(() => validateWolfiConfig(kaniko), /kaniko must be a root CI image/);
});

test("schema-v2 and derived source fields receive migration guidance", () => {
  const old = clone(validRaw);
  old.schemaVersion = 2;
  expectConfigError(() => validateWolfiConfig(old), /integer 3/);
  const derived = clone(validRaw);
  derived.image.reference = "example/image:1";
  expectConfigError(() => validateWolfiConfig(derived), /image: unknown field: reference/);
  const artifact = clone(validRaw);
  artifact.artifacts = {root: "artifacts/custom"};
  expectConfigError(() => validateWolfiConfig(artifact), /unknown field: artifacts/);
});

test("YAML aliases, merge keys, tags, duplicate keys, and interpolation are rejected", () => {
  expectConfigError(() => parseWolfiConfig(validSource.replace("schemaVersion: 3", "schemaVersion: 3\nschemaVersion: 3")), /unique/i);
  expectConfigError(() => parseWolfiConfig(validSource.replace("schemaVersion: 3", "schemaVersion: &v 3").replace("uid: 1000", "uid: *v")), /aliases/i);
  expectConfigError(() => parseWolfiConfig(validSource.replace("user:\n", "user:\n  <<: {}\n")), /merge keys/i);
  expectConfigError(() => parseWolfiConfig(validSource.replace("schemaVersion: 3", "schemaVersion: !number 3")), /tag/i);
  const injected = clone(validRaw);
  injected.wolfi.baseImage = "${BASE_IMAGE}";
  expectConfigError(() => validateWolfiConfig(injected), /interpolation/);
});

test("dependency and selector validation remains strict", () => {
  const withoutJava = clone(validRaw);
  delete withoutJava.build.java;
  expectConfigError(() => validateWolfiConfig(withoutJava), /maven.*requires build.java/);
  const withoutNode = clone(validRaw);
  delete withoutNode.build.node;
  expectConfigError(() => validateWolfiConfig(withoutNode), /npm.*requires build.node/);
  const badRust = clone(validRaw);
  badRust.build.rust.toolchain = "nightly";
  expectConfigError(() => validateWolfiConfig(badRust), /dated nightly/);
  const badExtension = clone(validRaw);
  badExtension.build.rust.components = ["rust-src"];
  expectConfigError(() => validateWolfiConfig(badExtension), /rust-analyzer.*offline activation/);
  assert.equal(PLAYWRIGHT_VERSION, "1.63.0");
});

test("repositories and identities reject unsafe values", () => {
  for (const repository of ["http://example.test/wolfi", "https://u:p@example.test/wolfi", "https://example.test/wolfi?q=1"] ) {
    const raw = clone(validRaw); raw.wolfi.repositories.main = repository;
    expectConfigError(() => validateWolfiConfig(raw), /HTTPS|credentials, a query/);
  }
  for (const [field, value] of [["name", "root"], ["uid", 0], ["gid", 1.5], ["uid", 2147483648]]) {
    const raw = clone(validRaw); raw.user[field] = value;
    expectConfigError(() => validateWolfiConfig(raw), /non-root POSIX|integer between/);
  }
});

test("semantic hashing is canonical and includes derived naming settings", () => {
  const commented = parseWolfiConfig(`# comment\n${validSource}\n`);
  assert.equal(wolfiConfigSemanticSha256(commented), wolfiConfigSemanticSha256(validConfig));
  assert.equal(canonicalJson({z: 1, a: {y: 2}}), canonicalJson({a: {y: 2}, z: 1}));
  assert.deepEqual(wolfiImageReference(validConfig), {reference: "local/toolbox-dev:0.2.0", platform: "linux/amd64"});
  assert.equal(companionLockPath("config/dev.yaml"), "config/dev.lock.json");
});

test("platform manifest and resolver-stage selection are deterministic", () => {
  const selected = selectPlatformManifest({digest: INDEX_DIGEST, manifests: [
    {digest: AMD64_DIGEST, mediaType: "application/vnd.oci.image.manifest.v1+json", platform: {os: "linux", architecture: "amd64"}},
    {digest: ARM64_DIGEST, mediaType: "application/vnd.oci.image.manifest.v1+json", platform: {os: "linux", architecture: "arm64"}}
  ]}, "linux/amd64");
  assert.deepEqual(selected, {digest: AMD64_DIGEST, mediaType: "application/vnd.oci.image.manifest.v1+json", indexDigest: INDEX_DIGEST});
  expectConfigError(() => selectPlatformManifest({digest: INDEX_DIGEST, manifests: []}, "linux/amd64"), /0 unambiguous/);
  const merged = mergeResolutionStages([{name: "apk", version: "1", resolved: {apk: {}}}, {name: "vendor", version: "1", resolved: {vscode: {}}}]);
  assert.deepEqual(Object.keys(merged.resolved), ["apk", "vscode"]);
  expectConfigError(() => mergeResolutionStages([{name: "a", version: "1", resolved: {apk: {}}}, {name: "b", version: "1", resolved: {apk: {}}}]), /both define/);
});

test("resolution fragments are hash-bound and reject invented fields", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "image-config-test-"));
  try {
    const file = path.join(directory, "fragment.json");
    fs.writeFileSync(file, JSON.stringify({schemaVersion: 1, name: "apk", version: "1", configSemanticSha256: wolfiConfigSemanticSha256(validConfig), resolved: {apk: {packages: []}}}));
    assert.equal(loadResolutionFragment(file, wolfiConfigSemanticSha256(validConfig)).name, "apk");
    expectConfigError(() => loadResolutionFragment(file, "0".repeat(64)), /different YAML/);
    const value = JSON.parse(fs.readFileSync(file)); value.checksum = "invented"; fs.writeFileSync(file, JSON.stringify(value));
    expectConfigError(() => loadResolutionFragment(file), /unknown fields/);
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});

test("base-only schema-v3 locks bind YAML and images.env", () => {
  const lock = createWolfiLock(validConfig, {generatedAt: "2026-09-05T00:00:00.000Z", baseImage: baseResolution()});
  assert.equal(lock.schemaVersion, 3);
  assert.equal(lock.source.settingsFileSha256, settingsFileSha256());
  assert.equal(lock.resolver.version, 3);
  assert.equal(verifyWolfiLock(validConfig, lock, {requireArtifacts: false}), true);
  const changed = clone(lock); changed.source.settingsFileSha256 = "0".repeat(64);
  expectConfigError(() => verifyWolfiLock(validConfig, changed, {requireArtifacts: false}), /config\/images.env/);
});

test("all committed locks are complete schema-v3 locks", () => {
  for (const name of settings.profiles) {
    const configPath = path.join(CONFIG_DIR, `${name}.yaml`);
    const lockPath = companionLockPath(configPath);
    const config = loadWolfiConfig(configPath);
    const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
    assert.equal(verifyWolfiLock(config, lock), true);
  }
});

console.log("Toolbox configuration and lock tests passed.");
