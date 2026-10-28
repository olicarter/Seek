import { createSignal } from "solid-js";

// The server's pages (Server/Pages.swift), as JSON.

export type Status = {
  soulseek: string;
  username?: string;
  signedIn: boolean;
  downloading: number;
  failure?: string;
  bandcamp?: string;
  bandcampSigningIn: boolean;
};

export type Release = {
  id: string;
  artist: string;
  title: string;
  year?: number;
  kind?: string;
  artwork?: string;
  copies: number;
  lossless: boolean;
  bandcamp: boolean;
  inLibrary: boolean;
  adding: boolean;
};

export type SearchPage = { query: string; searching: boolean; releases: Release[] };

export type Song = {
  kind: "have" | "missing" | "arriving";
  number?: number;
  disc: number;
  title: string;
  artist?: string;
  duration?: number;
  file?: string;
  available: boolean;
  progress?: number;
  lossless?: boolean;
};

export type AlbumPage = {
  artist: string;
  title: string;
  year?: number;
  artwork?: string;
  songs: Song[];
  footer: string;
  listed: boolean;
  inLibrary: boolean;
  canAdd: boolean;
  adding: boolean;
  lookingForCopies: boolean;
  copies: number;
  bandcamp?: { owned: boolean; page?: string; price?: string; downloading?: number };
};

export type ArtistPage = {
  name: string;
  albums: LibraryAlbum[];
  sections: { title: string; releases: { title: string; year: number; artwork?: string }[] }[];
};

export type LibraryAlbum = { artist: string; title: string; year?: number; artwork: string; songs: number };

export type Download = {
  id: string;
  name: string;
  album: string;
  user: string;
  state: string;
  active: boolean;
  progress: number;
  speed: number;
};

/** Which album page to open: by name, and the search result it came from, if any. */
export type AlbumRef = { artist: string; title: string; release?: string };

const SERVER_KEY = "seek.server";
const PAIRING_KEY = "seek.key";

function stored(name: string): string | null {
  try {
    return localStorage.getItem(name);
  } catch {
    return null;
  }
}

// The pairing link (from /pair on the Mac) ends #key=…: kept, then taken out of the address.
const pairing = new URLSearchParams(location.hash.slice(1)).get("key");
if (pairing) {
  try {
    localStorage.setItem(PAIRING_KEY, pairing);
  } catch {
    // Not kept: this page can still use it until it's closed.
  }
  history.replaceState(null, "", location.pathname + location.search);
}
const key = pairing ?? stored(PAIRING_KEY);

/** Whether this browser has the server's key (or doesn't need one: the Mac serving the page). */
export const isPaired = () => key !== null || !serverAddress();

/**
 * Where the server on the Mac is. The Mac serves the site itself at its own address; the copy on
 * 4n.studio is built with the Mac's tailnet address, which Settings can change for this browser.
 */
export function serverAddress(): string {
  // Storage can be off (a private window): the built-in address, then.
  return (stored(SERVER_KEY) ?? import.meta.env.VITE_SEEK_SERVER ?? "").replace(/\/$/, "");
}

export function setServerAddress(address: string) {
  try {
    if (address.trim()) localStorage.setItem(SERVER_KEY, address.trim());
    else localStorage.removeItem(SERVER_KEY);
  } catch {
    // Not kept, but used until the page reloads.
  }
  location.reload();
}

/** A path on the server (`/api/…`, `/files/…`) as an address; others (Apple's, Bandcamp's art) as they are. */
export function media(path: string): string;
export function media(path?: string): string | undefined;
export function media(path?: string): string | undefined {
  if (!path?.startsWith("/")) return path;
  // Audio, images and the event stream can't send headers: the key goes in the address.
  const withKey = key ? `${path}${path.includes("?") ? "&" : "?"}key=${encodeURIComponent(key)}` : path;
  return serverAddress() + withKey;
}

/** The server said this browser isn't paired. */
export class NotPaired extends Error {}

function headers(extra: Record<string, string> = {}): Record<string, string> {
  return key ? { ...extra, "X-Seek-Key": key } : extra;
}

function check(response: Response, path: string) {
  if (response.status === 401) throw new NotPaired();
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
}

async function get<T>(path: string): Promise<T> {
  const response = await fetch(serverAddress() + path, { headers: headers() });
  check(response, path);
  return response.json();
}

async function post<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(serverAddress() + path, {
    method: "POST",
    headers: headers({ "Content-Type": "application/json" }),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  check(response, path);
  return response.json();
}

function albumQuery(ref: AlbumRef): string {
  const params = new URLSearchParams({ artist: ref.artist, title: ref.title });
  if (ref.release) params.set("release", ref.release);
  return params.toString();
}

export const api = {
  status: () => get<Status>("/api/status"),
  login: (username: string, password: string) => post<Status>("/api/login", { username, password }),
  logout: () => post<Status>("/api/logout"),
  search: (query: string) => post<SearchPage>("/api/search", { query }),
  searchPage: () => get<SearchPage>("/api/search"),
  album: (ref: AlbumRef) => get<AlbumPage>(`/api/album?${albumQuery(ref)}`),
  add: (ref: AlbumRef) => post<AlbumPage>("/api/album/add", ref),
  library: () => get<LibraryAlbum[]>("/api/library"),
  downloads: () => get<Download[]>("/api/downloads"),
  takeFailure: () => post<{ message?: string }>("/api/failure/take"),
  artist: (name: string) => get<ArtistPage>(`/api/artist?name=${encodeURIComponent(name)}`),
  bandcampSignIn: () => post<Status>("/api/bandcamp/signin"),
  bandcampSignOut: () => post<Status>("/api/bandcamp/signout"),
  buying: () => post<{ ok: boolean }>("/api/bandcamp/buying"),
};

export function albumHref(ref: AlbumRef): string {
  return `/album?${albumQuery(ref)}`;
}

export function artistHref(name: string): string {
  return `/artist?name=${encodeURIComponent(name)}`;
}

/**
 * Bumped whenever the server says something shown may have changed: pages refetch on it.
 * At most every half second, so a busy search or download doesn't refetch constantly.
 */
// From 1: a resource with a falsy source never fetches, so a page would wait for the first event.
const [changes, setChanges] = createSignal(1);
export { changes };

let pending: number | undefined;
function connect() {
  const events = new EventSource(media("/api/events"));
  events.onmessage = () => {
    if (pending !== undefined) return;
    pending = window.setTimeout(() => {
      pending = undefined;
      setChanges((n) => n + 1);
    }, 500);
  };
  events.onerror = () => {
    events.close();
    window.setTimeout(connect, 2000);
  };
}
connect();
