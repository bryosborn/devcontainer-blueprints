#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const REPO_ROOT = fileURLToPath(new URL("../../", import.meta.url));
export const DEFAULT_SETTINGS_PATH = path.join(REPO_ROOT, "config/images.env");
const KEYS = ["IMAGE_PREFIX", "IMAGE_FAMILY", "IMAGE_VERSION", "IMAGE_PROFILES"];
const PROFILE_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;
const FAMILY_PATTERN = /^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$/;
const TAG_PATTERN = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

export class ImageSettingsError extends Error {
  constructor(message) {
    super(message);
    this.name = "ImageSettingsError";
  }
}

function fail(message) {
  throw new ImageSettingsError(`config/images.env: ${message}`);
}

function validatePlainValue(key, value) {
  if (value.length === 0 || value !== value.trim()) fail(`${key} must be a non-empty unquoted value without surrounding whitespace`);
  if (/[\s'"`$\\;&|<>()[\]{}]/u.test(value)) {
    fail(`${key} contains shell syntax, interpolation, quoting, or whitespace`);
  }
  if (/\p{Cc}/u.test(value)) fail(`${key} contains a control character`);
  return value;
}

function validatePrefix(value) {
  validatePlainValue("IMAGE_PREFIX", value);
  if (value.startsWith("/") || value.endsWith("/") || value.includes("@") || value.includes(":")) {
    fail("IMAGE_PREFIX must be an untagged OCI namespace without a registry port");
  }
  const parts = value.split("/");
  if (parts.some((part) => !FAMILY_PATTERN.test(part))) fail("IMAGE_PREFIX contains an invalid OCI path component");
  return value;
}

export function parseImageSettings(source) {
  const values = {};
  source.split(/\r?\n/u).forEach((line, index) => {
    const number = index + 1;
    if (line === "" || /^\s*#/u.test(line)) return;
    const match = /^([A-Z][A-Z0-9_]*)=([^\r\n]*)$/u.exec(line);
    if (!match) fail(`line ${number} must be KEY=VALUE data`);
    const [, key, raw] = match;
    if (!KEYS.includes(key)) fail(`line ${number} has unknown key ${key}`);
    if (Object.hasOwn(values, key)) fail(`line ${number} duplicates ${key}`);
    values[key] = validatePlainValue(key, raw);
  });
  const missing = KEYS.filter((key) => !Object.hasOwn(values, key));
  if (missing.length) fail(`missing required key${missing.length === 1 ? "" : "s"}: ${missing.join(", ")}`);

  const profiles = values.IMAGE_PROFILES.split(",");
  if (profiles.length === 0 || profiles.some((profile) => !PROFILE_PATTERN.test(profile))) {
    fail("IMAGE_PROFILES must be a comma-separated list of lowercase profile names");
  }
  if (new Set(profiles).size !== profiles.length) fail("IMAGE_PROFILES contains a duplicate profile");
  if (!FAMILY_PATTERN.test(values.IMAGE_FAMILY)) fail("IMAGE_FAMILY is not a valid OCI repository component");
  if (!TAG_PATTERN.test(values.IMAGE_VERSION)) fail("IMAGE_VERSION is not a valid OCI tag");

  return Object.freeze({
    prefix: validatePrefix(values.IMAGE_PREFIX),
    family: values.IMAGE_FAMILY,
    version: values.IMAGE_VERSION,
    profiles: Object.freeze(profiles)
  });
}

export function loadImageSettings(settingsPath = DEFAULT_SETTINGS_PATH) {
  let source;
  try {
    source = fs.readFileSync(settingsPath, "utf8");
  } catch (error) {
    throw new ImageSettingsError(`cannot read ${settingsPath}: ${error.message}`);
  }
  return parseImageSettings(source);
}

export function settingsFileSha256(settingsPath = DEFAULT_SETTINGS_PATH) {
  return crypto.createHash("sha256").update(fs.readFileSync(settingsPath)).digest("hex");
}

export function imageReference(settings, profile) {
  if (!settings.profiles.includes(profile)) fail(`profile ${profile} is not declared by IMAGE_PROFILES`);
  return `${settings.prefix}/${settings.family}-${profile}:${settings.version}`;
}

export function profilePaths(settings, profile) {
  if (!settings.profiles.includes(profile)) fail(`profile ${profile} is not declared by IMAGE_PROFILES`);
  return {
    config: path.join(REPO_ROOT, "config", `${profile}.yaml`),
    lock: path.join(REPO_ROOT, "config", `${profile}.lock.json`),
    artifacts: `artifacts/${profile}`,
    image: imageReference(settings, profile)
  };
}

const invokedPath = process.argv[1] == null ? null : pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedPath === import.meta.url) {
  try {
    const settings = loadImageSettings(process.argv[2] == null ? DEFAULT_SETTINGS_PATH : path.resolve(process.argv[2]));
    process.stdout.write(`${JSON.stringify(settings, null, 2)}\n`);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exitCode = 1;
  }
}
