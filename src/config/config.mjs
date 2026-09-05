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
import {
  DEFAULT_SETTINGS_PATH,
  imageReference,
  loadImageSettings,
  profilePaths,
  settingsFileSha256
} from "./settings.mjs";

const REPO_ROOT = fileURLToPath(new URL("../../", import.meta.url));
const DEFAULT_CONFIG_PATH = path.join(REPO_ROOT, "config/dev.yaml");
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
  if (components[0] !== "artifacts" || components.length < 2) {
    configError(location, "must identify a dedicated directory below artifacts/");
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

export const UTILITY_CATALOG = JSON.parse(fs.readFileSync(new URL("../components/utilities/catalog.json", import.meta.url), "utf8"));
export const PLAYWRIGHT_VERSION = "1.63.0";

function normalizeBuild(value) {
  const build = recordAt(value, "build", [], ["native", "python", "java", "maven", "node", "npm", "rust"]);
  const normalized = {};
  if (hasOwn(build, "native")) {
    const native = recordAt(build.native, "build.native", [], ["clang"]);
    normalized.native = hasOwn(native, "clang") ? { clang: selectorAt(native.clang, "build.native.clang") } : {};
  }
  if (hasOwn(build, "python")) {
    normalized.python = uniqueArrayAt(build.python, "build.python", selectorAt, { minItems: 1, maxItems: 8 });
  }
  for (const key of ["java", "maven", "node", "npm"]) {
    if (hasOwn(build, key)) normalized[key] = selectorAt(build[key], `build.${key}`);
  }
  if (hasOwn(build, "maven") && !hasOwn(build, "java")) configError("build.maven", "requires build.java");
  if (hasOwn(build, "npm") && !hasOwn(build, "node")) configError("build.npm", "requires build.node");
  if (hasOwn(build, "rust")) {
    const rust = recordAt(build.rust, "build.rust", ["toolchain", "components"]);
    const toolchain = selectorAt(rust.toolchain, "build.rust.toolchain");
    if (!/^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(toolchain)) {
      configError("build.rust.toolchain", "must be a dated nightly: nightly-YYYY-MM-DD");
    }
    const allowed = new Set(["rust-src", "rust-analyzer", "rustfmt", "clippy"]);
    const components = uniqueArrayAt(rust.components, "build.rust.components", selectorAt, { maxItems: allowed.size });
    for (const component of components) {
      if (!allowed.has(component)) configError("build.rust.components", `unsupported component: ${component}`);
    }
    normalized.rust = { toolchain, components };
  }
  return normalized;
}

function normalizeUtilities(value) {
  const selected = recordAt(value, "utilities", [], Object.keys(UTILITY_CATALOG));
  return Object.fromEntries(Object.entries(selected).map(([key, value]) => {
    const selector = selectorAt(value, `utilities.${key}`);
    const utility = UTILITY_CATALOG[key];
    if (selector === "latest" && utility.packages.some(p => p.nameTemplate)) {
      configError(`utilities.${key}`, `requires a package line such as "${utility.exampleSelector}"; latest is not a package line`);
    }
    return [key, selector];
  }));
}

function exactVersionAt(value, location) {
  const version = selectorAt(value, location);
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) configError(location, "requires an exact major.minor.patch version");
  return version;
}

function validateProfileContract(config) {
  const docker = config.docker ?? {};
  if (!Object.hasOwn(config, "playwright")) configError("playwright", `${config.profile} requires Playwright`);
  if (Object.hasOwn(config.utilities, "clamav")) configError("utilities.clamav", "is unavailable until the documented Wolfi remediation condition is met");
  if (config.profile === "dev") {
    if (!config.user || !config.devcontainer || !config.vscode) configError("profile", "dev requires user, devcontainer, and vscode settings");
    if (!docker.cli || !docker.buildx || !docker.compose || docker.socket !== true) {
      configError("profile", "dev requires Docker CLI, Buildx, Compose, and the identity-owned socket proxy");
    }
    if (config.kaniko) configError("profile", "dev cannot include Kaniko");
  } else if (config.profile === "build") {
    if (config.user || config.devcontainer || config.vscode || config.kaniko) {
      configError("profile", "build must be a root CI image without Dev Container, VS Code, or Kaniko settings");
    }
    if (!docker.cli || !docker.buildx || !docker.compose || docker.socket) {
      configError("profile", "build requires Docker CLI, Buildx, and Compose without the socket proxy");
    }
  } else if (config.profile === "kaniko") {
    if (config.user || config.devcontainer || config.vscode || config.docker || !config.kaniko) {
      configError("profile", "kaniko must be a root CI image with Kaniko and without Docker or VS Code settings");
    }
  }
}

export function validateWolfiConfig(value, { settings = loadImageSettings() } = {}) {
  if (value && Object.hasOwn(value, "toolchain")) {
    configError("toolchain", "migrate compiler/language entries to build (build becomes native) and CLI entries to utilities; regenerate the lock with update-lock");
  }
  const root = recordAt(value, "config", ["schemaVersion", "profile", "image", "wolfi"], [
    "user", "devcontainer", "docker", "vscode", "build", "utilities", "kaniko", "playwright"
  ]);
  if (root.schemaVersion !== 3) {
    configError("schemaVersion", "must be the integer 3; image names, artifact roots, and locks are now derived from config/images.env and profile");
  }
  const profile = stringAt(root.profile, "profile", { maxLength: 32 });
  if (!settings.profiles.includes(profile)) {
    configError("profile", `must be declared by IMAGE_PROFILES (${settings.profiles.join(", ")})`);
  }
  const image = recordAt(root.image, "image", ["platform"]);
  const platform = stringAt(image.platform, "image.platform", { maxLength: 32 });
  if (!["linux/amd64", "linux/arm64"].includes(platform)) {
    configError("image.platform", "must be linux/amd64 or linux/arm64");
  }
  const wolfi = recordAt(root.wolfi, "wolfi", ["baseImage", "repositories"]);
  const repositories = recordAt(wolfi.repositories, "wolfi.repositories", ["main", "extra"]);
  const devcontainer = root.devcontainer ?? false;
  if (typeof devcontainer !== "boolean" || (hasOwn(root, "devcontainer") && root.devcontainer == null)) {
    configError("devcontainer", "must be a boolean");
  }
  const normalized = {
    schemaVersion: 3,
    profile,
    image: {
      reference: imageReference(settings, profile),
      platform
    },
    artifacts: { root: profilePaths(settings, profile).artifacts },
    wolfi: {
      baseImage: splitMutableImageReference(wolfi.baseImage, "wolfi.baseImage").reference,
      repositories: {
        main: repositoryUrlAt(repositories.main, "wolfi.repositories.main"),
        extra: repositoryUrlAt(repositories.extra, "wolfi.repositories.extra")
      }
    },
    devcontainer,
    build: normalizeBuild(hasOwn(root, "build") ? root.build : {}),
    utilities: normalizeUtilities(hasOwn(root, "utilities") ? root.utilities : {})
  };
  if (hasOwn(root, "kaniko")) {
    const kaniko = recordAt(root.kaniko, "kaniko", ["version"]);
    normalized.kaniko = { version: exactVersionAt(kaniko.version, "kaniko.version") };
  }
  if (hasOwn(root, "playwright") && root.playwright !== false) {
    const playwright = root.playwright === true ? { version: PLAYWRIGHT_VERSION } : recordAt(root.playwright, "playwright", ["version"]);
    normalized.playwright = { version: exactVersionAt(playwright.version, "playwright.version") };
    if (!normalized.build.node || !normalized.build.npm) configError("playwright", "requires build.node and build.npm");
  }
  if (hasOwn(root, "user")) {
    const user = recordAt(root.user, "user", ["name", "uid", "gid"]);
    const name = stringAt(user.name, "user.name", { maxLength: 32 });
    if (!USER_NAME_PATTERN.test(name) || name === "root") {
      configError("user.name", "must be a non-root POSIX user name; omit user to run as root");
    }
    normalized.user = {
      name,
      uid: linuxIdAt(user.uid, "user.uid"),
      gid: linuxIdAt(user.gid, "user.gid")
    };
  }
  if (devcontainer && !normalized.user) {
    configError("devcontainer", "requires a configured non-root user");
  }
  if (hasOwn(root, "docker")) {
    const docker = recordAt(root.docker, "docker", [], ["cli", "buildx", "compose", "socket"]);
    const selected = {};
    for (const key of ["cli", "buildx", "compose"]) {
      if (hasOwn(docker, key)) selected[key] = selectorAt(docker[key], `docker.${key}`);
    }
    selected.socket = hasOwn(docker, "socket") ? docker.socket : false;
    if (typeof selected.socket !== "boolean") configError("docker.socket", "must be a boolean");
    if (hasOwn(selected, "buildx") && !hasOwn(selected, "cli")) {
      configError("docker.buildx", "requires docker.cli");
    }
    if (selected.socket && (!hasOwn(selected, "cli") || !devcontainer || !normalized.user)) {
      configError("docker.socket", "requires docker.cli, devcontainer: true, and a named user");
    }
    normalized.docker = selected;
  }
  if (hasOwn(root, "vscode")) {
    const vscode = recordAt(root.vscode, "vscode", ["version"], ["quality", "extensions"]);
    const quality = hasOwn(vscode, "quality") ? stringAt(vscode.quality, "vscode.quality", { maxLength: 16 }) : "stable";
    if (quality !== "stable") configError("vscode.quality", "must be stable; offline server layouts support stable releases");
    normalized.vscode = {
      version: selectorAt(vscode.version, "vscode.version"),
      quality,
      extensions: uniqueArrayAt(hasOwn(vscode, "extensions") ? vscode.extensions : [], "vscode.extensions", extensionIdAt, {
        maxItems: 256,
        caseInsensitive: true
      })
    };
    if (normalized.vscode.extensions.some((id) => id.toLowerCase() === "rust-lang.rust-analyzer")
        && !normalized.build.rust?.components.includes("rust-analyzer")) {
      configError("vscode.extensions", "rust-lang.rust-analyzer requires build.rust.components to include rust-analyzer for offline activation");
    }
  }
  validateProfileContract(normalized);
  return normalized;
}

export function parseWolfiConfig(source, sourceName = "image-profile.yaml", options = {}) {
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
  return validateWolfiConfig(value, options);
}

export function loadWolfiConfig(configPath = DEFAULT_CONFIG_PATH, settingsPath = DEFAULT_SETTINGS_PATH) {
  let source;
  try {
    source = fs.readFileSync(configPath, "utf8");
  } catch (error) {
    throw new WolfiConfigError(`cannot read ${configPath}: ${error.message}`);
  }
  const settings = loadImageSettings(settingsPath);
  const config = parseWolfiConfig(source, configPath, { settings });
  if (path.resolve(configPath) !== path.resolve(profilePaths(settings, config.profile).config)) {
    configError("profile", `must match its file name: config/${config.profile}.yaml`);
  }
  return config;
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

export function wolfiImageReference(config) {
  return { reference: config.image.reference, platform: config.image.platform };
}

export function companionLockPath(configPath) {
  return /\.ya?ml$/i.test(configPath)
    ? configPath.replace(/\.ya?ml$/i, ".lock.json")
    : `${configPath}.lock.json`;
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

export function verifyWolfiLock(config, lock, {
  requireBaseImage = true,
  requireArtifacts = true,
  expectedSettingsSha256 = settingsFileSha256()
} = {}) {
  recordAt(lock, "lock", ["schemaVersion", "generatedAt", "source", "resolver", "config", "image", "resolved"]);
  if (lock.schemaVersion !== 3) {
    configError("lock.schemaVersion", "must be the integer 3");
  }
  const generatedAt = stringAt(lock.generatedAt, "lock.generatedAt", { maxLength: 64 });
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(generatedAt)
      || Number.isNaN(Date.parse(generatedAt))) {
    configError("lock.generatedAt", "must be an ISO 8601 UTC timestamp");
  }

  const source = recordAt(lock.source, "lock.source", [
    "path", "fileSha256", "semanticSha256", "settingsPath", "settingsFileSha256"
  ]);
  stringAt(source.path, "lock.source.path", { maxLength: 512 });
  if (!SHA256_PATTERN.test(source.fileSha256)) {
    configError("lock.source.fileSha256", "must be a lowercase SHA256 value");
  }
  if (!SHA256_PATTERN.test(source.semanticSha256)) {
    configError("lock.source.semanticSha256", "must be a lowercase SHA256 value");
  }
  stringAt(source.settingsPath, "lock.source.settingsPath", { maxLength: 512 });
  if (!SHA256_PATTERN.test(source.settingsFileSha256)) {
    configError("lock.source.settingsFileSha256", "must be a lowercase SHA256 value");
  }
  if (source.settingsFileSha256 !== expectedSettingsSha256) {
    configError("lock.source.settingsFileSha256", "does not match config/images.env; run ./scripts/images.sh update-lock all");
  }

  const expectedHash = wolfiConfigSemanticSha256(config);
  if (source.semanticSha256 !== expectedHash) {
    configError(
      "lock.source.semanticSha256",
      `does not match the profile/settings (expected ${expectedHash}); run ./scripts/images.sh update-lock all`
    );
  }
  if (canonicalJson(lock.config) !== canonicalJson(config)) {
    configError("lock.config", "does not match the normalized YAML; run ./scripts/images.sh update-lock all");
  }
  if (canonicalJson(lock.image) !== canonicalJson(wolfiImageReference(config))) {
    configError("lock.image", "does not match the image coordinates derived from the YAML");
  }

  const resolver = recordAt(lock.resolver, "lock.resolver", ["name", "version", "runtime", "stages"]);
  if (resolver.name !== "devcontainer-blueprints-image-lock" || resolver.version !== 3) {
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

  recordAt(lock.resolved, "lock.resolved", requireBaseImage ? ["baseImage"] : [], ["baseImage", "apk", "vscode", "extensions", "kubectl", "rust", "tools", "kaniko", "playwright"]);
  const selectedVendor = {
    vscode: hasOwn(config, "vscode"),
    extensions: (config.vscode?.extensions.length ?? 0) > 0,
    kubectl: hasOwn(config.utilities, "kubectl"),
    rust: hasOwn(config.build, "rust"),
    kaniko: hasOwn(config, "kaniko"),
    playwright: hasOwn(config, "playwright")
  };
  for (const [name, selected] of Object.entries(selectedVendor)) {
    if (!selected && hasOwn(lock.resolved, name)) {
      configError(`lock.resolved.${name}`, "contains an artifact disabled by the configuration");
    }
  }
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
    if (base.platform !== config.image.platform) {
      configError("lock.resolved.baseImage.platform", "does not match image.platform");
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

  if (requireArtifacts) {
    for (const [name, selected] of Object.entries(selectedVendor)) {
      if (!selected) continue;
      const artifact = lock.resolved[name];
      if (artifact == null || typeof artifact !== "object" || Array.isArray(artifact) || Object.keys(artifact).length === 0) {
        configError(`lock.resolved.${name}`, "must contain the artifact mapping selected by the configuration");
      }
      if (["kaniko", "playwright"].includes(name)) {
        if (artifact.version !== config[name].version || artifact.platform !== config.image.platform) {
          configError(`lock.resolved.${name}`, "version/platform differs from the configuration");
        }
        const archive = recordAt(artifact.archive, `lock.resolved.${name}.archive`, ["file", "sha256", "size"]);
        relativeArtifactPathAt(archive.file, `lock.resolved.${name}.archive.file`);
        if (!SHA256_PATTERN.test(archive.sha256) || !Number.isSafeInteger(archive.size) || archive.size <= 0) {
          configError(`lock.resolved.${name}.archive`, "requires a SHA256 and positive size");
        }
      }
    }
    const apk = lock.resolved.apk;
    if (apk == null || typeof apk !== "object" || Array.isArray(apk)) {
      configError("lock.resolved.apk", "must contain the selected APK resolution");
    }
    recordAt(apk.packageSets, "lock.resolved.apk.packageSets", ["final"]);
    const finalLocation = "lock.resolved.apk.packageSets.final";
    const final = recordAt(apk.packageSets.final, finalLocation, [
      "artifactDirectory", "closure", "modules", "packages", "repositorySubdirs", "roots"
    ], ["repositorySubdir"]);
    stringAt(final.artifactDirectory, `${finalLocation}.artifactDirectory`, { maxLength: 512 });
    for (const field of ["closure", "modules", "packages", "repositorySubdirs", "roots"]) {
      if (!Array.isArray(final[field]) || final[field].length === 0) {
        configError(`${finalLocation}.${field}`, "must be a non-empty sequence");
      }
    }
    if (hasOwn(final, "repositorySubdir")) {
      stringAt(final.repositorySubdir, `${finalLocation}.repositorySubdir`, { maxLength: 512 });
    }
  }

  return true;
}

export function loadAndVerifyWolfiLock(
  configPath = DEFAULT_CONFIG_PATH,
  lockPath = companionLockPath(configPath),
  options = {},
  settingsPath = DEFAULT_SETTINGS_PATH
) {
  const config = loadWolfiConfig(configPath, settingsPath);
  const lock = readJsonFile(lockPath, "lockfile");
  const currentSettingsSha256 = settingsFileSha256(settingsPath);
  verifyWolfiLock(config, lock, { ...options, expectedSettingsSha256: currentSettingsSha256 });
  const actualFileSha256 = crypto.createHash("sha256").update(fs.readFileSync(configPath)).digest("hex");
  if (lock.source.fileSha256 !== actualFileSha256) {
    configError(
      "lock.source.fileSha256",
      `does not match the YAML bytes (expected ${actualFileSha256}); run ./scripts/images.sh update-lock ${config.profile}`
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
  node src/config/config.mjs validate [config.yaml]
  node src/config/config.mjs print-json [config.yaml]
  node src/config/config.mjs hash [config.yaml]
  node src/config/config.mjs get <field.path> [config.yaml]
  node src/config/config.mjs verify-lock [config.yaml] [lock.json]`);
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
      const lockPath = path.resolve(args[1] ?? companionLockPath(configPath));
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

export { DEFAULT_CONFIG_PATH, REPO_ROOT };
