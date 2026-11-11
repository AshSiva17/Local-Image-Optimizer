import { spawn } from 'node:child_process';
import { assertOwnedStorage, removeStorage } from './storage.js';
import { fileURLToPath } from 'node:url';

const storage = process.env.IMAGE_OPTIMIZER_STORAGE;
if (!storage || !process.env.OPTIMIZER_E2E_STORAGE || storage !== process.env.OPTIMIZER_E2E_STORAGE) throw new Error('Missing isolated test storage');
const token = process.env.OPTIMIZER_E2E_TOKEN;
assertOwnedStorage(storage, token);
const child = spawn('bundle', ['exec', 'rackup', 'test/support/config.ru', '-p', '4567', '-o', '127.0.0.1'], {
  cwd: fileURLToPath(new URL('../../backend', import.meta.url)), stdio: 'inherit',
  shell: process.platform === 'win32',
});
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal));
child.on('error', (error) => { console.error(error); removeStorage(storage, token); process.exitCode = 1; });
child.on('exit', (code) => {
  // Only delete our generated directory, after the API releases all file handles.
  removeStorage(storage, token);
  process.exitCode = code ?? 0;
});
