'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const [root, version, platform] = process.argv.slice(2);
function check(condition, message) {
  if (!condition) throw new Error(`Invalid Playwright payload: ${message}`);
}
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
check(manifest.schemaVersion === 1 && manifest.version === version && manifest.platform === platform,
  'version or architecture does not match the lock');
check(manifest.cachePath === '/opt/playwright/browsers' && manifest.video === false, 'cache/video contract');
check(JSON.stringify(manifest.browsers.map(b => b.name)) === JSON.stringify(['chromium', 'chromium-headless-shell']),
  'expected Chromium and headless shell only');
for (const browser of manifest.browsers) {
  check(/^\d+$/.test(browser.revision), 'revision');
  check(browser.cacheDirectory === `${browser.name.replaceAll('-', '_')}-${browser.revision}`, 'cache directory');
  check(typeof browser.executable === 'string' && !browser.executable.startsWith('/') &&
    !browser.executable.split('/').some(p => ['', '.', '..'].includes(p)), 'executable path');
  const directory = path.join(root, 'browsers', browser.cacheDirectory);
  const executable = path.join(directory, browser.executable);
  check(fs.statSync(executable).isFile(), 'missing browser executable');
  const handle = fs.openSync(executable, 'r');
  const header = Buffer.alloc(20);
  try { check(fs.readSync(handle, header, 0, 20, 0) === 20, 'truncated browser'); }
  finally { fs.closeSync(handle); }
  check(header.subarray(0, 4).equals(Buffer.from([0x7f, 69, 76, 70])) && header[4] === 2 && header[5] === 1,
    'browser must be a 64-bit little-endian ELF executable');
  check(header.readUInt16LE(18) === (platform === 'linux/amd64' ? 62 : 183), 'browser ELF architecture');
  const libraries = spawnSync('ldd', [executable], { encoding: 'utf8' });
  check(libraries.status === 0 && !/not found/.test(`${libraries.stdout}${libraries.stderr}`),
    `browser shared libraries: ${libraries.stdout || ''}${libraries.stderr || ''}${libraries.error || ''}`);
  check(fs.existsSync(path.join(directory, 'INSTALLATION_COMPLETE')), 'missing installation marker');
  check(!fs.existsSync(path.join(directory, 'DEPENDENCIES_VALIDATED')), 'host validation must not be bypassed');
}
check(!fs.readdirSync(path.join(root, 'browsers')).some(name => name.startsWith('ffmpeg')), 'video is not selected');
console.log(`Verified Playwright ${version} Chromium payload for ${platform}`);
