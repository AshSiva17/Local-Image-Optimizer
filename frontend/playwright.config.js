import { defineConfig } from '@playwright/test';
import { createStorage, assertOwnedStorage } from './tests/storage.js';

// Keep tests away from real job data. Reuse the same value in Playwright workers.
if (!process.env.OPTIMIZER_E2E_STORAGE) {
  const storage = createStorage();
  process.env.OPTIMIZER_E2E_STORAGE = storage.path;
  process.env.OPTIMIZER_E2E_TOKEN = storage.token;
}
assertOwnedStorage(process.env.OPTIMIZER_E2E_STORAGE, process.env.OPTIMIZER_E2E_TOKEN);
export default defineConfig({
  testDir: './tests',
  workers: 1,
  timeout: 30000,
  use: { baseURL: 'http://127.0.0.1:5173', browserName: 'chromium', trace: 'retain-on-failure' },
  webServer: [
    { command: 'node tests/start-api.js', gracefulShutdown: { signal: 'SIGTERM', timeout: 5000 },
      url: 'http://127.0.0.1:4567/api/health', reuseExistingServer: false,
      env: { IMAGE_OPTIMIZER_STORAGE: process.env.OPTIMIZER_E2E_STORAGE, RACK_ENV: 'test' } },
    { command: 'npm run dev -- --strictPort', url: 'http://127.0.0.1:5173', reuseExistingServer: false },
  ],
});
