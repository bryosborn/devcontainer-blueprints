const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');

test('local page renders fonts, artwork and an interactive result without errors', async ({ page }, testInfo) => {
  const errors = { page: [], console: [], requests: [], responses: [] };
  page.on('pageerror', error => errors.page.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.console.push(message.text()); });
  page.on('requestfailed', request => errors.requests.push(`${request.url()}: ${request.failure()?.errorText}`));
  page.on('response', response => { if (response.status() >= 400) errors.responses.push(`${response.status()} ${response.url()}`); });
  await page.goto('/');
  await expect(page).toHaveTitle('Wolfi browser check');
  await expect(page.getByRole('heading', { name: 'Wolfi browser check' })).toBeVisible();
  await expect(page.getByAltText('Local illustration with a blue circle, orange square and green triangle')).toBeVisible();
  await expect(page.locator('img')).toHaveJSProperty('naturalWidth', 400);
  await page.evaluate(() => document.fonts.ready);
  await expect(page.getByText('浏览器测试 / ブラウザ')).toBeVisible();
  await expect(page.getByText('ทดสอบเบราว์เซอร์')).toBeVisible();
  await expect(page.getByText('🌍 🚀 ✅')).toBeVisible();
  async function capture(name) {
    const filename = path.join(__dirname, 'results', `${name}.png`);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    await page.screenshot({ path: filename, fullPage: true, animations: 'disabled' });
    const bytes = fs.readFileSync(filename);
    expect(bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))).toBe(true);
    expect(bytes.readUInt32BE(16)).toBe(testInfo.project.use.viewport.width);
    expect(bytes.readUInt32BE(20)).toBeGreaterThanOrEqual(testInfo.project.use.viewport.height);
    await testInfo.attach(`${name} screenshot`, { path: filename, contentType: 'image/png' });
  }
  if (testInfo.project.name === 'desktop') await capture('desktop-initial');
  await page.getByLabel('Your name').fill('Wolfi developer');
  await page.getByRole('button', { name: 'Run local check' }).click();
  await expect(page.getByRole('status')).toHaveText('Ready, Wolfi developer! All assets are local.');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(await page.locator('[data-card]').count()).toBe(3);
  expect(errors).toEqual({ page: [], console: [], requests: [], responses: [] });
  await capture(testInfo.project.name);
  await testInfo.attach('browser-errors', { body: JSON.stringify(errors), contentType: 'application/json' });
});
