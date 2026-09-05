#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  classifyExtensionKind,
  collectCandidates,
  isElfForTargetPlatform,
  isCompatibleWithVSCode,
  normalizeExtensionId,
  splitExtensionId,
  topologicalInstallOrder,
  validateTargetNativePayload
} from "./prefetch-extensions.mjs";

function record(id, dependsOn = [], containerEligible = true) {
  return {
    id,
    normalizedId: normalizeExtensionId(id),
    dependsOnNormalizedIds: dependsOn.map(normalizeExtensionId),
    containerEligible
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

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../.."
);

test("splits publisher and extension name", () => {
  assert.deepEqual(splitExtensionId("ms-python.python"), {
    publisher: "ms-python",
    name: "python"
  });
  assert.deepEqual(splitExtensionId("publisher.name.with.dots"), {
    publisher: "publisher",
    name: "name.with.dots"
  });
  assert.throws(() => splitExtensionId("not-an-extension-id"));
});

test("classifies missing extensionKind as container eligible", () => {
  const result = classifyExtensionKind(undefined);
  assert.equal(result.containerEligible, true);
  assert.equal(result.hostOnly, false);
  assert.equal(result.classification, "container");
});

test("classifies workspace extensionKind as container eligible", () => {
  const result = classifyExtensionKind(["workspace"]);
  assert.equal(result.containerEligible, true);
  assert.equal(result.hostOnly, false);
  assert.equal(result.classification, "container");
});

test("classifies UI-only extensionKind as host-only", () => {
  const result = classifyExtensionKind(["ui"]);
  assert.equal(result.containerEligible, false);
  assert.equal(result.hostOnly, true);
  assert.equal(result.classification, "host");
});

test("classifies UI plus workspace as both", () => {
  const result = classifyExtensionKind(["ui", "workspace"]);
  assert.equal(result.containerEligible, true);
  assert.equal(result.hostOnly, false);
  assert.equal(result.classification, "both");
});

test("checks VS Code semver compatibility", () => {
  assert.equal(isCompatibleWithVSCode("1.124.2", "^1.90.0"), true);
  assert.equal(isCompatibleWithVSCode("1.80.0", "^1.90.0"), false);
  assert.equal(isCompatibleWithVSCode("1.124.2", ">=1.90.0 <2.0.0"), true);
  assert.equal(isCompatibleWithVSCode("1.124.2", "*"), true);
  assert.equal(isCompatibleWithVSCode("1.124.2", ""), true);
});

test("selects the declared target-platform payload from multi-platform Marketplace results", () => {
  const extension = {
    publisher: { publisherName: "ms-vscode" },
    extensionName: "cpptools",
    versions: [
      {
        version: "1.34.3",
        targetPlatform: "darwin-x64",
        files: [{
          assetType: "Microsoft.VisualStudio.Services.VSIXPackage",
          source: "https://example.invalid/cpptools-darwin-x64.vsix"
        }]
      },
      {
        version: "1.34.3",
        targetPlatform: "linux-x64",
        files: [{
          assetType: "Microsoft.VisualStudio.Services.VSIXPackage",
          source: "https://example.invalid/cpptools-linux-x64.vsix?channel=stable"
        }]
      },
      {
        version: "1.34.3",
        targetPlatform: "linux-arm64",
        files: [{
          assetType: "Microsoft.VisualStudio.Services.VSIXPackage",
          source: "https://example.invalid/cpptools-linux-arm64.vsix"
        }]
      },
      {
        version: "1.34.2",
        targetPlatform: "universal",
        files: [{
          assetType: "Microsoft.VisualStudio.Services.VSIXPackage",
          source: "https://example.invalid/cpptools-universal.vsix?channel=stable"
        }]
      }
    ]
  };

  const candidates = collectCandidates(extension, null, "linux-x64");
  assert.equal(candidates.length, 2);
  assert.equal(candidates[0].sourcePlatform, "linux-x64");
  assert.equal(candidates[0].targetPlatform, "linux-x64");
  assert.equal(
    candidates[0].downloadUrl,
    "https://example.invalid/cpptools-linux-x64.vsix?channel=stable&targetPlatform=linux-x64"
  );
  assert.equal(candidates[1].sourcePlatform, "universal");
  assert.equal(
    candidates[1].downloadUrl,
    "https://example.invalid/cpptools-universal.vsix?channel=stable"
  );
});

test("rejects non-Linux and wrong-architecture native payloads", () => {
  function elfHeader(machine) {
    const header = Buffer.alloc(20);
    Buffer.from([0x7f, 0x45, 0x4c, 0x46]).copy(header);
    header[5] = 1;
    header.writeUInt16LE(machine, 18);
    return header;
  }

  assert.equal(isElfForTargetPlatform(elfHeader(62), "linux-x64"), true);
  assert.equal(isElfForTargetPlatform(elfHeader(183), "linux-arm64"), true);
  assert.equal(isElfForTargetPlatform(elfHeader(183), "linux-x64"), false);
  assert.equal(
    isElfForTargetPlatform(Buffer.from([0xcf, 0xfa, 0xed, 0xfe]), "linux-x64"),
    false
  );
});

test("validates the native cpptools executable inside a VSIX fixture", () => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cpptools-vsix-fixture-"));

  function fixture(name, header) {
    const sourceRoot = path.join(fixtureRoot, name);
    const binaryDirectory = path.join(sourceRoot, "extension", "bin");
    const archive = path.join(fixtureRoot, `${name}.vsix`);
    fs.mkdirSync(binaryDirectory, { recursive: true });
    fs.writeFileSync(path.join(binaryDirectory, "cpptools"), header);
    execFileSync("zip", ["-q", "-r", archive, "extension"], {
      cwd: sourceRoot,
      stdio: "pipe"
    });
    return archive;
  }

  const x64Header = Buffer.alloc(20);
  Buffer.from([0x7f, 0x45, 0x4c, 0x46]).copy(x64Header);
  x64Header[5] = 1;
  x64Header.writeUInt16LE(62, 18);
  const machOHeader = Buffer.from([0xcf, 0xfa, 0xed, 0xfe]);

  try {
    assert.doesNotThrow(() => validateTargetNativePayload(
      "ms-vscode.cpptools",
      "linux-x64",
      fixture("linux-x64", x64Header)
    ));
    assert.throws(() => validateTargetNativePayload(
      "ms-vscode.cpptools",
      "linux-x64",
      fixture("darwin-x64", machOHeader)
    ), /not ELF machine 62/);
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("orders hard dependencies before dependents", () => {
  const records = [
    record("publisher.main", ["publisher.dep"]),
    record("publisher.dep")
  ];
  assert.deepEqual(topologicalInstallOrder(records), [
    "publisher.dep",
    "publisher.main"
  ]);
});

test("orders extension pack members before the pack", () => {
  const records = [
    record("publisher.pack", ["publisher.member-a", "publisher.member-b"]),
    record("publisher.member-a"),
    record("publisher.member-b", ["publisher.shared"]),
    record("publisher.shared")
  ];
  assert.deepEqual(topologicalInstallOrder(records), [
    "publisher.member-a",
    "publisher.shared",
    "publisher.member-b",
    "publisher.pack"
  ]);
});

test("excludes host-only extensions from install order but keeps graph traversal", () => {
  const records = [
    record("publisher.container", ["publisher.host-only"]),
    record("publisher.host-only", [], false)
  ];
  assert.deepEqual(topologicalInstallOrder(records), ["publisher.container"]);
});

test("excludes built-in dependencies from install order", () => {
  const records = [
    record("publisher.container", ["vscode.yaml"]),
    {
      ...record("vscode.yaml", [], false),
      builtin: true
    }
  ];
  assert.deepEqual(topologicalInstallOrder(records), ["publisher.container"]);
});

test("detects dependency cycles", () => {
  const records = [
    record("publisher.a", ["publisher.b"]),
    record("publisher.b", ["publisher.a"])
  ];
  assert.throws(() => topologicalInstallOrder(records), /cycle/i);
});

test("packages byte-identical extension archives across umasks and ambient options", () => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "extension-archive-umask-"));
  const serverVsix = path.join(fixtureRoot, "server.vsix");
  const clientVsix = path.join(fixtureRoot, "client.vsix");
  const lockfile = path.join(fixtureRoot, "vscode-extensions.lock.json");
  const normalArchive = path.join(fixtureRoot, "normal.tar.gz");
  const restrictiveArchive = path.join(fixtureRoot, "restrictive.tar.gz");
  const gzipEnvironmentArchive = path.join(fixtureRoot, "gzip-environment.tar.gz");
  const tarEnvironmentArchive = path.join(fixtureRoot, "tar-environment.tar.gz");
  const packager = path.join(
    repositoryRoot,
    "src/wolfi/components/vscode/package-extensions.sh"
  );

  function sha256(contents) {
    return createHash("sha256").update(contents).digest("hex");
  }

  function packageWithUmask(mask, output, environmentOverrides = {}) {
    const previousUmask = process.umask(mask);
    try {
      execFileSync(packager, ["--lock", lockfile, "--output", output], {
        cwd: repositoryRoot,
        env: { ...process.env, ...environmentOverrides },
        stdio: "pipe"
      });
    } finally {
      process.umask(previousUmask);
    }
  }

  try {
    fs.writeFileSync(serverVsix, "deterministic server fixture\n", { mode: 0o644 });
    fs.writeFileSync(clientVsix, "deterministic client fixture\n", { mode: 0o644 });
    fs.writeFileSync(lockfile, `${JSON.stringify({
      extensions: {
        "publisher.server": {
          version: "1.2.3",
          sha256: sha256(fs.readFileSync(serverVsix)),
          vsixPath: serverVsix
        },
        "publisher.client": {
          version: "4.5.6",
          sha256: sha256(fs.readFileSync(clientVsix)),
          vsixPath: clientVsix
        }
      },
      containerInstallOrder: ["publisher.server"],
      hostOnlyExtensions: ["publisher.client"]
    }, null, 2)}\n`, { mode: 0o644 });

    packageWithUmask(0o022, normalArchive);
    packageWithUmask(0o077, restrictiveArchive);
    packageWithUmask(0o022, gzipEnvironmentArchive, { GZIP: "-1" });
    packageWithUmask(0o022, tarEnvironmentArchive, {
      TAR_OPTIONS: "--format=posix"
    });

    const normalBytes = fs.readFileSync(normalArchive);
    for (const archive of [
      restrictiveArchive,
      gzipEnvironmentArchive,
      tarEnvironmentArchive
    ]) {
      const archiveBytes = fs.readFileSync(archive);
      assert.equal(sha256(normalBytes), sha256(archiveBytes));
      assert.deepEqual(normalBytes, archiveBytes);
    }
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

console.log("VS Code extension resolver tests passed.");
