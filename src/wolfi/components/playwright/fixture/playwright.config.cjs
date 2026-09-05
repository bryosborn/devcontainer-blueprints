const { defineConfig } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');

const manifest = JSON.parse(fs.readFileSync('/opt/playwright/manifest.json', 'utf8'));
const runnerVersion = require('@playwright/test/package.json').version;
if (runnerVersion !== manifest.version)
  throw new Error(`Fixture Playwright ${runnerVersion} differs from image browser version ${manifest.version}`);
if (process.env.PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS || process.env.PLAYWRIGHT_HOST_PLATFORM_OVERRIDE)
  throw new Error('Browser validation/platform overrides are forbidden in the fixture');
if (process.env.PLAYWRIGHT_BROWSERS_PATH !== manifest.cachePath)
  throw new Error('Fixture must use the image browser cache');

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'visual.spec.cjs',
  outputDir: path.join(__dirname, 'results/test-results'),
  timeout: 45000,
  expect: { timeout: 10000 },
  workers: 1,
  retries: 0,
  reporter: [['line'], ['json', { outputFile: path.join(__dirname, 'results/report.json') }]],
  use: {
    browserName: 'chromium',
    ...(process.env.PW_FIXTURE_CHANNEL === 'chromium' ? { channel: 'chromium' } : {}),
    baseURL: 'http://127.0.0.1:41739',
    locale: 'en-US',
    timezoneId: 'UTC',
    colorScheme: 'light',
    reducedMotion: 'reduce',
    trace: 'on',
    video: 'off',
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 } },
    { name: 'mobile', use: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, isMobile: true, hasTouch: true } },
  ],
  webServer: {
    command: 'node site/server.cjs',
    cwd: __dirname,
    url: 'http://127.0.0.1:41739',
    reuseExistingServer: false,
    timeout: 10000,
  },
});
