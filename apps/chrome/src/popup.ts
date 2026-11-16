import { palettes } from "./palettes.js";
import { apiOrigin, defaultSettings, isPDFURL, request, webURL } from "./api.js";
import type { DeliveryUpdate, ExtensionState as State, FeedChoice, LinkPreview, QueuedAction, Settings } from "./api.js";
import { tagPicker } from "./tags.js";

const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const input = (id: string) => el<HTMLInputElement>(id);
const button = (id: string) => el<HTMLButtonElement>(id);
const select = (id: string) => el<HTMLSelectElement>(id);
const note = (message: string) => { el("notice").textContent = message; };

async function send<T>(message: object): Promise<T> {
  const result = await chrome.runtime.sendMessage(message);
  if (result.error) throw new Error(result.error);
  return result.data as T;
}

function paint(settings: Settings) {
  document.documentElement.dataset.theme = settings.theme;
  document.documentElement.dataset.accent = settings.accent;
}

function render(state: State) {
  paint(state.settings);
  el("connection").dataset.online = String(state.online);
  const connection = `${state.online ? "Backend reachable" : "Backend offline"}. Check now`;
  el("connection-label").textContent = state.online ? "Backend reachable" : "Backend offline";
  button("sync").title = connection;
  button("sync").setAttribute("aria-label", connection);
  el("profile").textContent = state.session?.profile.username || state.session?.profile.name || "";
  el("account").hidden = !state.session;
  el("connect").hidden = Boolean(state.session);
  input("username").disabled = !state.online;
  for (const control of el("connect").querySelectorAll("button")) control.disabled = !state.online;
  el("save").hidden = !state.session || !el("settings").hidden;
  renderActions();
  const list = el("queue-list");
  list.replaceChildren();
  for (const item of state.queue) {
    const row = document.createElement("li");
    row.textContent = item.feed ? `Subscribe to ${item.feed.title || item.feed.url}` : item.article.title || item.article.url;
    const detail = document.createElement("small");
    detail.textContent = item.error ?? (!item.account ? "No linked account" : item.origin !== state.settings.origin ? `Waiting for ${item.origin}`
      : item.account && item.account !== state.session?.profile.id ? "Waiting for the original account" : "Waiting to sync");
    row.append(detail);
    if (item.error) row.append(queueButton("Retry", "retry", item));
    row.append(queueButton("Remove", "discard", item));
    list.append(row);
  }
  el("queue").hidden = !state.queue.length;
}

function queueButton(label: string, type: string, item: QueuedAction) {
  const control = document.createElement("button");
  control.type = "button";
  control.textContent = label;
  control.addEventListener("click", () => void send<State>({ type, id: item.id }).then(update).catch(report));
  return control;
}

function handleInvalidContext(error: unknown): boolean {
  if (!(error instanceof Error) || !error.message.includes("Extension context invalidated")) return false;
  window.clearInterval(buildCheck);
  button("reload-extension").hidden = true;
  note("FeedBasket was reloaded. Reopen the popup to continue.");
  return true;
}

function report(error: unknown) {
  if (!handleInvalidContext(error)) note(error instanceof Error ? error.message : "Request failed.");
}

let tab: chrome.tabs.Tab | undefined;
let current: State = { settings: defaultSettings, online: false, queue: [], recentTags: [], feedCategories: [] };
let valid = false;
let detected: LinkPreview["kind"] | undefined;
let checkedOnline = false;
let submitting = false;
let confirmation: { id: string; deliveredText: string } | undefined;
let closeTimer: number | undefined;
const earlyDeliveries = new Map<string, DeliveryUpdate>();
let feedRequest = 0;
let findingFeeds = false;
const picker = select("feed-picker");
const categoryPicker = select("feed-category");
const tags = tagPicker();
let tagRequest = 0;

function savingPDF() { return detected === "pdf" || input("save-as-pdf").checked; }

function showActionFeedback(text: string, state: "queued" | "delivered" | "error") {
  window.clearTimeout(closeTimer);
  const feedback = el("action-feedback");
  feedback.textContent = text;
  feedback.dataset.state = state;
  if (state === "error") {
    confirmation = undefined;
    submitting = false;
    renderActions();
  } else {
    closeTimer = window.setTimeout(() => window.close(), 1000);
  }
}

function updateDelivery(delivery: DeliveryUpdate) {
  if (confirmation?.id !== delivery.id) return;
  if (delivery.error) showActionFeedback(delivery.error, "error");
  else showActionFeedback(confirmation.deliveredText, "delivered");
}

select("accent").replaceChildren(...palettes.map(({id, label}) => new Option(label, id)));

function selectedFeed(): FeedChoice | undefined {
  const selected = picker.selectedOptions[0];
  return selected ? { url: selected.value, title: selected.text } : undefined;
}

function renderActions() {
  button("reload-extension").disabled = submitting;
  const feed = selectedFeed();
  const pdf = savingPDF();
  const feedOnly = !pdf && detected === "feed";
  const supported = valid && detected !== "unsupported";
  const canSubscribe = supported && !pdf && Boolean(feed);
  const disabled = submitting || !supported || !current.session;
  button("save-button").disabled = disabled || (findingFeeds && !pdf);
  button("save-button").hidden = !supported || feedOnly;
  button("save-button").textContent = pdf ? "Save PDF link" : "Save";
  button("save-subscribe-button").hidden = feedOnly;
  button("subscribe-button").classList.toggle("primary", feedOnly);
  button("subscribe-button").disabled = disabled || !canSubscribe || findingFeeds;
  button("save-subscribe-button").disabled = disabled || !canSubscribe || findingFeeds;
  el("tag-editor").hidden = !supported || feedOnly;
  el("pdf-override").hidden = !current.session || !supported || detected !== undefined || findingFeeds;
  el("feed-actions").hidden = !canSubscribe;
  el("feed-row").hidden = !canSubscribe;
  el("feed-title").textContent = feed?.title ?? "";
  el("feed-picker-row").hidden = !canSubscribe || picker.options.length < 2;
  el("feed-category-row").hidden = !canSubscribe || !current.feedCategories.length;
  categoryPicker.disabled = disabled || findingFeeds;
  el("checking-page").hidden = !findingFeeds || pdf;
}

function loadTags() {
  const session = current.session;
  if (!current.online || !session) return;
  const sequence = ++tagRequest;
  void request<({ name: string; count: number } | string)[]>(session.origin, "/api/v1/tags?ranked=true", session.token)
    .then(values => {
      if (sequence !== tagRequest) return;
      tags.setTags(values.map(value => typeof value === "string" ? value : value.name));
    }).catch(() => { /* Tags can still be entered manually while the backend is unavailable. */ });
}

async function findFeeds() {
  if (!valid || tab?.id === undefined || !tab.url || detected === "pdf" || findingFeeds || checkedOnline) return;
  const sequence = ++feedRequest;
  const { online, session } = current;
  findingFeeds = true;
  renderActions();
  let feeds: FeedChoice[] = [];
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({ type: document.contentType, feeds: Array.from(document.querySelectorAll<HTMLLinkElement>(
        'link[rel~="alternate"][type="application/rss+xml"], link[rel~="alternate"][type="application/atom+xml"], link[rel~="alternate"][type="application/rdf+xml"]'
      )).slice(0, 20).map(link => ({ title: link.title || location.hostname, url: link.href })) }),
    });
    if (sequence !== feedRequest) return;
    const page = result[0]?.result;
    if (page?.type === "application/pdf") detected = "pdf";
    feeds = page?.feeds ?? [];
  } catch { /* Chrome restricts injection on some tabs. */ }
  if (sequence !== feedRequest) return;
  if (detected !== "pdf" && online && session) {
    try {
      checkedOnline = true;
      const preview = await request<LinkPreview>(session.origin, "/api/v1/links/preview?url=" + encodeURIComponent(tab.url),
        session.token, undefined, 10000);
      if (sequence !== feedRequest) return;
      detected = preview.kind;
      if (preview.kind === "unsupported") note("This tab doesn’t contain an article, feed or PDF.");
      feeds = [...(preview.feeds ?? []), ...feeds];
      if (preview.kind === "feed" && !feeds.length) feeds = [{ url: tab.url, title: preview.title ?? "" }];
      if (preview.kind === "article" && !feeds.length) {
        feeds = await request<FeedChoice[]>(session.origin,
          "/api/v1/feeds/discover?probe=true&url=" + encodeURIComponent(tab.url), session.token, undefined, 8000);
      }
    } catch { /* A manual PDF choice is available when the preview is inconclusive. */ }
  }
  if (sequence !== feedRequest) return;
  findingFeeds = false;
  const previous = picker.value;
  picker.replaceChildren();
  const seen = new Set<string>();
  for (const feed of feeds) {
    try {
      const url = webURL(feed.url);
      if (isPDFURL(url) || seen.has(url.href)) continue;
      seen.add(url.href);
      picker.add(new Option(feed.title || url.hostname, url.href));
    } catch { continue; }
  }
  if (seen.has(previous)) picker.value = previous;
  renderActions();
}

function update(state: State) {
  const wasOnline = current.online;
  const changedSession = current.session?.origin !== state.session?.origin || current.session?.token !== state.session?.token;
  current = state;
  if (changedSession) {
    ++tagRequest;
    ++feedRequest;
    findingFeeds = false;
    checkedOnline = false;
    if (detected !== "pdf") detected = undefined;
    picker.replaceChildren();
    input("save-as-pdf").checked = false;
    tags.reset();
  }
  const category = changedSession ? "" : categoryPicker.value;
  categoryPicker.replaceChildren(new Option("Uncategorized", ""),
    ...state.feedCategories.map(item => new Option(item.name, item.id)));
  categoryPicker.value = state.feedCategories.some(item => item.id === category) ? category : "";
  tags.setRecent(state.recentTags);
  render(state);
  if (changedSession || !wasOnline) loadTags();
  if ((changedSession || !wasOnline) && state.session) void findFeeds();
}
button("settings-toggle").onclick = () => {
  const form = el("settings");
  form.hidden = !form.hidden;
  button("settings-toggle").setAttribute("aria-expanded", String(!form.hidden));
  el("save").hidden = !current.session || !form.hidden;
  tags.close();
  if (!form.hidden) {
    input("origin").value = current.settings.origin;
    select("theme").value = current.settings.theme;
    select("accent").value = current.settings.accent;
  }
  renderActions();
};
el<HTMLFormElement>("settings-form").onsubmit = event => {
  event.preventDefault();
  void (async () => {
    const origin = apiOrigin(input("origin").value);
    const url = new URL(origin);
    if (url.protocol === "https:" && !await chrome.permissions.request({ origins: [`https://${url.hostname}/*`] }))
      throw new Error("Allow access to the API host to use it.");
    await send({ type: "settings", settings: { origin, theme: select("theme").value, accent: select("accent").value } });
    update(await send<State>({ type: "state" }));
    note("Settings saved.");
    button("settings-toggle").click();
  })().catch(report);
};
el<HTMLFormElement>("connect").onsubmit = event => {
  event.preventDefault();
  const type = (event.submitter as HTMLButtonElement | null)?.value === "signup" ? "signup" : "connect";
  void send<State>({ type, username: input("username").value }).then(state => {
    input("username").value = "";
    update(state);
    note("Signed in.");
  }).catch(report);
};
button("auth").onclick = () => {
  void send<State>({ type: "signOut" }).then(state => { update(state); note(""); }).catch(report);
};
button("sync").onclick = () => {
  void send<State>({ type: "sync" }).then(state => { update(state); loadTags(); }).then(findFeeds).catch(report);
};
picker.onchange = renderActions;
input("save-as-pdf").onchange = () => { renderActions(); button("settings-toggle").click(); };
el<HTMLFormElement>("save").onsubmit = event => {
  event.preventDefault();
  if (submitting || !valid || !tab?.url || !current.session || detected === "unsupported") return;
  const action = (event.submitter as HTMLButtonElement | null)?.value;
  const subscribeOnly = action === "subscribe";
  const both = action === "both";
  const feed = selectedFeed();
  const pdf = savingPDF();
  if ((pdf && (subscribeOnly || both)) || (detected === "feed" && !subscribeOnly) || (findingFeeds && !pdf)) return;
  if ((subscribeOnly || both) && !feed) return;

  let message: object;
  if (subscribeOnly) {
    message = { type: "subscribe", feed: { ...feed, category_id: categoryPicker.value || undefined } };
  } else {
    const selectedTags = tags.forSave();
    if (!selectedTags) return;
    message = { type: "save", article: {
      url: tab.url, title: (tab.title ?? "").slice(0, 500), tags: selectedTags,
      document_type: pdf ? "pdf" : "article",
      subscribe_url: both ? feed?.url : undefined,
      subscribe_category_id: both ? categoryPicker.value || undefined : undefined,
    } };
  }

  submitting = true;
  el("action-feedback").textContent = "";
  renderActions();
  void send<{ id: string }>(message).then(({ id }) => {
    confirmation = { id, deliveredText: subscribeOnly ? "Subscribed to feed."
      : both ? "Saved to Read Later and subscribed to feed." : pdf ? "PDF link saved." : "Saved to Read Later." };
    const delivery = earlyDeliveries.get(id);
    earlyDeliveries.clear();
    if (delivery) updateDelivery(delivery);
    else showActionFeedback("Queued. It will sync automatically.", "queued");
  }).catch(error => {
    earlyDeliveries.clear();
    showActionFeedback(error instanceof Error ? error.message : "Request failed.", "error");
  });
};
chrome.runtime.onMessage.addListener((delivery: DeliveryUpdate, sender) => {
  if (delivery.type !== "delivery" || sender.id !== chrome.runtime.id || !submitting) return;
  if (confirmation) updateDelivery(delivery);
  else earlyDeliveries.set(delivery.id, delivery);
});
chrome.storage.onChanged.addListener(changes => {
  if (Object.keys(changes).some(key => key === "settings" || key === "session" || key === "online" ||
      key.startsWith("save:") || key.startsWith("recent-tags:") || key.startsWith("feed-categories:"))) {
    void send<State>({ type: "state" }).then(update).catch(report);
  }
});

async function checkLocalBuild() {
  try {
    const running = chrome.runtime.getManifest().version_name;
    if (!running?.includes(" (local ")) return;
    const response = await fetch(chrome.runtime.getURL("manifest.json"), { cache: "no-store" });
    if (!response.ok) return;
    const { version_name: installed } = await response.json();
    button("reload-extension").hidden = typeof installed !== "string" ||
      !installed.includes(" (local ") || installed === running;
  } catch (error) {
    // A missing build is temporary, but a reloaded extension invalidates this popup.
    handleInvalidContext(error);
  }
}

button("reload-extension").onclick = () => {
  if (submitting) return;
  try {
    chrome.runtime.reload();
  } catch (error) {
    report(error);
  }
};
const buildCheck = window.setInterval(() => void checkLocalBuild(), 3000);
window.addEventListener("pagehide", () => window.clearInterval(buildCheck), { once: true });
void checkLocalBuild();

void (async () => {
  update(await send<State>({ type: "state" }));
  [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.url) {
    try {
      const url = webURL(tab.url);
      valid = true;
      if (isPDFURL(url)) detected = "pdf";
      el("article").textContent = tab.title || url.hostname;
      el("source").textContent = url.hostname;
    } catch { note("Open a web page to save it. Local PDFs can be uploaded from the Mac app."); }
  }
  renderActions();
  void send<State>({ type: "sync" }).then(update).then(findFeeds).catch(report);
  if (valid) await findFeeds();
})().catch(report);
