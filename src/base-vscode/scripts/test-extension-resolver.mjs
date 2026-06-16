#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  classifyExtensionKind,
  isCompatibleWithVSCode,
  normalizeExtensionId,
  splitExtensionId,
  topologicalInstallOrder
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

console.log("VS Code extension resolver tests passed.");
