#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  isAlias,
  isMap,
  isPair,
  isScalar,
  isSeq,
  parseDocument
} from "yaml";

const REPO_ROOT = fileURLToPath(new URL("../../", import.meta.url));
const DEFAULT_CONFIG_PATH = path.join(REPO_ROOT, "config/wolfi-build.yaml");
const DEFAULT_LOCK_PATH = path.join(REPO_ROOT, "config/wolfi-build.lock.json");
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const IMAGE_COMPONENT_PATTERN = /^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$/;
const IMAGE_TAG_PATTERN = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;
const SELECTOR_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/;
const EXTENSION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$/;
const USER_NAME_PATTERN = /^[a-z_][a-z0-9_-]{0,31}$/;
const MAX_LINUX_ID = 2147483647;

export class WolfiConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = "WolfiConfigError";
  }
}

function configError(location, message) {
  throw new WolfiConfigError(`${location}: ${message}`);
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function inspectYamlNode(node, location = "document") {
  if (node == null) {
    return;
  }

  if (isAlias(node)) {
    configError(location, "YAML aliases are not allowed");
  }
  if (node.tag != null) {
    configError(location, "explicit or custom YAML tags are not allowed");
  }

  if (isMap(node)) {
    for (const pair of node.items) {
      inspectYamlNode(pair, location);
    }
    return;
  }

  if (isSeq(node)) {
    node.items.forEach((item, index) => inspectYamlNode(item, `${location}[${index}]`));
    return;
  }

  if (isPair(node)) {
    if (!isScalar(node.key) || typeof node.key.value !== "string") {
      configError(location, "mapping keys must be strings");
    }
    if (node.key.value === "<<") {
      configError(location, "YAML merge keys are not allowed");
    }
    inspectYamlNode(node.key, `${location}.${node.key.value}`);
    inspectYamlNode(node.value, `${location}.${node.key.value}`);
  }
}

function recordAt(value, location, requiredKeys, optionalKeys = []) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    configError(location, "must be a mapping");
  }

  const allowedKeys = new Set([...requiredKeys, ...optionalKeys]);
  const unknownKeys = Object.keys(value).filter((key) => !allowedKeys.has(key));
  if (unknownKeys.length > 0) {
    configError(location, `unknown field${unknownKeys.length === 1 ? "" : "s"}: ${unknownKeys.join(", ")}`);
  }

  const missingKeys = requiredKeys.filter((key) => !hasOwn(value, key));
  if (missingKeys.length > 0) {
    configError(location, `missing required field${missingKeys.length === 1 ? "" : "s"}: ${missingKeys.join(", ")}`);
  }

  return value;
}

function stringAt(value, location, { minLength = 1, maxLength = 256 } = {}) {
  if (typeof value !== "string") {
    configError(location, "must be a string");
  }
  if (value.length < minLength || value.length > maxLength) {
    configError(location, `must contain between ${minLength} and ${maxLength} characters`);
  }
  if (value !== value.trim()) {
    configError(location, "must not have leading or trailing whitespace");
  }
  if (value.includes("${")) {
    configError(location, "interpolation strings are not allowed");
  }
  if (/\p{Cc}/u.test(value)) {
    configError(location, "must not contain control characters");
  }
  return value;
}

function selectorAt(value, location) {
  const selector = stringAt(value, location, { maxLength: 128 });
  if (!SELECTOR_PATTERN.test(selector)) {
    configError(location, "must be a literal version or 'latest' selector");
  }
  return selector;
}

function imageComponentAt(value, location) {
  const component = stringAt(value, location, { maxLength: 128 });
  if (!IMAGE_COMPONENT_PATTERN.test(component)) {
    configError(location, "must be a lowercase OCI repository component");
  }
  return component;
}

function imagePrefixAt(value, location) {
  const prefix = stringAt(value, location, { maxLength: 255 });
  if (prefix.includes("@") || prefix.endsWith("/") || prefix.startsWith("/")) {
    configError(location, "must be an untagged OCI image prefix");
  }

  const components = prefix.split("/");
  if (components.some((component) => component.length === 0)) {
    configError(location, "must not contain empty path components");
  }

  components.forEach((component, index) => {
    if (index === 0 && component.includes(":")) {
      const separator = component.lastIndexOf(":");
      const host = component.slice(0, separator);
      const port = component.slice(separator + 1);
      if (!IMAGE_COMPONENT_PATTERN.test(host) || !/^[1-9][0-9]{0,4}$/.test(port) || Number(port) > 65535) {
        configError(location, "contains an invalid registry host or port");
      }
      return;
    }
    if (!IMAGE_COMPONENT_PATTERN.test(component)) {
      configError(location, `contains an invalid OCI path component: ${component}`);
    }
  });

  return prefix;
}

export function splitMutableImageReference(value, location = "image") {
  const reference = stringAt(value, location, { maxLength: 512 });
  if (reference.includes("@")) {
    configError(location, "must use a mutable tag; the lockfile records the resolved digest");
  }

  const lastSlash = reference.lastIndexOf("/");
  const lastColon = reference.lastIndexOf(":");
  if (lastColon <= lastSlash) {
    configError(location, "must include an explicit tag");
  }

  const repository = reference.slice(0, lastColon);
  const tag = reference.slice(lastColon + 1);
  imagePrefixAt(repository, location);
  if (!IMAGE_TAG_PATTERN.test(tag)) {
    configError(location, "contains an invalid OCI tag");
  }

  return { reference, repository, tag };
}

function relativeArtifactPathAt(value, location) {
  const artifactPath = stringAt(value, location, { maxLength: 512 });
  if (artifactPath.includes("\\") || path.posix.isAbsolute(artifactPath)) {
    configError(location, "must be a relative POSIX path");
  }
  const components = artifactPath.split("/");
  if (components.some((component) => component === "" || component === "." || component === "..")) {
    configError(location, "must not contain empty, '.' or '..' path components");
  }
  if (path.posix.normalize(artifactPath) !== artifactPath) {
    configError(location, "must be a normalized relative POSIX path");
  }
  return artifactPath;
}

function repositoryUrlAt(value, location) {
  const rawUrl = stringAt(value, location, { maxLength: 512 });
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    configError(location, "must be a valid HTTPS URL");
  }
  if (parsed.protocol !== "https:") {
    configError(location, "must use HTTPS");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    configError(location, "must not include credentials, a query, or a fragment");
  }
  if (!parsed.hostname || parsed.pathname === "/" || rawUrl.endsWith("/")) {
    configError(location, "must identify a repository path without a trailing slash");
  }
  if (parsed.href !== rawUrl) {
    configError(location, "must use its canonical URL form without encoded or dot path segments");
  }
  return rawUrl;
}

function linuxIdAt(value, location) {
  if (!Number.isInteger(value) || value < 1 || value > MAX_LINUX_ID) {
    configError(location, `must be an integer between 1 and ${MAX_LINUX_ID}`);
  }
  return value;
}

function extensionIdAt(value, location) {
  const extensionId = stringAt(value, location, { maxLength: 256 });
  if (!EXTENSION_ID_PATTERN.test(extensionId)) {
    configError(location, "must use a publisher.extension identifier");
  }
  return extensionId;
}

function uniqueArrayAt(value, location, validateItem, { minItems = 0, maxItems = 256, caseInsensitive = false } = {}) {
  if (!Array.isArray(value)) {
    configError(location, "must be a sequence");
  }
  if (value.length < minItems || value.length > maxItems) {
    configError(location, `must contain between ${minItems} and ${maxItems} entries`);
  }

  const seen = new Set();
  return value.map((item, index) => {
    const normalizedItem = validateItem(item, `${location}[${index}]`);
    const uniquenessKey = caseInsensitive && typeof normalizedItem === "string"
      ? normalizedItem.toLowerCase()
      : JSON.stringify(normalizedItem);
    if (seen.has(uniquenessKey)) {
      configError(`${location}[${index}]`, `duplicates an earlier entry: ${normalizedItem}`);
    }
    seen.add(uniquenessKey);
    return normalizedItem;
  });
}

function normalizeToolchain(value) {
  const toolchain = recordAt(value, "toolchain", [], [
    "build",
    "python",
    "java",
    "maven",
    "node",
    "npm",
    "clamav",
    "kubectl",
    "yq",
    "helm",
    "oras",
    "mongosh",
    "mongodbDatabaseTools",
    "rust"
  ]);
  const normalized = {};

  if (hasOwn(toolchain, "build")) {
    const build = recordAt(toolchain.build, "toolchain.build", ["clang"]);
    normalized.build = { clang: selectorAt(build.clang, "toolchain.build.clang") };
  }
  if (hasOwn(toolchain, "python")) {
    normalized.python = uniqueArrayAt(toolchain.python, "toolchain.python", selectorAt, { minItems: 1, maxItems: 8 });
  }

  for (const key of [
    "java",
    "maven",
    "node",
    "npm",
    "clamav",
    "kubectl",
    "yq",
    "helm",
    "oras",
    "mongosh",
    "mongodbDatabaseTools"
  ]) {
    if (hasOwn(toolchain, key)) {
      normalized[key] = selectorAt(toolchain[key], `toolchain.${key}`);
    }
  }

  if (hasOwn(toolchain, "maven") && !hasOwn(toolchain, "java")) {
    configError("toolchain.maven", "requires toolchain.java");
  }
  if (hasOwn(toolchain, "npm") && !hasOwn(toolchain, "node")) {
    configError("toolchain.npm", "requires toolchain.node");
  }

  if (hasOwn(toolchain, "rust")) {
    const rust = recordAt(toolchain.rust, "toolchain.rust", ["toolchain", "components"]);
    const allowedComponents = new Set(["rust-src", "rustfmt", "clippy"]);
    const components = uniqueArrayAt(rust.components, "toolchain.rust.components", selectorAt, {
      minItems: 1,
      maxItems: allowedComponents.size
    });
    for (const component of components) {
      if (!allowedComponents.has(component)) {
        configError("toolchain.rust.components", `unsupported component: ${component}`);
      }
    }
    normalized.rust = {
      toolchain: selectorAt(rust.toolchain, "toolchain.rust.toolchain"),
      components
    };
  }

  return normalized;
}

export function validateWolfiConfig(value) {
  const root = recordAt(value, "config", [
    "schemaVersion",
    "images",
    "artifacts",
    "wolfi",
    "user",
    "docker",
    "vscode",
    "toolchain"
  ]);

  if (root.schemaVersion !== 1) {
    configError("schemaVersion", "must be the integer 1");
  }

  const images = recordAt(root.images, "images", ["prefix", "version", "platform", "names"]);
  const imageNames = recordAt(images.names, "images.names", ["dod", "vscode", "toolchain"]);
  const normalizedNames = {
    dod: imageComponentAt(imageNames.dod, "images.names.dod"),
    vscode: imageComponentAt(imageNames.vscode, "images.names.vscode"),
    toolchain: imageComponentAt(imageNames.toolchain, "images.names.toolchain")
  };
  if (new Set(Object.values(normalizedNames)).size !== Object.keys(normalizedNames).length) {
    configError("images.names", "image names must be unique");
  }
  const platform = stringAt(images.platform, "images.platform", { maxLength: 32 });
  if (!new Set(["linux/amd64", "linux/arm64"]).has(platform)) {
    configError("images.platform", "must be linux/amd64 or linux/arm64");
  }
  const imageVersion = stringAt(images.version, "images.version", { maxLength: 128 });
  if (!IMAGE_TAG_PATTERN.test(imageVersion)) {
    configError("images.version", "must be a valid OCI tag");
  }

  const artifacts = recordAt(root.artifacts, "artifacts", ["root"]);
  const wolfi = recordAt(root.wolfi, "wolfi", ["baseImage", "repositories"]);
  const repositories = recordAt(wolfi.repositories, "wolfi.repositories", ["main", "extra"]);
  const user = recordAt(root.user, "user", ["name", "uid", "gid"]);
  const docker = recordAt(root.docker, "docker", ["cli", "buildx", "compose"]);
  const vscode = recordAt(root.vscode, "vscode", ["version", "quality", "extensions"]);

  const userName = stringAt(user.name, "user.name", { maxLength: 32 });
  if (!USER_NAME_PATTERN.test(userName) || userName === "root") {
    configError("user.name", "must be a non-root POSIX user name");
  }
  const quality = stringAt(vscode.quality, "vscode.quality", { maxLength: 16 });
  if (!new Set(["stable", "insider"]).has(quality)) {
    configError("vscode.quality", "must be stable or insider");
  }

  return {
    schemaVersion: 1,
    images: {
      prefix: imagePrefixAt(images.prefix, "images.prefix"),
      version: imageVersion,
      platform,
      names: normalizedNames
    },
    artifacts: {
      root: relativeArtifactPathAt(artifacts.root, "artifacts.root")
    },
    wolfi: {
      baseImage: splitMutableImageReference(wolfi.baseImage, "wolfi.baseImage").reference,
      repositories: {
        main: repositoryUrlAt(repositories.main, "wolfi.repositories.main"),
        extra: repositoryUrlAt(repositories.extra, "wolfi.repositories.extra")
      }
    },
    user: {
      name: userName,
      uid: linuxIdAt(user.uid, "user.uid"),
      gid: linuxIdAt(user.gid, "user.gid")
    },
    docker: {
      cli: selectorAt(docker.cli, "docker.cli"),
      buildx: selectorAt(docker.buildx, "docker.buildx"),
      compose: selectorAt(docker.compose, "docker.compose")
    },
    vscode: {
      version: selectorAt(vscode.version, "vscode.version"),
      quality,
      extensions: uniqueArrayAt(vscode.extensions, "vscode.extensions", extensionIdAt, {
        maxItems: 256,
        caseInsensitive: true
      })
    },
    toolchain: normalizeToolchain(root.toolchain)
  };
}

export function parseWolfiConfig(source, sourceName = "wolfi-build.yaml") {
  const document = parseDocument(source, {
    logLevel: "silent",
    merge: false,
    prettyErrors: true,
    schema: "core",
    strict: true,
    uniqueKeys: true
  });

  if (document.errors.length > 0) {
    throw new WolfiConfigError(
      `${sourceName}: invalid YAML:\n${document.errors.map((error) => `  ${error.message}`).join("\n")}`
    );
  }
  if (document.warnings.length > 0) {
    throw new WolfiConfigError(
      `${sourceName}: unsupported YAML:\n${document.warnings.map((warning) => `  ${warning.message}`).join("\n")}`
    );
  }
  if (document.contents == null) {
    throw new WolfiConfigError(`${sourceName}: configuration is empty`);
  }

  inspectYamlNode(document.contents);
  let value;
  try {
    value = document.toJS({ maxAliasCount: 0, mapAsMap: false });
  } catch (error) {
    throw new WolfiConfigError(`${sourceName}: could not convert YAML: ${error.message}`);
  }
  return validateWolfiConfig(value);
}

export function loadWolfiConfig(configPath = DEFAULT_CONFIG_PATH) {
  let source;
  try {
    source = fs.readFileSync(configPath, "utf8");
  } catch (error) {
    throw new WolfiConfigError(`cannot read ${configPath}: ${error.message}`);
  }
  return parseWolfiConfig(source, configPath);
}

function canonicalValue(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalValue);
  }
  if (value != null && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalValue(value[key])])
    );
  }
  return value;
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

export function wolfiConfigSemanticSha256(config) {
  return crypto.createHash("sha256").update(canonicalJson(config), "utf8").digest("hex");
}

export function wolfiImageReferences(config) {
  return Object.fromEntries(
    Object.entries(config.images.names).map(([key, name]) => {
      const repository = `${config.images.prefix}/${name}`;
      return [key, {
        name,
        repository,
        tag: config.images.version,
        reference: `${repository}:${config.images.version}`,
        platform: config.images.platform
      }];
    })
  );
}

function readJsonFile(filePath, description) {
  let source;
  try {
    source = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    throw new WolfiConfigError(`cannot read ${description} ${filePath}: ${error.message}`);
  }
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new WolfiConfigError(`${description} ${filePath} is not valid JSON: ${error.message}`);
  }
}

export function verifyWolfiLock(config, lock, { requireBaseImage = true } = {}) {
  recordAt(lock, "lock", ["schemaVersion", "generatedAt", "source", "resolver", "config", "images", "resolved"]);
  if (lock.schemaVersion !== 1) {
    configError("lock.schemaVersion", "must be the integer 1");
  }
  const generatedAt = stringAt(lock.generatedAt, "lock.generatedAt", { maxLength: 64 });
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(generatedAt)
      || Number.isNaN(Date.parse(generatedAt))) {
    configError("lock.generatedAt", "must be an ISO 8601 UTC timestamp");
  }

  const source = recordAt(lock.source, "lock.source", ["path", "fileSha256", "semanticSha256"]);
  stringAt(source.path, "lock.source.path", { maxLength: 512 });
  if (!SHA256_PATTERN.test(source.fileSha256)) {
    configError("lock.source.fileSha256", "must be a lowercase SHA256 value");
  }
  if (!SHA256_PATTERN.test(source.semanticSha256)) {
    configError("lock.source.semanticSha256", "must be a lowercase SHA256 value");
  }

  const expectedHash = wolfiConfigSemanticSha256(config);
  if (source.semanticSha256 !== expectedHash) {
    configError(
      "lock.source.semanticSha256",
      `does not match the YAML (expected ${expectedHash}); run ./scripts/wolfi/update-lock.sh`
    );
  }
  if (canonicalJson(lock.config) !== canonicalJson(config)) {
    configError("lock.config", "does not match the normalized YAML; run ./scripts/wolfi/update-lock.sh");
  }
  if (canonicalJson(lock.images) !== canonicalJson(wolfiImageReferences(config))) {
    configError("lock.images", "does not match the image coordinates derived from the YAML");
  }

  const resolver = recordAt(lock.resolver, "lock.resolver", ["name", "version", "runtime", "stages"]);
  if (resolver.name !== "devcontainer-blueprints-wolfi-lock" || resolver.version !== 1) {
    configError("lock.resolver", "uses an unsupported lock generator name or version");
  }
  if (resolver.runtime == null || typeof resolver.runtime !== "object" || Array.isArray(resolver.runtime)) {
    configError("lock.resolver.runtime", "must be a mapping");
  }
  for (const requiredRuntime of ["node", "yaml"]) {
    if (!hasOwn(resolver.runtime, requiredRuntime)) {
      configError("lock.resolver.runtime", `missing required field: ${requiredRuntime}`);
    }
  }
  for (const [name, value] of Object.entries(resolver.runtime)) {
    if (!/^[A-Za-z][A-Za-z0-9]*$/.test(name)) {
      configError("lock.resolver.runtime", `invalid tool name: ${name}`);
    }
    stringAt(value, `lock.resolver.runtime.${name}`, { maxLength: 512 });
  }
  if (!Array.isArray(resolver.stages) || resolver.stages.length === 0) {
    configError("lock.resolver.stages", "must be a non-empty sequence");
  }
  const stageNames = new Set();
  resolver.stages.forEach((stage, index) => {
    const location = `lock.resolver.stages[${index}]`;
    const normalizedStage = recordAt(stage, location, ["name", "version"], ["source", "sourceSha256"]);
    const stageName = stringAt(normalizedStage.name, `${location}.name`, { maxLength: 64 });
    stringAt(normalizedStage.version, `${location}.version`, { maxLength: 64 });
    if (!/^[a-z][a-z0-9-]*$/.test(stageName)) {
      configError(`${location}.name`, "must be a lowercase identifier");
    }
    if (stageNames.has(stageName)) {
      configError(location, `duplicates resolver stage: ${stageName}`);
    }
    stageNames.add(stageName);
    if (hasOwn(normalizedStage, "source")) {
      stringAt(normalizedStage.source, `${location}.source`, { maxLength: 512 });
    }
    if (hasOwn(normalizedStage, "sourceSha256") && !SHA256_PATTERN.test(normalizedStage.sourceSha256)) {
      configError(`${location}.sourceSha256`, "must be a lowercase SHA256 value");
    }
  });
  if (!stageNames.has("oci-base-image")) {
    configError("lock.resolver.stages", "must include the oci-base-image resolver");
  }

  recordAt(lock.resolved, "lock.resolved", requireBaseImage ? ["baseImage"] : [], ["baseImage", "apk", "vscode", "extensions", "kubectl", "rust", "tools"]);
  if (hasOwn(lock.resolved, "baseImage")) {
    const base = recordAt(lock.resolved.baseImage, "lock.resolved.baseImage", [
      "requested",
      "repository",
      "platform",
      "digest",
      "pinnedReference",
      "mediaType"
    ], ["indexDigest"]);
    const requested = splitMutableImageReference(config.wolfi.baseImage, "wolfi.baseImage");
    if (base.requested !== requested.reference || base.repository !== requested.repository) {
      configError("lock.resolved.baseImage", "does not resolve the configured base image");
    }
    if (base.platform !== config.images.platform) {
      configError("lock.resolved.baseImage.platform", "does not match images.platform");
    }
    if (!/^sha256:[a-f0-9]{64}$/.test(base.digest)) {
      configError("lock.resolved.baseImage.digest", "must be an OCI SHA256 digest");
    }
    if (base.pinnedReference !== `${requested.repository}@${base.digest}`) {
      configError("lock.resolved.baseImage.pinnedReference", "must combine repository and resolved platform digest");
    }
    if (hasOwn(base, "indexDigest") && !/^sha256:[a-f0-9]{64}$/.test(base.indexDigest)) {
      configError("lock.resolved.baseImage.indexDigest", "must be an OCI SHA256 digest");
    }
    stringAt(base.mediaType, "lock.resolved.baseImage.mediaType", { maxLength: 256 });
  }

  return true;
}

export function loadAndVerifyWolfiLock(configPath = DEFAULT_CONFIG_PATH, lockPath = DEFAULT_LOCK_PATH, options = {}) {
  const config = loadWolfiConfig(configPath);
  const lock = readJsonFile(lockPath, "lockfile");
  verifyWolfiLock(config, lock, options);
  const actualFileSha256 = crypto.createHash("sha256").update(fs.readFileSync(configPath)).digest("hex");
  if (lock.source.fileSha256 !== actualFileSha256) {
    configError(
      "lock.source.fileSha256",
      `does not match the YAML bytes (expected ${actualFileSha256}); run ./scripts/wolfi/update-lock.sh`
    );
  }
  return { config, lock };
}

function valueAtDotPath(value, dotPath) {
  if (!dotPath || dotPath.split(".").some((part) => !/^[A-Za-z][A-Za-z0-9]*$/.test(part))) {
    throw new WolfiConfigError("get requires a simple dot-separated field path");
  }
  let current = value;
  for (const part of dotPath.split(".")) {
    if (current == null || typeof current !== "object" || !hasOwn(current, part)) {
      throw new WolfiConfigError(`configuration field not found: ${dotPath}`);
    }
    current = current[part];
  }
  return current;
}

function printUsage() {
  console.error(`Usage:
  node scripts/wolfi/config.mjs validate [config.yaml]
  node scripts/wolfi/config.mjs print-json [config.yaml]
  node scripts/wolfi/config.mjs hash [config.yaml]
  node scripts/wolfi/config.mjs get <field.path> [config.yaml]
  node scripts/wolfi/config.mjs verify-lock [config.yaml] [lock.json]`);
}

function assertArgumentCount(command, args, minimum, maximum = minimum) {
  if (args.length < minimum || args.length > maximum) {
    throw new WolfiConfigError(
      `${command} expects ${minimum === maximum ? minimum : `${minimum}-${maximum}`} argument${maximum === 1 ? "" : "s"}`
    );
  }
}

async function main(argv) {
  const [command, ...args] = argv;
  switch (command) {
    case "validate": {
      assertArgumentCount(command, args, 0, 1);
      const configPath = path.resolve(args[0] ?? DEFAULT_CONFIG_PATH);
      loadWolfiConfig(configPath);
      console.log(`Validated ${path.relative(REPO_ROOT, configPath) || path.basename(configPath)}`);
      return;
    }
    case "print-json": {
      assertArgumentCount(command, args, 0, 1);
      const configPath = path.resolve(args[0] ?? DEFAULT_CONFIG_PATH);
      process.stdout.write(`${JSON.stringify(loadWolfiConfig(configPath), null, 2)}\n`);
      return;
    }
    case "hash": {
      assertArgumentCount(command, args, 0, 1);
      const configPath = path.resolve(args[0] ?? DEFAULT_CONFIG_PATH);
      console.log(wolfiConfigSemanticSha256(loadWolfiConfig(configPath)));
      return;
    }
    case "get": {
      assertArgumentCount(command, args, 1, 2);
      const [dotPath, configArgument] = args;
      const configPath = path.resolve(configArgument ?? DEFAULT_CONFIG_PATH);
      const value = valueAtDotPath(loadWolfiConfig(configPath), dotPath);
      console.log(value != null && typeof value === "object" ? JSON.stringify(value) : value);
      return;
    }
    case "verify-lock": {
      assertArgumentCount(command, args, 0, 2);
      const configPath = path.resolve(args[0] ?? DEFAULT_CONFIG_PATH);
      const lockPath = path.resolve(args[1] ?? DEFAULT_LOCK_PATH);
      loadAndVerifyWolfiLock(configPath, lockPath);
      console.log(`Verified ${path.relative(REPO_ROOT, lockPath) || path.basename(lockPath)}`);
      return;
    }
    default:
      printUsage();
      process.exitCode = 2;
  }
}

const invokedPath = process.argv[1] == null ? null : pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedPath === import.meta.url) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`ERROR: ${error.message}`);
    process.exitCode = 1;
  });
}

export { DEFAULT_CONFIG_PATH, DEFAULT_LOCK_PATH, REPO_ROOT };
