import { mkdtempSync, writeFileSync, readFileSync, realpathSync, lstatSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { randomUUID } from 'node:crypto';

const marker = '.optimizer-browser-owned';
export function createStorage() {
  const path = mkdtempSync(join(tmpdir(), 'optimizer-browser-'));
  const token = randomUUID();
  writeFileSync(join(path, marker), token);
  return { path, token };
}
export function assertOwnedStorage(path, token) {
  if (!path || !token || lstatSync(path).isSymbolicLink() ||
    realpathSync(dirname(path)) !== realpathSync(tmpdir()) || !basename(path).startsWith('optimizer-browser-') ||
    readFileSync(join(path, marker), 'utf8') !== token) throw new Error('Refusing to use/delete unowned test storage');
}
export function removeStorage(path, token) {
  assertOwnedStorage(path, token);
  rmSync(path, { recursive: true, force: true, maxRetries: 3 });
}
