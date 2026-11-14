import { apiOrigin, APIError, defaultSettings, isPDFURL, request, webURL } from "./api.js";
import type { DeliveryUpdate, ExtensionState, FeedChoice, Profile, QueueAction, QueuedAction, Save, Session, Settings } from "./api.js";
import { paletteID } from "./palettes.js";

const storage = chrome.storage.local;
const queuePrefix = "save:";
const alarm = "sync-feedbasket";
const recentTagKey = (session: Session) => `recent-tags:${session.origin}:${session.profile.id}`;

type Message =
  | { type: "state" | "sync" | "signOut" }
  | { type: "connect" | "signup"; username: string }
  | { type: "settings"; settings: Settings }
  | { type: "save"; article: Save }
  | { type: "subscribe"; feed: FeedChoice }
  | { type: "retry" | "discard"; id: string };

async function state(): Promise<ExtensionState> {
  const all = await storage.get(null) as Record<string, unknown> & {
    settings?: Partial<Settings>; session?: Session; online?: boolean;
  };
  const settings = { ...defaultSettings, ...all.settings };
  settings.accent = paletteID(settings.accent);
  const session = all.session?.origin === settings.origin ? all.session : undefined;
  const recent = session ? all[recentTagKey(session)] : undefined;
  return {
    settings, session, online: all.online === true,
    queue: Object.entries(all).filter(([key]) => key.startsWith(queuePrefix)).map(([, item]) => item as QueuedAction),
    recentTags: Array.isArray(recent) ? recent.filter((name): name is string => typeof name === "string") : [],
  };
}

async function status(online: boolean) {
  await storage.set({ online });
  const kind = online ? "online" : "offline";
  await chrome.action.setIcon({ path: { 16: `assets/${kind}-16.png`, 32: `assets/${kind}-32.png` } });
  const { queue } = await state();
  await chrome.action.setBadgeText({ text: queue.length ? String(Math.min(queue.length, 99)) : "" });
  await chrome.action.setBadgeBackgroundColor({ color: online ? "#663ea3" : "#5f6267" });
  await chrome.action.setTitle({ title: `FeedBasket · Backend ${online ? "reachable" : "offline"}${queue.length ? ` · ${queue.length} queued` : ""}` });
}

function reportDelivery(item: QueuedAction) {
  const update: DeliveryUpdate = { type: "delivery", id: item.id, error: item.error };
  void chrome.runtime.sendMessage(update).catch(() => { /* The popup may already be closed. */ });
}

async function sync() {
  const { settings, session, queue } = await state();
  try {
    const health = await request<{ status: string }>(settings.origin, "/health");
    if (health.status !== "ok") throw new Error("Unexpected health response");
  } catch {
    await status(false);
    return;
  }
  await status(true);

  if (!session) return;
  try {
    await request(settings.origin, "/api/v1/me", session.token);
  } catch (error) {
    if (error instanceof APIError && [401, 403].includes(error.status)) {
      await storage.remove("session");
    }
    else if (!(error instanceof APIError)) await status(false);
    return;
  }

  for (const item of queue.filter(item => item.origin === settings.origin &&
    item.account === session?.profile.id && !item.error).slice(0, 8)) {
    const key = queuePrefix + item.id;
    try {
      if (item.feed) await request(settings.origin, "/api/v1/feeds", session.token, item.feed);
      else await request(settings.origin, "/api/v1/articles", session.token, item.article);
      await storage.remove(key);
      reportDelivery(item);
    } catch (error) {
      if (!(error instanceof APIError)) {
        await status(false);
        return;
      }
      if (error.status === 401 || error.status === 403) {
        await storage.remove("session");
        break;
      }
      if (error.status >= 500 || error.status === 429) break;
      item.error = error.message;
      await storage.set({ [key]: item });
      reportDelivery(item);
    }
  }
  await status(true);
}

async function enqueue(action: QueueAction, session: Session, recentTags: string[] = []) {
  const item: QueuedAction = { ...action, id: crypto.randomUUID(), origin: session.origin, account: session.profile.id };
  const entries: Record<string, unknown> = { [queuePrefix + item.id]: item };
  if (action.article?.tags.length) {
    const names = [...action.article.tags].reverse().concat(recentTags);
    entries[recentTagKey(session)] = [...new Set(names.map(name => name.trim().toLowerCase()).filter(Boolean))].slice(0, 20);
  }
  await storage.set(entries);
  void scheduleSync();
  return { id: item.id };
}

async function handle(message: Message) {
  const current = await state();
  switch (message.type) {
    case "state": return current;
    case "sync": await sync(); return state();
    case "save": {
      if (!current.session) throw new Error("Connect an account before saving.");
      const url = webURL(message.article.url);
      const pdf = message.article.document_type === "pdf" || isPDFURL(url);
      if (message.article.tags.length > 30 || message.article.tags.some(tag => Array.from(tag).length > 80))
        throw new Error("Use up to 30 tags of at most 80 characters.");
      if (message.article.subscribe_url) {
        if (pdf) throw new Error("Save the PDF link, then subscribe separately to the feed.");
        webURL(message.article.subscribe_url);
      }
      return enqueue({ article: { ...message.article, document_type: pdf ? "pdf" : "article" } }, current.session, current.recentTags);
    }
    case "subscribe": {
      if (!current.session) throw new Error("Connect an account before subscribing.");
      const url = webURL(message.feed.url);
      return enqueue({ feed: { url: url.href, title: message.feed.title.slice(0, 500) } }, current.session);
    }
    case "settings": {
      const settings = { ...message.settings, origin: apiOrigin(message.settings.origin), accent: paletteID(message.settings.accent) };
      if (settings.origin !== current.settings.origin) await storage.remove(["session", "attempt"]);
      await storage.set({ settings });
      if (settings.origin !== current.settings.origin) {
        await status(false);
      }
      void scheduleSync();
      return settings;
    }
    case "connect":
    case "signup": {
      const login = await request<{ token: string; profile: Profile }>(
        current.settings.origin, "/api/v1/auth/" + message.type, undefined, { username: message.username.trim() });
      await storage.set({ session: { origin: current.settings.origin, token: login.token, profile: login.profile } satisfies Session });
      await storage.remove("attempt");
      void scheduleSync();
      return state();
    }
    case "signOut":
      if (current.session) await request(current.settings.origin, "/api/v1/auth/logout", current.session.token, {}).catch(() => {});
      await storage.remove(["session", "attempt"]);
      return state();
    case "discard":
      await storage.remove(queuePrefix + message.id);
      await status(current.online);
      return state();
    case "retry": {
      const item = current.queue.find(item => item.id === message.id);
      if (item) {
        delete item.error;
        await storage.set({ [queuePrefix + item.id]: item });
      }
      void scheduleSync();
      return state();
    }
  }
}

let tail: Promise<unknown> = Promise.resolve();
function serial<T>(work: () => Promise<T>): Promise<T> {
  const result = tail.then(work);
  tail = result.catch(() => {});
  return result;
}
function scheduleSync() { return serial(sync).catch(console.warn); }

async function start() {
  if (!await chrome.alarms.get(alarm)) await chrome.alarms.create(alarm, { periodInMinutes: 0.5 });
  await scheduleSync();
}

chrome.runtime.onInstalled.addListener(() => void start().catch(console.warn));
chrome.runtime.onStartup.addListener(() => void start().catch(console.warn));
chrome.alarms.onAlarm.addListener(event => { if (event.name === alarm) void scheduleSync(); });
chrome.runtime.onMessage.addListener((message: Message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(chrome.runtime.getURL(""))) return;
  serial(() => handle(message)).then(data => respond({ data }),
    error => respond({ error: error instanceof Error ? error.message : "Request failed." }));
  return true;
});
