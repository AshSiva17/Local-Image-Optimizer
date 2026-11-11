import { test, expect } from '@playwright/test';
import { readFile } from 'node:fs/promises';

const image = (name = 'test.png', content = 'image') => ({ name, mimeType: 'image/png', buffer: Buffer.from(content) });

test('live upload, queue, partial failure, per-file download and ZIP', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.locator('input[type=file]').setInputFiles([image('good.png'), image('bad.png', 'corrupt')]);
  await page.getByRole('button', { name: 'Optimize batch' }).click();
  await expect(page.getByText('2 / 2 processed')).toBeVisible();
  await expect(page.getByText('Failed to decode input image.')).toBeVisible();
  const downloadPromise = page.waitForEvent('download');
  await page.getByRole('link', { name: 'Download', exact: true }).click();
  const download = await downloadPromise;
  expect((await readFile(await download.path())).toString()).toBe('optimized-image');
  const zipPromise = page.waitForEvent('download');
  await page.getByRole('link', { name: 'Download zip' }).click();
  const zip = await zipPromise;
  expect((await readFile(await zip.path())).subarray(0, 2).toString()).toBe('PK');
  // Starting a new batch must not silently resubmit previous files.
  await page.locator('input[type=file]').setInputFiles(image('next.png'));
  await expect(page.getByText('1 image staged')).toBeVisible();
});

test('rapid repeated clicks submit only once', async ({ page }) => {
  let posts = 0;
  await page.route('**/api/jobs', async (route) => {
    posts += 1;
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.locator('input[type=file]').setInputFiles(image('slow.png', 'slow'));
  await page.getByRole('button', { name: 'Optimize batch' }).evaluate((button) => { button.click(); button.click(); button.click(); });
  await expect(page.getByText('1 / 1 processed')).toBeVisible();
  expect(posts).toBe(1);
});

test('polling retries a failed request and resumes after refresh', async ({ page }) => {
  let gets = 0;
  let completedJob;
  await page.route('**/api/jobs/*', async (route) => {
    if (route.request().method() !== 'GET' || route.request().url().endsWith('/export')) return route.continue();
    gets += 1;
    if (gets === 1) return route.fulfill({ status: 503, json: { error: 'Temporary failure' } });
    const response = await route.fetch();
    completedJob = await response.json();
    if (gets === 2) return route.fulfill({ json: { ...completedJob, status: 'processing', files: completedJob.files.map((file) => ({ ...file, status: 'processing' })) } });
    return route.fulfill({ response });
  });
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.locator('input[type=file]').setInputFiles(image());
  await page.getByRole('button', { name: 'Optimize batch' }).click();
  await expect(page.getByText('Job tracking interrupted. Retrying…')).toBeVisible();
  await expect.poll(() => gets).toBeGreaterThanOrEqual(2);
  await page.reload();
  await expect(page.getByText('1 / 1 processed')).toBeVisible();
  expect(completedJob.status).toBe('done');
});

test('missing remembered job and unavailable browser storage do not lock the UI', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('optimizerJobId', '00000000-0000-0000-0000-000000000000'));
  await page.goto('/');
  await expect(page.getByText('Previous job no longer exists.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new Error('Storage blocked'); } }));
  await page.reload();
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.locator('input[type=file]').setInputFiles(image());
  await page.getByRole('button', { name: 'Optimize batch' }).click();
  await expect(page.getByText('1 / 1 processed')).toBeVisible();
});

test('a rejected upload can be retried without losing the staged batch', async ({ page }) => {
  let posts = 0;
  await page.route('**/api/jobs', async (route) => {
    posts += 1;
    if (posts === 1) return route.fulfill({ status: 503, json: { error: 'Queue full. Try again later.' } });
    return route.continue();
  });
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Choose images' })).toBeEnabled();
  await page.locator('input[type=file]').setInputFiles(image());
  await page.getByRole('button', { name: 'Optimize batch' }).click();
  await expect(page.getByText('Queue full. Try again later.')).toBeVisible();
  await page.getByRole('button', { name: 'Optimize batch' }).click();
  await expect(page.getByText('1 / 1 processed')).toBeVisible();
  expect(posts).toBe(2);
});

test('temporary test storage cannot delete an unrelated directory', async () => {
  const { createStorage, removeStorage } = await import('./storage.js');
  const storage = createStorage();
  expect(() => removeStorage(storage.path, 'wrong-owner')).toThrow('unowned');
  removeStorage(storage.path, storage.token);
  expect(() => removeStorage(process.cwd(), storage.token)).toThrow();
});
