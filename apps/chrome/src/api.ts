import { defaultPalette } from "./palettes.js";

export const defaultSettings = {
  origin: "http://127.0.0.1:12000",
  theme: "system",
  accent: defaultPalette,
};

export type Settings = typeof defaultSettings;
export type Profile = { username?: string; id: string; name: string; email: string; picture: string };
export type Session = { origin: string; token: string; profile: Profile };
export type Save = { url: string; title: string; tags: string[]; subscribe_url?: string; document_type?: "article" | "pdf" };
export type FeedChoice = { url: string; title: string };
export type LinkPreview = { kind: "article" | "pdf" | "feed" | "unsupported"; title?: string; feeds?: FeedChoice[] };
export type QueueAction = { article: Save; feed?: never } | { feed: FeedChoice; article?: never };
export type QueuedAction = QueueAction & { id: string; origin: string; account?: string; error?: string };
export type DeliveryUpdate = { type: "delivery"; id: string; error?: string };

export function webURL(value: string): URL {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.href.length > 4000)
    throw new Error("Use a valid HTTP or HTTPS URL.");
  return url;
}

export function isPDFURL(url: URL): boolean {
  return url.pathname.toLowerCase().endsWith(".pdf");
}

export function apiOrigin(input: string): string {
  const url = new URL(input.trim());
  const loopback = ["localhost", "127.0.0.1"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(loopback && url.protocol === "http:")) ||
      url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("Use an HTTPS origin or a local HTTP URL such as http://127.0.0.1:12000.");
  }
  return url.origin;
}

export class APIError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export async function request<T>(origin: string, path: string, token?: string, body?: unknown, timeout = 5500): Promise<T> {
  const headers = new Headers();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (body !== undefined) headers.set("Content-Type", "application/json");
  const response = await fetch(origin + path, {
    method: body === undefined ? "GET" : "POST", headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "omit", redirect: "error", cache: "no-store", signal: AbortSignal.timeout(timeout),
  });
  if (!response.ok) {
    const detail = (await response.json().catch(() => ({}))).detail;
    throw new APIError(response.status, typeof detail === "string" ? detail :
      detail?.message ?? `Backend returned HTTP ${response.status}.`);
  }
  return (response.status === 204 ? undefined : await response.json()) as T;
}
