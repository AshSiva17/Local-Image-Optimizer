// Bound requests so a disconnected API cannot leave upload/tracking controls stuck.
export async function fetchJson(url, options = {}, timeoutMs = 10000) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  const timer = setTimeout(abort, timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(body.error || `API returned HTTP ${response.status}.`), { status: response.status });
    return body;
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
  }
}

// Browsers can deny storage (private settings, embedded contexts, quota).
export const rememberedJob = {
  get() { try { return localStorage.getItem('optimizerJobId'); } catch { return null; } },
  set(id) { try { localStorage.setItem('optimizerJobId', id); } catch { /* Tracking still works for this page. */ } },
  clear() { try { localStorage.removeItem('optimizerJobId'); } catch { /* Storage is optional. */ } },
};
