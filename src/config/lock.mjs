#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  DEFAULT_CONFIG_PATH,
  companionLockPath,
  REPO_ROOT,
  WolfiConfigError,
  loadWolfiConfig,
  splitMutableImageReference,
  verifyWolfiLock,
  wolfiConfigSemanticSha256,
  wolfiImageReference
} from "./config.mjs";
import { DEFAULT_SETTINGS_PATH, settingsFileSha256 } from "./settings.mjs";

const require = createRequire(import.meta.url);
const YAML_PACKAGE_VERSION = require("yaml/package.json").version;
const LOCK_GENERATOR_VERSION = 3;
const OCI_DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/;

function run(command, args) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"]
    }).trim();
  } catch (error) {
    const detail = error.stderr?.trim() || error.stdout?.trim() || error.message;
    throw new WolfiConfigError(`${command} ${args.join(" ")} failed: ${detail}`);
  }
}

function requireDigest(value, location) {
  if (!OCI_DIGEST_PATTERN.test(value ?? "")) {
    throw new WolfiConfigError(`${location}: expected an OCI SHA256 digest, got ${JSON.stringify(value)}`);
  }
  return value;
}

export function selectPlatformManifest(manifest, platform) {
  if (manifest == null || typeof manifest !== "object" || Array.isArray(manifest)) {
    throw new WolfiConfigError("base-image resolver returned an invalid manifest document");
  }

  const [os, architecture] = platform.split("/");
  if (Array.isArray(manifest.manifests)) {
    const candidates = manifest.manifests.filter((entry) =>
      entry?.platform?.os === os
      && entry?.platform?.architecture === architecture
      && (entry.platform.variant == null || entry.platform.variant === "")
    );
    if (candidates.length !== 1) {
      throw new WolfiConfigError(
        `base image has ${candidates.length} unambiguous manifests for ${platform}; expected exactly one`
      );
    }
    return {
      digest: requireDigest(candidates[0].digest, "base-image platform manifest"),
      mediaType: candidates[0].mediaType,
      indexDigest: requireDigest(manifest.digest, "base-image index")
    };
  }

  return {
    digest: requireDigest(manifest.digest, "base-image manifest"),
    mediaType: manifest.mediaType
  };
}

export function resolveBaseImage(config, { inspectManifest } = {}) {
  const requested = splitMutableImageReference(config.wolfi.baseImage, "wolfi.baseImage");
  const inspect = inspectManifest ?? ((reference) => {
    const output = run("docker", [
      "buildx",
      "imagetools",
      "inspect",
      reference,
      "--format",
      "{{json .Manifest}}"
    ]);
    try {
      return JSON.parse(output);
    } catch (error) {
      throw new WolfiConfigError(`docker returned invalid manifest JSON for ${reference}: ${error.message}`);
    }
  });

  const selected = selectPlatformManifest(inspect(requested.reference), config.image.platform);
  if (typeof selected.mediaType !== "string" || selected.mediaType.length === 0) {
    throw new WolfiConfigError("base-image resolver did not return a manifest media type");
  }

  return {
    requested: requested.reference,
    repository: requested.repository,
    platform: config.image.platform,
    digest: selected.digest,
    pinnedReference: `${requested.repository}@${selected.digest}`,
    mediaType: selected.mediaType,
    ...(selected.indexDigest == null ? {} : { indexDigest: selected.indexDigest })
  };
}

function assertSafeJson(value, location = "resolution fragment") {
  if (value == null || typeof value === "string" || typeof value === "boolean") {
    return;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new WolfiConfigError(`${location}: contains a non-finite number`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertSafeJson(item, `${location}[${index}]`));
    return;
  }
  if (typeof value !== "object") {
    throw new WolfiConfigError(`${location}: contains a non-JSON value`);
  }
  for (const [key, child] of Object.entries(value)) {
    if (new Set(["__proto__", "prototype", "constructor"]).has(key)) {
      throw new WolfiConfigError(`${location}: contains a prohibited key: ${key}`);
    }
    assertSafeJson(child, `${location}.${key}`);
  }
}

function sha256Text(value) {
  return crypto.createHash("sha256").update(value, "utf8").digest("hex");
}

export function loadResolutionFragment(fragmentPath, expectedConfigSha256) {
  let source;
  let fragment;
  try {
    source = fs.readFileSync(fragmentPath, "utf8");
  } catch (error) {
    throw new WolfiConfigError(`cannot read resolution fragment ${fragmentPath}: ${error.message}`);
  }
  try {
    fragment = JSON.parse(source);
  } catch (error) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath} is not valid JSON: ${error.message}`);
  }
  assertSafeJson(fragment, `resolution fragment ${fragmentPath}`);

  const keys = fragment != null && typeof fragment === "object" && !Array.isArray(fragment)
    ? Object.keys(fragment)
    : [];
  const unknownKeys = keys.filter((key) => !new Set([
    "schemaVersion",
    "name",
    "version",
    "configSemanticSha256",
    "resolved"
  ]).has(key));
  if (unknownKeys.length > 0) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: unknown fields: ${unknownKeys.join(", ")}`);
  }
  if (fragment?.schemaVersion !== 1) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: schemaVersion must be 1`);
  }
  if (typeof fragment.name !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(fragment.name)) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: name must be a lowercase identifier`);
  }
  if (typeof fragment.version !== "string" || fragment.version.length === 0) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: version must be a non-empty string`);
  }
  if (!/^[a-f0-9]{64}$/.test(fragment.configSemanticSha256 ?? "")) {
    throw new WolfiConfigError(
      `resolution fragment ${fragmentPath}: configSemanticSha256 must be a lowercase SHA256 value`
    );
  }
  if (expectedConfigSha256 != null && fragment.configSemanticSha256 !== expectedConfigSha256) {
    throw new WolfiConfigError(
      `resolution fragment ${fragmentPath}: was generated for a different YAML configuration`
    );
  }
  if (fragment.resolved == null || typeof fragment.resolved !== "object" || Array.isArray(fragment.resolved)) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: resolved must be a mapping`);
  }
  if (Object.keys(fragment.resolved).length === 0) {
    throw new WolfiConfigError(`resolution fragment ${fragmentPath}: resolved must not be empty`);
  }

  return {
    ...fragment,
    sourceSha256: sha256Text(source)
  };
}

export function mergeResolutionStages(stages) {
  const resolved = {};
  const metadata = [];
  const seenStageNames = new Set();

  for (const stage of stages) {
    assertSafeJson(stage, `resolver stage ${stage?.name ?? "unknown"}`);
    if (typeof stage?.name !== "string" || typeof stage?.version !== "string") {
      throw new WolfiConfigError("each resolver stage requires string name and version fields");
    }
    if (seenStageNames.has(stage.name)) {
      throw new WolfiConfigError(`duplicate resolver stage: ${stage.name}`);
    }
    seenStageNames.add(stage.name);
    if (stage.resolved == null || typeof stage.resolved !== "object" || Array.isArray(stage.resolved)) {
      throw new WolfiConfigError(`resolver stage ${stage.name} must return a resolved mapping`);
    }

    for (const [key, value] of Object.entries(stage.resolved)) {
      if (hasOwn(resolved, key)) {
        throw new WolfiConfigError(`resolver stages both define resolved.${key}`);
      }
      resolved[key] = value;
    }
    metadata.push({
      name: stage.name,
      version: stage.version,
      ...(stage.source == null ? {} : { source: stage.source }),
      ...(stage.sourceSha256 == null ? {} : { sourceSha256: stage.sourceSha256 })
    });
  }

  return { resolved, metadata };
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function relativeSourcePath(configPath) {
  const relative = path.relative(REPO_ROOT, configPath);
  if (relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative)) {
    return relative.split(path.sep).join("/");
  }
  return path.resolve(configPath);
}

export function createWolfiLock(config, {
  configPath = DEFAULT_CONFIG_PATH,
  settingsPath = DEFAULT_SETTINGS_PATH,
  generatedAt = new Date().toISOString(),
  baseImage,
  resolutionStages = [],
  runtime = {}
} = {}) {
  const baseStage = {
    name: "oci-base-image",
    version: "1",
    resolved: { baseImage }
  };
  const { resolved, metadata } = mergeResolutionStages([baseStage, ...resolutionStages]);

  return {
    schemaVersion: 3,
    generatedAt,
    source: {
      path: relativeSourcePath(configPath),
      fileSha256: crypto.createHash("sha256").update(fs.readFileSync(configPath)).digest("hex"),
      semanticSha256: wolfiConfigSemanticSha256(config),
      settingsPath: relativeSourcePath(settingsPath),
      settingsFileSha256: settingsFileSha256(settingsPath)
    },
    resolver: {
      name: "devcontainer-blueprints-image-lock",
      version: LOCK_GENERATOR_VERSION,
      runtime: {
        node: process.versions.node,
        yaml: YAML_PACKAGE_VERSION,
        ...runtime
      },
      stages: metadata
    },
    config,
    image: wolfiImageReference(config),
    resolved
  };
}

function writeJsonAtomically(outputPath, value) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const temporaryPath = path.join(
    path.dirname(outputPath),
    `.${path.basename(outputPath)}.${process.pid}.tmp`
  );
  try {
    fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o644,
      flag: "wx"
    });
    fs.renameSync(temporaryPath, outputPath);
  } finally {
    fs.rmSync(temporaryPath, { force: true });
  }
}

function parseArguments(argv) {
  const options = {
    configPath: null,
    lockPath: null,
    baseLockPath: null,
    baseOnly: false,
    fragmentPaths: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--config" || argument === "--lock" || argument === "--base-lock" || argument === "--resolution-file") {
      const value = argv[index + 1];
      if (value == null || value.startsWith("--")) {
        throw new WolfiConfigError(`${argument} requires a path`);
      }
      index += 1;
      if (argument === "--config") {
        options.configPath = path.resolve(value);
      } else if (argument === "--lock") {
        options.lockPath = path.resolve(value);
      } else if (argument === "--base-lock") {
        options.baseLockPath = path.resolve(value);
      } else {
        options.fragmentPaths.push(path.resolve(value));
      }
      continue;
    }
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--base-only") {
      options.baseOnly = true;
      continue;
    }
    throw new WolfiConfigError(`unknown argument: ${argument}`);
  }
  if (!options.help) {
    if (options.configPath == null) throw new WolfiConfigError("--config is required");
    if (options.baseOnly && (options.baseLockPath != null || options.fragmentPaths.length > 0)) {
      throw new WolfiConfigError("--base-only cannot merge a base lock or resolution fragments");
    }
    options.lockPath ??= companionLockPath(options.configPath);
  }
  return options;
}

function printUsage() {
  console.log(`Internal usage: node src/config/lock.mjs [options]

Options:
  --config PATH           Source YAML (required)
  --lock PATH             Generated lockfile (default: selected YAML basename + .lock.json)
  --base-lock PATH        Reuse base resolution from an earlier verified lock
  --base-only             Write the internal base-resolution intermediate
  --resolution-file PATH  Merge a real resolver-produced JSON fragment; repeatable
  --help                  Show this help

Resolution fragment schema:
  {
    "schemaVersion": 1,
    "name": "resolver-name",
    "version": "1",
    "configSemanticSha256": "<current config semantic SHA256>",
    "resolved": {"apk": {...}}
  }`);
}

async function main(argv) {
  const options = parseArguments(argv);
  if (options.help) {
    printUsage();
    return;
  }

  const config = loadWolfiConfig(options.configPath);
  const configSemanticSha256 = wolfiConfigSemanticSha256(config);
  let baseImage;
  if (options.baseLockPath == null) {
    baseImage = resolveBaseImage(config);
  } else {
    let baseLock;
    try {
      baseLock = JSON.parse(fs.readFileSync(options.baseLockPath, "utf8"));
    } catch (error) {
      throw new WolfiConfigError(`cannot read base lock ${options.baseLockPath}: ${error.message}`);
    }
    verifyWolfiLock(config, baseLock, { requireArtifacts: false });
    baseImage = baseLock.resolved.baseImage;
  }
  const externalStages = options.fragmentPaths.map((fragmentPath) => {
    const fragment = loadResolutionFragment(fragmentPath, configSemanticSha256);
    return {
      name: fragment.name,
      version: fragment.version,
      resolved: fragment.resolved,
      sourceSha256: fragment.sourceSha256
    };
  });
  const runtime = {
    dockerClient: run("docker", ["version", "--format", "{{.Client.Version}}"]),
    dockerBuildx: run("docker", ["buildx", "version"]),
    npm: run("npm", ["--version"]),
    python: run("python3", ["--version"])
  };
  const lock = createWolfiLock(config, {
    configPath: options.configPath,
    settingsPath: DEFAULT_SETTINGS_PATH,
    baseImage,
    resolutionStages: externalStages,
    runtime
  });
  verifyWolfiLock(config, lock, { requireArtifacts: !options.baseOnly });
  writeJsonAtomically(options.lockPath, lock);
  console.log(`Wrote ${relativeSourcePath(options.lockPath)}`);
  console.log(`  config SHA256: ${lock.source.semanticSha256}`);
  console.log(`  base image:    ${lock.resolved.baseImage.pinnedReference}`);
}

const invokedPath = process.argv[1] == null ? null : pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedPath === import.meta.url) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`ERROR: ${error.message}`);
    process.exitCode = 1;
  });
}

export { LOCK_GENERATOR_VERSION, YAML_PACKAGE_VERSION };
