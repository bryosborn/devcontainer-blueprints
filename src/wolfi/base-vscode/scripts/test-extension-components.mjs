#!/usr/bin/env node

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

const [extensionsRoot] = process.argv.slice(2);
if (!extensionsRoot) {
  console.error("Usage: test-extension-components.mjs EXTENSIONS_DIR");
  process.exit(2);
}

const scratchRoot = mkdtempSync(join(tmpdir(), "wolfi-extension-components-"));
const cleanups = [];

function extension(id) {
  const prefix = `${id.toLowerCase()}-`;
  const matches = readdirSync(extensionsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.toLowerCase().startsWith(prefix))
    .map((entry) => join(extensionsRoot, entry.name));
  assert.equal(matches.length, 1, `expected exactly one installed ${id} directory`);

  const directory = matches[0];
  const manifest = JSON.parse(readFileSync(join(directory, "package.json"), "utf8"));
  assert.equal(
    `${manifest.publisher}.${manifest.name}`.toLowerCase(),
    id.toLowerCase(),
    `${id} manifest identity`,
  );
  return { directory, manifest };
}

function summarize(text) {
  return text.replaceAll("\0", "").trim().slice(-2000);
}

function run(command, args = [], options = {}) {
  const {
    cwd,
    env,
    input = "",
    timeoutMs = 15_000,
    allowNonzero = false,
  } = options;

  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      const result = { code, signal, stdout, stderr, timedOut };
      if (timedOut || (!allowNonzero && code !== 0)) {
        reject(new Error(
          `${command} ${args.join(" ")} failed (code=${code}, signal=${signal}, timedOut=${timedOut})\n` +
          `stdout: ${summarize(stdout)}\nstderr: ${summarize(stderr)}`,
        ));
      } else {
        resolve(result);
      }
    });

    child.stdin.end(input);
  });
}

function frame(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  return Buffer.concat([
    Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii"),
    body,
  ]);
}

function extractFrames(buffer) {
  const messages = [];
  let remaining = buffer;
  while (remaining.length) {
    const headerStart = remaining.indexOf("Content-Length:");
    if (headerStart < 0) break;
    if (headerStart > 0) remaining = remaining.subarray(headerStart);
    const headerEnd = remaining.indexOf("\r\n\r\n");
    if (headerEnd < 0) break;
    const header = remaining.subarray(0, headerEnd).toString("ascii");
    const match = /(?:^|\r\n)Content-Length:\s*(\d+)/i.exec(header);
    if (!match) throw new Error(`malformed protocol header: ${header}`);
    const length = Number.parseInt(match[1], 10);
    const bodyStart = headerEnd + 4;
    if (remaining.length < bodyStart + length) break;
    const body = remaining.subarray(bodyStart, bodyStart + length).toString("utf8");
    messages.push(JSON.parse(body));
    remaining = remaining.subarray(bodyStart + length);
  }
  return messages;
}

async function protocolHandshake({ label, command, args, cwd, env, request, matches, timeoutMs = 45_000 }) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    cleanups.push(() => child.kill("SIGKILL"));
    let stdout = Buffer.alloc(0);
    let stderr = "";
    let settled = false;

    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill("SIGTERM");
      if (error) reject(error);
      else resolve();
    };

    const timer = setTimeout(() => {
      finish(new Error(
        `${label} did not answer its initialize request within ${timeoutMs}ms\n` +
        `stdout: ${summarize(stdout.toString("utf8"))}\n` +
        `stderr: ${summarize(stderr)}`,
      ));
    }, timeoutMs);

    child.once("error", (error) => finish(error));
    child.once("close", (code, signal) => {
      if (!settled) {
        finish(new Error(
          `${label} exited before initialize response (code=${code}, signal=${signal})\n` +
          `stdout: ${summarize(stdout.toString("utf8"))}\n` +
          `stderr: ${summarize(stderr)}`,
        ));
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.stdout.on("data", (chunk) => {
      stdout = Buffer.concat([stdout, chunk]);
      try {
        for (const message of extractFrames(stdout)) {
          if (matches(message)) {
            finish();
            return;
          }
        }
      } catch (error) {
        finish(error);
      }
    });
    child.stdin.write(frame(request));
  });
  console.log(`PASS ${label}: process started and answered an initialize request`);
}

const lspInitialize = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    processId: process.pid,
    clientInfo: { name: "wolfi-offline-smoke", version: "1" },
    rootUri: `file://${scratchRoot}`,
    capabilities: {},
    workspaceFolders: [{ uri: `file://${scratchRoot}`, name: "wolfi-offline-smoke" }],
  },
};
const isLspInitialize = (message) =>
  message?.jsonrpc === "2.0" && message?.id === 1 && message?.result && !message?.error;

try {
  const python = extension("ms-python.debugpy");
  const pythonLibs = join(python.directory, "bundled", "libs");
  await protocolHandshake({
    label: "Python debugpy adapter",
    command: "python3.13",
    args: ["-m", "debugpy.adapter"],
    env: { PYTHONPATH: pythonLibs },
    request: {
      seq: 1,
      type: "request",
      command: "initialize",
      arguments: {
        clientID: "wolfi-offline-smoke",
        adapterID: "python",
        pathFormat: "path",
        linesStartAt1: true,
        columnsStartAt1: true,
      },
    },
    matches: (message) =>
      message?.type === "response" && message?.request_seq === 1 &&
      message?.command === "initialize" && message?.success === true,
  });

  const cpp = extension("ms-vscode.cpptools");
  const cppBin = join(cpp.directory, "bin");
  const cppServer = join(cppBin, "cpptools");
  chmodSync(cppServer, statSync(cppServer).mode | 0o100);
  const cppResult = await run(cppServer, [], { cwd: cppBin, allowNonzero: true });
  assert.equal(cppResult.timedOut, false, "C/C++ language service exits after closed stdin");
  assert.match(cppResult.stdout, /cpptoolsShutdown/, "C/C++ language service protocol output");
  assert.doesNotMatch(cppResult.stderr, /rosetta error|error while loading|not found/i);
  console.log("PASS C/C++ cpptools: native language service started and emitted protocol shutdown");

  const rust = extension("rust-lang.rust-analyzer");
  const rustMain = join(rust.directory, `${rust.manifest.main}.js`);
  await run(process.execPath, ["--check", rustMain]);
  await run("rustc", ["--version"]);
  const analyzer = await run("rustup", ["which", "rust-analyzer"], { allowNonzero: true });
  assert.equal(
    analyzer.code,
    0,
    `frozen Rust toolchain must contain rust-analyzer: ${summarize(analyzer.stderr)}`,
  );
  const analyzerPath = analyzer.stdout.trim();
  await run(analyzerPath, ["--version"]);
  await protocolHandshake({
    label: "Rust Analyzer language server",
    command: analyzerPath,
    args: [],
    request: lspInitialize,
    matches: isLspInitialize,
    timeoutMs: 60_000,
  });
  console.log("PASS Rust Analyzer: extension bundle parses and the server answers LSP initialize");

  const java = extension("redhat.java");
  await protocolHandshake({
    label: "Java JDT LS",
    command: join(java.directory, "server", "bin", "jdtls"),
    args: ["-data", join(scratchRoot, "jdtls-workspace")],
    request: lspInitialize,
    matches: isLspInitialize,
    timeoutMs: 90_000,
  });

  const yaml = extension("redhat.vscode-yaml");
  await protocolHandshake({
    label: "YAML language server",
    command: process.execPath,
    args: [join(yaml.directory, "dist", "languageserver.js"), "--stdio"],
    request: {
      ...lspInitialize,
      params: {
        ...lspInitialize.params,
        initializationOptions: { l10nPath: join(yaml.directory, "dist", "l10n") },
      },
    },
    matches: isLspInitialize,
  });

  const xml = extension("redhat.vscode-xml");
  await protocolHandshake({
    label: "XML LemMinX language server",
    command: "java",
    args: ["-jar", join(xml.directory, "server", "org.eclipse.lemminx-uber.jar")],
    request: lspInitialize,
    matches: isLspInitialize,
    timeoutMs: 60_000,
  });

  const docker = extension("ms-azuretools.vscode-containers");
  await protocolHandshake({
    label: "Dockerfile language server",
    command: process.execPath,
    args: [join(docker.directory, "dist", "dockerfile-language-server-nodejs", "lib", "server.js"), "--stdio"],
    request: lspInitialize,
    matches: isLspInitialize,
  });

  console.log(
    "BOUNDARY: These are executable/module protocol smokes, not full VS Code extension-host activation; " +
    "a matching desktop VS Code client is not available in this headless test.",
  );
} finally {
  for (const cleanup of cleanups.reverse()) {
    try { cleanup(); } catch { /* best-effort child cleanup */ }
  }
  rmSync(scratchRoot, { recursive: true, force: true });
}
