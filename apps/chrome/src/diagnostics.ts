const key = "diagnostics";
const capacity = 200;
let pending: Promise<void> = Promise.resolve();

export function diagnostic(message: string, level: "INFO" | "WARNING" = "INFO") {
  pending = pending.then(async () => {
    const stored = await chrome.storage.local.get(key);
    const entries = (stored[key] ?? []) as string[];
    entries.push(`${new Date().toISOString()} ${level} worker.js] ${message}`);
    await chrome.storage.local.set({ [key]: entries.slice(-capacity) });
  }).catch(() => { /* A diagnostics failure must not interrupt saving. */ });
}
