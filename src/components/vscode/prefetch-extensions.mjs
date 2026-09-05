#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import semver from "semver";

const MARKETPLACE_URL = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery";
const VSIX_ASSET_TYPE = "Microsoft.VisualStudio.Services.VSIXPackage";
const NETWORK_ATTEMPTS = 5;

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function withNetworkRetries(description, operation) {
  let lastError;
  for (let attempt = 1; attempt <= NETWORK_ATTEMPTS; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (error?.retryable === false || attempt === NETWORK_ATTEMPTS) {
        throw error;
      }
      const delay = 2 ** (attempt - 1) * 1000;
      console.warn(`Retrying ${description} after transient error (${attempt}/${NETWORK_ATTEMPTS}): ${error.message}`);
      await sleep(delay);
    }
  }
  throw lastError;
}

export function normalizeExtensionId(id) {
  return id.trim().toLowerCase();
}

export function splitExtensionId(id) {
  const parts = id.split(".");
  if (parts.length < 2 || !parts[0] || !parts.slice(1).join(".")) {
    throw new Error(`Extension ID must look like publisher.name: ${id}`);
  }
  return { publisher: parts[0], name: parts.slice(1).join(".") };
}

export function classifyExtensionKind(extensionKind) {
  if (extensionKind === undefined || extensionKind === null) {
    return {
      classification: "container",
      containerEligible: true,
      hostOnly: false,
      reason: "extensionKind missing; treated as workspace-capable",
      extensionKind: []
    };
  }

  const kinds = Array.isArray(extensionKind) ? extensionKind : [String(extensionKind)];
  const normalized = kinds.map((kind) => String(kind).toLowerCase());
  const hasWorkspace = normalized.includes("workspace");
  const hasUi = normalized.includes("ui");

  if (hasWorkspace && hasUi) {
    return {
      classification: "both",
      containerEligible: true,
      hostOnly: false,
      reason: "extensionKind includes both ui and workspace",
      extensionKind: kinds
    };
  }

  if (hasWorkspace) {
    return {
      classification: "container",
      containerEligible: true,
      hostOnly: false,
      reason: "extensionKind includes workspace",
      extensionKind: kinds
    };
  }

  if (normalized.length === 1 && hasUi) {
    return {
      classification: "host",
      containerEligible: false,
      hostOnly: true,
      reason: "extensionKind is UI-only",
      extensionKind: kinds
    };
  }

  return {
    classification: "container",
    containerEligible: true,
    hostOnly: false,
    reason: "extensionKind does not exclude workspace installation",
    extensionKind: kinds
  };
}

export function isCompatibleWithVSCode(targetVersion, enginesRange) {
  if (!enginesRange || enginesRange === "*") {
    return true;
  }

  const coerced = semver.coerce(targetVersion);
  if (!coerced) {
    throw new Error(`Target VS Code version is not semver-compatible: ${targetVersion}`);
  }

  try {
    return semver.satisfies(coerced.version, enginesRange, { includePrerelease: true });
  } catch {
    return false;
  }
}

export function topologicalInstallOrder(extensionRecords, options = {}) {
  const warnings = options.warnings ?? [];
  const records = new Map();
  for (const record of extensionRecords) {
    records.set(record.normalizedId, record);
  }

  const temporary = new Set();
  const permanent = new Set();
  const ordered = [];

  function visit(id, stack = []) {
    if (permanent.has(id)) {
      return;
    }
    if (temporary.has(id)) {
      if (options.allowCycles) {
        warnings.push(`Extension dependency cycle detected: ${[...stack, id].join(" -> ")}. Using deterministic source resolution order for the cycle.`);
        return;
      }
      throw new Error(`Extension dependency cycle detected: ${[...stack, id].join(" -> ")}`);
    }

    temporary.add(id);
    const record = records.get(id);
    if (!record) {
      throw new Error(`Missing resolved extension in graph: ${id}`);
    }

    for (const dependency of record.dependsOnNormalizedIds) {
      if (records.has(dependency)) {
        visit(dependency, [...stack, id]);
      }
    }

    temporary.delete(id);
    permanent.add(id);
    if (record.containerEligible) {
      ordered.push(record.id);
    }
  }

  for (const id of records.keys()) {
    visit(id);
  }

  return ordered;
}

function parseArgs(argv) {
  const args = {
    vscodeVersion: "",
    vscodeCommit: "",
    serverMetadata: "",
    extensionsFile: "",
    targetPlatform: "",
    artifactRoot: "",
    quality: "",
    includeUi: false,
    includePrerelease: false,
    allowHostOnlyDependency: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--vscode-version":
        args.vscodeVersion = argv[++index];
        break;
      case "--vscode-commit":
        args.vscodeCommit = argv[++index];
        break;
      case "--server-metadata":
        args.serverMetadata = argv[++index];
        break;
      case "--extensions-file":
        args.extensionsFile = argv[++index];
        break;
      case "--target-platform":
        args.targetPlatform = argv[++index];
        break;
      case "--artifact-root":
        args.artifactRoot = argv[++index];
        break;
      case "--quality":
        args.quality = argv[++index];
        break;
      case "--include-ui":
        args.includeUi = true;
        break;
      case "--include-prerelease":
        args.includePrerelease = true;
        break;
      case "--allow-host-only-dependency":
        args.allowHostOnlyDependency = true;
        break;
      case "-h":
      case "--help":
        printUsage();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function printUsage() {
  console.log(`Usage:
  node src/components/vscode/prefetch-extensions.mjs [options]

Options:
  --vscode-version VERSION       Target VS Code product version.
  --vscode-commit COMMIT         Target VS Code commit SHA.
  --server-metadata FILE         VS Code Server metadata JSON.
  --extensions-file FILE         Extension ID list.
  --target-platform PLATFORM     linux-x64 or linux-arm64.
  --artifact-root DIR            Artifact root.
  --quality QUALITY              stable.
  --include-ui                   Include host-only extensions in install order.
  --include-prerelease           Include Marketplace prerelease versions.
  --allow-host-only-dependency   Warn instead of failing when a container extension depends on a host-only extension.
  -h, --help                     Show help.`);
}

function repoRoot() {
  return path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
}

function resolvePath(root, maybeRelative) {
  if (path.isAbsolute(maybeRelative)) {
    return maybeRelative;
  }
  return path.join(root, maybeRelative);
}

function toRepoPath(root, absolutePath) {
  return path.relative(root, absolutePath).split(path.sep).join("/");
}


function readExtensionList(filePath) {
  return fs.readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function ensureCommand(command) {
  try {
    execFileSync(command, ["--help"], { stdio: "ignore" });
  } catch {
    throw new Error(`Required command not found or not runnable: ${command}`);
  }
}

async function marketplaceQuery(extensionId, targetPlatform) {
  const criteria = [
    { filterType: 7, value: extensionId },
    { filterType: 8, value: "Microsoft.VisualStudio.Code" }
  ];
  if (targetPlatform) {
    criteria.push({ filterType: 23, value: targetPlatform });
  }

  const body = {
    filters: [
      {
        criteria,
        pageNumber: 1,
        pageSize: 100,
        sortBy: 0,
        sortOrder: 0
      }
    ],
    assetTypes: [VSIX_ASSET_TYPE],
    flags: 243
  };

  return withNetworkRetries(`Marketplace query for ${extensionId}`, async () => {
    const response = await fetch(MARKETPLACE_URL, {
      method: "POST",
      headers: {
        Accept: "application/json;api-version=3.0-preview.1",
        "Content-Type": "application/json",
        "User-Agent": "VSCode Offline Extension Prefetcher"
      },
      body: JSON.stringify(body)
    });

    if (!response.ok) {
      const error = new Error(`Marketplace query failed for ${extensionId}: HTTP ${response.status}`);
      error.retryable = response.status === 408 || response.status === 429 || response.status >= 500;
      throw error;
    }

    return response.json();
  });
}

function extensionFromQueryResult(result, requestedId) {
  const normalized = normalizeExtensionId(requestedId);
  const extensions = result.results?.flatMap((entry) => entry.extensions ?? []) ?? [];
  return extensions.find((extension) => {
    const publisher = extension.publisher?.publisherName ?? "";
    const name = extension.extensionName ?? "";
    return normalizeExtensionId(`${publisher}.${name}`) === normalized;
  }) ?? extensions[0];
}

function versionSortDescending(a, b) {
  const parsedA = semver.parse(a.version);
  const parsedB = semver.parse(b.version);
  if (parsedA && parsedB) {
    return semver.rcompare(parsedA, parsedB);
  }
  return String(b.version).localeCompare(String(a.version));
}

function fileUrlForVersion(extension, version) {
  const explicit = version.files?.find((file) => file.assetType === VSIX_ASSET_TYPE && file.source)?.source;
  if (explicit) {
    return explicit;
  }

  const publisher = extension.publisher?.publisherName;
  const name = extension.extensionName;
  if (!publisher || !name) {
    throw new Error(`Marketplace response did not include publisher/name for version ${version.version}`);
  }

  return `https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${encodeURIComponent(publisher)}/vsextensions/${encodeURIComponent(name)}/${encodeURIComponent(version.version)}/vspackage`;
}

function fileUrlForPlatform(extension, version, sourcePlatform) {
  const url = new URL(fileUrlForVersion(extension, version));
  if (sourcePlatform && sourcePlatform !== "universal") {
    // Marketplace commonly returns the same asset URL for every platform
    // record. Without this selector that URL can default to a different OS.
    url.searchParams.set("targetPlatform", sourcePlatform);
  }
  return url.toString();
}

function candidateTargetPlatform(version, fallbackPlatform) {
  const direct = version.targetPlatform;
  if (direct) {
    return direct;
  }

  const property = version.properties?.find((entry) => {
    const key = String(entry.key ?? "").toLowerCase();
    return key.includes("targetplatform");
  });

  return property?.value ?? fallbackPlatform ?? "universal";
}

export function collectCandidates(platformExtension, universalExtension, targetPlatform) {
  let candidates = new Map();

  function add(extension, fallbackPlatform) {
    if (!extension) {
      return;
    }
    for (const version of extension.versions ?? []) {
      // Marketplace target-platform queries can return every platform build
      // for a release. Trust each version record rather than labeling the
      // first returned payload with the platform used in the query.
      const sourcePlatform = candidateTargetPlatform(version, fallbackPlatform);
      if (sourcePlatform !== targetPlatform && sourcePlatform !== "universal") {
        continue;
      }
      const key = `${version.version}|${sourcePlatform}`;
      if (!candidates.has(key)) {
        candidates.set(key, {
          extension,
          version,
          versionString: version.version,
          sourcePlatform,
          targetPlatform: candidateTargetPlatform(version, sourcePlatform),
          downloadUrl: fileUrlForPlatform(extension, version, sourcePlatform)
        });
      }
    }
  }

  add(platformExtension, targetPlatform);
  add(universalExtension, "universal");

  if (platformExtension && platformExtension.extensionName.includes("rust-analyzer")) {
    candidates = new Map(
      Array.from(candidates.entries()).filter(([, value]) => !value.versionString.includes("0.4"))
    );
  }

  return [...candidates.values()].sort((a, b) => {
    const versionCompare = versionSortDescending(
      { version: a.versionString },
      { version: b.versionString }
    );
    if (versionCompare !== 0) {
      return versionCompare;
    }
    if (a.sourcePlatform === targetPlatform && b.sourcePlatform !== targetPlatform) {
      return -1;
    }
    if (a.sourcePlatform !== targetPlatform && b.sourcePlatform === targetPlatform) {
      return 1;
    }
    return 0;
  });
}

export function isElfForTargetPlatform(header, targetPlatform) {
  const expectedMachine = {
    "linux-x64": 62,
    "linux-arm64": 183,
  }[targetPlatform];
  if (!expectedMachine) {
    return false;
  }

  const isElf = header.length >= 20 && header.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
  const isLittleEndian = header[5] === 1;
  const machine = isLittleEndian ? header.readUInt16LE(18) : -1;
  return isElf && isLittleEndian && machine === expectedMachine;
}

export function validateTargetNativePayload(requestedId, targetPlatform, vsixPath) {
  if (normalizeExtensionId(requestedId) !== "ms-vscode.cpptools") {
    return;
  }

  const expectedMachine = { "linux-x64": 62, "linux-arm64": 183 }[targetPlatform];
  if (!expectedMachine) {
    return;
  }

  // cpptools ships native services. Validate the primary executable before
  // accepting the candidate so a mislabeled or incorrectly selected VSIX
  // falls through to the next compatible Marketplace version.
  const extractionRoot = fs.mkdtempSync(
    path.join(path.dirname(vsixPath), "cpptools-native-check-"),
  );
  const executablePath = path.join(extractionRoot, "extension", "bin", "cpptools");
  try {
    execFileSync("unzip", ["-qq", vsixPath, "extension/bin/cpptools", "-d", extractionRoot], {
      stdio: "pipe",
    });
    const header = fs.readFileSync(executablePath).subarray(0, 20);
    if (!isElfForTargetPlatform(header, targetPlatform)) {
      throw new Error(
        `cpptools native payload is not ELF machine ${expectedMachine} for ${targetPlatform}`,
      );
    }
  } finally {
    fs.rmSync(extractionRoot, { recursive: true, force: true });
  }
}

async function downloadFile(url, destination) {
  await fs.promises.mkdir(path.dirname(destination), { recursive: true });
  const buffer = await withNetworkRetries(`VSIX download ${url}`, async () => {
    const response = await fetch(url, {
      headers: {
        "User-Agent": "VSCode Offline Extension Prefetcher"
      }
    });
    if (!response.ok) {
      const error = new Error(`Download failed: HTTP ${response.status} ${url}`);
      error.retryable = response.status === 408 || response.status === 429 || response.status >= 500;
      throw error;
    }
    return Buffer.from(await response.arrayBuffer());
  });
  await fs.promises.writeFile(destination, buffer);
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function validateVsix(filePath) {
  execFileSync("unzip", ["-tqq", filePath], { stdio: "pipe" });
  const packageJsonRaw = execFileSync("unzip", ["-p", filePath, "extension/package.json"], {
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024
  });
  if (!packageJsonRaw.trim()) {
    throw new Error(`VSIX does not contain extension/package.json: ${filePath}`);
  }
  return JSON.parse(packageJsonRaw);
}

function safeFileSegment(value) {
  return String(value).replace(/[^A-Za-z0-9._-]/g, "_");
}

function metadataFromPackage(packageJson) {
  return {
    license: packageJson.license ?? "",
    repository: packageJson.repository ?? null,
    displayName: packageJson.displayName ?? "",
    description: packageJson.description ?? ""
  };
}

class ExtensionResolver {
  constructor(options) {
    this.options = options;
    this.records = new Map();
    this.warnings = [];
    this.sourceExtensions = options.sourceExtensions;
  }

  async resolveAll() {
    for (const id of this.sourceExtensions) {
      await this.resolveOne(id, null, "source");
    }

    return [...this.records.values()];
  }

  async resolveOne(extensionId, parentRecord, relationship) {
    const normalizedId = normalizeExtensionId(extensionId);
    if (this.records.has(normalizedId)) {
      const record = this.records.get(normalizedId);
      this.addParentRelationship(record, parentRecord, relationship);
      return record;
    }

    console.log(`Resolving ${extensionId}`);
    const platformResult = await marketplaceQuery(extensionId, this.options.targetPlatform);
    const universalResult = await marketplaceQuery(extensionId, "");
    const platformExtension = extensionFromQueryResult(platformResult, extensionId);
    const universalExtension = extensionFromQueryResult(universalResult, extensionId);

    const candidates = collectCandidates(platformExtension, universalExtension, this.options.targetPlatform)
      .filter((candidate) => {
        if (this.options.includePrerelease) {
          return true;
        }
        const parsed = semver.parse(candidate.versionString);
        return !parsed || parsed.prerelease.length === 0;
      });

    if (candidates.length === 0 && normalizedId.startsWith("vscode.")) {
      const builtinRecord = this.createBuiltinRecord(extensionId);
      this.addParentRelationship(builtinRecord, parentRecord, relationship);
      this.records.set(builtinRecord.normalizedId, builtinRecord);
      this.warnings.push(`${extensionId} is referenced as a dependency but is not a Marketplace VSIX; recorded as a VS Code built-in.`);
      return builtinRecord;
    }

    if (candidates.length === 0) {
      throw new Error(`No Marketplace versions found for ${extensionId}`);
    }

    const accepted = await this.selectCompatibleCandidate(extensionId, candidates);
    this.addParentRelationship(accepted, parentRecord, relationship);
    this.records.set(accepted.normalizedId, accepted);

    for (const dependency of accepted.extensionDependencies) {
      const dependencyRecord = await this.resolveOne(dependency, accepted, "dependency");
      if (!dependencyRecord.containerEligible && accepted.containerEligible && !dependencyRecord.builtin && !this.options.allowHostOnlyDependency) {
        throw new Error(`${accepted.id} depends on host-only extension ${dependencyRecord.id}. Use --allow-host-only-dependency to record a warning instead.`);
      }
      if (!dependencyRecord.containerEligible && accepted.containerEligible && !dependencyRecord.builtin) {
        this.warnings.push(`${accepted.id} depends on host-only extension ${dependencyRecord.id}.`);
      }
    }

    for (const packMember of accepted.extensionPack) {
      await this.resolveOne(packMember, accepted, "pack");
    }

    return accepted;
  }

  createBuiltinRecord(extensionId) {
    const { publisher, name } = splitExtensionId(extensionId);
    return {
      id: extensionId,
      normalizedId: normalizeExtensionId(extensionId),
      publisher,
      name,
      version: "",
      targetPlatform: "builtin",
      isUniversalFallback: false,
      enginesVscode: "",
      extensionKind: [],
      classification: "builtin",
      classificationReason: "VS Code built-in dependency; no VSIX artifact is installed",
      containerEligible: false,
      hostOnly: false,
      builtin: true,
      extensionDependencies: [],
      extensionPack: [],
      dependsOnNormalizedIds: [],
      dependents: [],
      vsixPath: "",
      packageJsonPath: "",
      sha256: "",
      downloadUrl: "",
      marketplaceUrl: "",
      license: "",
      repository: null,
      displayName: extensionId,
      description: "VS Code built-in dependency"
    };
  }

  addParentRelationship(record, parentRecord, relationship) {
    if (!parentRecord || relationship === "source") {
      return;
    }
    record.dependents.push({
      id: parentRecord.id,
      relationship
    });
    parentRecord.dependsOnNormalizedIds.push(record.normalizedId);
  }

  async selectCompatibleCandidate(requestedId, candidates) {
    const errors = [];

    for (const candidate of candidates) {
      const tempDir = path.join(this.options.artifactRootAbs, ".tmp");
      const tempPath = path.join(tempDir, `${safeFileSegment(requestedId)}-${safeFileSegment(candidate.versionString)}-${process.pid}.vsix.tmp`);
      try {
        await downloadFile(candidate.downloadUrl, tempPath);
        const packageJson = validateVsix(tempPath);
        validateTargetNativePayload(requestedId, this.options.targetPlatform, tempPath);
        const enginesVscode = packageJson.engines?.vscode ?? "";
        if (!isCompatibleWithVSCode(this.options.targetVscodeVersion, enginesVscode)) {
          const reason = `engines.vscode ${enginesVscode || "<missing>"} does not match VS Code ${this.options.targetVscodeVersion}`;
          errors.push(`${candidate.versionString}: ${reason}`);
          console.warn(
            `  rejected ${requestedId}@${candidate.versionString} (${candidate.sourcePlatform}): ${reason}`,
          );
          fs.rmSync(tempPath, { force: true });
          continue;
        }

        const classification = classifyExtensionKind(packageJson.extensionKind);
        const id = `${packageJson.publisher ?? splitExtensionId(requestedId).publisher}.${packageJson.name ?? splitExtensionId(requestedId).name}`;
        const normalizedId = normalizeExtensionId(id);
        const finalDir = path.join(
          this.options.artifactRootAbs,
          this.options.quality,
          this.options.targetVscodeCommit,
          this.options.targetPlatform,
          normalizedId,
          candidate.versionString
        );
        const platformForFile = candidate.sourcePlatform === this.options.targetPlatform ? this.options.targetPlatform : "universal";
        const finalName = `${normalizedId}-${candidate.versionString}-${platformForFile}.vsix`;
        const finalPath = path.join(finalDir, finalName);

        fs.mkdirSync(finalDir, { recursive: true });
        if (fs.existsSync(finalPath) && sha256File(finalPath) === sha256File(tempPath)) {
          fs.rmSync(tempPath, { force: true });
        } else {
          fs.renameSync(tempPath, finalPath);
        }

        const sha256 = sha256File(finalPath);
        const packageJsonPath = path.join(finalDir, "package.json");
        const metadataPath = path.join(finalDir, "metadata.json");
        fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);

        const record = {
          id,
          normalizedId,
          publisher: packageJson.publisher ?? splitExtensionId(requestedId).publisher,
          name: packageJson.name ?? splitExtensionId(requestedId).name,
          version: candidate.versionString,
          targetPlatform: candidate.sourcePlatform === this.options.targetPlatform ? this.options.targetPlatform : "universal",
          isUniversalFallback: candidate.sourcePlatform !== this.options.targetPlatform,
          enginesVscode,
          extensionKind: classification.extensionKind,
          classification: classification.classification,
          classificationReason: classification.reason,
          containerEligible: this.options.includeUi ? true : classification.containerEligible,
          hostOnly: classification.hostOnly,
          extensionDependencies: Array.isArray(packageJson.extensionDependencies) ? packageJson.extensionDependencies : [],
          extensionPack: Array.isArray(packageJson.extensionPack) ? packageJson.extensionPack : [],
          dependsOnNormalizedIds: [],
          dependents: [],
          vsixPath: toRepoPath(this.options.repoRoot, finalPath),
          packageJsonPath: toRepoPath(this.options.repoRoot, packageJsonPath),
          sha256,
          downloadUrl: candidate.downloadUrl,
          marketplaceUrl: `https://marketplace.visualstudio.com/items?itemName=${encodeURIComponent(id)}`,
          ...metadataFromPackage(packageJson)
        };

        fs.writeFileSync(metadataPath, `${JSON.stringify(record, null, 2)}\n`);
        fs.writeFileSync(path.join(finalDir, "SHA256SUMS"), `${sha256}  ${finalName}\n`);
        console.log(`  selected ${record.id}@${record.version} (${record.targetPlatform})`);
        return record;
      } catch (error) {
        fs.rmSync(tempPath, { force: true });
        errors.push(`${candidate.versionString}: ${error.message}`);
        console.warn(
          `  rejected ${requestedId}@${candidate.versionString} (${candidate.sourcePlatform}): ${error.message}`,
        );
      }
    }

    throw new Error(`No compatible version found for ${requestedId}:\n  ${errors.join("\n  ")}`);
  }
}

function buildLockfile(options, records, warnings) {
  const extensions = {};
  for (const record of records) {
    const { normalizedId, containerEligible, hostOnly, dependsOnNormalizedIds, dependents, ...publicRecord } = record;
    extensions[record.id] = {
      ...publicRecord,
      dependencyGraph: {
        dependsOn: dependsOnNormalizedIds.map((id) => records.find((item) => item.normalizedId === id)?.id ?? id),
        dependents
      }
    };
  }

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    quality: options.quality,
    targetVscodeVersion: options.targetVscodeVersion,
    targetVscodeCommit: options.targetVscodeCommit,
    targetPlatform: options.targetPlatform,
    sourceExtensions: options.sourceExtensions,
    containerInstallOrder: topologicalInstallOrder(records, {
      allowCycles: true,
      warnings
    }),
    hostOnlyExtensions: records.filter((record) => record.hostOnly).map((record) => record.id),
    builtinDependencies: records.filter((record) => record.builtin).map((record) => record.id),
    extensions,
    warnings
  };
}

async function main() {
  const root = repoRoot();
  const args = parseArgs(process.argv.slice(2));

  const quality = args.quality || "stable";
  if (quality !== "stable") {
    throw new Error("Initial extension prefetch support only supports stable quality.");
  }

  const targetPlatform = args.targetPlatform;
  if (!["linux-x64", "linux-arm64"].includes(targetPlatform)) {
    throw new Error(`Unsupported extension target platform: ${targetPlatform}`);
  }

  if (!args.artifactRoot || !args.extensionsFile) {
    throw new Error("--artifact-root and --extensions-file are required.");
  }
  const artifactRoot = args.artifactRoot;
  const artifactRootAbs = resolvePath(root, artifactRoot);
  const extensionsFile = resolvePath(root, args.extensionsFile);
  const serverMetadataPath = args.serverMetadata ? resolvePath(root, args.serverMetadata) : "";

  let targetVscodeVersion = args.vscodeVersion;
  let targetVscodeCommit = args.vscodeCommit;

  if ((!targetVscodeVersion || !targetVscodeCommit) && fs.existsSync(serverMetadataPath)) {
    const metadata = readJsonFile(serverMetadataPath);
    targetVscodeVersion ||= metadata.productVersion;
    targetVscodeCommit ||= metadata.commit;
  }

  if (!targetVscodeVersion) {
    throw new Error("Could not resolve target VS Code product version. Use --vscode-version or provide server metadata.");
  }
  if (!targetVscodeCommit) {
    throw new Error("Could not resolve target VS Code commit. Use --vscode-commit or provide server metadata.");
  }
  if (!/^[0-9a-f]{40}$/i.test(targetVscodeCommit)) {
    throw new Error(`VS Code commit does not look like a 40-character SHA: ${targetVscodeCommit}`);
  }

  ensureCommand("unzip");
  fs.mkdirSync(artifactRootAbs, { recursive: true });

  const sourceExtensions = readExtensionList(extensionsFile);
  const resolver = new ExtensionResolver({
    repoRoot: root,
    artifactRootAbs,
    quality,
    targetPlatform,
    targetVscodeVersion,
    targetVscodeCommit,
    sourceExtensions,
    includePrerelease: args.includePrerelease,
    includeUi: args.includeUi,
    allowHostOnlyDependency: args.allowHostOnlyDependency
  });

  const records = await resolver.resolveAll();
  const lockfile = buildLockfile(resolver.options, records, resolver.warnings);
  const lockfilePath = path.join(artifactRootAbs, "vscode-extensions.lock.json");
  const currentPath = path.join(artifactRootAbs, `current-${quality}-${targetPlatform}.json`);
  const archiveName = "vscode-extensions.tar.gz";
  const archivePath = path.join(artifactRootAbs, archiveName);

  fs.writeFileSync(lockfilePath, `${JSON.stringify(lockfile, null, 2)}\n`);
  fs.copyFileSync(lockfilePath, currentPath);

  execFileSync("bash", [
    path.join(root, "src/components/vscode/package-extensions.sh"),
    "--lock",
    lockfilePath,
    "--output",
    archivePath
  ], { stdio: "inherit" });

  console.log("VS Code extension prefetch complete:");
  console.log(`  lockfile: ${lockfilePath}`);
  console.log(`  current:  ${currentPath}`);
  console.log(`  archive:  ${archivePath}`);
  console.log(`  installable extensions: ${lockfile.containerInstallOrder.length}`);
  console.log(`  host-only extensions:   ${lockfile.hostOnlyExtensions.length}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  });
}
