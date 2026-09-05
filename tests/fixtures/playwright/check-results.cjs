const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const directory = path.join(__dirname, 'results');
const report = JSON.parse(fs.readFileSync(path.join(directory, 'report.json'), 'utf8'));
assert.equal(report.stats.expected, 2, 'both desktop and mobile must execute successfully');
for (const key of ['unexpected', 'flaky', 'skipped']) assert.equal(report.stats[key], 0, key);
assert.deepEqual(report.errors, []);
for (const name of ['desktop-initial', 'desktop', 'mobile']) {
  const filename = path.join(directory, `${name}.png`);
  assert(fs.statSync(filename).size > 1000, `${name} screenshot is empty`);
  const png = fs.readFileSync(filename);
  assert.equal(png.readUInt32BE(16), name === 'mobile' ? 390 : 1280, `${name} viewport width`);
  assert(png.readUInt32BE(20) >= (name === 'mobile' ? 844 : 900), `${name} viewport height`);
}
const entries = fs.readdirSync(path.join(directory, 'test-results'), { recursive: true });
assert.equal(entries.filter(name => name.endsWith('trace.zip')).length, 2, 'both traces are required');
assert(!entries.some(name => name.endsWith('.webm')), 'video must remain disabled');
console.log('TOOLBOX_PLAYWRIGHT_FIXTURE_PASS');
