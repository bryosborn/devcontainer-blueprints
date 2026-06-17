#!/usr/bin/env node
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import semver from "semver";

const UPDATE_API_ROOT = "https://update.code.visualstudio.com/api";
const DOWNLOAD_ROOT = "https://update.code.visualstudio.com";
const MARKETPLACE_URL = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery";
const VSIX_ASSET_TYPE = "Microsoft.VisualStudio.Services.VSIXPackage";
const MANIFEST_ASSET_TYPE = "Microsoft.VisualStudio.Code.Manifest";
const execFileAsync = promisify(execFile);

function usage() {
  console.log(`Usage:
  prefetch.mjs [options]

Options:
  --version VERSION             VS Code product version, e.g. 1.124.2 or latest.
  --commit COMMIT               Exact VS Code commit SHA. Skips product-version lookup.
  --quality QUALITY             VS Code quality. Default comes from WSL_VSCODE_QUALITY.
  --client-platform PLATFORM    VS Code client update platform.
  --server-platform PLATFORM    Server platform. Repeatable.
  --extension EXTENSION_ID      Marketplace extension to resolve. Repeatable.
  --artifact-root DIR           Artifact root. Default comes from WSL_ARTIFACT_ROOT.
  --no-bootstrap-image          Do not build/save the Dev Containers bootstrap container image.
  --bootstrap-extension ID      Dev Containers extension ID. Default comes from WSL_DEVCONTAINERS_BOOTSTRAP_EXTENSION.
  --bootstrap-image-name NAME   Bootstrap image repository. Default comes from WSL_DEVCONTAINERS_BOOTSTRAP_IMAGE_NAME.
  --print                       Print manifest to stdout as well as writing it.
  -h, --help                    Show help.`);
}

function repoRoot() {
  return path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
}

function listFromEnv(value, fallback) {
  const items = String(value ?? "")
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
  return items.length > 0 ? items : fallback;
}

function booleanFromEnv(value, fallback) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  return !/^(0|false|no|off)$/i.test(String(value).trim());
}

function parseArgs(argv) {
  const args = {
    version: process.env.WSL_VSCODE_VERSION || "latest",
    commit: process.env.WSL_VSCODE_COMMIT || "",
    quality: process.env.WSL_VSCODE_QUALITY || "stable",
    clientPlatform: process.env.WSL_CLIENT_PLATFORM || "win32-x64-archive",
    serverPlatforms: listFromEnv(process.env.WSL_SERVER_PLATFORMS, ["server-linux-x64"]),
    extensions: listFromEnv(process.env.WSL_EXTENSIONS, ["ms-vscode-remote.remote-wsl"]),
    artifactRoot: process.env.WSL_ARTIFACT_ROOT || "artifacts/wsl",
    prefetchBootstrapImage: booleanFromEnv(process.env.WSL_PREFETCH_DEVCONTAINERS_BOOTSTRAP_IMAGE, true),
    bootstrapExtension: process.env.WSL_DEVCONTAINERS_BOOTSTRAP_EXTENSION || "ms-vscode-remote.remote-containers",
    bootstrapImageName: process.env.WSL_DEVCONTAINERS_BOOTSTRAP_IMAGE_NAME || "vsc-volume-bootstrap",
    print: false,
    serverPlatformsOverridden: false,
    extensionsOverridden: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--version":
        args.version = argv[++index];
        args.commit = "";
        break;
      case "--commit":
        args.commit = argv[++index];
        break;
      case "--quality":
        args.quality = argv[++index];
        break;
      case "--client-platform":
        args.clientPlatform = argv[++index];
        break;
      case "--server-platform":
        if (!args.serverPlatformsOverridden) {
          args.serverPlatforms = [];
          args.serverPlatformsOverridden = true;
        }
        args.serverPlatforms.push(argv[++index]);
        break;
      case "--extension":
        if (!args.extensionsOverridden) {
          args.extensions = [];
          args.extensionsOverridden = true;
        }
        args.extensions.push(argv[++index]);
        break;
      case "--artifact-root":
        args.artifactRoot = argv[++index];
        break;
      case "--no-bootstrap-image":
        args.prefetchBootstrapImage = false;
        break;
      case "--bootstrap-extension":
        args.bootstrapExtension = argv[++index];
        break;
      case "--bootstrap-image-name":
        args.bootstrapImageName = argv[++index];
        break;
      case "--print":
        args.print = true;
        break;
      case "-h":
      case "--help":
        usage();
        process.exit(0);
        break;
      default:
        if (arg.startsWith("-")) {
          throw new Error(`Unknown argument: ${arg}`);
        }
        if (args.version && args.version !== "latest") {
          throw new Error(`Unexpected positional argument: ${arg}`);
        }
        args.version = arg;
        args.commit = "";
    }
  }

  delete args.serverPlatformsOverridden;
  delete args.extensionsOverridden;

  if (args.prefetchBootstrapImage) {
    const bootstrapExtension = normalizeExtensionId(args.bootstrapExtension);
    if (!args.extensions.some((extensionId) => normalizeExtensionId(extensionId) === bootstrapExtension)) {
      args.extensions.push(args.bootstrapExtension);
    }
  }

  return args;
}

function resolvePath(root, filePath) {
  return path.isAbsolute(filePath) ? filePath : path.join(root, filePath);
}

function relativeForManifest(artifactRoot, filePath) {
  return path.relative(artifactRoot, filePath).split(path.sep).join("/");
}

function sanitizePathPart(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9._-]+/g, "-");
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      Accept: "application/json",
      "User-Agent": "devcontainer-blueprints-wsl-artifacts",
      ...(options.headers ?? {})
    }
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }
  return response.json();
}

function jsonField(value, fallback = "") {
  return value === undefined || value === null ? fallback : String(value);
}

async function resolveVSCode(args) {
  if (args.commit) {
    const commit = args.commit.toLowerCase();
    if (!/^[0-9a-f]{40}$/i.test(commit)) {
      throw new Error(`Commit does not look like a 40-character SHA: ${args.commit}`);
    }
    if (!args.version || args.version === "latest") {
      throw new Error("When --commit is used, provide --version too so extension compatibility can be checked.");
    }
    return {
      requestedVersion: args.version,
      productVersion: args.version,
      commit,
      quality: args.quality,
      clientPlatform: args.clientPlatform,
      metadataUrl: "",
      rawMetadata: null
    };
  }

  const requestedVersion = args.version || "latest";
  const metadataUrl = requestedVersion === "latest"
    ? `${UPDATE_API_ROOT}/update/${encodeURIComponent(args.clientPlatform)}/${encodeURIComponent(args.quality)}/latest`
    : `${UPDATE_API_ROOT}/versions/${encodeURIComponent(requestedVersion)}/${encodeURIComponent(args.clientPlatform)}/${encodeURIComponent(args.quality)}`;
  const rawMetadata = await fetchJson(metadataUrl);
  const commit = jsonField(rawMetadata.version).toLowerCase();

  if (!/^[0-9a-f]{40}$/i.test(commit)) {
    throw new Error(`VS Code metadata did not return a commit SHA at .version: ${commit}`);
  }

  return {
    requestedVersion,
    productVersion: jsonField(rawMetadata.productVersion, jsonField(rawMetadata.name, requestedVersion)),
    commit,
    quality: args.quality,
    clientPlatform: args.clientPlatform,
    metadataUrl,
    rawMetadata
  };
}

async function resolveServerArtifact(vscode, serverPlatform) {
  const metadataUrl = `${UPDATE_API_ROOT}/versions/commit:${encodeURIComponent(vscode.commit)}/${encodeURIComponent(serverPlatform)}/${encodeURIComponent(vscode.quality)}`;
  let metadata = null;
  let url = "";
  let upstreamSha256 = "";

  try {
    metadata = await fetchJson(metadataUrl);
    url = jsonField(metadata.url);
    upstreamSha256 = jsonField(metadata.sha256hash);
  } catch (error) {
    metadata = { warning: `Metadata endpoint failed: ${error.message}` };
  }

  if (!url) {
    url = `${DOWNLOAD_ROOT}/commit:${encodeURIComponent(vscode.commit)}/${encodeURIComponent(serverPlatform)}/${encodeURIComponent(vscode.quality)}`;
  }

  return {
    kind: "vscode-server",
    platform: serverPlatform,
    quality: vscode.quality,
    commit: vscode.commit,
    url,
    upstreamSha256,
    metadataUrl,
    archiveName: `vscode-server-${serverPlatform.replace(/^server-/, "")}.tar.gz`,
    rawMetadata: metadata
  };
}

function normalizeExtensionId(extensionId) {
  return String(extensionId).trim().toLowerCase();
}

function splitExtensionId(extensionId) {
  const parts = extensionId.split(".");
  if (parts.length < 2) {
    throw new Error(`Extension ID must look like publisher.name: ${extensionId}`);
  }
  return {
    publisher: parts[0],
    name: parts.slice(1).join(".")
  };
}

async function marketplaceQuery(extensionId) {
  const body = {
    filters: [
      {
        criteria: [
          { filterType: 7, value: extensionId },
          { filterType: 8, value: "Microsoft.VisualStudio.Code" }
        ],
        pageNumber: 1,
        pageSize: 100,
        sortBy: 0,
        sortOrder: 0
      }
    ],
    assetTypes: [VSIX_ASSET_TYPE, MANIFEST_ASSET_TYPE],
    flags: 243
  };

  const response = await fetch(MARKETPLACE_URL, {
    method: "POST",
    headers: {
      Accept: "application/json;api-version=3.0-preview.1",
      "Content-Type": "application/json",
      "User-Agent": "devcontainer-blueprints-wsl-artifacts"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok) {
    throw new Error(`Marketplace query failed for ${extensionId}: HTTP ${response.status}`);
  }
  return response.json();
}

function extensionFromQueryResult(result, requestedId) {
  const requested = normalizeExtensionId(requestedId);
  const extensions = result.results?.flatMap((entry) => entry.extensions ?? []) ?? [];
  return extensions.find((extension) => {
    const publisher = extension.publisher?.publisherName ?? "";
    const name = extension.extensionName ?? "";
    return normalizeExtensionId(`${publisher}.${name}`) === requested;
  }) ?? extensions[0];
}

function property(version, key) {
  return version.properties?.find((entry) => entry.key === key)?.value ?? "";
}

function assetUrl(version, assetType) {
  return version.files?.find((file) => file.assetType === assetType && file.source)?.source ?? "";
}

function fallbackVsixUrl(extension, versionString) {
  const publisher = extension.publisher?.publisherName;
  const name = extension.extensionName;
  if (!publisher || !name) {
    throw new Error(`Marketplace response did not include publisher/name for version ${versionString}`);
  }
  return `https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${encodeURIComponent(publisher)}/vsextensions/${encodeURIComponent(name)}/${encodeURIComponent(versionString)}/vspackage`;
}

function versionSortDescending(a, b) {
  const parsedA = semver.parse(a.version);
  const parsedB = semver.parse(b.version);
  if (parsedA && parsedB) {
    return semver.rcompare(parsedA, parsedB);
  }
  return String(b.version).localeCompare(String(a.version));
}

function compatibleWithVSCode(productVersion, enginesRange) {
  if (!enginesRange || enginesRange === "*") {
    return true;
  }
  const coerced = semver.coerce(productVersion);
  if (!coerced) {
    throw new Error(`VS Code product version is not semver-compatible: ${productVersion}`);
  }
  return semver.satisfies(coerced.version, enginesRange, { includePrerelease: true });
}

async function resolveExtensionArtifact(extensionId, productVersion) {
  const result = await marketplaceQuery(extensionId);
  const extension = extensionFromQueryResult(result, extensionId);
  if (!extension) {
    throw new Error(`No Marketplace extension found for ${extensionId}`);
  }

  const candidates = [...(extension.versions ?? [])]
    .filter((version) => {
      const parsed = semver.parse(version.version);
      return !parsed || parsed.prerelease.length === 0;
    })
    .sort(versionSortDescending);

  const attempted = [];
  const accepted = candidates.find((version) => {
    const engines = property(version, "Microsoft.VisualStudio.Code.Engine");
    attempted.push({ version: version.version, enginesVscode: engines });
    try {
      return compatibleWithVSCode(productVersion, engines);
    } catch {
      return false;
    }
  });

  if (!accepted) {
    throw new Error(`No compatible ${extensionId} version found for VS Code ${productVersion}`);
  }

  const publisher = extension.publisher?.publisherName ?? splitExtensionId(extensionId).publisher;
  const name = extension.extensionName ?? splitExtensionId(extensionId).name;
  const versionString = accepted.version;

  return {
    kind: "vscode-extension",
    id: `${publisher}.${name}`,
    requestedId: extensionId,
    version: versionString,
    targetPlatform: accepted.targetPlatform ?? "universal",
    enginesVscode: property(accepted, "Microsoft.VisualStudio.Code.Engine"),
    preRelease: property(accepted, "Microsoft.VisualStudio.Code.PreRelease") === "true",
    url: assetUrl(accepted, VSIX_ASSET_TYPE) || fallbackVsixUrl(extension, versionString),
    manifestUrl: assetUrl(accepted, MANIFEST_ASSET_TYPE),
    marketplaceUrl: `https://marketplace.visualstudio.com/items?itemName=${encodeURIComponent(`${publisher}.${name}`)}`,
    files: accepted.files ?? [],
    selection: {
      compatibleWith: productVersion,
      attempted: attempted.slice(0, 10)
    }
  };
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  await pipeline(fs.createReadStream(filePath), hash);
  return hash.digest("hex");
}

async function commandOutput(command, args, options = {}) {
  const { stdout } = await execFileAsync(command, args, {
    ...options,
    maxBuffer: options.maxBuffer ?? 20 * 1024 * 1024
  });
  return stdout;
}

async function runCommand(command, args, options = {}) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
      ...options
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with code ${code}`));
      }
    });
  });
}

async function requireCommand(command) {
  const versionArgs = command === "unzip" ? ["-v"] : ["--version"];
  try {
    await commandOutput(command, versionArgs, { maxBuffer: 1024 * 1024 });
  } catch (error) {
    throw new Error(`Required command failed or was not found: ${command}. ${error.message}`);
  }
}

async function downloadArtifact(url, outputPath, expectedSha256 = "") {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });

  if (fs.existsSync(outputPath)) {
    const existingSha256 = await sha256File(outputPath);
    if (!expectedSha256 || existingSha256 === expectedSha256) {
      return { sha256: existingSha256, reused: true };
    }
  }

  const response = await fetch(url, {
    headers: {
      "User-Agent": "devcontainer-blueprints-wsl-artifacts"
    }
  });
  if (!response.ok) {
    throw new Error(`Download failed with HTTP ${response.status}: ${url}`);
  }

  const tmpPath = `${outputPath}.tmp`;
  fs.rmSync(tmpPath, { force: true });
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(tmpPath));
  const actualSha256 = await sha256File(tmpPath);

  if (expectedSha256 && actualSha256 !== expectedSha256) {
    fs.rmSync(tmpPath, { force: true });
    throw new Error(`SHA256 mismatch for ${url}: expected ${expectedSha256}, got ${actualSha256}`);
  }

  fs.renameSync(tmpPath, outputPath);
  return { sha256: actualSha256, reused: false };
}

function serverOutputPath(artifactRoot, artifact) {
  return path.join(
    artifactRoot,
    "vscode-server",
    artifact.quality,
    artifact.commit,
    artifact.platform,
    artifact.archiveName
  );
}

function extensionOutputPath(artifactRoot, artifact) {
  const id = sanitizePathPart(artifact.id);
  const targetPlatform = sanitizePathPart(artifact.targetPlatform || "universal");
  return path.join(
    artifactRoot,
    "vscode-extensions",
    id,
    artifact.version,
    targetPlatform,
    `${id}-${artifact.version}-${targetPlatform}.vsix`
  );
}

async function unzipText(vsixPath, entryPath) {
  return commandOutput("unzip", ["-p", vsixPath, entryPath], {
    maxBuffer: 40 * 1024 * 1024
  });
}

function defaultCaCertificates() {
  const candidates = [
    process.env.SSL_CERT_FILE,
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt"
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return fs.readFileSync(candidate);
    }
  }

  return Buffer.from("");
}

function dockerImageOutputPath(artifactRoot, imageRef) {
  return path.join(
    artifactRoot,
    "docker-images",
    `${sanitizePathPart(imageRef)}.tar`
  );
}

function parseBaseImage(dockerfileText) {
  return dockerfileText.split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => /^FROM\s+/i.test(line))
    ?.replace(/^FROM\s+/i, "")
    .trim() ?? "";
}

async function buildDevContainersBootstrapImage(root, artifactRoot, extensionDownload, args) {
  await requireCommand("unzip");
  await requireCommand("docker");

  const extensionArtifact = extensionDownload.artifact;
  const extensionVersion = extensionArtifact.version;
  const imageRef = `${args.bootstrapImageName}:${extensionVersion}`;
  const defaultImageRef = `${args.bootstrapImageName}:latest`;
  const outputPath = dockerImageOutputPath(artifactRoot, imageRef);
  let reused = fs.existsSync(outputPath);
  const dockerfileArtifactPath = path.join(
    artifactRoot,
    "devcontainers-bootstrap",
    extensionVersion,
    "bootstrap.Dockerfile"
  );

  if (!reused) {
    const contextDir = fs.mkdtempSync(path.join(os.tmpdir(), "devcontainers-bootstrap-"));
    try {
      const cliDir = path.join(
        contextDir,
        ".vscode-remote-containers",
        "dist",
        `dev-containers-cli-${extensionVersion}`
      );
      fs.mkdirSync(path.join(cliDir, "dist", "spec-node"), { recursive: true });
      fs.mkdirSync(path.join(cliDir, "scripts"), { recursive: true });

      const dockerfileText = await unzipText(extensionDownload.outputPath, "extension/scripts/bootstrap.Dockerfile");
      fs.writeFileSync(path.join(contextDir, "bootstrap.Dockerfile"), dockerfileText);
      fs.mkdirSync(path.dirname(dockerfileArtifactPath), { recursive: true });
      fs.writeFileSync(dockerfileArtifactPath, dockerfileText);
      fs.writeFileSync(path.join(contextDir, "host-ca-certificates.crt"), defaultCaCertificates());
      fs.writeFileSync(path.join(cliDir, "package.json"), await unzipText(extensionDownload.outputPath, "extension/package.json"));
      fs.writeFileSync(
        path.join(cliDir, "dist", "spec-node", "devContainersSpecCLI.js"),
        await unzipText(extensionDownload.outputPath, "extension/dist/spec-node/devContainersSpecCLI.js")
      );
      fs.writeFileSync(
        path.join(cliDir, "scripts", "updateUID.Dockerfile"),
        await unzipText(extensionDownload.outputPath, "extension/scripts/updateUID.Dockerfile")
      );

      console.log(`Building Dev Containers bootstrap container image: ${imageRef}`);
      await runCommand("docker", [
        "build",
        "--pull",
        "-f",
        path.join(contextDir, "bootstrap.Dockerfile"),
        "-t",
        imageRef,
        "-t",
        defaultImageRef,
        contextDir
      ]);

      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      console.log(`Saving Dev Containers bootstrap container image artifact: ${relativeForManifest(artifactRoot, outputPath)}`);
      await runCommand("docker", [
        "save",
        "--output",
        outputPath,
        imageRef,
        defaultImageRef
      ]);
    } finally {
      fs.rmSync(contextDir, { recursive: true, force: true });
    }
  } else {
    console.log(`Reusing Dev Containers bootstrap container image artifact: ${relativeForManifest(artifactRoot, outputPath)}`);
  }

  const sha256 = await sha256File(outputPath);
  let imageInspect = null;
  try {
    imageInspect = JSON.parse(await commandOutput("docker", ["image", "inspect", imageRef]))[0] ?? null;
  } catch {
    imageInspect = null;
  }

  let dockerfileText = "";
  if (fs.existsSync(dockerfileArtifactPath)) {
    dockerfileText = fs.readFileSync(dockerfileArtifactPath, "utf8");
  }

  return {
    kind: "docker-image",
    id: "devcontainers-bootstrap-container-image",
    purpose: "Prebuilt Dev Containers bootstrap container image used by Clone Repository in Container Volume.",
    sourceExtension: extensionArtifact.id,
    sourceExtensionVersion: extensionVersion,
    bootstrapImageRef: imageRef,
    defaultImageRef,
    imageRefs: [imageRef, defaultImageRef],
    baseImage: parseBaseImage(dockerfileText),
    imageId: imageInspect?.Id ?? "",
    repoTags: imageInspect?.RepoTags ?? [imageRef, defaultImageRef],
    dockerfilePath: fs.existsSync(dockerfileArtifactPath) ? relativeForManifest(artifactRoot, dockerfileArtifactPath) : "",
    path: relativeForManifest(artifactRoot, outputPath),
    sha256,
    reused
  };
}

async function main() {
  const root = repoRoot();
  const args = parseArgs(process.argv.slice(2));
  const artifactRoot = resolvePath(root, args.artifactRoot);
  fs.mkdirSync(artifactRoot, { recursive: true });

  const vscode = await resolveVSCode(args);
  const artifacts = [];
  const extensionDownloads = new Map();

  for (const platform of args.serverPlatforms) {
    const artifact = await resolveServerArtifact(vscode, platform);
    const outputPath = serverOutputPath(artifactRoot, artifact);
    const download = await downloadArtifact(artifact.url, outputPath, artifact.upstreamSha256);
    artifacts.push({
      ...artifact,
      path: relativeForManifest(artifactRoot, outputPath),
      sha256: download.sha256,
      reused: download.reused
    });
  }

  for (const extensionId of args.extensions) {
    const artifact = await resolveExtensionArtifact(extensionId, vscode.productVersion);
    const outputPath = extensionOutputPath(artifactRoot, artifact);
    const download = await downloadArtifact(artifact.url, outputPath);
    const manifestArtifact = {
      ...artifact,
      path: relativeForManifest(artifactRoot, outputPath),
      sha256: download.sha256,
      reused: download.reused
    };
    artifacts.push(manifestArtifact);
    extensionDownloads.set(normalizeExtensionId(artifact.id), {
      artifact: manifestArtifact,
      outputPath
    });
  }

  if (args.prefetchBootstrapImage) {
    const bootstrapExtension = normalizeExtensionId(args.bootstrapExtension);
    const extensionDownload = extensionDownloads.get(bootstrapExtension);
    if (!extensionDownload) {
      throw new Error(`Bootstrap extension was not downloaded: ${args.bootstrapExtension}`);
    }
    artifacts.push(await buildDevContainersBootstrapImage(root, artifactRoot, extensionDownload, args));
  }

  const manifest = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    purpose: "Downloaded VS Code WSL bootstrap artifacts for transfer.",
    vscode,
    artifactRoot: path.relative(root, artifactRoot).split(path.sep).join("/"),
    artifacts
  };

  const manifestPath = path.join(artifactRoot, "manifest.json");
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  if (args.print) {
    console.log(JSON.stringify(manifest, null, 2));
  } else {
    console.log(`Wrote WSL artifact manifest: ${path.relative(root, manifestPath)}`);
    console.log(`VS Code ${vscode.productVersion} -> ${vscode.commit}`);
    for (const artifact of artifacts) {
      console.log(`  ${artifact.kind}: ${artifact.path}`);
    }
  }
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
