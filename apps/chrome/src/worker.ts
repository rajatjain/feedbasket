import { apiOrigin, APIError, defaultSettings, isPDFURL, request, webURL } from "./api.js";
import type { DeliveryUpdate, FeedChoice, Profile, QueueAction, QueuedAction, Save, Session, Settings } from "./api.js";
import { paletteID } from "./palettes.js";
import { diagnostic } from "./diagnostics.js";

const storage = chrome.storage.local;
const queuePrefix = "save:";
const alarm = "sync-feedbasket";

function actionKind(item: QueueAction) {
  return item.feed ? "subscription" : item.article.document_type ?? "article";
}
type State = { settings: Settings; session?: Session; online: boolean; queue: QueuedAction[] };
type Message =
  | { type: "state" | "sync" | "signOut" }
  | { type: "connect" | "signup"; username: string }
  | { type: "settings"; settings: Settings }
  | { type: "save"; article: Save }
  | { type: "subscribe"; feed: FeedChoice }
  | { type: "retry" | "discard"; id: string };

async function state(): Promise<State> {
  const all = await storage.get(null) as Record<string, unknown> & {
    settings?: Partial<Settings>; session?: Session; online?: boolean;
  };
  const settings = { ...defaultSettings, ...all.settings };
  settings.accent = paletteID(settings.accent);
  return {
    settings, online: all.online === true,
    session: all.session?.origin === settings.origin ? all.session : undefined,
    queue: Object.entries(all).filter(([key]) => key.startsWith(queuePrefix)).map(([, item]) => item as QueuedAction),
  };
}

async function status(online: boolean) {
  const previous = await storage.get("online");
  if (previous.online !== online) diagnostic(online ? "Backend reachable" : "Backend offline", online ? "INFO" : "WARNING");
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
      diagnostic("Backend rejected the session", "WARNING");
      await storage.remove("session");
    }
    else if (!(error instanceof APIError)) await status(false);
    return;
  }

  for (const item of queue.filter(item => item.origin === settings.origin &&
    item.account === session?.profile.id && !item.error).slice(0, 8)) {
    const key = queuePrefix + item.id;
    const action = actionKind(item);
    try {
      const result = item.feed
        ? await request<{ id: string }>(settings.origin, "/api/v1/feeds", session.token, item.feed)
        : await request<{ article: { id: string } }>(settings.origin, "/api/v1/articles", session.token, item.article);
      await storage.remove(key);
      reportDelivery(item);
      const target = "article" in result ? `article_id=${result.article.id}` : `feed_id=${result.id}`;
      diagnostic(`Queued action delivered queue_id=${item.id} kind=${action} ${target}`);
    } catch (error) {
      if (!(error instanceof APIError)) {
        diagnostic(`Delivery interrupted queue_id=${item.id} kind=${action} state=queued`, "WARNING");
        await status(false);
        return;
      }
      if (error.status === 401 || error.status === 403) {
        diagnostic(`Backend rejected session queue_id=${item.id} kind=${action} status=${error.status}`, "WARNING");
        await storage.remove("session");
        break;
      }
      const retryable = error.status >= 500 || error.status === 429;
      diagnostic(`Delivery failed queue_id=${item.id} kind=${action} status=${error.status} retryable=${retryable}`, "WARNING");
      if (retryable) break;
      item.error = error.message;
      await storage.set({ [key]: item });
      reportDelivery(item);
    }
  }
  await status(true);
}

async function enqueue(action: QueueAction, session: Session) {
  const item: QueuedAction = { ...action, id: crypto.randomUUID(), origin: session.origin, account: session.profile.id };
  await storage.set({ [queuePrefix + item.id]: item });
  diagnostic(`Action queued queue_id=${item.id} kind=${actionKind(item)}`);
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
      if (message.article.tags.length > 30 || message.article.tags.some(tag => tag.length > 80))
        throw new Error("Use up to 30 tags of at most 80 characters.");
      if (message.article.subscribe_url) {
        if (pdf) throw new Error("Save the PDF link, then subscribe separately to the feed.");
        webURL(message.article.subscribe_url);
      }
      return enqueue({ article: { ...message.article, document_type: pdf ? "pdf" : "article" } }, current.session);
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
      diagnostic("Account connected");
      void scheduleSync();
      return state();
    }
    case "signOut":
      if (current.session) await request(current.settings.origin, "/api/v1/auth/logout", current.session.token, {}).catch(() => {});
      await storage.remove(["session", "attempt"]);
      diagnostic("Account disconnected");
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
